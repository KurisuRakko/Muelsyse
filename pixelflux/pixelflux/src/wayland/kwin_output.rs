//! KWin output-management-v2 控制器。
//!
//! KWin 的虚拟输出不会提供 wlroots 的 output-management 协议。这里使用 KDE
//! 私有协议先注册目标 custom mode，再重新读取 mode 对象并提交配置；每次提交都
//! 等待 `applied`/`failed`，因此调用方不会把“请求已发送”误当成“输出已调整”。

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use serde_json::{json, Value};
use wayland_client::protocol::wl_registry;
use wayland_client::{delegate_noop, Connection, Dispatch, EventQueue, QueueHandle};

use crate::wayland::kdeproto::output_device::{
    kde_output_device_mode_v2::{self, KdeOutputDeviceModeV2},
    kde_output_device_v2::{self, KdeOutputDeviceV2},
};
use crate::wayland::kdeproto::output_management::{
    kde_mode_list_v2::KdeModeListV2,
    kde_output_configuration_v2::{self, KdeOutputConfigurationV2},
    kde_output_management_v2::KdeOutputManagementV2,
};
use crate::wayland::wlclient::{
    bounded_roundtrip, impl_sync_callback, socket_path, SyncState, IO_TIMEOUT,
};

#[derive(Clone, Copy)]
struct ModeInfo {
    width: u32,
    height: u32,
    refresh_mhz: Option<u32>,
}

struct Device {
    proxy: KdeOutputDeviceV2,
    enabled: bool,
    current: Option<KdeOutputDeviceModeV2>,
    capabilities: u32,
    scale: f64,
}

#[derive(Default)]
struct State {
    manager: Option<KdeOutputManagementV2>,
    manager_version: u32,
    devices: Vec<Device>,
    modes: Vec<(KdeOutputDeviceModeV2, ModeInfo)>,
    applied: Option<bool>,
    sync_done: bool,
}

/// KWin output-management-v2 的严格模式控制器。
pub struct KWinOutputController;

/// 旧版 adapter 不认识 `op=cursor`：只提示一次，避免每次切换都刷屏。
static CURSOR_SUPPORT_WARNED: AtomicBool = AtomicBool::new(false);

impl KWinOutputController {
    /// 只在目标 mode 被 KWin 确认后返回；无法创建目标 mode 时直接失败。
    pub(crate) fn apply(
        display: &str,
        width: i32,
        height: i32,
        fps: u32,
    ) -> Result<(i32, i32), String> {
        apply_output_mode(display, width, height, fps)
    }

    /// 通过 KWin output-management-v2 应用并验证真实的输出缩放。
    pub(crate) fn apply_scale(display: &str, scale: f64) -> Result<(), String> {
        apply_output_scale(display, scale)?;
        // 缩放改变后主动请求一次合成，避免静态桌面没有新损坏区域而不产生新帧。
        Self::repaint()
    }

    /// 在 PipeWire stream 已连接后请求一次当前 virtual output 重绘，确保静态桌面也
    /// 产生首个有效的 KWin screencast DMA-BUF 帧。
    pub(crate) fn repaint() -> Result<(), String> {
        request_adapter(json!({"op": "repaint"}), "KWin repaint")
    }

    /// 切换 KWin 虚拟输出的软件光标抑制状态。
    ///
    /// `visible == false` 对应 Selkies 的 CSS 光标模式：KWin 不再把光标画进视频帧，
    /// 但 screencast 的 `SPA_META_Cursor` 照常提供形状；`visible == true` 恢复视频
    /// 光标（pointer-lock/原生光标模式）。adapter 缺失或版本过旧时返回错误并只提示
    /// 一次，调用方保持原有视频行为，采集不受影响。
    pub(crate) fn set_cursor_visible(visible: bool) -> Result<(), String> {
        let outcome = request_adapter(
            json!({"op": "cursor", "hidden": !visible}),
            "KWin cursor suppression",
        );
        if let Err(error) = &outcome {
            warn_cursor_support_once(error);
        }
        outcome
    }
}

/// 只警告一次：deployment 里的 KWin 可能还没有 `op=cursor`（需要重启会话才生效）。
fn warn_cursor_support_once(error: &str) {
    if !CURSOR_SUPPORT_WARNED.swap(true, Ordering::Relaxed) {
        eprintln!(
            "[KWinCapture] KWin adapter 不支持 op=cursor，视频光标保持原状（H.264/CSS 光标仍可用）: {error}"
        );
    }
}

impl SyncState for State {
    fn sync_done_mut(&mut self) -> &mut bool {
        &mut self.sync_done
    }
}
impl_sync_callback!(State);

