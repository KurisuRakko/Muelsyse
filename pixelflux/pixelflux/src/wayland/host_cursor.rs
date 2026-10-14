//! KWin host capture 的光标投递。
//!
//! KWin 的 `zkde_screencast` 在 `metadata` pointer mode 下不把光标画进视频，而是每帧
//! 通过 `SPA_META_Cursor` 给出光标位置/hotspot，并在形状变化时附带一张位图。本模块
//! 负责三件事：
//!
//! 1. 从 PipeWire 的原始 `spa_buffer` 里安全地把 `SPA_META_Cursor` 复制出来（所有
//!    偏移、长度、stride、尺寸都做边界检查，畸形 metadata 只丢弃位图而不越界）；
//! 2. 用一个纯状态机决定何时真的需要通知客户端：`id == 0` 只发一次隐藏，位图与
//!    hotspot 都没变时什么都不发，hotspot 变化时复用上一张位图；
//! 3. 把 premultiplied RGBA 位图按既有 `wayland::cursor::cap_and_encode` 路径缩放并
//!    转成直通 alpha 的 PNG，再以 X11/合成器完全相同的契约调用 Python 回调：
//!    `cb(msg_type, png, hot_x, hot_y)`。
//!
//! 客户端只消费位图与 hotspot（CSS 光标由浏览器按本地指针位置绘制），因此纯粹的
//! position 变化记录在状态里用于诊断，不需要产生协议消息。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Mutex;

use image::RgbaImage;
use pipewire as pw;
use pyo3::prelude::*;
use pyo3::types::PyBytes;

use crate::wayland::cursor::{CappedSprite, cap_and_encode, scaled_hotspot};

/// KWin `screencaststream.cpp` 固定按 256×256 分配 cursor bitmap（`CURSOR_META_SIZE`），
/// 超过该边长的描述不可能是合法光标，一律拒绝。
const MAX_BITMAP_SIDE: u32 = 256;

/// 缓存的光标上界：一次会话里形状数量有限，超过后按最旧条目淘汰。
const SPRITE_CACHE_MAX: usize = 32;

/// Python 回调槽；`None` 表示消费者还没注册或不关心光标。
static CALLBACK: Mutex<Option<Py<PyAny>>> = Mutex::new(None);

/// 交付前的边长上限（selkies 的 `cursor_size_cap`，已按 DPI 缩放）。
static SIZE_CAP: AtomicI32 = AtomicI32::new(128);

/// 是否已经因为 adapter 不支持而提示过，避免每条帧刷屏。
static SHUTDOWN: AtomicBool = AtomicBool::new(false);

/// 已编码的位图，键为 `(内容 hash, cap)`：hotspot 变化只需换 hotspot。
static SPRITE_CACHE: Mutex<Option<HashMap<(u64, i32), CappedSprite>>> = Mutex::new(None);

/// 从 `SPA_META_Cursor` 复制出来的一张位图（紧凑 RGBA，premultiplied）。
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct Bitmap {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) bytes: Vec<u8>,
}

/// 一帧 `SPA_META_Cursor` 的内容（已脱离 buffer 生命周期）。
pub(crate) struct Meta {
    pub(crate) id: u32,
    pub(crate) position: (i32, i32),
    pub(crate) hotspot: (i32, i32),
    pub(crate) bitmap: Option<Bitmap>,
}

/// 状态机给出的投递动作。
pub(crate) enum Delivery {
    /// 与上次投递完全一致，不需要通知客户端。
    None,
    /// 光标离开/没有有效光标：发一次隐藏。
    Hide,
    /// 新形状或新 hotspot。
    Sprite { bitmap: Bitmap, hotspot: (i32, i32) },
}

/// KWin 对 buffer 的两种内容形态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FrameContent {
    /// 带视频内容：照常构造 HostFrame 交给编码器。
    Video,
    /// 只有光标 metadata（KWin 把 chunk 标成 `SPA_CHUNK_FLAG_CORRUPTED`）：
    /// 这段内存没有可读视频内容，只能取光标 metadata 后归还 buffer。
    CursorOnly,
}

/// 由 chunk flags 判定这一帧该走视频路径还是只取 metadata。
pub(crate) fn frame_content(flags: pw::spa::buffer::ChunkFlags) -> FrameContent {
    if flags.contains(pw::spa::buffer::ChunkFlags::CORRUPTED) {
        FrameContent::CursorOnly
    } else {
        FrameContent::Video
    }
}

