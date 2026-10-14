#!/usr/bin/env python3
"""为 KWin 自管的 Xwayland 准备 X11 监听 socket 与 Xauthority，然后 exec 成 KWin。

用法:
    selkies-xwayland-listen.py --display :0 --xauth-file <path> \
        --socket-dir <X11 socket 目录> --lock-dir <X11 lock 目录> -- <kwin_bin> <kwin 参数...>

--socket-dir 与 --lock-dir 都是必填、没有默认值，这是从一次真实事故里学到的：
这两个参数过去默认指向 /tmp/.X11-unix 与 /tmp，而准备流程会 unlink 掉目标路径上的
旧 socket 与 lock，于是任何忘了传参的测试脚本都会删掉**生产会话正在用**的 X11
socket，主机上所有 X11 客户端当场连不上，只能重启 wayland 服务才恢复。真正需要
默认值的调用方（launcher 里）本来就显式传这两个参数，所以这个默认值只服务于测试，
却带来了破坏生产的能力——必填是唯一安全的做法。

本进程不留驻: 准备完成后 os.execv 替换成 KWin，所以调用方拿到的 pid 始终就是
KWin 自己的 pid。
"""

import argparse
import errno
import os
import re
import secrets
import socket
import stat
import struct
import sys
import tempfile

LISTEN_BACKLOG = 128
COOKIE_LENGTH = 16
FAMILY_LOCAL = 256
# 全 1 的 family 表示 FamilyWild：不限定地址，任何来源都能用这条 cookie。
FAMILY_WILD = 65535
AUTH_NAME = b"MIT-MAGIC-COOKIE-1"


def fail(message):
    print(message, file=sys.stderr)
    return 1


def peer_is_listening(socket_path):
    """connect 探测：能连上就一定有人在服务这个路径。

    这是只读判断，探测失败不代表路径没人占（见 probe_socket_path），所以它只用来
    走"确定被占用"的快路径。陈旧残留（进程已死、文件还在）会得到 ECONNREFUSED 或
    ENOENT，据此区分"有活的 X 服务器"与"可能是垃圾文件"。
    """
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(0.2)
        probe.connect(socket_path)
    except OSError:
        return False
    finally:
        probe.close()
    return True


def process_is_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # 进程存在但不属于当前用户，仍然算占用。
        return True
    except OSError:
        return False
    return True


def read_lock_pid(lock_path):
    try:
        with open(lock_path, "r", encoding="ascii", errors="replace") as handle:
            content = handle.read()
    except OSError:
        return None
    stripped = content.strip()
    if not stripped.isdigit():
        return None
    return int(stripped)


