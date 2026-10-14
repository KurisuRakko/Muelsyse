//! KWin host backend 的文本集成探针。
//!
//! 它只读取帧元数据，不保存图像：验证 output-management-v2、PipeWire
//! DMA-BUF 所有权、动态模式切换和 KWin fake-input 是否能一起工作。

use std::thread;
use std::time::{Duration, Instant};

use pixelflux::wayland::host::{HostBackend, HostSession};

fn wait_frame(
    host: &HostSession,
    expected: (i32, i32),
    timeout: Duration,
) -> Result<(i32, i32, bool), String> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Some(frame) = host.try_take_frame(0) {
            let result = (frame.width, frame.height, frame.dmabuf.is_some());
            host.release_frame(0, frame);
            if (result.0, result.1) != expected {
                return Err(format!(
                    "收到错误尺寸 {}x{}，期望 {}x{}",
                    result.0, result.1, expected.0, expected.1
                ));
            }
            return Ok(result);
        }
        thread::sleep(Duration::from_millis(25));
    }
    Err(format!("等待 {}x{} DMA-BUF 帧超时", expected.0, expected.1))
}

fn resize_and_verify(host: &HostSession, step: usize, size: (i32, i32)) {
    let _ = host.start_capture(0, size.0, size.1, true, false);
    let frame = wait_frame(host, size, Duration::from_secs(10))
        .unwrap_or_else(|error| panic!("POC_FAIL resize step {step}: {error}"));
    println!(
        "RESIZE_FRAME step={} width={} height={} dmabuf={}",
        step, frame.0, frame.1, frame.2
    );
    if !frame.2 {
        panic!("POC_FAIL resize step {step} returned a non-DMA-BUF frame");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let display = args.get(1).map(String::as_str).unwrap_or("kwin-kwin-poc");
    let first = (
        args.get(2).and_then(|v| v.parse().ok()).unwrap_or(3840),
        args.get(3).and_then(|v| v.parse().ok()).unwrap_or(2160),
    );
    let resize_targets: Vec<(i32, i32)> = if args.len() > 4 {
        if !(args.len() - 4).is_multiple_of(2) {
            panic!("POC_FAIL resize arguments must be width/height pairs");
        }
        args[4..]
            .chunks_exact(2)
            .map(|pair| {
                (
                    pair[0]
                        .parse()
                        .unwrap_or_else(|_| panic!("POC_FAIL invalid resize width: {}", pair[0])),
                    pair[1]
                        .parse()
                        .unwrap_or_else(|_| panic!("POC_FAIL invalid resize height: {}", pair[1])),
                )
            })
            .collect()
    } else {
        // 覆盖预置、常用和非预置尺寸，并回到初始 4K mode。
        vec![(1920, 1080), (2560, 1440), (1733, 977), (3840, 2160)]
    };

    let (wake_tx, _wake_rx) = calloop::channel::channel();
    let host = HostSession::connect(display, HostBackend::Kwin, None, wake_tx)
        .unwrap_or_else(|error| panic!("POC_FAIL host connect: {error}"));
    println!("HOST_CONNECTED outputs={}", host.output_count());

    let _ = host.start_capture(0, first.0, first.1, true, false);
    let initial = wait_frame(&host, first, Duration::from_secs(10))
        .unwrap_or_else(|error| panic!("POC_FAIL initial capture: {error}"));
    println!(
        "INITIAL_FRAME width={} height={} dmabuf={}",
        initial.0, initial.1, initial.2
    );
    if !initial.2 {
        panic!("POC_FAIL initial frame was not DMA-BUF");
    }

    let input_deadline = Instant::now() + Duration::from_secs(5);
    let mut input_ok = false;
    while Instant::now() < input_deadline {
        let motion = host.pointer_motion_abs(100.0, 100.0);
        let button = host.pointer_button(272, true) && host.pointer_button(272, false);
        let axis = host.pointer_axis(0.0, 1.0);
        if motion && button && axis {
            input_ok = true;
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    println!("INPUT_SENT={input_ok}");
    if !input_ok {
        panic!("POC_FAIL KWin fake-input was not ready");
    }

    // 连续请求只保留最后一个目标，验证快速拖动窗口时不会提交过期尺寸。
    host.start_capture(0, 1920, 1080, true, false);
    host.start_capture(0, 2560, 1440, true, false);
    host.start_capture(0, 1733, 977, true, false);
    let burst = wait_frame(&host, (1733, 977), Duration::from_secs(10))
        .unwrap_or_else(|error| panic!("POC_FAIL coalesced resize burst: {error}"));
    println!(
        "BURST_FRAME width={} height={} dmabuf={}",
        burst.0, burst.1, burst.2
    );
    if !burst.2 {
        panic!("POC_FAIL coalesced resize returned a non-DMA-BUF frame");
    }

    for (step, size) in resize_targets.into_iter().enumerate() {
        resize_and_verify(&host, step + 1, size);
    }
    println!("POC_PASS host-session kwin dmabuf dynamic-resize input");
}
