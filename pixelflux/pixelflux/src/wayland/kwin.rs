//! KWin 原生捕获的第一阶段探针。
//!
//! KWin 6.3 不发布 `ext-image-copy-capture` 或 `zwlr_screencopy`，但它为受权限声明
//! 的客户端提供 `zkde_screencast_unstable_v1`。本模块先证明完整的协议交接和 PipeWire
//! DMA-BUF 协商，不提供 SHM/CPU 回退；后续帧所有权会在同一接口上接入 VAAPI。

use std::collections::HashMap;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use pipewire as pw;
use pw::properties::properties;
use pw::spa;
use pw::spa::buffer::DataType;
use pw::spa::param::video::{VideoFlags, VideoInfoRaw};
use pw::spa::pod::Pod;
use smithay::backend::allocator::dmabuf::{Dmabuf, DmabufFlags};
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::utils::Rectangle;
use wayland_client::protocol::{wl_output, wl_registry};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle, delegate_noop};
use wayland_protocols_plasma::screencast::v1::client::{
    zkde_screencast_stream_unstable_v1::{self, ZkdeScreencastStreamUnstableV1},
    zkde_screencast_unstable_v1::ZkdeScreencastUnstableV1,
};

use crate::wayland::wlclient::{
    SyncState, bounded_roundtrip, drain_pipe, impl_sync_callback, socket_path,
};

use super::host::{FrameSink, HostFrame, ToHost};

/// `zkde_screencast_unstable_v1` 的 pointer mode 取值（见 plasma-wayland-protocols）。
const POINTER_HIDDEN: u32 = 1;
/// metadata：流里不画光标，但每帧通过 `SPA_META_Cursor` 提供位置/hotspot，
/// 形状变化时附带位图。Selkies 的 CSS 光标模式依赖这一模式。
const POINTER_METADATA: u32 = 4;
/// KWin `screencaststream.cpp` 的 `CURSOR_META_SIZE(256, 256)`：consumer 必须请求
/// 至少这么大的 cursor meta 区域，KWin 才会往里写位图。
const KWIN_CURSOR_META_SIDE: usize = 256;
const MIN_WIDTH: i32 = 1;
const MIN_HEIGHT: i32 = 1;
const MAX_WIDTH: i32 = 8192;
const MAX_HEIGHT: i32 = 8192;
// 两个有界在途 buffer：一个交给编码器时，另一个可接收下一帧。
const KWIN_IN_FLIGHT_SLOTS: usize = 2;
/// 向 KWin 要的 buffer 数（KWin 的上限）。KWin 默认只给 3 个，我们最多占
/// `KWIN_IN_FLIGHT_SLOTS` 个，KWin 手里常常只剩 1 个；它还在回程（上一帧或
/// cursor-only 帧）时，下一次重绘 dequeue 不到 buffer，整帧就丢了。
const KWIN_STREAM_BUFFERS: i32 = 4;
/// PipeWire 协商与帧路径的文本指标；探针不返回像素，也不读取 DMA-BUF 内容。
#[derive(Clone, Debug, Default)]
pub struct ProbeReport {
    pub node_id: u32,
    pub width: u32,
    pub height: u32,
    pub framerate_num: u32,
    pub framerate_den: u32,
    pub max_framerate_num: u32,
    pub max_framerate_den: u32,
    pub modifier: Option<u64>,
    pub dmabuf_frames: u64,
    pub non_dmabuf_frames: u64,
}
/// KWin 私有 screencast 的严格入口。
///
/// 这个入口只接受 PipeWire DMA-BUF；PipeWire SHM、CPU 拷贝和本地
/// compositor 回退都不会被隐藏在调用方后面。
pub struct KWinCaptureSource;
impl KWinCaptureSource {
    /// 运行不启动 Selkies 的文本探针，供部署前置检查复用。
    pub fn probe(
        display: &str,
        width: i32,
        height: i32,
        fps: u32,
        duration: Duration,
    ) -> Result<ProbeReport, String> {
        probe(display, width, height, fps, duration)
    }

    /// 为 pixelflux host session 运行严格的 KWin 捕获线程。
    pub(crate) fn capture_loop(
        display: &str,
        index: usize,
        expected_name: Option<String>,
        commands: std::sync::mpsc::Receiver<ToHost>,
        wake_rd: OwnedFd,
        frames: &FrameSink,
        sizes: Arc<Mutex<Vec<(i32, i32)>>>,
        registry_index: usize,
    ) -> Result<(), String> {
        capture_loop(
            display,
            index,
            expected_name,
            commands,
            wake_rd,
            frames,
            sizes,
            registry_index,
        )
    }
}
#[derive(Default)]
struct KwinState {
    manager: Option<ZkdeScreencastUnstableV1>,
    outputs: Vec<wl_output::WlOutput>,
    node_id: Option<u32>,
    error: Option<String>,
    closed: bool,
    sync_done: bool,
}
impl SyncState for KwinState {
    fn sync_done_mut(&mut self) -> &mut bool {
        &mut self.sync_done
    }
}
impl_sync_callback!(KwinState);
impl Dispatch<wl_registry::WlRegistry, ()> for KwinState {
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
            "zkde_screencast_unstable_v1" if state.manager.is_none() && version >= 1 => {
                state.manager = Some(registry.bind(name, version.min(4), qh, ()));
            }
            "wl_output" => {
                state
                    .outputs
                    .push(registry.bind(name, version.min(4), qh, ()));
            }
            _ => {}
        }
    }
}

