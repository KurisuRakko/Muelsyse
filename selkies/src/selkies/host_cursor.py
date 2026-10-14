# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""KWin host capture 的软件光标显隐状态机。

Selkies 的 CSS 光标模式要求视频里没有 KWin 合成的光标，同时 `zkde_screencast`
的 `SPA_META_Cursor` 继续提供真实形状；pointer-lock / 原生光标模式则相反。这个
状态机把 Selkies 侧的多条触发路径收敛成一次幂等、best-effort 的调用：

- `SET_NATIVE_CURSOR_RENDERING` / `p,0` / `p,1`（客户端切换）；
- `media_pipeline.set_pointer_visible`（WebRTC 采集侧开关）；
- 采集启动/停止与客户端断开时的对齐与恢复。

只有 KWin host capture 部署（`wayland_host_backend == "kwin"` 且
`wayland_host_display` 非空）会真的调用 pixelflux；pixelflux 构建里没有
`set_host_cursor_visibility`，或 KWin adapter 还不认识 `op=cursor`（旧 KWin）时，
这里只提示一次并保持原有视频行为，绝不把失败当成成功。
"""

import asyncio
import logging
from typing import Any, Optional

from .settings import settings as app_settings

logger = logging.getLogger("selkies_app")


class HostCursorController:
    """把“视频里是否显示光标”映射到 KWin 的软件光标抑制状态。"""

    def __init__(self, settings_obj: Any = None) -> None:
        """初始化状态机。

        Args:
            settings_obj: 读取部署设置的 settings 对象；默认用进程级 settings，
                便于测试注入替身。
        """
        self._settings = settings_obj if settings_obj is not None else app_settings
        # None：尚未对齐（或上次失败/采集重启后）；True/False：已确认应用的值。
        self._visible: Optional[bool] = None
        # 部署差异（旧 pixelflux / 旧 KWin）只提示一次。
        self._warned = False

    def is_active(self) -> bool:
        """当前部署是否是 KWin host capture。"""
        backend = (getattr(self._settings, "wayland_host_backend", "") or "").strip().lower()
        display = (getattr(self._settings, "wayland_host_display", "") or "").strip()
        return backend == "kwin" and bool(display)

    @property
    def display(self) -> str:
        """KWin 会话的 Wayland socket 名。"""
        return (getattr(self._settings, "wayland_host_display", "") or "").strip()

    @property
    def visible(self) -> Optional[bool]:
        """已确认应用的可见性；None 表示尚未对齐。"""
        return self._visible

    def forget(self) -> None:
        """采集停止/重启后忘记已应用状态，下一次调用重新对齐 KWin。"""
        self._visible = None

    async def apply(self, module: Any, visible: bool) -> bool:
        """幂等地把 `visible` 应用到 KWin 的软件光标层。

        调用走 `asyncio.to_thread`，不在事件循环里做阻塞的 socket 往返。

        Args:
            module: 具有 `set_host_cursor_visibility(display, visible)` 的
                pixelflux ScreenCapture；None 或缺少该 API 时降级。
            visible: True = 视频里显示光标（原生/pointer-lock 模式）；
                False = 隐藏视频光标，形状继续经 cursor 回调下发（CSS 模式）。

        Returns:
            已确认应用（或已经处于该状态）返回 True；降级/失败返回 False。
        """
        if not self.is_active():
            return False
        if self._visible == visible:
            return True
        if module is None or not hasattr(module, "set_host_cursor_visibility"):
            self._warn_once(
                "pixelflux 构建没有 set_host_cursor_visibility；保持原有视频光标行为。")
            return False
        try:
            await asyncio.to_thread(
                module.set_host_cursor_visibility, self.display, visible)
        except Exception as exc:  # noqa: BLE001 - 降级路径，任何异常都不该中断采集
            self._visible = None
            self._warn_once(
                "KWin cursor suppression 不可用（adapter 或 KWin 版本过旧）：%s" % (exc,))
            return False
        self._visible = visible
        return True

    async def restore_visible(self, module: Any) -> bool:
        """best-effort 把视频光标恢复为可见（断开/停止采集后不留 hidden 状态）。"""
        if not self.is_active():
            return False
        self.forget()
        return await self.apply(module, True)

    def _warn_once(self, message: str) -> None:
        """部署差异只提示一次，避免每次切换都刷日志。"""
        if not self._warned:
            self._warned = True
            logger.warning(message)
