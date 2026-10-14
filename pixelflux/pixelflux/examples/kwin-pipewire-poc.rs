//! KWin→PipeWire DMA-BUF 文本探针，不启动 Selkies，也不保存图像。

use std::time::Duration;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let display = args.get(1).map(String::as_str).unwrap_or("wayland-host");
    let width = args.get(2).and_then(|v| v.parse().ok()).unwrap_or(3840);
    let height = args.get(3).and_then(|v| v.parse().ok()).unwrap_or(2160);
    let fps = args.get(4).and_then(|v| v.parse().ok()).unwrap_or(60);
    let seconds = args.get(5).and_then(|v| v.parse().ok()).unwrap_or(5);

    match pixelflux::wayland::kwin::KWinCaptureSource::probe(
        display,
        width,
        height,
        fps,
        Duration::from_secs(seconds),
    ) {
        Ok(report) => {
            println!(
                "POC_PASS node={} format={}x{} fps={}/{} max_fps={}/{} modifier={:?} dmabuf_frames={} non_dmabuf_frames={}",
                report.node_id,
                report.width,
                report.height,
                report.framerate_num,
                report.framerate_den,
                report.max_framerate_num,
                report.max_framerate_den,
                report.modifier,
                report.dmabuf_frames,
                report.non_dmabuf_frames,
            );
        }
        Err(error) => {
            eprintln!("POC_FAIL {error}");
            std::process::exit(1);
        }
    }
}