delegate_noop!(KwinState: ZkdeScreencastUnstableV1);
impl Dispatch<wl_output::WlOutput, ()> for KwinState {
    fn event(
        _: &mut Self,
        _: &wl_output::WlOutput,
        _: wl_output::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        // 预检只需要拿到第一个 wl_output；KWin 的 geometry/mode 事件不能用
        // delegate_noop!，因为该宏对非空事件会触发 unreachable!。
    }
}
impl Dispatch<ZkdeScreencastStreamUnstableV1, ()> for KwinState {
    fn event(
        state: &mut Self,
        _: &ZkdeScreencastStreamUnstableV1,
        event: zkde_screencast_stream_unstable_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            zkde_screencast_stream_unstable_v1::Event::Created { node } => {
                state.node_id = Some(node);
            }
            zkde_screencast_stream_unstable_v1::Event::Failed { error } => {
                state.error = Some(error);
            }
            zkde_screencast_stream_unstable_v1::Event::Closed => state.closed = true,
            _ => {}
        }
    }
}
/// 持有 Wayland stream 直到 PipeWire 探针完成，避免 KWin 提前销毁 node。
struct KwinStream {
    _conn: Connection,
    _queue: EventQueue<KwinState>,
    stream: ZkdeScreencastStreamUnstableV1,
    node_id: u32,
}

impl KwinStream {
    /// 打开一条 screencast 流，pointer mode 使用采集路径的 metadata。
    fn open(display: &str) -> Result<Self, String> {
        Self::open_with_pointer(display, POINTER_METADATA)
    }

    /// 打开一条 screencast 流并指定 pointer mode。
    ///
    /// 生产采集用 [`POINTER_METADATA`]（CSS 光标的形状来源）；帧路径诊断探针用
    /// [`POINTER_HIDDEN`]，保持“只要视频帧、不要光标数据”的旧语义。
    fn open_with_pointer(display: &str, pointer: u32) -> Result<Self, String> {
        // KWin 在刚完成 virtual mode apply 时可能需要一个短暂的事件循环
        // 周期才创建 screencast node；有界重试可吸收这个正常竞态，但不会
        // 把真正的协议失败变成无限等待或静默回退。
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            match Self::open_once(display, pointer) {
                Ok(stream) => return Ok(stream),
                Err(error)
                    if error.contains("KWin 未返回 screencast node")
                        && Instant::now() < deadline =>
                {
                    eprintln!("[KWinCapture] screencast node 尚未就绪，稍后重试: {error}");
                    thread::sleep(Duration::from_millis(50));
                }
                Err(error) => return Err(error),
            }
        }
    }

    fn open_once(display: &str, pointer: u32) -> Result<Self, String> {
        let path = socket_path(display).ok_or("XDG_RUNTIME_DIR 未设置")?;
        let socket = UnixStream::connect(&path)
            .map_err(|e| format!("连接 KWin Wayland socket {path}: {e}"))?;
        let conn =
            Connection::from_socket(socket).map_err(|e| format!("Wayland 初始化失败: {e}"))?;
        let mut queue = conn.new_event_queue::<KwinState>();
        let qh = queue.handle();
        let _registry = conn.display().get_registry(&qh, ());
        let mut state = KwinState::default();
        bounded_roundtrip(&conn, &mut queue, &mut state)?;

        let manager = state
            .manager
            .clone()
            .ok_or("KWin 未发布 zkde_screencast_unstable_v1")?;
        let output = state
            .outputs
            .first()
            .cloned()
            .ok_or("KWin 未发布 wl_output")?;
        let stream = manager.stream_output(&output, pointer, &qh, ());
        queue
            .flush()
            .map_err(|e| format!("发送 KWin screencast 请求失败: {e}"))?;

        for _ in 0..20 {
            bounded_roundtrip(&conn, &mut queue, &mut state)?;
            if state.node_id.is_some() || state.error.is_some() || state.closed {
                break;
            }
        }
        let node_id = state.node_id.ok_or_else(|| {
            state
                .error
                .unwrap_or_else(|| "KWin 未返回 screencast node".into())
        })?;
        println!("[KWinCapture] zkde_screencast node={node_id}");
        Ok(Self {
            _conn: conn,
            _queue: queue,
            stream,
            node_id,
        })
    }
}
/// PipeWire 已协商的单平面 BGRA/BGRx DMA-BUF 描述。
#[derive(Clone, Copy, Debug)]
struct Negotiated {
    format: pw::spa::param::video::VideoFormat,
    width: u32,
    height: u32,
    fps_num: u32,
    fps_den: u32,
    modifier: u64,
}

#[derive(Debug)]
enum RunStop {
    Idle,
    Restart { width: i32, height: i32, fps: u32 },
}

