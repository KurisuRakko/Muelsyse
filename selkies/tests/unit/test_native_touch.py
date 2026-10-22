#!/usr/bin/env python3
"""What the server does with a client's native touch frames.

A `t` message is one touch frame of framebuffer pixels from the display that
delivered it. On the KWin host it reaches the compositor as touchscreen input,
offset into the combined layout and converted to logical pixels the same way an
absolute pointer move is; contact ids are made unique across connections, since
KWin ignores a down on an id it still holds; and a client that vanishes
mid-touch leaves no finger down, while a collaborator's contacts stay down.
Secure mode admits touch only from a connection holding input authority, as it
does the pointer. Anywhere else the frame is dropped, and the
capability the server advertises says so.

Usage: python3 tests/unit/test_native_touch.py
"""
import asyncio
import os
import sys
from typing import Any, List, Optional, Tuple

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))

from selkies.input_handler import WebRTCInput, VIEWER_COLLAB_EXTRA_PREFIXES  # noqa: E402

results: List[Tuple[str, bool]] = []


def check(label: str, ok: Any, detail: str = "") -> None:
    results.append((label, bool(ok)))
    print(f"{'PASS' if ok else 'FAIL'}  [native-touch] {label}  {detail}", flush=True)


class Server:
    """A data server that knows the layout and each display's DPI."""

    def __init__(self, layouts: dict, dpi: float) -> None:
        self.display_layouts = layouts
        self.dpi = dpi

    def _display_dpi(self, display_id: str) -> float:
        return self.dpi


class PixelfluxStub:
    """The KWin host's touch entry points; `delivers` plays the connection."""

    def __init__(self, available: bool = True, delivers: bool = True) -> None:
        self.frames: List[list] = []
        self.available = available
        self.delivers = delivers

    def native_touch_available(self) -> bool:
        return self.available

    def inject_touch(self, frame: list) -> bool:
        self.frames.append(frame)
        return self.delivers


SINGLE = {"primary": {"x": 0, "y": 0, "w": 1920, "h": 1080}}
DUAL = {"primary": {"x": 0, "y": 0, "w": 1920, "h": 1080},
        "second": {"x": 1920, "y": 0, "w": 1280, "h": 720}}


def make(layouts: Optional[dict] = None, dpi: float = 192, backend: str = "kwin",
         stub: Optional[PixelfluxStub] = None) -> Tuple[WebRTCInput, PixelfluxStub]:
    h = WebRTCInput.__new__(WebRTCInput)
    stub = stub or PixelfluxStub()
    h.is_wayland = True
    h.wayland_input = stub
    h._external_wayland_host = True
    h._wayland_host_backend = backend
    h.data_server_instance = Server(layouts or SINGLE, dpi)
    h.system_dpi = dpi
    h._touch_contacts = {}
    h._touch_next_id = 0
    h.button_mask = 0
    return h, stub


def send(h: WebRTCInput, msg: str, display_id: str = "primary", conn_id: Any = 1) -> None:
    asyncio.run(h.on_message(msg, display_id, conn_id))