/// 把 metadata 事件去重成投递动作的纯状态机（可单测，无 IO）。
///
/// `KWin` 只在形状变化时携带位图，其他帧只有 position/hotspot；因此这里缓存最近一次
/// 下发过的位图，hotspot 变化时直接复用像素，不重新编码也不重新发送整张 PNG。
#[derive(Default)]
pub(crate) struct DeliveryState {
    /// 最近一次观察到的可见性，`None` 表示还没观察过。
    visible: Option<bool>,
    /// 最近一次真正下发过的 `(hash, 位图, hot_x, hot_y)`。
    last_sprite: Option<(u64, Bitmap, i32, i32)>,
    /// 最近一帧的 position，仅用于诊断与测试断言。
    last_position: Option<(i32, i32)>,
}

impl DeliveryState {
    /// 观察一帧 metadata，返回是否需要通知客户端。
    pub(crate) fn observe(&mut self, meta: &Meta) -> Delivery {
        self.last_position = Some(meta.position);

        if meta.id == 0 {
            self.last_sprite = None;
            if self.visible == Some(false) {
                return Delivery::None;
            }
            self.visible = Some(false);
            return Delivery::Hide;
        }
        self.visible = Some(true);

        let (hash, hotspot) = match meta.bitmap.as_ref() {
            Some(bitmap) => (Some(bitmap_hash(bitmap)), meta.hotspot),
            None => (None, meta.hotspot),
        };
        if let (Some(hash), Some((last_hash, _, last_x, last_y))) = (hash, self.last_sprite.as_ref())
            && *last_hash == hash
            && (*last_x, *last_y) == hotspot
        {
            return Delivery::None;
        }

        if let Some(bitmap) = meta.bitmap.as_ref() {
            let hash = hash.expect("bitmap 存在时 hash 必然存在");
            self.last_sprite = Some((hash, bitmap.clone(), hotspot.0, hotspot.1));
            return Delivery::Sprite {
                bitmap: bitmap.clone(),
                hotspot,
            };
        }

        // 只有 hotspot 变化：复用上一张位图。
        if let Some((hash, bitmap, last_x, last_y)) = self.last_sprite.clone()
            && (last_x, last_y) != hotspot
        {
            self.last_sprite = Some((hash, bitmap.clone(), hotspot.0, hotspot.1));
            return Delivery::Sprite { bitmap, hotspot };
        }

        Delivery::None
    }

    /// 最近一帧的 position（诊断用）。
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) fn last_position(&self) -> Option<(i32, i32)> {
        self.last_position
    }
}

/// `xxh3` 内容哈希：同一个形状在 KWin 侧重复出现时用来判断“位图没变”。
fn bitmap_hash(bitmap: &Bitmap) -> u64 {
    let mut bytes = Vec::with_capacity(bitmap.bytes.len() + 8);
    bytes.extend_from_slice(&bitmap.width.to_le_bytes());
    bytes.extend_from_slice(&bitmap.height.to_le_bytes());
    bytes.extend_from_slice(&bitmap.bytes);
    xxhash_rust::xxh3::xxh3_64_with_seed(&bytes, 0)
}