/// 从 PipeWire 的原始 `pw_buffer` 取出第一个 SPA data plane。
///
/// 这里刻意绕过高层 `Buffer` 的 Drop：只有 pixelflux/编码器归还 HostFrame 后，
/// 才能把该 raw buffer 放回 PipeWire，避免 KWin 在编码完成前重用 DMA-BUF。
unsafe fn first_data(raw: *mut pw::sys::pw_buffer) -> Option<&'static mut pw::spa::buffer::Data> {
    if raw.is_null() {
        return None;
    }
    let spa_buffer = unsafe { (*raw).buffer };
    if spa_buffer.is_null() {
        return None;
    }
    let n_datas = unsafe { (*spa_buffer).n_datas as usize };
    let datas = unsafe { (*spa_buffer).datas };
    if datas.is_null() || n_datas == 0 {
        return None;
    }
    // 该引用只在当前 PipeWire process 回调期间读取；返回的 DMA-BUF fd 会
    // 立即 dup，回调结束后不再保留此引用。
    Some(unsafe { &mut *(datas as *mut pw::spa::buffer::Data) })
}

fn build_dmabuf(data: &pw::spa::buffer::Data, negotiated: Negotiated) -> Result<Dmabuf, String> {
    if data.type_() != DataType::DmaBuf || data.fd() < 0 {
        return Err(format!(
            "PipeWire buffer 不是有效 DMA-BUF: {:?}",
            data.type_()
        ));
    }
    let chunk = data.chunk();
    let stride = chunk.stride();
    if stride <= 0 {
        return Err(format!("PipeWire DMA-BUF stride 无效: {stride}"));
    }
    let duplicated = unsafe { libc::dup(data.fd()) };
    if duplicated < 0 {
        return Err(format!(
            "复制 PipeWire DMA-BUF fd 失败: {}",
            std::io::Error::last_os_error()
        ));
    }
    let fd = unsafe { OwnedFd::from_raw_fd(duplicated) };
    let fourcc = match negotiated.format {
        pw::spa::param::video::VideoFormat::BGRA => Fourcc::Argb8888,
        pw::spa::param::video::VideoFormat::BGRx => Fourcc::Xrgb8888,
        other => return Err(format!("KWin PipeWire pixel format 不受支持: {other:?}")),
    };
    let mut builder = Dmabuf::builder(
        (negotiated.width as i32, negotiated.height as i32),
        fourcc,
        Modifier::from(negotiated.modifier),
        DmabufFlags::empty(),
    );
    if !builder.add_plane(fd, 0, chunk.offset(), stride as u32) {
        return Err("创建 KWin DMA-BUF plane 失败".into());
    }
    builder
        .build()
        .ok_or_else(|| "KWin DMA-BUF 没有可用 plane".into())
}

fn drain_release(
    stream: &pw::stream::Stream,
    commands: &Arc<Mutex<std::sync::mpsc::Receiver<ToHost>>>,
    held: &mut HashMap<usize, usize>,
    generation: u64,
) -> Option<RunStop> {
    let mut latest_start = None;
    let mut idle_seen = false;
    loop {
        let command = match commands.lock().unwrap().try_recv() {
            Ok(command) => command,
            Err(std::sync::mpsc::TryRecvError::Empty) => break,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => return Some(RunStop::Idle),
        };
        match command {
            ToHost::Release {
                generation: frame_generation,
                slot,
            } => {
                if frame_generation == generation
                    && let Some(raw) = held.remove(&slot)
                {
                    unsafe { stream.queue_raw_buffer(raw as *mut pw::sys::pw_buffer) };
                }
            }
            ToHost::Start { width, height, .. } => {
                // 连续 resize 只保留最后一个目标；同一时间不会并发提交两个
                // KWin mode，旧 generation 的缓冲会在这里统一归还。
                latest_start = Some((width, height));
            }
            ToHost::Idle => {
                latest_start = None;
                idle_seen = true;
            }
        }
    }
    if latest_start.is_some() {
        if let Some((width, height)) = latest_start {
            println!(
                "[KWinCapture] coalesced resize request {}x{} generation={generation}",
                width, height
            );
        }
        for (_, raw) in held.drain() {
            unsafe { stream.queue_raw_buffer(raw as *mut pw::sys::pw_buffer) };
        }
        latest_start.map(|(width, height)| RunStop::Restart {
            width,
            height,
            fps: 60,
        })
    } else if idle_seen {
        Some(RunStop::Idle)
    } else {
        None
    }
}

