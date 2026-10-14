#!/usr/bin/env python3
"""Two display pages, each streaming at its own render scale.

A page's framebuffer is its own window's CSS size times its own `render_scale`,
so the two displays of an extended desktop can stream at different densities.
The browser's `devicePixelRatio` is not a multiplier: two pages of the same CSS
size and the same render scale ask for the same framebuffer whatever their
screens are. Checked with the scales both ways round and with the device pixel
ratios differing both ways round: the monitor the server realizes for the
secondary, the secondary's own buffer against its CSS box, the scale each page
publishes with the layout, and where a pointer on it lands.

Uses `E2E_DISPLAY` when set; otherwise starts a throwaway Xvfb wide enough for
the two-display union.
Usage: python3 tests/e2e/test_mixed_dpi.py [websockets|webrtc|all]
"""
import json
import os
import subprocess
import sys
import time
from typing import Any, Dict, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import helpers as H
import core_lib as C
from playwright.sync_api import sync_playwright

MODES = ("websockets", "webrtc")
PRIMARY_CSS = (1512, 806)
SECONDARY_CSS = (1920, 936)
# The two pages of the device-pixel-ratio case share this CSS size, so the same
# render scale must land on one framebuffer for both of them.
SAME_CSS = (1280, 720)

# A window this page can report a desktop position for, since the real one
# cannot be moved: the pages sit side by side with no chrome above them.
DESKTOP_INIT = """(() => {
  window.__desk = [%d, 0];
  window.__inset = [0, 0];
  Object.defineProperty(window, 'screenX', {get: () => window.__desk[0]});
  Object.defineProperty(window, 'screenY', {get: () => 0});
})()"""
LAYOUT_JS = "window.webrtcInput && window.webrtcInput._layout"
SINK_JS = """() => {
  const canvas = document.getElementById('videoCanvas');
  const video = document.getElementById('stream');
  const buffer = (canvas && canvas.width > 0) ? [canvas.width, canvas.height]
                 : (video && video.videoWidth > 0) ? [video.videoWidth, video.videoHeight] : null;
  if (!buffer) return null;
  // Whichever sink is drawn: the canvas, the worker's canvas, or the video.
  let css = [0, 0];
  for (const id of ['videoCanvas', 'videoWorkerCanvas', 'videoStream', 'stream']) {
    const el = document.getElementById(id);
    const r = el && el.getBoundingClientRect ? el.getBoundingClientRect() : null;
    if (r && r.width > 0) { css = [Math.round(r.width), Math.round(r.height)]; break; }
  }
  return {w: buffer[0], h: buffer[1], cssW: css[0], cssH: css[1],
          density: window.webrtcInput ? window.webrtcInput._cursorDensity() : null};
}"""


def wait_for(pred, timeout: float = 15) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.25)
    return False


def monitors(display: str) -> Dict[str, Tuple[int, int, int, int]]:
    """The RandR monitors the server publishes: name -> (w, h, x, y)."""
    out = subprocess.run(["xrandr", "--display", display, "--listmonitors"],
                         capture_output=True, text=True).stdout
    found = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3 or not parts[0].rstrip(":").isdigit():
            continue
        name = parts[1].lstrip("+*")
        geom = parts[2]  # WIDTH/mmxHEIGHT/mm+X+Y
        size, x, y = geom.split("+")
        w = int(size.split("x")[0].split("/")[0])
        h = int(size.split("x")[1].split("/")[0])
        found[name] = (w, h, int(x), int(y))
    return found


def new_display_context(browser: Any, mode: str, css: Tuple[int, int], dpr: int,
                        desk_x: int, url_hash: str = "") -> Any:
    ctx = browser.new_context(viewport={"width": css[0], "height": css[1]},
                              device_scale_factor=dpr)
    ctx.add_init_script(f"window.__SELKIES_STREAMING_MODE__ = '{mode}';")
    ctx.add_init_script(C.WIRE_TAP_JS)
    ctx.add_init_script(DESKTOP_INIT % desk_x)
    page = ctx.new_page()
    page.console_errors = []
    page.on("console",
            lambda m: page.console_errors.append(m.text) if m.type == "error" else None)
    page.goto(H.BASE_URL + "/" + url_hash, wait_until="load")
    return page