delegate_noop!(State: KdeOutputManagementV2);
delegate_noop!(State: KdeModeListV2);

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        else {
            return;
        };
        match interface.as_str() {
            "kde_output_management_v2" if state.manager.is_none() && version >= 1 => {
                state.manager_version = version;
                state.manager = Some(registry.bind(name, version.min(22), qh, ()));
            }
            "kde_output_device_v2" => {
                state.devices.push(Device {
                    proxy: registry.bind(name, version.min(11), qh, ()),
                    enabled: false,
                    current: None,
                    capabilities: 0,
                    scale: 1.0,
                });
            }
            _ => {}
        }
    }
}

impl Dispatch<KdeOutputDeviceV2, ()> for State {
    fn event(
        state: &mut Self,
        device: &KdeOutputDeviceV2,
        event: kde_output_device_v2::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(entry) = state.devices.iter_mut().find(|d| &d.proxy == device) else {
            return;
        };
        match event {
            kde_output_device_v2::Event::Enabled { enabled } => entry.enabled = enabled != 0,
            kde_output_device_v2::Event::CurrentMode { mode } => entry.current = Some(mode),
            kde_output_device_v2::Event::Capabilities { flags } => {
                entry.capabilities = flags.into()
            }
            kde_output_device_v2::Event::Scale { factor } => entry.scale = factor,
            kde_output_device_v2::Event::Mode { mode } => {
                // mode 的 size/refresh 会随后异步到达；先记录代理，等两个
                // round-trip 后由 mode 事件填入完整描述。
                state.modes.retain(|(old, _)| old != &mode);
                state.modes.push((
                    mode,
                    ModeInfo {
                        width: 0,
                        height: 0,
                        refresh_mhz: None,
                    },
                ));
            }
            _ => {}
        }
    }

    wayland_client::event_created_child!(State, KdeOutputDeviceV2, [
        kde_output_device_v2::EVT_MODE_OPCODE => (KdeOutputDeviceModeV2, ()),
    ]);
}