fn run_pipewire_capture(
    display: &str,
    width: i32,
    height: i32,
    fps: u32,
    generation: u64,
    commands: Arc<Mutex<std::sync::mpsc::Receiver<ToHost>>>,
    wake_rd: OwnedFd,
    frames: &FrameSink,
    sizes: &Arc<Mutex<Vec<(i32, i32)>>>,
    registry_index: usize,
) -> Result<RunStop, String> {
    println!("[KWinCapture] applying capture target {width}x{height}@{fps}");
    super::kwin_output::KWinOutputController::apply(display, width, height, fps)?;
    if let Some(size) = sizes.lock().unwrap().get_mut(registry_index) {
        *size = (width, height);
    }
    let stream = KwinStream::open(display)?;
    let negotiated = Arc::new(Mutex::new(None::<Negotiated>));
    let stop = Arc::new(Mutex::new(None::<RunStop>));
    let held = Arc::new(Mutex::new(HashMap::<usize, usize>::new()));
    let next_slot = Arc::new(Mutex::new(0usize));
    let wake_requested = Arc::new(AtomicBool::new(false));
    let stats_enabled = std::env::var_os("PIXELFLUX_KWIN_STATS").is_some_and(|value| value != "0");
    let stats_frames = Arc::new(AtomicU64::new(0));
    let stats_callbacks = Arc::new(AtomicU64::new(0));
    let stats_no_slot = Arc::new(AtomicU64::new(0));
    let stats_cursor_only = Arc::new(AtomicU64::new(0));
    let stats_started = Instant::now();

    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None)
        .map_err(|e| format!("创建 KWin PipeWire main loop 失败: {e}"))?;
    let context = pw::context::ContextRc::new(&mainloop, None)
        .map_err(|e| format!("创建 KWin PipeWire context 失败: {e}"))?;
    let core = context
        .connect_rc(None)
        .map_err(|e| format!("连接用户 PipeWire daemon 失败: {e}"))?;
    let pw_stream = pw::stream::StreamBox::new(
        &core,
        "selkies-kwin",
        properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
            *pw::keys::NODE_NAME => "selkies-kwin",
        },
    )
    .map_err(|e| format!("创建 KWin PipeWire stream 失败: {e}"))?;

    let negotiated_for_params = negotiated.clone();
    let negotiated_for_process = negotiated.clone();
    let stop_for_process = stop.clone();
    let held_for_process = held.clone();
    let slot_for_process = next_slot.clone();
    let commands_for_process = commands.clone();
    let frames_for_process = frames.clone();
    let mainloop_for_process = mainloop.clone();
    let stats_frames_for_process = stats_frames.clone();
    let stats_callbacks_for_process = stats_callbacks.clone();
    let stats_no_slot_for_process = stats_no_slot.clone();
    let stats_cursor_only_for_process = stats_cursor_only.clone();
    // 光标交付状态机：只在本 capture 线程里使用，随流重启一起重建。
    let mut cursor_state = crate::wayland::host_cursor::DeliveryState::default();
    let _listener = pw_stream
        .add_local_listener::<()>()
        .state_changed(|_, _, old, new| {
            println!("[KWinCapture] PipeWire state {old:?} -> {new:?}");
        })
        .param_changed(move |_, _, id, pod| {
            let Some(pod) = pod else { return };
            if id != pw::spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut format = VideoInfoRaw::new();
            if let Err(error) = format.parse(pod) {
                eprintln!("[KWinCapture] PipeWire format 解析失败: {error}");
                return;
            }
            let size = format.size();
            let rate = format.framerate();
            let max_rate = format.max_framerate();
            let effective_rate = if rate.num != 0 && rate.denom != 0 {
                rate
            } else {
                max_rate
            };
            let modifier = format.modifier();
            println!(
                "[KWinCapture] DMA-BUF format {:?} {}x{} fps={}/{} modifier={modifier}",
                format.format(),
                size.width,
                size.height,
                effective_rate.num,
                effective_rate.denom
            );
            *negotiated_for_params.lock().unwrap() = Some(Negotiated {
                format: format.format(),
                width: size.width,
                height: size.height,
                fps_num: effective_rate.num,
                fps_den: effective_rate.denom,
                modifier,
            });
        })
        .process(move |stream, _| {
            let generation = generation;
            if stats_enabled {
                stats_callbacks_for_process.fetch_add(1, Ordering::Relaxed);
            }
            crate::perf::kwin_callback();
            let held_guard = &mut *held_for_process.lock().unwrap();
            if let Some(stop_reason @ (RunStop::Restart { .. } | RunStop::Idle)) =
                drain_release(stream, &commands_for_process, held_guard, generation)
            {
                *stop_for_process.lock().unwrap() = Some(stop_reason);
                mainloop_for_process.quit();
                return;
            }

            let raw = unsafe { stream.dequeue_raw_buffer() };
            // 光标 metadata 先于视频帧处理：cursor-only 帧同样携带新形状，
            // 不能因为“没有视频内容”而丢掉。
            if let Some(meta) = unsafe { crate::wayland::host_cursor::read_meta(raw) } {
                let delivery = cursor_state.observe(&meta);
                crate::wayland::host_cursor::deliver(delivery);
            }
            let Some(data) = (unsafe { first_data(raw) }) else {
                if !raw.is_null() {
                    unsafe { stream.queue_raw_buffer(raw) };
                }
                eprintln!("[KWinCapture] PipeWire DMA-BUF buffer 没有 data plane");
                *stop_for_process.lock().unwrap() = Some(RunStop::Idle);
                mainloop_for_process.quit();
                return;
            };
            if data.type_() != DataType::DmaBuf {
                unsafe { stream.queue_raw_buffer(raw) };
                eprintln!(
                    "[KWinCapture] 严格模式拒绝 {:?}，禁止 SHM/CPU fallback",
                    data.type_()
                );
                *stop_for_process.lock().unwrap() = Some(RunStop::Idle);
                mainloop_for_process.quit();
                return;
            }
            // KWin 把“只有光标 metadata、没有视频内容”的 buffer 标成 CORRUPTED：
            // 这里只归还 buffer，不构造 HostFrame、不进编码器，也不计入视频帧数。
            if crate::wayland::host_cursor::frame_content(data.chunk().flags())
                == crate::wayland::host_cursor::FrameContent::CursorOnly
            {
                unsafe { stream.queue_raw_buffer(raw) };
                crate::perf::kwin_cursor_only();
                if stats_enabled {
                    stats_cursor_only_for_process.fetch_add(1, Ordering::Relaxed);
                }
                return;
            }
            let Some(current) = *negotiated_for_process.lock().unwrap() else {
                unsafe { stream.queue_raw_buffer(raw) };
                eprintln!("[KWinCapture] 收到 DMA-BUF 帧前没有格式协商结果");
                *stop_for_process.lock().unwrap() = Some(RunStop::Idle);
                mainloop_for_process.quit();
                return;
            };
            if current.width as i32 != width
                || current.height as i32 != height
                || current.fps_num != fps
                || current.fps_den != 1
            {
                unsafe { stream.queue_raw_buffer(raw) };
                eprintln!(
                    "[KWinCapture] PipeWire 协商结果 {}x{}@{}/{} 不符合目标 {}x{}@{}",
                    current.width,
                    current.height,
                    current.fps_num,
                    current.fps_den,
                    width,
                    height,
                    fps
                );
                *stop_for_process.lock().unwrap() = Some(RunStop::Idle);
                mainloop_for_process.quit();
                return;
            }
            let dmabuf = match build_dmabuf(data, current) {
                Ok(dmabuf) => dmabuf,
                Err(error) => {
                    unsafe { stream.queue_raw_buffer(raw) };
                    eprintln!("[KWinCapture] DMA-BUF 导入描述失败: {error}");
                    *stop_for_process.lock().unwrap() = Some(RunStop::Idle);
                    mainloop_for_process.quit();
                    return;
                }
            };
            let mut slot = slot_for_process.lock().unwrap();
            let chosen = (0..KWIN_IN_FLIGHT_SLOTS).find(|candidate| !held_guard.contains_key(candidate));
            let Some(chosen) = chosen else {
                unsafe { stream.queue_raw_buffer(raw) };
                crate::perf::kwin_no_slot();
                if stats_enabled {
                    stats_no_slot_for_process.fetch_add(1, Ordering::Relaxed);
                }
                return;
            };
            *slot = (chosen + 1) % KWIN_IN_FLIGHT_SLOTS;
            held_guard.insert(chosen, raw as usize);
            crate::perf::kwin_video();
            if stats_enabled {
                let count = stats_frames_for_process.fetch_add(1, Ordering::Relaxed) + 1;
                if count % 300 == 0 {
                    let elapsed_ms = stats_started.elapsed().as_millis();
                    let fps = (count as f64) / stats_started.elapsed().as_secs_f64().max(0.001);
                    let callbacks = stats_callbacks_for_process.load(Ordering::Relaxed);
                    let no_slot = stats_no_slot_for_process.load(Ordering::Relaxed);
                    let cursor_only = stats_cursor_only_for_process.load(Ordering::Relaxed);
                    println!(
                        "KWIN_CAPTURE_STATS width={width} height={height} frames={count} callbacks={callbacks} dropped_no_slot={no_slot} cursor_only={cursor_only} elapsed_ms={elapsed_ms} fps={fps:.2} dmabuf=true"
                    );
                }
            }
            if !frames_for_process.send(HostFrame {
                generation,
                slot: chosen,
                dmabuf: Some(dmabuf),
                cpu: None,
                width,
                height,
                damage: vec![Rectangle::new((0, 0).into(), (width, height).into())],
            }) {
                held_guard.remove(&chosen);
                unsafe { stream.queue_raw_buffer(raw) };
                *stop_for_process.lock().unwrap() = Some(RunStop::Idle);
                mainloop_for_process.quit();
            }
        })
        .register()
        .map_err(|e| format!("注册 KWin PipeWire listener 失败: {e}"))?;

    // 静态桌面可能没有新的 PipeWire process 回调；resize/release 仍必须立即唤醒。
    let wake_for_io = wake_requested.clone();
    let mainloop_for_io = mainloop.clone();
    let _wake_source =
        mainloop
            .loop_()
            .add_io(wake_rd, pw::spa::support::system::IoFlags::IN, move |fd| {
                drain_pipe(fd.as_raw_fd());
                wake_for_io.store(true, Ordering::Release);
                mainloop_for_io.quit();
            });

    let params = make_dmabuf_params(width as u32, height as u32, fps)?;
    let meta_params = make_cursor_meta_params()?;
    let pod = Pod::from_bytes(&params).ok_or("创建 KWin DMA-BUF 参数 Pod 失败")?;
    let meta_pod = Pod::from_bytes(&meta_params).ok_or("创建 KWin cursor meta 参数 Pod 失败")?;
    let buffers_params = make_buffers_params(KWIN_STREAM_BUFFERS)?;
    let buffers_any_params = make_buffers_params(0)?;
    let buffers_pod = Pod::from_bytes(&buffers_params).ok_or("创建 KWin buffers 参数 Pod 失败")?;
    let buffers_any_pod = Pod::from_bytes(&buffers_any_params).ok_or("创建 KWin buffers 参数 Pod 失败")?;
    // 只“增加”Meta 与 Buffers 请求：流属性与格式提案保持与原实现逐字节一致，否则 KWin
    // 的格式协商会以 "no more input formats" 失败。
    let mut pods = [pod, meta_pod, buffers_pod, buffers_any_pod];
    pw_stream
        .connect(
            spa::utils::Direction::Input,
            Some(stream.node_id),
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::NO_CONVERT,
            &mut pods,
        )
        .map_err(|e| format!("连接 KWin PipeWire node {} 失败: {e}", stream.node_id))?;
    println!(
        "[KWinCapture] connected node={} with DMA-BUF only",
        stream.node_id
    );
    super::kwin_output::KWinOutputController::repaint()?;
    loop {
        mainloop.run();
        if wake_requested.swap(false, Ordering::AcqRel) {
            let mut held_guard = held.lock().unwrap();
            if let Some(stop_reason) =
                drain_release(&pw_stream, &commands, &mut held_guard, generation)
            {
                *stop.lock().unwrap() = Some(stop_reason);
            }
            drop(held_guard);
            if stop.lock().unwrap().is_none() {
                continue;
            }
        }
        break;
    }

    let mut held_guard = held.lock().unwrap();
    for (_, raw) in held_guard.drain() {
        unsafe { pw_stream.queue_raw_buffer(raw as *mut pw::sys::pw_buffer) };
    }
    drop(held_guard);
    if stats_enabled {
        let count = stats_frames.load(Ordering::Relaxed);
        let callbacks = stats_callbacks.load(Ordering::Relaxed);
        let no_slot = stats_no_slot.load(Ordering::Relaxed);
        let cursor_only = stats_cursor_only.load(Ordering::Relaxed);
        let elapsed_ms = stats_started.elapsed().as_millis();
        let fps = (count as f64) / stats_started.elapsed().as_secs_f64().max(0.001);
        println!(
            "KWIN_CAPTURE_SUMMARY width={width} height={height} frames={count} callbacks={callbacks} dropped_no_slot={no_slot} cursor_only={cursor_only} elapsed_ms={elapsed_ms} fps={fps:.2} dmabuf=true"
        );
    }
    Ok(stop.lock().unwrap().take().unwrap_or(RunStop::Idle))
}