def wait_video(page: Any, mode: str, timeout: float = 45) -> Optional[dict]:
    return (C.wait_wr_video(page, timeout=timeout) if mode == "webrtc"
            else C.wait_ws_video(page, timeout=timeout))


def post(page: Any, message: dict) -> None:
    """Post a dashboard message into the page."""
    page.evaluate("(m) => window.postMessage(m, window.location.origin)", message)


def hover(page: Any, cx: int, cy: int) -> Tuple[int, int]:
    """Hovers the stream at a client point and reads the X pointer back."""
    page.evaluate("""([cx, cy]) => {
      const ev = new MouseEvent('mousemove', {buttons: 0, clientX: cx, clientY: cy,
        screenX: window.__desk[0] + cx, screenY: cy, bubbles: true});
      document.getElementById('overlayInput').dispatchEvent(ev);
    }""", [cx, cy])
    time.sleep(0.3)
    return C.x11_mouse_pos()


def secondary_rect(page: Any) -> dict:
    layout = page.evaluate(LAYOUT_JS) or {}
    return next((r for r in layout.get("rects", []) if r["x"] > 0), {})


def own_rect(page: Any) -> dict:
    """The page's own rectangle in the layout, carrying the scale it published."""
    return (page.evaluate(LAYOUT_JS) or {}).get("own") or {}


def published(page: Any) -> list:
    """The display scales this page has reported to the server, in order."""
    sent = page.evaluate("(window.__wireSent || [])"
                         ".filter(d => typeof d === 'string' && d.startsWith('SETTINGS,'))")
    return [json.loads(m[len("SETTINGS,"):]).get("displayScale") for m in sent]