def probe_socket_path(socket_path, lock_path, display):
    """拿回 X<N> 这个路径，判定它到底是"被活会话占用"还是"可清理的垃圾"。

    成功时返回 (socket, None)：socket 已经 bind 好但还没 listen，就是最终要交给
    KWin 的那个。失败时返回 (None, 退出码)，错误信息已经打到 stderr。

    先用 connect 探测（只读）抓"确定有活的 X 服务器"，再用 bind 探测做权威判定：
    bind 成功就证明这个路径上没有活进程，那么刚才删掉的就是垃圾文件；bind 以
    EADDRINUSE 失败就说明路径另有一个 still-open 的 socket，属于被占用，就此退出。
    两种信号都要是因为它们互补：connect 对"bind 了但没 listen"的 socket 会失败，
    而 bind 探测必须先 unlink，光靠它会在无人占用时误判。probe 结束后 fd 一直开着，
    所以这个路径在 listen 之前不会被第三方抢走。
    """
    if os.path.exists(socket_path) and peer_is_listening(socket_path):
        return None, fail("XWAYLAND_PREP_FAIL display %s busy" % display)

    for path in (socket_path, lock_path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            continue

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        # 只传文件系统路径（不以 "\0" 开头），确保绝不绑 abstract 名字。
        server.bind(socket_path)
    except OSError as exc:
        server.close()
        if exc.errno == errno.EADDRINUSE:
            return None, fail("XWAYLAND_PREP_FAIL display %s busy" % display)
        return None, fail(
            "XWAYLAND_PREP_FAIL cannot occupy %s: %s" % (socket_path, exc)
        )

    # display 号不能因为发现残留就偷偷换号：这个号要塞进 systemd/D-Bus 的 DISPLAY
    # 给整个会话用，换了号菜单和 krunner 起的 X11 客户端就会连到别处。
    return server, None


def prepare_socket_dir(socket_dir):
    """确保 socket 目录存在且是 X 惯例的 01777。

    只在目录是我们自己新建时才设权限：/tmp/.X11-unix 这类目录通常由 systemd-tmpfiles
    以 root 预建好，服务以普通用户运行，而 Linux 上非属主 chmod 一律 EPERM——与目标
    权限是否已经正确无关。因此对已存在的目录只做检查，权限不合适也只警告不致命：
    目录能不能用最终由后面的 bind 决定。
    """
    if os.path.isdir(socket_dir):
        st = os.stat(socket_dir)
        # sticky 位 + other-writable 已经是 X 目录该有的样子，什么都不用做。
        if stat.S_IMODE(st.st_mode) & 0o1002 == 0o1002:
            return 0
        try:
            os.chmod(socket_dir, 0o1777)
        except OSError as exc:
            print(
                "XWAYLAND_PREP_WARN cannot chmod existing socket dir %s: %s" % (socket_dir, exc),
                file=sys.stderr,
            )
        return 0

    try:
        os.mkdir(socket_dir, 0o1777)
    except OSError as exc:
        return fail("XWAYLAND_PREP_FAIL cannot create socket dir %s: %s" % (socket_dir, exc))
    # mkdir 的 mode 受 umask 限制，所以创建后补一次；这时目录属于自己，chmod 必成功。
    try:
        os.chmod(socket_dir, 0o1777)
    except OSError as exc:
        return fail("XWAYLAND_PREP_FAIL cannot chmod socket dir %s: %s" % (socket_dir, exc))
    return 0


def listen_on_socket(server, socket_path):
    """把已经占好路径的 socket 切成监听态。

    这样建出来的只可能是文件系统 socket：abstract socket 活在网络命名空间里，同一
    netns 下的其它容器可以直接连上，而 X11 连上之后没有任何鉴权，等于把键盘交出去。
    路径 socket 至少要穿过目录权限，KWin 再用 cookie 做第二道门槛。
    """
    # 权限设在 socket *文件* 上（对 AF_UNIX fd 调 fchmod 在某些内核上直接 EINVAL），
    # 且安排在 listen 之前，避免出现"已经可连但权限还没放宽/收紧"的窗口。
    try:
        os.chmod(socket_path, 0o777)
    except OSError as exc:
        server.close()
        return fail("XWAYLAND_PREP_FAIL cannot chmod %s: %s" % (socket_path, exc))
    try:
        server.listen(LISTEN_BACKLOG)
    except OSError as exc:
        server.close()
        return fail("XWAYLAND_PREP_FAIL cannot listen on %s: %s" % (socket_path, exc))
    return 0


def write_lock_file(lock_path):
    """按 X 服务器惯例写 pid: "%10d\\n"。

    固定宽度是历史格式，xauth/X 工具链按这个宽度解析。这里写的 pid 就是本进程 pid，
    而本进程随后会 exec 成 KWin，所以它同时是调用方（launcher）眼里的 KWin pid——两
    者相同，才让会话结束时的清理能凭 lock 判定"这个号是本会话的"。

    排他性并不来自这里的 O_EXCL：占用检查在 probe_socket_path 里已经先 unlink 过旧
    文件，真正保证同名号不会被两个会话同时占用的是那一步 unlink+bind 的原子性——
    bind 撞上别人的活 socket 会 EADDRINUSE。O_EXCL 只是兜住"同一路径被并发写入"的
    极端情况，失败即退出，不会带着半个状态继续。
    """
    try:
        fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o444)
    except OSError as exc:
        return fail("XWAYLAND_PREP_FAIL cannot create lock %s: %s" % (lock_path, exc))
    try:
        os.write(fd, ("%10d\n" % os.getpid()).encode("ascii"))
    finally:
        os.close(fd)
    return 0


def build_xauth_entry(family, address, number, data):
    def field(value):
        return struct.pack(">H", len(value)) + value

    return (
        struct.pack(">H", family)
        + field(address)
        + field(number)
        + field(AUTH_NAME)
        + field(data)
    )