/// KWin host capture thread. 该入口只允许 DMA-BUF，失败即结束线程，不会回退到
/// pixelflux 自己的 compositor、wlroots 或 SHM。
pub(crate) fn capture_loop(
    display: &str,
    _index: usize,
    _expected_name: Option<String>,
    from_main: std::sync::mpsc::Receiver<ToHost>,
    wake_rd: std::os::fd::OwnedFd,
    frames: &FrameSink,
    sizes: Arc<Mutex<Vec<(i32, i32)>>>,
    registry_index: usize,
) -> Result<(), String> {
    let commands = Arc::new(Mutex::new(from_main));
    let first = loop {
        match commands.lock().unwrap().recv() {
            Ok(ToHost::Start { width, height, .. }) => break (width, height),
            Ok(ToHost::Idle) => continue,
            Ok(ToHost::Release { .. }) => continue,
            Err(_) => return Ok(()),
        }
    };
    let mut generation = 1_u64;
    let mut target = first;
    loop {
        let outcome = run_pipewire_capture(
            display,
            target.0,
            target.1,
            60,
            generation,
            commands.clone(),
            wake_rd
                .try_clone()
                .map_err(|error| format!("复制 KWin capture wake fd 失败: {error}"))?,
            frames,
            &sizes,
            registry_index,
        )?;
        match outcome {
            RunStop::Idle => loop {
                match commands.lock().unwrap().recv() {
                    Ok(ToHost::Start { width, height, .. }) => {
                        target = (width, height);
                        break;
                    }
                    Ok(ToHost::Idle | ToHost::Release { .. }) => continue,
                    Err(_) => return Ok(()),
                }
            },
            RunStop::Restart { width, height, .. } => target = (width, height),
        }
        generation = generation.wrapping_add(1);
    }
}

