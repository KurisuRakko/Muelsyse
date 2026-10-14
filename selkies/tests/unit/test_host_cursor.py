#!/usr/bin/env python3
"""KWin host capture 的软件光标显隐状态机。

Selkies 的 CSS 光标模式要求视频里没有 KWin 合成的光标，pointer-lock 模式相反；
这个状态机必须幂等、必须把阻塞的 adapter 往返移出事件循环，并且在部署不支持
（旧 pixelflux / 旧 KWin adapter）时降级而不是把失败当成功。
"""
import asyncio
import logging
import os
import sys
import threading

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))
import helpers as H  # noqa: E402

from selkies.host_cursor import HostCursorController  # noqa: E402


class FakeSettings:
    """只带两个部署字段的 settings 替身。"""

    def __init__(self, backend: str = "kwin", display: str = "wayland-remote-desktop") -> None:
        self.wayland_host_backend = backend
        self.wayland_host_display = display


class FakeModule:
    """记录调用参数的 pixelflux ScreenCapture 替身。"""

    def __init__(self, fail: bool = False) -> None:
        self.calls: list = []
        self.threads: list = []
        self.fail = fail

    def set_host_cursor_visibility(self, display: str, visible: bool) -> bool:
        self.threads.append(threading.get_ident())
        self.calls.append((display, visible))
        if self.fail:
            raise RuntimeError("adapter 不认识 op=cursor")
        return True


class NoApiModule:
    """没有 set_host_cursor_visibility 的旧 pixelflux 构建。"""


class CaptureLog(logging.Handler):
    """收集 host_cursor 的记录，用来断言“只提示一次”。"""

    def __init__(self) -> None:
        super().__init__()
        self.messages: list = []

    def emit(self, record: logging.LogRecord) -> None:
        self.messages.append(record.getMessage())


def with_log() -> CaptureLog:
    """把 host_cursor 的 logger 换成收集器。"""
    handler = CaptureLog()
    logger = logging.getLogger("selkies_app")
    logger.addHandler(handler)
    logger.setLevel(logging.WARNING)
    return handler


def run(coro):
    """跑一个协程（测试不需要事件循环的其它特性）。"""
    return asyncio.get_event_loop().run_until_complete(coro)


res = H.Results("host-cursor")

kwin = HostCursorController(FakeSettings())
res.check("KWin host capture 部署下状态机生效", kwin.is_active())
res.check("非 kwin backend 不生效",
          not HostCursorController(FakeSettings(backend="protocol")).is_active())
res.check("没有 host display 时不生效",
          not HostCursorController(FakeSettings(display="")).is_active())

module = FakeModule()
main_thread = threading.get_ident()
applied = run(kwin.apply(module, False))
res.check("首次 apply 调用 pixelflux 并确认成功",
          applied and module.calls == [("wayland-remote-desktop", False)], module.calls)
res.check("apply 走 to_thread，不在事件循环线程里做阻塞往返",
          module.threads and module.threads[0] != main_thread, module.threads)
res.check("状态机记录已应用值", kwin.visible is False)

applied_again = run(kwin.apply(module, False))
res.check("重复 apply 幂等，不再触碰 adapter",
          applied_again and len(module.calls) == 1, module.calls)

applied_true = run(kwin.apply(module, True))
res.check("切换回原生光标会再次下发 hidden=false",
          applied_true and module.calls[-1] == ("wayland-remote-desktop", True), module.calls)

restored = run(kwin.restore_visible(module))
res.check("restore_visible 在已可见时确认成功且状态归零（forget 后为 None）",
          restored and kwin.visible is True, (restored, kwin.visible))
kwin.forget()
res.check("forget 后状态未知", kwin.visible is None)

inactive = HostCursorController(FakeSettings(backend="protocol"))
inactive_module = FakeModule()
res.check("非 KWin 部署不调用 adapter",
          run(inactive.apply(inactive_module, False)) is False and not inactive_module.calls)

log = with_log()
legacy = HostCursorController(FakeSettings())
res.check("旧 pixelflux 缺少 API 时降级为 False",
          run(legacy.apply(NoApiModule(), False)) is False)
run(legacy.apply(NoApiModule(), True))
res.check("降级只提示一次", len([m for m in log.messages if "set_host_cursor_visibility" in m]) == 1,
          log.messages)

failing = HostCursorController(FakeSettings())
failing_module = FakeModule(fail=True)
fail_log = CaptureLog()
logging.getLogger("selkies_app").addHandler(fail_log)
res.check("adapter 拒绝时降级为 False",
          run(failing.apply(failing_module, False)) is False)
res.check("失败后状态回到未知，下一次会重试", failing.visible is None)
failing_module.fail = False
res.check("重试成功后确认状态",
          run(failing.apply(failing_module, False)) is True and failing.visible is False)
res.check("失败也只提示一次",
          len([m for m in fail_log.messages if "cursor suppression" in m]) == 1, fail_log.messages)
logging.getLogger("selkies_app").removeHandler(fail_log)
logging.getLogger("selkies_app").removeHandler(log)

sys.exit(0 if res.summary() else 1)