/// 从 PipeWire 的原始 `pw_buffer` 里读出 `SPA_META_Cursor`。
///
/// 返回 `None` 表示该 buffer 没有 cursor metadata（例如 pointer mode 仍是 hidden）。
/// 位图字段任何一项越界/畸形都只丢掉位图，position/hotspot 仍然有效。
///
/// # Safety
/// `raw` 必须是当前 PipeWire process 回调给我们的 `pw_buffer` 指针，且只在回调期间使用。
pub(crate) unsafe fn read_meta(raw: *mut pw::sys::pw_buffer) -> Option<Meta> {
    use pw::spa::sys;

    if raw.is_null() {
        return None;
    }
    let buffer = unsafe { (*raw).buffer };
    if buffer.is_null() {
        return None;
    }

    let cursor_type = sys::SPA_META_Cursor;
    let cursor_size = std::mem::size_of::<sys::spa_meta_cursor>();
    let meta = unsafe { sys::spa_buffer_find_meta(buffer, cursor_type) };
    if meta.is_null() {
        return None;
    }
    let meta_size = unsafe { (*meta).size } as usize;
    if meta_size < cursor_size {
        return None;
    }
    let cursor = unsafe { sys::spa_buffer_find_meta_data(buffer, cursor_type, cursor_size) }
        as *const sys::spa_meta_cursor;
    if cursor.is_null() {
        return None;
    }

    // SAFETY: `spa_buffer_find_meta_data` 已确认该 meta 至少容纳一个 spa_meta_cursor，
    // 且指针来自 KWin 在当前回调里填充的 buffer。
    let (id, position, hotspot, bitmap_offset) = unsafe {
        let cursor = &*cursor;
        (
            cursor.id,
            (cursor.position.x, cursor.position.y),
            (cursor.hotspot.x, cursor.hotspot.y),
            cursor.bitmap_offset,
        )
    };

    Some(Meta {
        id,
        position,
        hotspot,
        bitmap: unsafe { read_bitmap(cursor, meta_size, bitmap_offset) },
    })
}

/// 读取并校验 `spa_meta_bitmap`；任何越界或畸形都返回 `None`。
///
/// # Safety
/// `cursor` 指向 `meta_size` 字节的 cursor meta 区域。
unsafe fn read_bitmap(
    cursor: *const pw::spa::sys::spa_meta_cursor,
    meta_size: usize,
    bitmap_offset: u32,
) -> Option<Bitmap> {
    use pw::spa::sys;

    let offset = bitmap_offset as usize;
    if offset == 0 || offset < std::mem::size_of::<sys::spa_meta_cursor>() {
        return None;
    }
    let header_end = offset.checked_add(std::mem::size_of::<sys::spa_meta_bitmap>())?;
    if header_end > meta_size {
        return None;
    }

    let bitmap_ptr = unsafe { (cursor as *const u8).add(offset) } as *const sys::spa_meta_bitmap;
    if bitmap_ptr.is_null() {
        return None;
    }
    let (format, width, height, stride, data_offset) = unsafe {
        let bitmap = &*bitmap_ptr;
        (
            bitmap.format,
            bitmap.size.width,
            bitmap.size.height,
            bitmap.stride,
            bitmap.offset as usize,
        )
    };

    // 只接受 KWin 实际写出的直通 RGBA/BGRA；其它格式视为“没有新位图”。
    let format_ok = format == sys::SPA_VIDEO_FORMAT_RGBA as u32
        || format == sys::SPA_VIDEO_FORMAT_BGRA as u32;
    if !format_ok
        || width == 0
        || height == 0
        || width > MAX_BITMAP_SIDE
        || height > MAX_BITMAP_SIDE
    {
        return None;
    }

    let row_bytes = (width as usize).checked_mul(4)?;
    let stride = stride.max(0) as usize;
    if stride < row_bytes || stride > MAX_BITMAP_SIDE as usize * 4 {
        return None;
    }

    // `spa_meta_bitmap.offset` 相对 bitmap 头本身（KWin 写的是 sizeof(spa_meta_bitmap)），
    // 因此数据起点是 bitmap 头偏移加它，而不是再加一次头长度。
    let data_start = offset.checked_add(data_offset)?;
    let data_len = stride.checked_mul(height as usize)?;
    let data_end = data_start.checked_add(data_len)?;
    if data_end > meta_size {
        return None;
    }

    // SAFETY: 上面的检查保证 [data_start, data_end) 落在 meta 区域内。
    let source =
        unsafe { std::slice::from_raw_parts((cursor as *const u8).add(data_start), data_len) };
    let mut bytes = Vec::with_capacity(row_bytes * height as usize);
    for row in source.chunks_exact(stride).take(height as usize) {
        let mut pixel_row = row[..row_bytes].to_vec();
        if format == sys::SPA_VIDEO_FORMAT_BGRA as u32 {
            for pixel in pixel_row.chunks_exact_mut(4) {
                pixel.swap(0, 2);
            }
        }
        bytes.extend_from_slice(&pixel_row);
    }

    Some(Bitmap {
        width,
        height,
        bytes,
    })
}

/// 注册/替换 Python 回调（`None` 撤回）。
pub(crate) fn set_callback(callback: Option<Py<PyAny>>) {
    *CALLBACK.lock().unwrap() = callback;
}