def main() -> None:
    h, wl = make()
    check("the KWin host offers native touch", h.native_touch_available())
    send(h, "t,d,1,200,100")
    send(h, "t,m,1,220,100,d,2,400,300")
    send(h, "t,u,1,220,100,u,2,400,300")
    down, both, ups = wl.frames
    check("a down lands in logical pixels, as a pointer move would",
          down == [("d", 1, 100.0, 50.0)], f"{down}")
    check("one message is one frame, in order",
          both == [("m", 1, 110.0, 50.0), ("d", 2, 200.0, 150.0)], f"{both}")
    check("ups lift the contacts they name and the server holds none after",
          ups == [("u", 1, 0.0, 0.0), ("u", 2, 0.0, 0.0)] and not h._touch_contacts, f"{ups}")

    h, wl = make(DUAL)
    send(h, "t,d,1,100,50", "second")
    check("a secondary display's touch is offset into the layout",
          wl.frames[-1] == [("d", 1, (1920 + 100) / 2.0, 25.0)], f"{wl.frames[-1]}")
    send(h, "t,d,1,100,50", "unlaid")
    check("a display with no laid-out region injects nothing", len(wl.frames) == 1)

    h, wl = make()
    send(h, "t,d,1,10,10", conn_id="a")
    send(h, "t,d,1,20,20", conn_id="b")
    a, b = wl.frames[0][0][1], wl.frames[1][0][1]
    check("the same client id from two connections is two contacts", a != b, f"{a}, {b}")
    send(h, "t,d,1,30,30", conn_id="a")
    check("a down on a contact already held is dropped", len(wl.frames) == 2)
    send(h, "t,m,9,30,30", conn_id="a")
    check("motion of a contact never put down is dropped", len(wl.frames) == 2)
    h.release_touches("a")
    check("a departing client's contacts are lifted, a collaborator's kept",
          wl.frames[-1] == [("u", a, 0.0, 0.0)] and list(h._touch_contacts) == [("b", 1)],
          f"{wl.frames[-1]}")
    send(h, "t,c,0,0,0", conn_id="b")
    check("the last connection holding contacts cancels the sequence",
          wl.frames[-1] == [("c", 0, 0.0, 0.0)] and not h._touch_contacts, f"{wl.frames[-1]}")
    send(h, "t,d,1,10,10", conn_id="a")
    send(h, "t,d,1,20,20", conn_id="b")
    send(h, "t,c,0,0,0", conn_id="a")
    check("a cancel from one connection leaves another's contacts down",
          wl.frames[-1][0][0] == "u" and list(h._touch_contacts) == [("b", 1)], f"{wl.frames[-1]}")
    h.release_touches("b")
    check("a departing client leaves no finger down",
          wl.frames[-1] == [("c", 0, 0.0, 0.0)] and not h._touch_contacts, f"{wl.frames[-1]}")
    n = len(wl.frames)
    h.release_touches("b")
    asyncio.run(h.release_mouse_buttons())
    check("nothing is ended when the connection holds no contact", len(wl.frames) == n)

    h, wl = make()
    for bad in ("t,d,1,10", "t,x,1,10,10", "t,d,one,10,10", "t,d,1,nan,10", "t"):
        send(h, bad)
    check("a malformed frame is dropped whole", not wl.frames, f"{wl.frames}")
    send(h, "t," + ",".join(["d,1,5,5"] * 41))
    check("an oversized frame is dropped", not wl.frames)
    send(h, "t,d,1,-50,99999")
    check("coordinates are clamped before conversion",
          wl.frames[-1] == [("d", 1, 0.0, 65535.0 / 2.0)], f"{wl.frames[-1]}")
    send(h, "t,c,0,0,0")
    check("a cancel forgets every contact", wl.frames[-1] == [("c", 0, 0.0, 0.0)] and not h._touch_contacts)

    h, wl = make()
    for i in range(1, 25):
        send(h, f"t,d,{i},{i},{i}")
    check("held contacts are capped", len(h._touch_contacts) == WebRTCInput.MAX_TOUCH_CONTACTS,
          f"{len(h._touch_contacts)}")

    h, wl = make(stub=PixelfluxStub(delivers=False))
    send(h, "t,d,1,10,10")
    check("contacts a lost connection held are forgotten (KWin cancels them itself)",
          not h._touch_contacts)

    for backend in ("protocol", "wlroots"):
        h, wl = make(backend=backend)
        send(h, "t,d,1,10,10")
        check(f"the {backend} host neither offers nor injects native touch",
              not h.native_touch_available() and not wl.frames)
    h, wl = make(stub=PixelfluxStub(available=False))
    check("a KWin without the touch protocol is not offered", not h.native_touch_available())
    h, _ = make()
    h.wayland_input = object()
    check("a pixelflux without touch injection is not offered", not h.native_touch_available())

    check("a collaborating viewer may touch as it may point",
          any("t,1,2,3".startswith(p) for p in VIEWER_COLLAB_EXTRA_PREFIXES))
    from selkies.selkies import SECURE_INPUT_PREFIXES
    check("secure mode gates touch on input authority as it gates the pointer",
          "t,d,1,2,3".split(",", 1)[0] in SECURE_INPUT_PREFIXES)

    failed = [label for label, ok in results if not ok]
    print(f"[native-touch] {len(results) - len(failed)}/{len(results)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
