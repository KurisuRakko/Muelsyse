#!/usr/bin/env python3
"""The `ws` scroll verb: fractional axis deltas injected as sent.

A `ws,<dx>,<dy>` delta reaches `inject_mouse_scroll` unchanged on Wayland, in
the units and signs the `m2` scroll clicks use, so a client switching paths
scrolls the same way. A delta is clamped, a non-finite or malformed one is
dropped, and a zero one injects nothing. Without the Wayland harness the delta
is carried into the scroll clicks `m2` would have sent.
"""
import asyncio
import os
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))

from selkies import input_handler as ih  # noqa: E402
from selkies.input_handler import WebRTCInput  # noqa: E402

results = []


def check(label: str, ok, detail="") -> None:
    results.append((label, bool(ok)))
    print(f"{'PASS' if ok else 'FAIL'}  [smooth-scroll] {label}  {detail}", flush=True)


class FakeWayland:
    def __init__(self) -> None:
        self.scrolls = []

    def inject_mouse_scroll(self, dx: float, dy: float) -> None:
        self.scrolls.append((dx, dy))

    def inject_mouse_button(self, button: int, state: int) -> None:
        pass

    def inject_mouse_move(self, x: float, y: float) -> None:
        pass

    def inject_relative_mouse_move(self, dx: float, dy: float) -> None:
        pass


def make_handler(wayland: bool = True) -> WebRTCInput:
    h = WebRTCInput.__new__(WebRTCInput)
    h.wayland_input = FakeWayland() if wayland else None
    h.xdisplay = None
    h.button_mask = 0
    h._smooth_scroll_carry = (0.0, 0.0)
    h.last_x = 0
    h.last_y = 0
    h.tracked_position_stale = False
    h.data_server_instance = None
    h.ping_start = None
    return h


async def m2_scroll(bit: int) -> tuple:
    """The axis delta one `m2` scroll click on `bit` injects."""
    h = make_handler()
    await h.send_x11_mouse(0, 0, 0, 1, relative=True)
    await h.send_x11_mouse(0, 0, 1 << bit, 1, relative=True)
    return h.wayland_input.scrolls[-1]


async def ws(msg: str, wayland: bool = True) -> WebRTCInput:
    h = make_handler(wayland)
    await h.on_message(msg)
    return h


async def main() -> None:
    h = await ws("ws,1.25,-3.5")
    check("a fractional delta is injected as sent",
          h.wayland_input.scrolls == [(1.25, -3.5)], h.wayland_input.scrolls)

    # Each m2 scroll bit and the ws delta of one notch in its direction agree.
    notch = ih.SCROLL_AXIS_UNITS_PER_NOTCH
    for bit, msg in ((3, f"ws,0,{notch}"), (4, f"ws,0,{-notch}"),
                     (6, f"ws,{-notch},0"), (7, f"ws,{notch},0")):
        click = await m2_scroll(bit)
        sent = (await ws(msg)).wayland_input.scrolls
        check(f"m2 bit {bit} and {msg} scroll alike", sent == [click], f"{sent} vs {click}")

    h = await ws("ws,1000,-1000")
    cap = ih.SMOOTH_SCROLL_MAX_UNITS
    check("an oversized delta is clamped", h.wayland_input.scrolls == [(cap, -cap)],
          h.wayland_input.scrolls)

    for msg in ("ws,nan,1", "ws,1,inf", "ws,-inf,0", "ws,abc,1", "ws,1", "ws,", "ws"):
        h = await ws(msg)
        check(f"{msg!r} is dropped", h.wayland_input.scrolls == [], h.wayland_input.scrolls)

    h = await ws("ws,0,0")
    check("a zero delta injects nothing", h.wayland_input.scrolls == [])
    h = await ws("ws,-0.0,0.00")
    check("a signed zero injects nothing", h.wayland_input.scrolls == [])

    # Without the Wayland harness the delta becomes the clicks m2 would send.
    clicks = []
    h = make_handler(wayland=False)
    h.send_mouse = lambda action, data: clicks.append(action)
    for _ in range(4):
        await h.on_message("ws,0,4")
    check("X11 carries fractions into whole clicks",
          clicks == [ih.MOUSE_SCROLL_UP], clicks)
    await h.on_message("ws,-25,0")
    check("X11 horizontal clicks follow the sign",
          clicks == [ih.MOUSE_SCROLL_UP, ih.MOUSE_SCROLL_LEFT, ih.MOUSE_SCROLL_LEFT], clicks)
    await h.on_message("ws,0,-8")
    check("X11 reversal drops the carry the other way",
          len(clicks) == 3 and h._smooth_scroll_carry[1] == -8.0, h._smooth_scroll_carry)


asyncio.run(main())
failed = [r for r in results if not r[1]]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