impl Dispatch<KdeOutputDeviceModeV2, ()> for State {
    fn event(
        state: &mut Self,
        mode: &KdeOutputDeviceModeV2,
        event: kde_output_device_mode_v2::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let Some((_, info)) = state.modes.iter_mut().find(|(proxy, _)| proxy == mode) {
            match event {
                kde_output_device_mode_v2::Event::Size { width, height } => {
                    info.width = width.max(0) as u32;
                    info.height = height.max(0) as u32;
                }
                kde_output_device_mode_v2::Event::Refresh { refresh } => {
                    info.refresh_mhz = (refresh >= 0).then_some(refresh as u32);
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<KdeOutputConfigurationV2, ()> for State {
    fn event(
        state: &mut Self,
        _: &KdeOutputConfigurationV2,
        event: kde_output_configuration_v2::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            kde_output_configuration_v2::Event::Applied => state.applied = Some(true),
            kde_output_configuration_v2::Event::Failed => state.applied = Some(false),
            _ => {}
        }
    }
}

fn read_state(display: &str) -> Result<(Connection, EventQueue<State>, State), String> {
    let path = socket_path(display).ok_or("XDG_RUNTIME_DIR 未设置")?;
    let socket =
        UnixStream::connect(&path).map_err(|e| format!("连接 KWin socket {path} 失败: {e}"))?;
    let conn = Connection::from_socket(socket).map_err(|e| format!("Wayland 初始化失败: {e}"))?;
    let mut queue = conn.new_event_queue::<State>();
    let qh = queue.handle();
    let _registry = conn.display().get_registry(&qh, ());
    let mut state = State::default();
    bounded_roundtrip(&conn, &mut queue, &mut state)?;
    bounded_roundtrip(&conn, &mut queue, &mut state)?;
    Ok((conn, queue, state))
}

fn apply_configuration(
    conn: &Connection,
    queue: &mut EventQueue<State>,
    state: &mut State,
    configuration: KdeOutputConfigurationV2,
) -> Result<(), String> {
    state.applied = None;
    configuration.apply();
    queue
        .flush()
        .map_err(|e| format!("提交 KWin output configuration 失败: {e}"))?;
    let deadline = Instant::now() + IO_TIMEOUT;
    while state.applied.is_none() && Instant::now() < deadline {
        bounded_roundtrip(conn, queue, state)?;
    }
    configuration.destroy();
    let _ = queue.flush();
    match state.applied {
        Some(true) => Ok(()),
        Some(false) => Err("KWin 拒绝了 output configuration".into()),
        None => Err("等待 KWin output configuration 超时".into()),
    }
}

fn target_mode(
    state: &State,
    width: u32,
    height: u32,
    refresh_mhz: u32,
) -> Option<KdeOutputDeviceModeV2> {
    state
        .modes
        .iter()
        .find(|(_, info)| {
            info.width == width
                && info.height == height
                && info
                    .refresh_mhz
                    .is_some_and(|refresh| refresh.abs_diff(refresh_mhz) <= 1)
        })
        .map(|(mode, _)| mode.clone())
}

fn current_mode_info(state: &State, device_index: usize) -> Option<ModeInfo> {
    let current = state.devices.get(device_index)?.current.as_ref()?;
    state
        .modes
        .iter()
        .find(|(mode, _)| mode == current)
        .map(|(_, info)| *info)
}

fn current_scale(state: &State, device_index: usize) -> Option<f64> {
    state.devices.get(device_index).map(|device| device.scale)
}

/// 在同一个 output configuration 中设置 scale，并在重新绑定后验证 KWin 的状态。
fn apply_output_scale(display: &str, scale: f64) -> Result<(), String> {
    if !scale.is_finite() || !(0.1..=4.0).contains(&scale) {
        return Err(format!("KWin output scale 参数无效: {scale}"));
    }
    let (conn, mut queue, mut state) = read_state(display)?;
    let manager = state
        .manager
        .clone()
        .ok_or("KWin 未发布 kde_output_management_v2")?;
    let device = state
        .devices
        .iter()
        .find(|device| device.enabled)
        .or_else(|| state.devices.first())
        .ok_or("KWin 没有可配置的 output device")?;
    let device_index = state
        .devices
        .iter()
        .position(|candidate| std::ptr::eq(candidate, device))
        .ok_or("KWin output device 索引丢失")?;
    let qh = queue.handle();
    let configuration = manager.create_configuration(&qh, ());
    configuration.scale(&device.proxy, scale);
    apply_configuration(&conn, &mut queue, &mut state, configuration)?;
    drop(queue);
    drop(conn);

    let (_, _, verified) = read_state(display)?;
    let actual = current_scale(&verified, device_index).ok_or("KWin 重连后没有 output scale")?;
    if (actual - scale).abs() > 0.01 {
        return Err(format!(
            "KWin applied 后 output scale 为 {actual:.3}，目标为 {scale:.3}"
        ));
    }
    println!("[KWinOutput] applied scale {scale:.2}");
    Ok(())
}

fn adapter_socket_path() -> Result<String, String> {
    if let Ok(path) = std::env::var("SELKIES_KWIN_ADAPTER_SOCKET") {
        if !path.is_empty() {
            return Ok(path);
        }
    }
    let runtime = std::env::var("XDG_RUNTIME_DIR").map_err(|_| "XDG_RUNTIME_DIR 未设置")?;
    Ok(format!(
        "{}/selkies-kwin-adapter.sock",
        runtime.trim_end_matches('/')
    ))
}

fn prepare_mode_with_adapter(
    output_index: usize,
    width: u32,
    height: u32,
    refresh_mhz: u32,
) -> Result<(), String> {
    let path = adapter_socket_path()?;
    let mut socket = UnixStream::connect(&path)
        .map_err(|error| format!("连接 KWin Selkies 适配层 {path} 失败: {error}"))?;
    socket
        .set_read_timeout(Some(IO_TIMEOUT))
        .map_err(|error| format!("设置适配层读取超时失败: {error}"))?;
    socket
        .set_write_timeout(Some(IO_TIMEOUT))
        .map_err(|error| format!("设置适配层写入超时失败: {error}"))?;
    let request = json!({
        "op": "prepare",
        "output_index": output_index,
        "width": width,
        "height": height,
        "refresh_mhz": refresh_mhz,
    });
    socket
        .write_all(format!("{request}\n").as_bytes())
        .map_err(|error| format!("发送 KWin mode 请求失败: {error}"))?;

    let mut line = String::new();
    BufReader::new(socket)
        .read_line(&mut line)
        .map_err(|error| format!("读取 KWin mode 响应失败: {error}"))?;
    let response: Value =
        serde_json::from_str(&line).map_err(|error| format!("KWin mode 响应不是 JSON: {error}"))?;
    if !response.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        let message = response
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("KWin 适配层拒绝了 mode")
            .to_string();
        return Err(message);
    }
    println!(
        "[KWinOutput] adapter prepared output={output_index} {width}x{height}@{}",
        refresh_mhz / 1000
    );
    Ok(())
}

fn request_adapter(request: Value, operation: &str) -> Result<(), String> {
    let path = adapter_socket_path()?;
    let mut socket = UnixStream::connect(&path)
        .map_err(|error| format!("连接 KWin Selkies 适配层 {path} 失败: {error}"))?;
    socket
        .set_read_timeout(Some(IO_TIMEOUT))
        .map_err(|error| format!("设置适配层读取超时失败: {error}"))?;
    socket
        .set_write_timeout(Some(IO_TIMEOUT))
        .map_err(|error| format!("设置适配层写入超时失败: {error}"))?;
    socket
        .write_all(format!("{request}\n").as_bytes())
        .map_err(|error| format!("发送 {operation} 请求失败: {error}"))?;

    let mut line = String::new();
    BufReader::new(socket)
        .read_line(&mut line)
        .map_err(|error| format!("读取 {operation} 响应失败: {error}"))?;
    let response: Value = serde_json::from_str(&line)
        .map_err(|error| format!("{operation} 响应不是 JSON: {error}"))?;
    if !response.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        let message = response
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("KWin 适配层拒绝请求")
            .to_string();
        return Err(format!("{operation} 失败: {message}"));
    }
    Ok(())
}

/// 为 KWin 虚拟输出申请一个可验证的 `width×height@fps` 模式。
pub(crate) fn apply_output_mode(
    display: &str,
    width: i32,
    height: i32,
    fps: u32,
) -> Result<(i32, i32), String> {
    apply_output_mode_attempt(display, width, height, fps, false)
}

fn apply_output_mode_attempt(
    display: &str,
    width: i32,
    height: i32,
    fps: u32,
    retry_used: bool,
) -> Result<(i32, i32), String> {
    if width <= 0 || height <= 0 || fps == 0 {
        return Err(format!("KWin output mode 参数无效: {width}x{height}@{fps}"));
    }
    let width = width as u32;
    let height = height as u32;
    let refresh_mhz = fps.saturating_mul(1000);
    let (conn, mut queue, mut state) = read_state(display)?;
    let manager = state
        .manager
        .clone()
        .ok_or("KWin 未发布 kde_output_management_v2")?;
    let device = state
        .devices
        .iter()
        .find(|device| device.enabled)
        .or_else(|| state.devices.first())
        .ok_or("KWin 没有可配置的 output device")?;
    let device_index = state
        .devices
        .iter()
        .position(|candidate| std::ptr::eq(candidate, device))
        .ok_or("KWin output device 索引丢失")?;

    if target_mode(&state, width, height, refresh_mhz).is_none() {
        if retry_used {
            return Err(format!(
                "KWin 没有在重读协议后公布目标 mode {width}x{height}@{fps}"
            ));
        }
        if state.manager_version < 18 || device.capabilities & (1 << 13) == 0 {
            prepare_mode_with_adapter(device_index, width, height, refresh_mhz)?;
        } else {
            let qh = queue.handle();
            let mode_list = manager.create_mode_list(&qh, ());
            mode_list.set_resolution(width, height);
            mode_list.set_refresh_rate(refresh_mhz);
            mode_list.add_mode();
            let configuration = manager.create_configuration(&qh, ());
            configuration.set_custom_modes(&device.proxy, &mode_list);
            apply_configuration(&conn, &mut queue, &mut state, configuration)?;
            mode_list.destroy();
        }
        // The custom-mode list belongs to this Wayland connection. Rebind all
        // proxies before looking up and applying the newly published mode. The
        // KWin 6.3 adapter follows the same rule through its local socket.
        drop(queue);
        drop(conn);
        return apply_output_mode_attempt(display, width as i32, height as i32, fps, true);
    }

    let device = state
        .devices
        .iter()
        .find(|device| device.enabled)
        .or_else(|| state.devices.first())
        .ok_or("KWin 没有可配置的 output device")?;
    let mode = target_mode(&state, width, height, refresh_mhz)
        .ok_or_else(|| format!("KWin 未公布可用的 custom mode {width}x{height}@{fps}"))?;
    let qh = queue.handle();
    let configuration = manager.create_configuration(&qh, ());
    configuration.mode(&device.proxy, &mode);
    apply_configuration(&conn, &mut queue, &mut state, configuration)?;
    drop(queue);
    drop(conn);
    let (_, _, verified) = read_state(display)?;
    let current = current_mode_info(&verified, device_index).ok_or("KWin 重连后没有当前 mode")?;
    if current.width != width
        || current.height != height
        || current.refresh_mhz != Some(refresh_mhz)
    {
        return Err(format!(
            "KWin applied 后当前 mode 为 {}x{}@{:?}，目标为 {width}x{height}@{refresh_mhz}",
            current.width, current.height, current.refresh_mhz
        ));
    }
    println!("[KWinOutput] applied {width}x{height}@{fps}");
    Ok((width as i32, height as i32))
}
