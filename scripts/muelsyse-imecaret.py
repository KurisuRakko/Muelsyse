#!/usr/bin/env python3
"""远程 app 的输入光标位置传感器：冒充 fcitx 的 DBus portal，只收光标矩形。

浏览器端输入法的候选框要跟随远程 app 的光标，服务端就得知道光标在哪。X11 上的 Qt app
（WeChat、WPS）自带 fcitx 输入上下文插件，只要以 `QT_IM_MODULE=fcitx` 启动，就会在
session bus 上找 `org.freedesktop.portal.Fcitx`，并在每次光标移动时调
`InputContext1.SetCursorRect`，传的是 X 根窗口坐标（native 像素）。本进程占用这个名字，
记下「当前获得焦点的输入上下文」及其光标矩形，经 unix socket 推给 Selkies。

它不是输入法：`ProcessKeyEvent` 一律立即返回 false（键原样交还 app），从不发
`CommitString`。文字仍走 Selkies 自己的上屏通道。本进程不在时，
插件找不到服务，按键直通 app，和没装插件时一样。

socket 协议：每行一个 JSON，连接建立时先发一次当前状态，之后每次变化发一行：
    {"caret": {"x": 1, "y": 2, "w": 3, "h": 4} | null, "app": "wechat", "src": "fcitx"}
坐标是 X 根窗口像素（Xwayland 缩放开着时就是视频帧像素）。

用法:
    muelsyse-imecaret.py [--socket PATH] [--verbose]
socket 默认 `$XDG_RUNTIME_DIR/muelsyse-imecaret.sock`，可用 MUELSYSE_IMECARET_SOCKET 覆盖。
"""

import argparse
import json
import logging
import os
import socket
import stat
import struct
import sys
import uuid

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

PORTAL_SERVICE = "org.freedesktop.portal.Fcitx"
IM_PATH = "/org/freedesktop/portal/inputmethod"
IM_IFACE = "org.fcitx.Fcitx.InputMethod1"
IC_IFACE = "org.fcitx.Fcitx.InputContext1"
IC_PATH_PREFIX = "/org/freedesktop/portal/inputcontext/"
# 一个读得慢的客户端最多积压这么多字节，超过就断开它，绝不阻塞 DBus 主循环。
MAX_CLIENT_BACKLOG = 64 * 1024

log = logging.getLogger("muelsyse-imecaret")


class CaretState:
    """焦点输入上下文与它的光标矩形；变化时通知 sink。"""

    def __init__(self, sink):
        self._sink = sink
        self.focused = None
        self._last = None

    def snapshot(self):
        ic = self.focused
        rect = ic.rect if ic is not None else None
        return {
            "caret": None if rect is None else dict(zip(("x", "y", "w", "h"), rect)),
            "app": ic.program if ic is not None else "",
            "src": "fcitx",
        }

    def changed(self):
        snap = self.snapshot()
        if snap == self._last:
            return
        self._last = snap
        log.debug("caret %s", snap)
        self._sink(snap)

    def focus_in(self, ic):
        self.focused = ic
        self.changed()

    def focus_out(self, ic):
        # 另一个 app 的 FocusIn 可能先于这个 FocusOut 到达，只清自己。
        if self.focused is ic:
            self.focused = None
            self.changed()

    def rect_changed(self, ic):
        if self.focused is ic:
            self.changed()


