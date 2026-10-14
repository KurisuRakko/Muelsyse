//! KWin 受信任输入与 data-control 剪贴板桥。
//!
//! 输入连接和剪贴板连接都指向同一个外部 KWin socket。输入使用 KWin
//! 的私有 fake-input 协议，剪贴板复用成熟的 ext/wlr data-control 客户端；
//! 两条路径都不经过 pixelflux 自己的 compositor。

use pyo3::{Py, PyAny};

use crate::wayland::{dcclient, ficlient, wlclient::socket_path};

/// KWin host backend 的输入与剪贴板入口。
pub struct KWinInputClipboardBridge;

impl KWinInputClipboardBridge {
    /// 将 fake-input 客户端绑定到完整的 KWin socket 路径。
    pub fn arm(display: &str) {
        ficlient::arm(socket_path(display));
    }

    pub fn pointer_motion_rel(dx: f64, dy: f64) -> bool {
        ficlient::pointer_motion_rel(dx, dy)
    }

    pub fn pointer_motion_abs(x: f64, y: f64) -> bool {
        ficlient::pointer_motion_abs(x, y)
    }

    pub fn pointer_button(button: u32, pressed: bool) -> bool {
        ficlient::pointer_button(button, pressed)
    }

    pub fn pointer_axis(dx: f64, dy: f64) -> bool {
        ficlient::pointer_axis(dx, dy)
    }

    pub fn keyboard_key(key: u32, pressed: bool) -> bool {
        ficlient::keyboard_key(key, pressed)
    }

    pub(crate) fn clipboard_types(display: &str) -> Result<Vec<String>, String> {
        dcclient::list_types(&socket_path(display).ok_or("XDG_RUNTIME_DIR 未设置")?)
    }

    pub(crate) fn clipboard_read(display: &str, mime: &str) -> Result<Option<Vec<u8>>, String> {
        dcclient::read(&socket_path(display).ok_or("XDG_RUNTIME_DIR 未设置")?, mime)
    }

    pub(crate) fn clipboard_write(
        display: &str,
        entries: Vec<(String, Vec<u8>)>,
    ) -> Result<(), String> {
        dcclient::write(
            &socket_path(display).ok_or("XDG_RUNTIME_DIR 未设置")?,
            entries,
        )
    }

    pub(crate) fn clipboard_clear(display: &str) -> Result<(), String> {
        dcclient::clear(&socket_path(display).ok_or("XDG_RUNTIME_DIR 未设置")?)
    }

    pub(crate) fn clipboard_watch(display: &str, callback: Py<PyAny>) -> Result<(), String> {
        dcclient::watch(
            &socket_path(display).ok_or("XDG_RUNTIME_DIR 未设置")?,
            callback,
        )
    }

    pub(crate) fn clipboard_unwatch(display: &str) {
        if let Some(path) = socket_path(display) {
            dcclient::unwatch(&path);
        }
    }
}