/// 更新交付前的边长上限；缓存按键里带 cap，换 cap 不会命中旧尺寸。
pub(crate) fn set_size_cap(cap: i32) {
    SIZE_CAP.store(cap, Ordering::Relaxed);
}

/// 解释器退出：撤掉回调，后续投递直接丢弃。
pub(crate) fn shutdown() {
    SHUTDOWN.store(true, Ordering::Relaxed);
    *CALLBACK.lock().unwrap() = None;
}

/// 投递一个动作；只在有回调、未退出时调用 Python。
pub(crate) fn deliver(delivery: Delivery) {
    if SHUTDOWN.load(Ordering::Relaxed) {
        return;
    }
    match delivery {
        Delivery::None => {}
        Delivery::Hide => call_callback("hide", Vec::new(), 0, 0),
        Delivery::Sprite { bitmap, hotspot } => {
            let cap = SIZE_CAP.load(Ordering::Relaxed);
            let hash = bitmap_hash(&bitmap);
            let Some((png, hot_x, hot_y)) = encode_sprite(hash, &bitmap, hotspot, cap) else {
                eprintln!("[KWinCapture] cursor 位图编码失败，保持上一张 shape");
                return;
            };
            call_callback("png", png, hot_x, hot_y);
        }
    }
}

/// 编码（或在缓存里命中）一张位图，并把 hotspot 按缩放后的尺寸重算。
fn encode_sprite(
    hash: u64,
    bitmap: &Bitmap,
    hotspot: (i32, i32),
    cap: i32,
) -> Option<(Vec<u8>, i32, i32)> {
    let key = (hash, cap);
    let mut cache = SPRITE_CACHE.lock().unwrap();
    let cache = cache.get_or_insert_with(HashMap::new);
    if !cache.contains_key(&key) {
        if cache.len() >= SPRITE_CACHE_MAX {
            if let Some(&evict) = cache.keys().next() {
                cache.remove(&evict);
            }
        }
        let image = RgbaImage::from_raw(bitmap.width, bitmap.height, bitmap.bytes.clone())?;
        let sprite = cap_and_encode(image, cap)?;
        cache.insert(key, sprite);
    }
    let sprite = cache.get(&key)?;
    let (hot_x, hot_y) = scaled_hotspot(sprite, hotspot.0, hotspot.1);
    Some((sprite.png.clone(), hot_x, hot_y))
}