/// 在 `display` 上打开 KWin screencast，并严格验证 PipeWire 只返回 DMA-BUF 帧。
pub fn probe(
    display: &str,
    width: i32,
    height: i32,
    fps: u32,
    duration: Duration,
) -> Result<ProbeReport, String> {
    if !(MIN_WIDTH..=MAX_WIDTH).contains(&width) || !(MIN_HEIGHT..=MAX_HEIGHT).contains(&height) {
        return Err(format!("探针分辨率超出范围: {width}x{height}"));
    }
    if fps == 0 {
        return Err("探针帧率必须大于 0".into());
    }
    // 直接探针也走同一条输出控制路径，否则虚拟输出仍停在启动的 4K 模式，
    // 探针请求的尺寸只会成为 PipeWire 格式候选而不会真正改变桌面输出。
    super::kwin_output::KWinOutputController::apply(display, width, height, fps)?;
    // 帧路径诊断探针只统计 DMA-BUF 帧，不需要光标数据：保持 hidden 模式，
    // 避免 KWin 为这条一次性流提取位图。
    let stream = KwinStream::open_with_pointer(display, POINTER_HIDDEN)?;
    let report = Arc::new(Mutex::new(ProbeReport {
        node_id: stream.node_id,
        ..ProbeReport::default()
    }));
    run_pipewire_probe(
        stream.node_id,
        width as u32,
        height as u32,
        fps,
        duration,
        report.clone(),
    )?;
    let final_report = report.lock().unwrap().clone();
    if final_report.non_dmabuf_frames != 0 {
        return Err(format!(
            "KWin PipeWire 返回了 {} 个非 DMA-BUF 帧，禁止 CPU/SHM 回退",
            final_report.non_dmabuf_frames
        ));
    }
    if final_report.dmabuf_frames == 0 {
        return Err("探针窗口内没有收到 DMA-BUF 帧".into());
    }
    if (final_report.width, final_report.height) != (width as u32, height as u32) {
        return Err(format!(
            "KWin/PipeWire 协商了 {}x{}，不是请求的 {}x{}",
            final_report.width, final_report.height, width, height
        ));
    }
    if final_report.framerate_num == 0
        || final_report.framerate_den == 0
        || final_report.framerate_num as u64 != fps as u64 * final_report.framerate_den as u64
    {
        return Err(format!(
            "KWin/PipeWire 协商帧率 {}/{}，不是请求的 {} FPS",
            final_report.framerate_num, final_report.framerate_den, fps
        ));
    }
    if final_report.modifier.is_none() {
        return Err("PipeWire 协商结果没有 DMA-BUF modifier".into());
    }
    Ok(final_report)
}

