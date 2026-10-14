#!/usr/bin/env python3
"""The derived `scaling_dpi` default is the same number on all three sides.

Three copies exist: the cores' shared rule in lib/stream-density.js and one per
dashboard, which cannot import it. They have to agree, because they do not
merely display the same value: on connect the core sends its derived default,
and the dashboard posts *its* over the top whenever the two differ (the
`willPostDerived` gate). A formula changed on one side alone would leave the
desktop taking one DPI and the picker showing another, then quietly overwrite
the one the core applied.

The rules are JavaScript, so what is compared here is what each source
declares: the stops offered and the constant a session defaults to, for both
the remote desktop's DPI (DEFAULT_DPI) and the render scale
(DEFAULT_RENDER_SCALE). Neither derives from anything any more -- not from the
local display's `devicePixelRatio`, and, since the desktop DPI was decoupled
from the framebuffer, not from a manual resolution either. Both are product
decisions, not properties of the screen the browser is on or of the size the
operator asked for.

The declarations also have to be free of the deleted HiDPI switch, and the two
cores -- which consume the lib -- have to read the same stops; both are
asserted here.

Usage: python3 tests/unit/test_dpi_default_mirror.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ADDONS = os.path.join(ROOT, "addons")

SOURCES = {
    "lib": "selkies-web-core/lib/stream-density.js",
    "dashboard": "selkies-dashboard/src/components/Sidebar.jsx",
    "wish": "selkies-dashboard-wish/src/components/dashboard/settings.tsx",
}
# The density each side reads off a manual resolution. Written the same way in
# all three, so a change to the rule has to be made in all three.

results = []


def check(label: str, ok: object, detail: object = "") -> None:
    results.append((label, bool(ok)))
    print(f"{'PASS' if ok else 'FAIL'}  [dpi-default-mirror] {label}  {detail}", flush=True)


def read(rel: str) -> str:
    with open(os.path.join(ADDONS, rel), encoding="utf-8") as fh:
        return fh.read()


def stops(text: str) -> list:
    """The DPI stops the source offers, from either shape they are written in."""
    listed = re.search(r"DPI_STOPS\s*=\s*\[([^\]]*)\]", text)
    if listed:
        return [int(n) for n in re.findall(r"\d+", listed.group(1))]
    options = re.search(r"dpiScalingOptions\s*(?::[^=]*)?=\s*\[(.*?)\n\]", text, re.S)
    return [int(n) for n in re.findall(r"value:\s*(\d+)", options.group(1))] if options else []


def render_stops(text: str) -> list:
    """The render-scale stops the source offers, in either shape."""
    listed = re.search(r"RENDER_SCALE_STOPS\s*=\s*\[([^\]]*)\]", text)
    if listed:
        return [int(n) for n in re.findall(r"\d+", listed.group(1))]
    options = re.search(r"renderScaleOptions\s*(?::[^=]*)?=\s*\[(.*?)\n\]", text, re.S)
    return [int(n) for n in re.findall(r"value:\s*(\d+)", options.group(1))] if options else []


def main() -> bool:
    texts = {name: read(rel) for name, rel in SOURCES.items()}
    reference = stops(texts["lib"])
    check("the lib names the stops", len(reference) > 1, reference)
    for name in ("dashboard", "wish"):
        got = stops(texts[name])
        check(f"{name} offers the same stops", got == reference, f"{got} vs {reference}")

    default = {name: re.findall(r"DEFAULT_DPI\s*(?::\s*number)?\s*=\s*(\d+)", text)
               for name, text in texts.items()}
    check("every side defaults a windowed session to the same DPI",
          len({tuple(v) for v in default.values()}) == 1 and default["lib"], default)
    check("that default is one of the stops",
          default["lib"] and int(default["lib"][0]) in reference, default["lib"])

    render_reference = render_stops(texts["lib"])
    check("the lib names the render-scale stops", len(render_reference) > 1, render_reference)
    for name in ("dashboard", "wish"):
        got = render_stops(texts[name])
        check(f"{name} offers the same render-scale stops", got == render_reference,
              f"{got} vs {render_reference}")

    render_default = {
        name: re.findall(r"DEFAULT_RENDER_SCALE\s*(?::\s*number)?\s*=\s*(\d+)", text)
        for name, text in texts.items()}
    check("every side defaults to the same render scale",
          len({tuple(v) for v in render_default.values()}) == 1 and render_default["lib"],
          render_default)
    check("that default is one of the render-scale stops",
          render_default["lib"] and int(render_default["lib"][0]) in render_reference,
          render_default["lib"])

    # The decoupling itself: neither default may be read off the other's units.
    for name, text in texts.items():
        check(f"{name} no longer derives a DPI from a resolution",
              "DPI_UNITY_ROWS" not in text and "96 * rows" not in text)

    # The HiDPI switch is deleted from every declaration site, and from the
    # server definitions the payload is built from. A leftover token is how a
    # removed control keeps being written and read.
    HIDPI_TOKENS = ("use_css_scaling", "useCssScaling", "HIDPI_SPEC", "setUseCssScaling")
    for name, text in texts.items():
        found = [token for token in HIDPI_TOKENS if token in text]
        check(f"{name} carries no HiDPI-switch token", not found, ",".join(found))
    with open(os.path.join(ROOT, "src", "selkies", "settings.py"), encoding="utf-8") as fh:
        settings_text = fh.read()
    found = [token for token in HIDPI_TOKENS if token in settings_text]
    check("settings.py carries no HiDPI-switch token", not found, ",".join(found))

    # The cores consume the lib rather than copying it: the render-scale stops
    # are imported (a local literal would be a second source of truth), and
    # ws-core's one local copy of the DPI stops has to be the same five.
    core_texts = {name: read(rel) for name, rel in (
        ("ws core", "selkies-web-core/selkies-ws-core.js"),
        ("wr core", "selkies-web-core/selkies-wr-core.js"))}
    for name, text in core_texts.items():
        check(f"the {name} imports the render-scale stops rather than declaring them",
              "RENDER_SCALE_STOPS" in text
              and re.search(r"RENDER_SCALE_STOPS\s*=\s*\[", text) is None)
    local_dpi = re.search(r"SCALING_DPI_STOPS\s*=\s*\[([^\]]*)\]", core_texts["ws core"])
    local_stops = [int(n) for n in re.findall(r"\d+", local_dpi.group(1))] if local_dpi else []
    check("the ws core's local DPI stops are the lib's", local_stops == reference,
          f"{local_stops} vs {reference}")
    check("the wr core declares no DPI stops of its own",
          re.search(r"\bDPI_STOPS\s*=", core_texts["wr core"]) is None)

    failed = [label for label, ok in results if not ok]
    print(f"[dpi-default-mirror] {len(results) - len(failed)}/{len(results)} passed")
    return not failed


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