/// 以既有契约调用 Python：`cb(msg_type, png, hot_x, hot_y)`。
fn call_callback(msg_type: &str, png: Vec<u8>, hot_x: i32, hot_y: i32) {
    Python::attach(|py| {
        let callback = {
            let guard = CALLBACK.lock().unwrap();
            guard.as_ref().map(|callback| callback.clone_ref(py))
        };
        if let Some(callback) = callback {
            let bytes = PyBytes::new(py, &png);
            if let Err(error) = callback.call1(py, (msg_type, bytes, hot_x, hot_y)) {
                eprintln!("[KWinCapture] cursor 回调失败: {error}");
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bitmap(width: u32, height: u32, fill: u8) -> Bitmap {
        Bitmap {
            width,
            height,
            bytes: vec![fill; (width * height * 4) as usize],
        }
    }

    fn meta(id: u32, position: (i32, i32), hotspot: (i32, i32), bitmap: Option<Bitmap>) -> Meta {
        Meta {
            id,
            position,
            hotspot,
            bitmap,
        }
    }

    #[test]
    fn hide_is_delivered_once() {
        let mut state = DeliveryState::default();
        assert!(matches!(
            state.observe(&meta(0, (10, 20), (0, 0), None)),
            Delivery::Hide
        ));
        assert!(matches!(
            state.observe(&meta(0, (11, 21), (0, 0), None)),
            Delivery::None
        ));
    }

    #[test]
    fn bitmap_is_delivered_and_then_silent() {
        let mut state = DeliveryState::default();
        let first = meta(7, (100, 200), (4, 4), Some(bitmap(32, 32, 0x40)));
        assert!(matches!(state.observe(&first), Delivery::Sprite { .. }));
        assert!(matches!(state.observe(&first), Delivery::None));

        // 同一张位图、新 position：仍然是 None（css 光标位置由浏览器本地指针决定）。
        let moved = meta(7, (300, 400), (4, 4), None);
        assert!(matches!(state.observe(&moved), Delivery::None));
        assert_eq!(state.last_position(), Some((300, 400)));
    }

    #[test]
    fn hotspot_change_reuses_last_bitmap() {
        let mut state = DeliveryState::default();
        let first = meta(7, (10, 10), (2, 2), Some(bitmap(16, 16, 0x20)));
        assert!(matches!(state.observe(&first), Delivery::Sprite { .. }));
        match state.observe(&meta(7, (10, 10), (5, 6), None)) {
            Delivery::Sprite { bitmap, hotspot } => {
                assert_eq!(hotspot, (5, 6));
                assert_eq!(bitmap.width, 16);
                assert_eq!(bitmap.bytes, first.bitmap.as_ref().unwrap().bytes);
            }
            _ => panic!("hotspot 变化必须重新下发"),
        }
    }

    #[test]
    fn new_bitmap_replaces_previous_one() {
        let mut state = DeliveryState::default();
        assert!(matches!(
            state.observe(&meta(1, (0, 0), (0, 0), Some(bitmap(8, 8, 1)))),
            Delivery::Sprite { .. }
        ));
        assert!(matches!(
            state.observe(&meta(2, (0, 0), (0, 0), Some(bitmap(8, 8, 2)))),
            Delivery::Sprite { .. }
        ));
        // 隐藏后旧位图不能复用。
        assert!(matches!(
            state.observe(&meta(0, (0, 0), (0, 0), None)),
            Delivery::Hide
        ));
        assert!(matches!(
            state.observe(&meta(3, (0, 0), (0, 0), None)),
            Delivery::None
        ));
    }

    #[test]
    fn premultiplied_alpha_becomes_straight_png() {
        // 一颗 alpha=128、premultiplied RGB=(128,0,0) 的像素应为 (255,0,0,128)；
        // alpha=0 的像素不能触发除零。
        let mut bytes = vec![0u8; 4 * 4];
        bytes[0..4].copy_from_slice(&[128, 0, 0, 128]);
        bytes[4..8].copy_from_slice(&[0, 0, 0, 0]);
        let sprite = Bitmap {
            width: 2,
            height: 2,
            bytes,
        };
        let (png, hot_x, hot_y) = encode_sprite(bitmap_hash(&sprite), &sprite, (1, 1), 0)
            .expect("编码应当成功");
        assert_eq!((hot_x, hot_y), (1, 1));
        let decoded = image::load_from_memory(&png).expect("PNG 可解码").to_rgba8();
        assert_eq!(decoded.get_pixel(0, 0).0, [255, 0, 0, 128]);
        assert_eq!(decoded.get_pixel(1, 0).0, [0, 0, 0, 0]);
    }

    #[test]
    fn cursor_only_frames_are_separated_from_video() {
        use pw::spa::buffer::ChunkFlags;
        // KWin 对 cursor-only 帧设 SPA_CHUNK_FLAG_CORRUPTED；视频帧 flags 为 NONE。
        assert_eq!(frame_content(ChunkFlags::CORRUPTED), FrameContent::CursorOnly);
        assert_eq!(frame_content(ChunkFlags::empty()), FrameContent::Video);
    }

    /// 合成一个只带 cursor meta 的 `pw_buffer`，用于读取路径的边界测试。
    struct SyntheticCursor {
        region: Vec<u8>,
        meta: pw::spa::sys::spa_meta,
        buffer: pw::spa::sys::spa_buffer,
        pw_buffer: pw::sys::pw_buffer,
    }

    impl SyntheticCursor {
        fn new(
            position: (i32, i32),
            hotspot: (i32, i32),
            bitmap: Option<(u32, u32, i32, Option<u32>)>,
        ) -> Self {
            use pw::spa::sys;
            const CURSOR: usize = std::mem::size_of::<sys::spa_meta_cursor>();
            const BITMAP: usize = std::mem::size_of::<sys::spa_meta_bitmap>();
            let (width, height, stride, offset_override) =
                bitmap.unwrap_or((0, 0, 0, None));
            let stride_usize = stride.max(0) as usize;
            let data_len = stride_usize.saturating_mul(height as usize);
            let declared_bitmap = if bitmap.is_some() { BITMAP } else { 0 };
            let mut region = vec![0u8; CURSOR + declared_bitmap + data_len];

            let cursor = region.as_mut_ptr() as *mut sys::spa_meta_cursor;
            unsafe {
                (*cursor).id = 1;
                (*cursor).position = sys::spa_point {
                    x: position.0,
                    y: position.1,
                };
                (*cursor).hotspot = sys::spa_point {
                    x: hotspot.0,
                    y: hotspot.1,
                };
                (*cursor).bitmap_offset = if bitmap.is_some() {
                    CURSOR as u32 + offset_override.unwrap_or(0)
                } else {
                    0
                };
                if bitmap.is_some() {
                    let bitmap_ptr = region.as_mut_ptr().add(CURSOR) as *mut sys::spa_meta_bitmap;
                    (*bitmap_ptr).format = sys::SPA_VIDEO_FORMAT_RGBA as u32;
                    (*bitmap_ptr).size = sys::spa_rectangle { width, height };
                    (*bitmap_ptr).stride = stride;
                    (*bitmap_ptr).offset = BITMAP as u32;
                    let data = region.as_mut_ptr().add(CURSOR + BITMAP);
                    for index in 0..data_len {
                        *data.add(index) = (index % 251) as u8;
                    }
                }
            }

            let meta = pw::spa::sys::spa_meta {
                type_: sys::SPA_META_Cursor,
                size: region.len() as u32,
                data: region.as_mut_ptr().cast(),
            };
            let mut buffer: sys::spa_buffer = unsafe { std::mem::zeroed() };
            buffer.n_metas = 1;
            buffer.metas = &meta as *const _ as *mut _;
            let mut pw_buffer: pw::sys::pw_buffer = unsafe { std::mem::zeroed() };
            pw_buffer.buffer = &buffer as *const _ as *mut _;
            Self {
                region,
                meta,
                buffer,
                pw_buffer,
            }
        }

        fn raw(&mut self) -> *mut pw::sys::pw_buffer {
            self.meta.data = self.region.as_mut_ptr().cast();
            self.buffer.metas = &self.meta as *const _ as *mut _;
            &mut self.pw_buffer
        }
    }

    #[test]
    fn read_meta_parses_valid_bitmap() {
        let mut synthetic = SyntheticCursor::new((120, 240), (3, 5), Some((32, 32, 32 * 4, None)));
        let meta = unsafe { read_meta(synthetic.raw()) }.expect("应有 cursor meta");
        assert_eq!(meta.id, 1);
        assert_eq!(meta.position, (120, 240));
        assert_eq!(meta.hotspot, (3, 5));
        let bitmap = meta.bitmap.expect("应有位图");
        assert_eq!((bitmap.width, bitmap.height), (32, 32));
        assert_eq!(bitmap.bytes.len(), 32 * 32 * 4);
    }

    #[test]
    fn read_meta_keeps_position_without_bitmap() {
        let mut synthetic = SyntheticCursor::new((7, 8), (1, 2), None);
        let meta = unsafe { read_meta(synthetic.raw()) }.expect("应有 cursor meta");
        assert!(meta.bitmap.is_none());
        assert_eq!(meta.position, (7, 8));
    }

    #[test]
    fn read_meta_rejects_malformed_bitmap() {
        // bitmap_offset 指向 meta 区域之外。
        let mut out_of_range = SyntheticCursor::new((0, 0), (0, 0), Some((4, 4, 16, Some(4096))));
        let meta = unsafe { read_meta(out_of_range.raw()) }.expect("cursor meta 仍然存在");
        assert!(meta.bitmap.is_none());

        // stride 小于一行像素。
        let mut bad_stride = SyntheticCursor::new((0, 0), (0, 0), Some((8, 8, 8, None)));
        let meta = unsafe { read_meta(bad_stride.raw()) }.expect("cursor meta 仍然存在");
        assert!(meta.bitmap.is_none());

        // 尺寸超过 KWin 的 256×256 上限。
        let mut too_large =
            SyntheticCursor::new((0, 0), (0, 0), Some((512, 1, 512 * 4, None)));
        let meta = unsafe { read_meta(too_large.raw()) }.expect("cursor meta 仍然存在");
        assert!(meta.bitmap.is_none());
    }
}