def write_xauth_file(xauth_file, display_number, data):
    """直接写 Xauthority 二进制格式，不依赖 xauth 命令（容器/最小安装里没有它）。

    写两条: FamilyLocal（绑定本机 hostname）与 FamilyWild（address 为空）。Xwayland
    自己看到的 family 依连接方式而定，两条都写可以让本地与本机 hostname 两种连接
    都通过校验，避免只写一条时随机失败。
    """
    hostname = socket.gethostname().encode("utf-8")
    number = str(display_number).encode("ascii")
    payload = build_xauth_entry(FAMILY_LOCAL, hostname, number, data) + build_xauth_entry(
        FAMILY_WILD, b"", number, data
    )

    directory = os.path.dirname(os.path.abspath(xauth_file))
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        fd, temp_path = tempfile.mkstemp(prefix=".selkies-xauth-", dir=directory)
    except OSError as exc:
        return fail("XWAYLAND_PREP_FAIL cannot write xauth file %s: %s" % (xauth_file, exc))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        os.replace(temp_path, xauth_file)
    except OSError as exc:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        return fail("XWAYLAND_PREP_FAIL cannot write xauth file %s: %s" % (xauth_file, exc))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        description="准备 Xwayland 的 X11 socket 与 Xauthority，然后 exec 成 KWin"
    )
    parser.add_argument("--display", required=True, help="X11 display，形如 :0")
    parser.add_argument("--xauth-file", required=True, help="Xauthority cookie 文件路径")
    parser.add_argument(
        "--socket-dir",
        required=True,
        help=(
            "X11 socket 目录，必须显式传入，没有默认值。历史上它默认指向 /tmp/.X11-unix，"
            "而准备流程会 unlink 掉该路径下同 display 号的旧 socket，曾导致忘传参数的测试"
            "脚本删掉生产会话正在用的 X11 socket。"
        ),
    )
    parser.add_argument(
        "--lock-dir",
        required=True,
        help=(
            "X11 lock 文件目录，必须显式传入，没有默认值。历史上它默认指向 /tmp，而准备"
            "流程会 unlink 掉该路径下同 display 号的旧 lock，曾导致忘传参数的测试脚本删掉"
            "生产会话正在用的 X11 lock。"
        ),
    )
    parser.add_argument("kwin_argv", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    kwin_argv = list(args.kwin_argv)
    if kwin_argv and kwin_argv[0] == "--":
        kwin_argv = kwin_argv[1:]
    if not kwin_argv:
        return fail("XWAYLAND_PREP_FAIL missing KWin command")

    match = re.fullmatch(r":(\d+)", args.display)
    if not match:
        return fail("XWAYLAND_PREP_FAIL invalid display %s" % args.display)
    display_number = int(match.group(1))

    socket_dir = args.socket_dir
    socket_path = os.path.join(socket_dir, "X%d" % display_number)
    lock_path = os.path.join(args.lock_dir, ".X%d-lock" % display_number)

    # lock 文件里的 pid 还活着就是最硬的占用证据，先查它，避免白跑一次探测。
    if os.path.lexists(lock_path):
        lock_pid = read_lock_pid(lock_path)
        if lock_pid is not None and process_is_alive(lock_pid):
            return fail("XWAYLAND_PREP_FAIL display %s busy" % args.display)

    status = prepare_socket_dir(socket_dir)
    if status != 0:
        return status

    server, status = probe_socket_path(socket_path, lock_path, args.display)
    if server is None:
        return status

    status = listen_on_socket(server, socket_path)
    if status != 0:
        for path in (socket_path, lock_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        return status

    # lock 目录由调用方通过 --lock-dir 指定，别假设它一定存在。
    try:
        os.makedirs(os.path.dirname(os.path.abspath(lock_path)), mode=0o1777, exist_ok=True)
    except OSError as exc:
        server.close()
        for path in (socket_path, lock_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        return fail("XWAYLAND_PREP_FAIL cannot create lock dir: %s" % exc)

    status = write_lock_file(lock_path)
    if status != 0:
        server.close()
        try:
            os.unlink(socket_path)
        except OSError:
            pass
        return status

    cookie = secrets.token_bytes(COOKIE_LENGTH)
    status = write_xauth_file(args.xauth_file, display_number, cookie)
    if status != 0:
        server.close()
        for path in (socket_path, lock_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        return status

    fd = server.fileno()
    # KWin 要拿到这个 fd 才能真正把 Xwayland 接到我们建好的 socket 上（只给 fd 时
    # --xwayland-xauthority 才生效），所以 exec 前必须标记可继承。
    os.set_inheritable(fd, True)

    # KWin 与它派生的子进程都在这个环境里跑，DISPLAY/XAUTHORITY 因此对整棵会话树可见。
    os.environ["DISPLAY"] = args.display
    os.environ["XAUTHORITY"] = args.xauth_file

    # 全部用 --key=value 形式: 否则 KWin 可能把裸 fd 数字当成位置参数而不是取值。
    extra = [
        "--xwayland",
        "--xwayland-fd=%d" % fd,
        "--xwayland-display=%s" % args.display,
        "--xwayland-xauthority=%s" % args.xauth_file,
    ]
    print(
        "XWAYLAND_PREP_READY display=%s socket=%s fd=%d" % (args.display, socket_path, fd),
        file=sys.stderr,
    )
    try:
        os.execv(kwin_argv[0], kwin_argv + extra)
    except OSError as exc:
        # exec 失败说明 KWin 根本没起来，别留下没人用的 socket/lock 让下次准备误判。
        server.close()
        for path in (socket_path, lock_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        return fail("XWAYLAND_PREP_FAIL cannot exec %s: %s" % (kwin_argv[0], exc))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