fn run_pipewire_probe(
    node_id: u32,
    width: u32,
    height: u32,
    fps: u32,
    duration: Duration,
    report: Arc<Mutex<ProbeReport>>,
) -> Result<(), String> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None)
        .map_err(|e| format!("创建 PipeWire main loop 失败: {e}"))?;
    let context = pw::context::ContextRc::new(&mainloop, None)
        .map_err(|e| format!("创建 PipeWire context 失败: {e}"))?;
    let core = context
        .connect_rc(None)
        .map_err(|e| format!("连接用户 PipeWire daemon 失败: {e}"))?;
    let stream = pw::stream::StreamBox::new(
        &core,
        "selkies-kwin-poc",
        properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
            *pw::keys::NODE_NAME => "selkies-kwin-poc",
        },
    )
    .map_err(|e| format!("创建 PipeWire stream 失败: {e}"))?;

    let report_for_params = report.clone();
    let report_for_frames = report.clone();
    let mainloop_for_error = mainloop.clone();
    let _listener = stream
        .add_local_listener::<()>()
        .state_changed(|_, _, old, new| {
            println!("[KWinCapture] PipeWire state {old:?} -> {new:?}");
        })
        .param_changed(move |_, _, id, param| {
            let Some(param) = param else { return };
            if id != pw::spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut format = VideoInfoRaw::new();
            if let Err(e) = format.parse(param) {
                eprintln!("[KWinCapture] PipeWire 格式解析失败: {e}");
                return;
            }
            let size = format.size();
            let rate = format.framerate();
            let max_rate = format.max_framerate();
            // KWin advertises a zero default rate and places the real refresh cap
            // in max-framerate; use that value for the hard 60 FPS gate.
            let effective_rate = if rate.num != 0 && rate.denom != 0 {
                rate
            } else {
                max_rate
            };
            let modifier = format
                .flags()
                .contains(VideoFlags::MODIFIER)
                .then_some(format.modifier());
            println!(
                "[KWinCapture] DMA-BUF format {:?} {}x{} fps={}/{} max_fps={}/{} modifier={:?}",
                format.format(),
                size.width,
                size.height,
                effective_rate.num,
                effective_rate.denom,
                max_rate.num,
                max_rate.denom,
                modifier
            );
            let mut current = report_for_params.lock().unwrap();
            current.width = size.width;
            current.height = size.height;
            current.framerate_num = effective_rate.num;
            current.framerate_den = effective_rate.denom;
            current.max_framerate_num = max_rate.num;
            current.max_framerate_den = max_rate.denom;
            current.modifier = modifier;
        })
        .process(move |stream, _| {
            let Some(mut buffer) = stream.dequeue_buffer() else {
                return;
            };
            let Some(data) = buffer.datas_mut().first_mut() else {
                eprintln!("[KWinCapture] PipeWire DMA-BUF buffer 没有 data plane");
                mainloop_for_error.quit();
                return;
            };
            if data.type_() != DataType::DmaBuf {
                let mut current = report_for_frames.lock().unwrap();
                current.non_dmabuf_frames += 1;
                eprintln!(
                    "[KWinCapture] 严格模式拒绝 {:?} buffer，禁止 SHM/CPU 回退",
                    data.type_()
                );
                mainloop_for_error.quit();
                return;
            }
            if data.fd() < 0 {
                eprintln!("[KWinCapture] PipeWire DMA-BUF plane fd 无效");
                mainloop_for_error.quit();
                return;
            }
            let mut current = report_for_frames.lock().unwrap();
            current.dmabuf_frames += 1;
        })
        .register()
        .map_err(|e| format!("注册 PipeWire listener 失败: {e}"))?;

    let params = make_dmabuf_params(width, height, fps)?;
    let pod = Pod::from_bytes(&params).ok_or("创建 PipeWire DMA-BUF 参数 Pod 失败")?;
    let mut pods = [pod];
    stream
        .connect(
            spa::utils::Direction::Input,
            Some(node_id),
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::NO_CONVERT,
            &mut pods,
        )
        .map_err(|e| format!("连接 KWin PipeWire node {node_id} 失败: {e}"))?;
    println!("[KWinCapture] PipeWire 已连接 node={node_id}，仅接受 DMA-BUF");

    let mainloop_for_timer = mainloop.clone();
    let timer = mainloop
        .loop_()
        .add_timer(move |_| mainloop_for_timer.quit());
    timer
        .update_timer(Some(duration), None)
        .into_result()
        .map_err(|e| format!("启动 PipeWire 探针定时器失败: {e}"))?;
    mainloop.run();
    Ok(())
}