class InputContext(dbus.service.Object):
    """一个 app 内的输入上下文。只记位置，不处理任何按键。"""

    def __init__(self, bus, path, owner, program, state, registry):
        super().__init__(bus, path)
        self.path = path
        self.owner = owner
        self.program = program
        self.rect = None
        self._state = state
        self._registry = registry

    def destroy(self):
        self._state.focus_out(self)
        self._registry.pop(self.path, None)
        try:
            self.remove_from_connection()
        except LookupError:
            pass

    def _from_owner(self, sender):
        # 只接受创建者本人的调用，别的连接拿到路径也改不了状态。
        return sender == self.owner

    @dbus.service.method(IC_IFACE, in_signature="", out_signature="", sender_keyword="sender")
    def FocusIn(self, sender=None):
        if self._from_owner(sender):
            self._state.focus_in(self)

    @dbus.service.method(IC_IFACE, in_signature="", out_signature="", sender_keyword="sender")
    def FocusOut(self, sender=None):
        if self._from_owner(sender):
            self._state.focus_out(self)

    @dbus.service.method(IC_IFACE, in_signature="iiii", out_signature="", sender_keyword="sender")
    def SetCursorRect(self, x, y, w, h, sender=None):
        if not self._from_owner(sender):
            return
        # Qt 在光标无效时不调；仍防一手 0x0 或负尺寸。
        if w < 0 or h <= 0:
            return
        self.rect = (int(x), int(y), int(w), int(h))
        self._state.rect_changed(self)

    @dbus.service.method(IC_IFACE, in_signature="iiiid", out_signature="", sender_keyword="sender")
    def SetCursorRectV2(self, x, y, w, h, scale, sender=None):
        self.SetCursorRect(x, y, w, h, sender=sender)

    @dbus.service.method(IC_IFACE, in_signature="", out_signature="", sender_keyword="sender")
    def DestroyIC(self, sender=None):
        if self._from_owner(sender):
            self.destroy()

    @dbus.service.method(IC_IFACE, in_signature="uuubu", out_signature="b")
    def ProcessKeyEvent(self, keyval, keycode, state, is_release, time):
        return False

    @dbus.service.method(IC_IFACE, in_signature="", out_signature="")
    def Reset(self):
        pass

    @dbus.service.method(IC_IFACE, in_signature="t", out_signature="")
    def SetCapability(self, caps):
        pass

    @dbus.service.method(IC_IFACE, in_signature="t", out_signature="")
    def SetSupportedCapability(self, caps):
        pass

    @dbus.service.method(IC_IFACE, in_signature="suu", out_signature="")
    def SetSurroundingText(self, text, cursor, anchor):
        pass

    @dbus.service.method(IC_IFACE, in_signature="uu", out_signature="")
    def SetSurroundingTextPosition(self, cursor, anchor):
        pass

    # 插件声明了这些信号；我们从不发，但 introspection 里得有。
    @dbus.service.signal(IC_IFACE, signature="s")
    def CommitString(self, text):
        pass

    @dbus.service.signal(IC_IFACE, signature="sss")
    def CurrentIM(self, name, unique_name, lang):
        pass


class InputMethod(dbus.service.Object):
    """`CreateInputContext` 的入口；还负责 app 退出时清掉它的输入上下文。"""

    def __init__(self, bus, state):
        super().__init__(bus, IM_PATH)
        self._bus = bus
        self._state = state
        self._next_id = 1
        self.contexts = {}
        bus.add_signal_receiver(
            self._name_owner_changed,
            signal_name="NameOwnerChanged",
            dbus_interface="org.freedesktop.DBus",
            path="/org/freedesktop/DBus",
        )

    @dbus.service.method(IM_IFACE, in_signature="a(ss)", out_signature="oay", sender_keyword="sender")
    def CreateInputContext(self, args, sender=None):
        info = {str(k): str(v) for k, v in args}
        path = f"{IC_PATH_PREFIX}{self._next_id}"
        self._next_id += 1
        program = info.get("program", "")
        self.contexts[path] = InputContext(self._bus, path, sender, program, self._state, self.contexts)
        log.info("新输入上下文 %s program=%r owner=%s", path, program, sender)
        return dbus.ObjectPath(path), dbus.ByteArray(uuid.uuid4().bytes)

    def _name_owner_changed(self, name, old, new):
        if new or not name.startswith(":"):
            return
        for ic in [ic for ic in self.contexts.values() if ic.owner == name]:
            log.info("%s 已断开，清掉 %s", name, ic.path)
            ic.destroy()


