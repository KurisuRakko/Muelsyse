#!/usr/bin/env python3
"""The density settings a new session starts from, and the separation between them.

`render_scale` is the framebuffer multiplier: the client asks for its window's
CSS size times this percentage, so the server's default of 100 streams the
window at its own size. `scaling_dpi` is the remote desktop's own DPI, five
stops (96/120/144/168/192), defaulting to 96 (unity): it sizes the compositor's
output scale, which draws the remote fonts and icons, and nothing else. The
operator can still override it, and an override locks the stop
(OPERATOR_LOCKED_WHEN_OVERRIDDEN), which the client must not talk over. A manual
resolution is the operator's own framebuffer and reads neither.

`adaptive_frame_drop` ships enabled and is a plain bool, so a client can turn
it off per display without an operator flag.

The HiDPI switch this file was named for is deleted, not merely unwired:
`use_css_scaling`, `useCssScaling`, `HIDPI_SPEC` and `setUseCssScaling` have to
be absent from the server definitions, both cores and both dashboards, which
the checks at the end assert directly.

Usage: python3 tests/unit/test_hidpi_defaults.py
"""
import os
import re
import subprocess
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
ADDONS = os.path.join(REPO, "addons")
RENDER_STOPS = ["100", "125", "150", "175", "200"]
STOPS = ["96", "120", "144", "168", "192"]

passed = failed = 0


def check(label: str, ok, detail="") -> None:
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"{'PASS' if ok else 'FAIL'}  [hidpi-defaults] {label}  {detail}", flush=True)


# settings reads argv and SELKIES_* at import, so each scenario is its own
# interpreter carrying only the variables it means to test.
BASE_ENV = {k: v for k, v in os.environ.items() if not k.startswith("SELKIES_")}


def probe(code: str, **env: str) -> str:
    out = subprocess.run(
        [sys.executable, "-c", f"import selkies.settings as s; {code}"],
        capture_output=True, text=True, timeout=120,
        env=dict(BASE_ENV, PYTHONPATH=os.path.join(REPO, "src"), **env))
    return (out.stdout.strip() or out.stderr.strip()[-300:])


definition = probe(
    "d = next(x for x in s.SETTING_DEFINITIONS if x['name'] == 'scaling_dpi');"
    " print(d['type'], d['default'], ','.join(d['meta']['allowed']))")
check("scaling_dpi is a five-stop enum defaulting to 96",
      definition == f"enum 96 {','.join(STOPS)}", definition)

check("a session that asks for nothing resolves to 96",
      probe("print(s.settings.scaling_dpi)") == "96")

check("an operator choice still wins",
      probe("print(s.settings.scaling_dpi, s.settings._overridden['scaling_dpi'])",
            SELKIES_SCALING_DPI="120") == "120 True")

check("and an operator choice locks the stop against the client",
      probe("print('scaling_dpi' in s.OPERATOR_LOCKED_WHEN_OVERRIDDEN)") == "True")

# Legality: the sanitizer is the single gate both transports hand client
# values to, so an out-of-range stop must fall back to the server's value
# rather than to the cheapest one.
legality = probe(
    "import logging;"
    " f = lambda v: s.sanitize_client_setting('scaling_dpi', v, s.settings, logging.getLogger('t'));"
    " print(f('96'), f('192'), f('150'), f('0'), f(None))")
check("every declared stop is accepted and anything else falls back to the server value",
      legality == "96 192 96 96 96", legality)

payload = probe(
    "p = s.build_client_settings_payload()['scaling_dpi'];"
    " print(p['value'], ','.join(p['allowed']), p['overridden'], p.get('locked', False))")
check("the published payload carries the default and all five stops",
      payload == f"96 {','.join(STOPS)} False False", payload)

render_definition = probe(
    "d = next(x for x in s.SETTING_DEFINITIONS if x['name'] == 'render_scale');"
    " print(d['type'], d['default'], ','.join(d['meta']['allowed']))")
check("render_scale is a five-stop percentage enum defaulting to 100",
      render_definition == f"enum 100 {','.join(RENDER_STOPS)}", render_definition)

check("a session that asks for nothing renders at 1x",
      probe("print(s.settings.render_scale)") == "100")

adaptive = probe(
    "d = next(x for x in s.SETTING_DEFINITIONS if x['name'] == 'adaptive_frame_drop');"
    " p = s.build_client_settings_payload()['adaptive_frame_drop'];"
    " print(d['type'], d['default'], p['value'], p['locked'])")
check("adaptive_frame_drop is a bool that ships enabled and unlocked",
      adaptive == "bool True True False", adaptive)

check("an operator can force adaptive_frame_drop off",
      probe("print(s.build_client_settings_payload()['adaptive_frame_drop']['value'])",
            SELKIES_ADAPTIVE_FRAME_DROP="false") == "False")