fn make_dmabuf_params(width: u32, height: u32, fps: u32) -> Result<Vec<u8>, String> {
    use pw::spa::pod::serialize::PodSerializer;
    use pw::spa::pod::{Property, PropertyFlags, Value};
    use std::io::Cursor;

    let mut object = spa::pod::object!(
        spa::utils::SpaTypes::ObjectParamFormat,
        spa::param::ParamType::EnumFormat,
        spa::pod::property!(
            spa::param::format::FormatProperties::MediaType,
            Id,
            spa::param::format::MediaType::Video
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::MediaSubtype,
            Id,
            spa::param::format::MediaSubtype::Raw
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoFormat,
            Choice,
            Enum,
            Id,
            spa::param::video::VideoFormat::BGRx,
            spa::param::video::VideoFormat::BGRx,
            spa::param::video::VideoFormat::BGRA
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoSize,
            Choice,
            Range,
            Rectangle,
            spa::utils::Rectangle { width, height },
            spa::utils::Rectangle {
                width: 1,
                height: 1
            },
            spa::utils::Rectangle {
                width: MAX_WIDTH as u32,
                height: MAX_HEIGHT as u32
            }
        ),
        spa::pod::property!(
            spa::param::format::FormatProperties::VideoFramerate,
            Choice,
            Range,
            Fraction,
            spa::utils::Fraction { num: fps, denom: 1 },
            spa::utils::Fraction { num: 0, denom: 1 },
            spa::utils::Fraction {
                num: 1000,
                denom: 1
            }
        ),
    );
    // DRM_FORMAT_MOD_LINEAR 的 ABI 值固定为 0；这里不再引入另一个 DRM FFI。
    let linear = 0_i64;
    object.properties.push(Property {
        key: spa::param::format::FormatProperties::VideoModifier.as_raw(),
        flags: PropertyFlags::MANDATORY | PropertyFlags::DONT_FIXATE,
        value: Value::Choice(spa::pod::ChoiceValue::Long(spa::utils::Choice(
            spa::utils::ChoiceFlags::empty(),
            spa::utils::ChoiceEnum::Enum {
                default: linear,
                alternatives: vec![linear],
            },
        ))),
    });
    PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Object(object))
        .map(|serialized| serialized.0.into_inner())
        .map_err(|e| format!("序列化 DMA-BUF 格式失败: {e:?}"))
}

/// 请求 `SPA_META_Cursor`：KWin 只往 consumer 显式请求过的 meta 区域写光标数据。
///
/// 区域大小与 KWin `screencaststream.cpp` 的 `CURSOR_META_SIZE(256, 256)` 对齐
/// （`sizeof(spa_meta_cursor) + sizeof(spa_meta_bitmap) + 256 * 256 * 4`），因为位图
/// 是就地写在 cursor meta 之后的。
fn make_cursor_meta_params() -> Result<Vec<u8>, String> {
    use pw::spa::pod::serialize::PodSerializer;
    use pw::spa::pod::{Object, Property, Value};
    use std::io::Cursor;

    let cursor_size = std::mem::size_of::<spa::sys::spa_meta_cursor>()
        + std::mem::size_of::<spa::sys::spa_meta_bitmap>()
        + KWIN_CURSOR_META_SIDE * KWIN_CURSOR_META_SIDE * 4;
    let object = Object {
        type_: spa::utils::SpaTypes::ObjectParamMeta.as_raw(),
        id: spa::param::ParamType::Meta.as_raw(),
        properties: vec![
            Property::new(
                spa::sys::SPA_PARAM_META_type,
                Value::Id(spa::utils::Id(spa::sys::SPA_META_Cursor as u32)),
            ),
            Property::new(
                spa::sys::SPA_PARAM_META_size,
                Value::Int(cursor_size as i32),
            ),
        ],
    };
    PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Object(object))
        .map(|serialized| serialized.0.into_inner())
        .map_err(|e| format!("序列化 cursor meta 参数失败: {e:?}"))
}

/// consumer 侧的 Buffers 提案：`at_least > 0` 时要求至少这么多个 buffer，与 KWin 的
/// 区间求交后就是这个数；`0` 不设下限，作为 KWin 给不到时的退路，协商结果同默认。
fn make_buffers_params(at_least: i32) -> Result<Vec<u8>, String> {
    use pw::spa::pod::serialize::PodSerializer;
    use pw::spa::pod::{ChoiceValue, Object, Property, Value};
    use pw::spa::utils::{Choice, ChoiceEnum, ChoiceFlags};
    use std::io::Cursor;

    let (default, min) = if at_least > 0 { (at_least, at_least) } else { (2, 1) };
    let object = Object {
        type_: spa::utils::SpaTypes::ObjectParamBuffers.as_raw(),
        id: spa::param::ParamType::Buffers.as_raw(),
        properties: vec![Property::new(
            spa::sys::SPA_PARAM_BUFFERS_buffers,
            Value::Choice(ChoiceValue::Int(Choice(
                ChoiceFlags::empty(),
                ChoiceEnum::Range { default, min, max: 16 },
            ))),
        )],
    };
    PodSerializer::serialize(Cursor::new(Vec::new()), &Value::Object(object))
        .map(|serialized| serialized.0.into_inner())
        .map_err(|e| format!("序列化 buffers 参数失败: {e:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_invalid_probe_size() {
        let error = probe("wayland-test", 0, 1080, 60, Duration::from_millis(1)).unwrap_err();
        assert!(error.contains("分辨率"));
    }
}