def density_case(res: "H.Results", mode: str, browser: Any,
                 primary_scale: int, secondary_scale: int,
                 primary_dpr: int, secondary_dpr: int,
                 primary_css: Tuple[int, int] = PRIMARY_CSS,
                 secondary_css: Tuple[int, int] = SECONDARY_CSS,
                 compare_buffers: bool = False) -> None:
    """One arrangement: each page ends up at its own render scale.

    `compare_buffers` is the device-pixel-ratio-blind check: two pages of the
    same CSS size and the same render scale must stream one framebuffer
    whatever their screens' device pixel ratios are.
    """
    tag = (f"[{mode}] primary {primary_scale}%@x{primary_dpr}, "
           f"secondary {secondary_scale}%@x{secondary_dpr}:")
    page = new_display_context(browser, mode, primary_css, primary_dpr, 0)
    try:
        res.check(f"{tag} primary video flows", bool(wait_video(page, mode)), "")
        if primary_scale != 100:
            post(page, {"type": "setRenderScale", "value": primary_scale})
        primary_w = primary_css[0] * primary_scale // 100
        primary_h = primary_css[1] * primary_scale // 100
        placed = wait_for(
            lambda: monitors(H.TEST_DISPLAY).get("selkies-primary", (0, 0))[:2]
            == (primary_w, primary_h), 30)
        res.check(f"{tag} the primary's monitor is its CSS size times its own scale",
                  placed, f"want {primary_w}x{primary_h} monitors={monitors(H.TEST_DISPLAY)}")

        dpage = new_display_context(browser, mode, secondary_css, secondary_dpr,
                                    primary_css[0], "#display2-right")
        try:
            res.check(f"{tag} secondary video flows", bool(wait_video(dpage, mode)), "")
            if secondary_scale != 100:
                post(dpage, {"type": "setRenderScale", "value": secondary_scale})
            want = (secondary_css[0] * secondary_scale // 100,
                    secondary_css[1] * secondary_scale // 100)
            realized = wait_for(
                lambda: monitors(H.TEST_DISPLAY).get("selkies-display2", (0, 0))[:2]
                == want, 30)
            got = monitors(H.TEST_DISPLAY)
            res.check(f"{tag} the secondary's monitor is its CSS size times its own scale",
                      realized, f"want {want} monitors={got}")
            res.check(f"{tag} the primary's monitor keeps its own scale",
                      got.get("selkies-primary", (0,))[0] == primary_w, got)
            res.check(f"{tag} the secondary sits at the primary's right edge",
                      got.get("selkies-display2", (0, 0, -1))[2] == primary_w, got)

            # The page draws that many stream pixels into its CSS box, and maps
            # the cursor and pointer at the same density.
            sink_ok = wait_for(lambda: (dpage.evaluate(SINK_JS) or {}).get("w") == want[0], 15)
            sink = dpage.evaluate(SINK_JS) or {}
            res.check(f"{tag} the secondary's buffer is its own scale in its own CSS box",
                      sink_ok and abs(sink.get("cssW", 0) - secondary_css[0]) <= 2
                      and abs(sink.get("density", 0) - secondary_scale / 100) < 0.01, sink)
            if compare_buffers:
                psink_ok = wait_for(
                    lambda: (page.evaluate(SINK_JS) or {}).get("w") == want[0], 15)
                psink = page.evaluate(SINK_JS) or {}
                res.check(f"{tag} the same render scale at two device pixel ratios "
                          f"streams one framebuffer",
                          psink_ok and [psink.get("w"), psink.get("h")]
                          == [sink.get("w"), sink.get("h")] == [want[0], want[1]],
                          f"primary {psink} secondary {sink}")

            # The cross-display drag converts through these, so each page has to
            # publish the ratio its box draws at: the render scale in framebuffer
            # pixels per CSS pixel.
            res.check(f"{tag} the primary publishes its own scale",
                      wait_for(lambda: own_rect(page).get("scale") == primary_scale / 100, 15),
                      f"primary published {published(page)}")
            laid = wait_for(lambda: secondary_rect(page).get("scale") == secondary_scale / 100, 15)
            res.check(f"{tag} the secondary publishes its own scale with the layout",
                      laid, f"primary published {published(page)}, secondary {published(dpage)}")

            # A point on the secondary lands where its own scale puts it.
            pos = hover(dpage, 100, 100)
            expect = (primary_w + 100 * secondary_scale // 100,
                      100 * secondary_scale // 100)
            res.check(f"{tag} a pointer on the secondary maps at its own scale",
                      abs(pos[0] - expect[0]) <= 2 and abs(pos[1] - expect[1]) <= 2,
                      f"got {pos} expected {expect}")
            errors = [m for m in page.console_errors + dpage.console_errors
                      if "favicon" not in m and "ERR_" not in m and "404" not in m]
            res.check(f"{tag} no console errors", not errors, errors[:3])
        finally:
            dpage.context.close()
    finally:
        page.context.close()
        # The secondary's monitor is gone with its page before the next case.
        wait_for(lambda: "selkies-display2" not in monitors(H.TEST_DISPLAY), 15)


def drive(res: "H.Results", mode: str) -> None:
    H.server_start(mode=mode, wayland=False)
    with sync_playwright() as p:
        kwargs = {"headless": True, "args": C.BROWSER_ARGS}
        if C.CHROME_PATH:
            kwargs["executable_path"] = C.CHROME_PATH
        browser = p.chromium.launch(**kwargs)
        try:
            # Each page follows its own render scale, with the larger one on
            # either side in turn.
            density_case(res, mode, browser, 100, 200, 2, 2)
            density_case(res, mode, browser, 200, 100, 2, 2)
            # The render scale is the only multiplier: one CSS size, one render
            # scale, two device pixel ratios, one framebuffer -- both ways round.
            density_case(res, mode, browser, 100, 100, 2, 1,
                         primary_css=SAME_CSS, secondary_css=SAME_CSS,
                         compare_buffers=True)
            density_case(res, mode, browser, 100, 100, 1, 2,
                         primary_css=SAME_CSS, secondary_css=SAME_CSS,
                         compare_buffers=True)
        finally:
            browser.close()


def main(selection: str) -> "H.Results":
    res = H.Results("mixed-dpi")
    xproc = None
    if not H.TEST_DISPLAY:
        xproc, xdisp = H.private_x_server(width=8192, height=4096)
        H.TEST_DISPLAY = xdisp
    try:
        for mode in (MODES if selection == "all" else (selection,)):
            drive(res, mode)
    finally:
        H.server_stop()
        if xproc is not None:
            H.stop_x_server(xproc, H.TEST_DISPLAY)
    res.summary()
    return res


if __name__ == "__main__":
    r = main(sys.argv[1] if len(sys.argv) > 1 else "all")
    sys.exit(0 if not r.failed() else 1)