# The three scaling settings are independent: the HiDPI flag and the render
# scale size the framebuffer, `scaling_dpi` sizes the remote desktop, and no
# one of them may write another. The rule is JavaScript on the client sides,
# so what is compared is the source.
for core_name in ("selkies-ws-core.js", "selkies-wr-core.js"):
    core = open(os.path.join(ADDONS, "selkies-web-core", core_name),
                encoding="utf-8").read()
    auto = re.search(r"function autoDeriveDpi\(\)\s*\{(.*?)\n\t*\}", core, re.S)
    check(f"{core_name} derives the desktop DPI from nothing but the default",
          bool(auto) and "autoScalingDpi()" in auto.group(1)
          and "manual" not in auto.group(1),
          auto.group(1).strip() if auto else "autoDeriveDpi not found")

    effective = re.search(r"function effectiveScalingDpi\(\)\s*\{(.*?)\n\t*\}", core, re.S)
    check(f"{core_name} reports the desktop DPI as picked, never collapsed to 96",
          bool(effective) and "96" not in effective.group(1),
          effective.group(1).strip() if effective else "effectiveScalingDpi not found")

    check(f"{core_name} carries the render scale on its own message",
          "case 'setRenderScale'" in core or 'case "setRenderScale"' in core)
    # `scalingDpiFollowed` is a different message and may stay; what must be
    # gone is the DPI riding along on the HiDPI flag.
    check(f"{core_name} no longer rides the DPI on the HiDPI message",
          "message.scalingDpi" not in core and "scalingDpi:" not in core)

for name, rel in (("dashboard", os.path.join("selkies-dashboard", "src", "components", "Sidebar.jsx")),
                  ("wish", os.path.join("selkies-dashboard-wish", "src", "components",
                                        "dashboard", "settings.tsx"))):
    text = open(os.path.join(ADDONS, rel), encoding="utf-8").read()
    check(f"{name} has no coupling chokepoint left",
          "applyHidpiChoice" not in text)
    check(f"{name} no longer maps the HiDPI toggle onto a DPI stop",
          re.search(r"hidpiEnabled\s*\?\s*96\s*:", text) is None)
    check(f"{name} no longer remembers a DPI across a HiDPI toggle",
          "HIDPI_LAST_DPI_KEY" not in text)
    check(f"{name} offers the desktop DPI and the render scale separately",
          "desktopDpiLabel" in text and "renderScaleLabel" in text)

    # The decisive one: each handler writes its own key and no other's.
    def handler_body(source: str, handler: str) -> str:
        """The handler's own text: from its name to the first closing brace
        that sits at the start of a line, whichever indent the file uses."""
        start = source.index(handler)
        ends = [source.index(close, start)
                for close in ("\n  };", "\n    };") if close in source[start:]]
        return source[start:min(ends)] if ends else ""

    for handler, own, other in (
            ("applyDesktopDpi", "scaling_dpi", "render_scale"),
            ("applyRenderScale", "render_scale", "scaling_dpi"),
    ):
        body = handler_body(text, handler)
        check(f"{name}: {handler} writes {own}", own in body, body.strip()[:100])
        check(f"{name}: {handler} leaves {other} alone", other not in body)

# The HiDPI switch is deleted, not merely unwired: no token of it may survive
# in the server definitions, either core or either dashboard. A leftover key or
# spec is how a removed control keeps being written and read.
HIDPI_TOKENS = ("use_css_scaling", "useCssScaling", "HIDPI_SPEC", "setUseCssScaling")
HIDPI_FILES = {
    "settings.py": os.path.join(REPO, "src", "selkies", "settings.py"),
    "ws core": os.path.join(ADDONS, "selkies-web-core", "selkies-ws-core.js"),
    "wr core": os.path.join(ADDONS, "selkies-web-core", "selkies-wr-core.js"),
    "dashboard": os.path.join(ADDONS, "selkies-dashboard", "src", "components",
                              "Sidebar.jsx"),
    "wish": os.path.join(ADDONS, "selkies-dashboard-wish", "src", "components",
                         "dashboard", "settings.tsx"),
}
leftovers = {side: [token for token in HIDPI_TOKENS
                    if token in open(path, encoding="utf-8").read()]
             for side, path in HIDPI_FILES.items()}
for side, tokens in leftovers.items():
    check(f"{side} carries no HiDPI-switch token", not tokens, ",".join(tokens))
for token in HIDPI_TOKENS:
    holders = [side for side, tokens in leftovers.items() if token in tokens]
    check(f"{token} is gone from every tracked side", not holders, ",".join(holders))

print(f"[hidpi-defaults] {passed}/{passed + failed} passed")
sys.exit(1 if failed else 0)
