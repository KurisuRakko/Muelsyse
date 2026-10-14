#!/usr/bin/env python3
"""The desktop's own DPI answers to its own setting and to nothing else.

`scaling_dpi` sizes the remote desktop: the compositor's output scale is it
over 96, so it decides how large the remote fonts and icons are drawn. The
framebuffer is a different setting -- the window's CSS size times
`render_scale` -- and this suite pins the separation from the outside: it
drives real browser densities and real manual resolutions through a browser and
reads back Xft.dpi, which must not move for any of them. Only an explicit pick
changes it.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import core_lib as C  # noqa: E402
import helpers as H  # noqa: E402
from playwright.sync_api import sync_playwright  # noqa: E402

# The scaling_dpi stops the clients offer, in 25% steps.
STOPS = [96, 120, 144, 168, 192]
# 96 is unity: a new session leaves the remote desktop at its own size.
DEFAULT_DPI = 96
DPRS = [1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
# Resolutions whose own size would once have been read as a DPI (3840x2160 as
# 192, 2560x1440 as 120). Nothing may derive from them now.
MANUAL_RESOLUTIONS = [(3840, 2160), (2560, 1440), (1280, 720)]
# A pick no default returns, so a desktop sitting at it can only have taken the
# stored one.
PINNED_DPI = 168

# A stored pick, written before the core reads its settings.
PINNED_INIT = """(() => {
  const prefix = (window.location.origin + window.location.pathname)
    .replace(/[^a-zA-Z0-9._-]/g, '_');
  localStorage.setItem(prefix + '_scaling_dpi', '%d');
})()""" % PINNED_DPI


def expected(_dpr: float) -> int:
    """The desktop DPI a session lands on, whatever the browser's density.

    A constant. The local screen is a property of where the browser happens to
    be, and the remote desktop's size is not its business; the framebuffer,
    which is, follows `render_scale` instead.
    """
    return DEFAULT_DPI


def xft_dpi() -> int:
    """Read Xft.dpi from the running resource database.

    Returns:
        The Xft.dpi value, or 96 when unset: X's own default, which is what
        an application reads when nothing overrides it.
    """
    env = {**os.environ, "DISPLAY": H.require_display()}
    out = subprocess.run(["xrdb", "-query"], capture_output=True, text=True, env=env).stdout
    for line in out.splitlines():
        if line.startswith("Xft.dpi"):
            return int(line.split(":")[1].strip())
    return 96


def engine_files(root: str) -> list:
    """The JS and HTML files the served client is built from."""
    found = []
    for base, _dirs, names in os.walk(root):
        found += [os.path.join(base, name) for name in names
                  if name.endswith((".js", ".mjs", ".html"))]
    return found


def check_no_hidpi_switch(res: "H.Results", root: str) -> None:
    """The deleted HiDPI switch must not survive in the client being served.

    The dynamic checks above drive what the engine does; this one reads what the
    engine is, because a stale bundle would keep writing a setting the server no
    longer defines while every Xft.dpi reading still looked right.
    """
    tokens = ("use_css_scaling", "useCssScaling", "setUseCssScaling", "HIDPI_SPEC")
    hits = []
    for path in engine_files(root):
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        hits += [f"{os.path.relpath(path, root)} carries {token}"
                 for token in tokens if token in text]
    res.check("the served client carries no HiDPI-switch token", not hits,
              "; ".join(hits[:4]))


def run() -> int:
    """Drive each DPR through a fresh browser context and compare Xft.dpi."""
    res = H.Results("dpi-accuracy")
    H.server_start(mode="websockets", web_root=H.CLASSIC_DIST)
    check_no_hidpi_switch(res, H.CLASSIC_DIST)
    subprocess.run(["xrdb", "-remove"], capture_output=True,
                   env={**os.environ, "DISPLAY": H.require_display()})
    with sync_playwright() as p:
        browser = C.chromium_launch(p)
        try:
            for dpr in DPRS:
                ctx = browser.new_context(viewport={"width": 1000, "height": 700},
                                          device_scale_factor=dpr)
                page = ctx.new_page()
                page.goto(f"{H.BASE_URL}/", wait_until="load", timeout=60000)
                page.wait_for_timeout(9000)
                got, want = xft_dpi(), expected(dpr)
                res.check(f"dpr {dpr} applies Xft.dpi {want}", got == want,
                          f"got {got}")
                ctx.close()

            # A live density change (the window dragged to another monitor, an
            # OS scaling change) is not a framebuffer multiplier any more -- the
            # render scale is -- and the remote desktop is not on that monitor
            # either, so it must not be resized with it.
            ctx = browser.new_context(viewport={"width": 1000, "height": 700},
                                      device_scale_factor=1.0)
            page = ctx.new_page()
            page.goto(f"{H.BASE_URL}/", wait_until="load", timeout=60000)
            page.wait_for_timeout(9000)
            res.check("live dpr: starts at the default DPI",
                      xft_dpi() == DEFAULT_DPI, f"got {xft_dpi()}")
            cdp = ctx.new_cdp_session(page)
            cdp.send("Emulation.setDeviceMetricsOverride", {
                "width": 1000, "height": 700, "deviceScaleFactor": 2.0,
                "mobile": False})
            page.wait_for_timeout(9000)
            res.check("live dpr: 2.0 does not move the desktop DPI",
                      xft_dpi() == DEFAULT_DPI, f"got {xft_dpi()}")
            ctx.close()

            # A manual resolution is a framebuffer. It says nothing about how
            # large the remote desktop should draw its own UI.
            ctx = browser.new_context(viewport={"width": 1000, "height": 700},
                                      device_scale_factor=1.0)
            page = ctx.new_page()
            page.goto(f"{H.BASE_URL}/", wait_until="load", timeout=60000)
            page.wait_for_timeout(9000)
            for width, height in MANUAL_RESOLUTIONS:
                page.evaluate(
                    "([w, h]) => window.postMessage("
                    "{type: 'setManualResolution', width: w, height: h},"
                    " window.location.origin)", [width, height])
                page.wait_for_timeout(9000)
                res.check(f"a manual {width}x{height} leaves the desktop DPI alone",
                          xft_dpi() == DEFAULT_DPI, f"got {xft_dpi()}")
            page.evaluate("window.postMessage({type: 'resetResolutionToWindow'},"
                          " window.location.origin)")
            page.wait_for_timeout(9000)
            res.check("and so does resetting back to the window size",
                      xft_dpi() == DEFAULT_DPI, f"got {xft_dpi()}")

            # The render scale is the other half of the framebuffer, and is
            # likewise no business of the desktop's.
            page.evaluate("window.postMessage({type: 'setRenderScale', value: 200},"
                          " window.location.origin)")
            page.wait_for_timeout(9000)
            res.check("a 2x render scale leaves the desktop DPI alone",
                      xft_dpi() == DEFAULT_DPI, f"got {xft_dpi()}")
            ctx.close()

            # The constant is only a default: an explicit pick governs, and
            # nothing re-derives over it. That is what makes it configurable.
            ctx = browser.new_context(viewport={"width": 1000, "height": 700},
                                      device_scale_factor=1.0)
            ctx.add_init_script(PINNED_INIT)
            page = ctx.new_page()
            page.goto(f"{H.BASE_URL}/", wait_until="load", timeout=60000)
            page.wait_for_timeout(9000)
            res.check(f"a stored pick applies Xft.dpi {PINNED_DPI}",
                      xft_dpi() == PINNED_DPI, f"got {xft_dpi()}")
            page.evaluate(
                "window.postMessage({type: 'setManualResolution',"
                " width: 3840, height: 2160}, window.location.origin)")
            page.wait_for_timeout(9000)
            res.check("and a manual resolution does not re-derive over it",
                      xft_dpi() == PINNED_DPI, f"got {xft_dpi()}")
            ctx.close()
        finally:
            browser.close()
    H.server_stop()
    return 0 if res.summary() else 1


if __name__ == "__main__":
    sys.exit(run())
