#!/usr/bin/env python3
"""muelsyse-imecaret 的端到端测试：在私有 session bus 上模拟 fcitx-qt5 插件的调用。

用法（不会碰真实会话的 bus）:
    dbus-run-session -- python3 scripts/tests/test_imecaret_dbus.py
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time

import dbus

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "muelsyse-imecaret.py")
IM = ("org.freedesktop.portal.Fcitx", "/org/freedesktop/portal/inputmethod")


def wait_for(pred, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


class Reader:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(path)
        self.sock.settimeout(3)
        self.buf = b""

    def next(self):
        while b"\n" not in self.buf:
            self.buf += self.sock.recv(4096)
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)


def main():
    assert "DBUS_SESSION_BUS_ADDRESS" in os.environ, "run under dbus-run-session"
    tmp = tempfile.mkdtemp()
    path = os.path.join(tmp, "caret.sock")
    proc = subprocess.Popen([sys.executable, DAEMON, "--socket", path])
    try:
        bus = dbus.SessionBus()
        assert wait_for(lambda: bus.name_has_owner(IM[0]) and os.path.exists(path)), "daemon did not start"
        r = Reader(path)
        assert r.next()["caret"] is None

        im = dbus.Interface(bus.get_object(*IM), "org.fcitx.Fcitx.InputMethod1")
        ic_path, uid = im.CreateInputContext([("program", "wechat"), ("display", "x11:")])
        assert len(uid) == 16
        ic = dbus.Interface(bus.get_object(IM[0], ic_path), "org.fcitx.Fcitx.InputContext1")

        ic.SetCursorRect(10, 20, 2, 30)          # 未聚焦：不广播
        assert ic.ProcessKeyEvent(0x61, 38, 0, False, 0) is not True
        ic.FocusIn()
        msg = r.next()
        assert msg == {"caret": {"x": 10, "y": 20, "w": 2, "h": 30}, "app": "wechat", "src": "fcitx"}, msg
        ic.SetCursorRect(100, 200, 0, 28)
        assert r.next()["caret"] == {"x": 100, "y": 200, "w": 0, "h": 28}

        # 第二个 app 抢到焦点后，第一个迟到的 FocusOut 不能清掉它
        ic2_path, _ = im.CreateInputContext([("program", "wps")])
        ic2 = dbus.Interface(bus.get_object(IM[0], ic2_path), "org.fcitx.Fcitx.InputContext1")
        ic2.SetCursorRect(5, 6, 1, 20)
        ic2.FocusIn()
        assert r.next()["app"] == "wps"
        ic.FocusOut()
        ic2.SetCursorRect(7, 8, 1, 20)
        msg = r.next()
        assert msg["app"] == "wps" and msg["caret"]["x"] == 7, msg

        # 晚连上的客户端先拿到当前状态
        r2 = Reader(path)
        assert r2.next()["caret"]["x"] == 7

        ic2.DestroyIC()
        assert r.next()["caret"] is None

        # app 断开总线：它的输入上下文被清掉
        child = subprocess.run([sys.executable, "-c", f"""
import dbus,time
b=dbus.SessionBus()
im=dbus.Interface(b.get_object({IM[0]!r},{IM[1]!r}),'org.fcitx.Fcitx.InputMethod1')
p,_=im.CreateInputContext([('program','kid')])
ic=dbus.Interface(b.get_object({IM[0]!r},p),'org.fcitx.Fcitx.InputContext1')
ic.SetCursorRect(1,1,1,9); ic.FocusIn(); time.sleep(0.3)
"""], check=True)
        assert r.next()["app"] == "kid"
        assert r.next()["caret"] is None
        print("PASS test_imecaret_dbus")
    finally:
        proc.terminate()
        proc.wait(timeout=5)
    assert not os.path.exists(path), "socket not cleaned up"


if __name__ == "__main__":
    main()