class CaretSocket:
    """unix socket 广播。非阻塞发送，积压过多的客户端直接断开。"""

    def __init__(self, path):
        self.path = path
        self._clients = {}
        self._current = b""
        self._server = None

    def open(self):
        try:
            st = os.lstat(self.path)
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISSOCK(st.st_mode):
                raise RuntimeError(f"{self.path} 已存在且不是 socket，拒绝覆盖")
            os.unlink(self.path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_NONBLOCK | socket.SOCK_CLOEXEC)
        old_umask = os.umask(0o177)
        try:
            srv.bind(self.path)
        finally:
            os.umask(old_umask)
        srv.listen(8)
        self._server = srv
        GLib.io_add_watch(srv.fileno(), GLib.IO_IN, self._accept)

    def close(self):
        for conn in list(self._clients):
            self._drop(conn)
        if self._server is not None:
            self._server.close()
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass

    def publish(self, snapshot):
        self._current = (json.dumps(snapshot, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        for conn in list(self._clients):
            self._queue(conn, self._current)

    def _accept(self, fd, cond):
        try:
            conn, _ = self._server.accept()
        except OSError:
            return True
        _pid, uid, _gid = struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        if uid != os.getuid():
            conn.close()
            return True
        conn.setblocking(False)
        self._clients[conn] = {"buf": b"", "watch": None,
                               "hup": GLib.io_add_watch(conn.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self._on_readable, conn)}
        if self._current:
            self._queue(conn, self._current)
        return True

    def _on_readable(self, fd, cond, conn):
        # 客户端不该发东西；读到 EOF 或出错就断开。
        try:
            data = conn.recv(4096)
        except BlockingIOError:
            return True
        except OSError:
            data = b""
        if not data or cond & (GLib.IO_HUP | GLib.IO_ERR):
            self._drop(conn)
            return False
        return True

    def _queue(self, conn, data):
        client = self._clients.get(conn)
        if client is None:
            return
        client["buf"] += data
        if len(client["buf"]) > MAX_CLIENT_BACKLOG:
            log.warning("socket 客户端积压过多，断开")
            self._drop(conn)
            return
        self._flush(conn)

    def _flush(self, conn, *_):
        client = self._clients.get(conn)
        if client is None:
            return False
        try:
            while client["buf"]:
                sent = conn.send(client["buf"])
                client["buf"] = client["buf"][sent:]
        except BlockingIOError:
            pass
        except OSError:
            self._drop(conn)
            return False
        if client["buf"] and client["watch"] is None:
            client["watch"] = GLib.io_add_watch(conn.fileno(), GLib.IO_OUT, self._on_writable, conn)
        return True

    def _on_writable(self, fd, cond, conn):
        client = self._clients.get(conn)
        if client is None:
            return False
        self._flush(conn)
        client = self._clients.get(conn)
        if client is None:
            return False
        if client["buf"]:
            return True
        client["watch"] = None
        return False

    def _drop(self, conn):
        # 在自己的回调里移除 source 也安全：GLib 发现它已销毁，就不再处理回调的返回值。
        client = self._clients.pop(conn, None)
        if client is None:
            return
        for source in (client["watch"], client["hup"]):
            if source is not None:
                GLib.source_remove(source)
        conn.close()


def default_socket_path():
    override = os.environ.get("MUELSYSE_IMECARET_SOCKET")
    if override:
        return override
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        raise SystemExit("XDG_RUNTIME_DIR 未设置，无法确定 socket 路径")
    return os.path.join(runtime, "muelsyse-imecaret.sock")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", default=None, help="unix socket 路径")
    parser.add_argument("--verbose", action="store_true")
    opts = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if opts.verbose else logging.INFO,
                        format="%(name)s: %(message)s")

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    sock = CaretSocket(opts.socket or default_socket_path())
    sock.open()
    state = CaretState(sock.publish)
    InputMethod(bus, state)

    reply = bus.request_name(PORTAL_SERVICE, dbus.bus.NAME_FLAG_DO_NOT_QUEUE)
    if reply not in (dbus.bus.REQUEST_NAME_REPLY_PRIMARY_OWNER, dbus.bus.REQUEST_NAME_REPLY_ALREADY_OWNER):
        sock.close()
        log.error("%s 已被占用（真的 fcitx 在跑？），退出", PORTAL_SERVICE)
        return 1
    log.info("已占用 %s，socket %s", PORTAL_SERVICE, sock.path)
    sock.publish(state.snapshot())

    loop = GLib.MainLoop()
    for sig in (2, 15):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, loop.quit)
    try:
        loop.run()
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
