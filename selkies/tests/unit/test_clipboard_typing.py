#!/usr/bin/env python3
"""Clipboard-paste text injection: the typing route for Wayland compositors
with no zwp_virtual_keyboard (KWin).

Drives the real keyboard worker and _inject_text_via_clipboard against fakes:
buffered unicode keysyms must flush through the virtual keyboard when it works
and fall back to save clipboard -> write text -> Shift+Insert -> restore when
it does not, lifting held modifiers around the chord, restoring binary
clipboards under their mime, clearing when there was nothing to restore, and
dropping nothing silently unless both engines fail. Where pixelflux counts the
paste requests its selection serves, the restore waits for that proof of
delivery, an unfetched paste stays on the clipboard, client clipboard writes
during an injection are held until it ends, and concurrent injections queue.
"""
import asyncio
import os
import sys
import threading

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))

from selkies.input_handler import PixelfluxVkUnavailable, WebRTCInput  # noqa: E402

SHIFT_L = 0xFFE1
INSERT = 0xFF63
CTRL_L = 0xFFE3
BACKSPACE = 0xFF08

results = []


def check(label: str, ok, detail="") -> None:
    results.append((label, bool(ok)))
    print(f"{'PASS' if ok else 'FAIL'}  {label}  {detail}", flush=True)


class FakeWaylandInput:
    """No set_keymap_string, so the worker treats the seat as non-native and
    buffers unicode keysyms the way it does for a nested app compositor."""

    def __init__(self) -> None:
        self.cleared: list = []
        self.set_calls: list = []

    def clipboard_clear_app(self, display: str) -> None:
        self.cleared.append(display)

    def set_clipboard(self, mime: str, data) -> None:
        self.set_calls.append((mime, data))


class TrackedWaylandInput(FakeWaylandInput):
    """Adds pixelflux's paste-delivery ledger, scripted per write.

    `outcomes` maps each tracked write, in order, to how its paste goes:
    "served" (fetched once, selection kept), "never" (nobody fetches),
    "lost" (another client took the selection first), "served_lost"
    (fetched, then the selection moved on). `stray` fetches happen as soon as
    the selection is taken, before any chord (a clipboard manager reading
    it). `gate`, when set, holds every post-chord wait until released, so a
    test can act mid-injection.
    """

    def __init__(self, log: list, outcomes=None, gate=None, stray: int = 0) -> None:
        super().__init__()
        self.log = log
        self.outcomes = list(outcomes or [])
        self.gate = gate
        self.stray = stray
        self.tracked: dict = {}
        self.chorded: set = set()
        self.released: list = []
        self.app_writes: list = []
        self.uncounted: list = []

    def clipboard_write_app_tracked(self, display, entries, uncounted=()):
        token = len(self.tracked) + 1
        text = entries[0][1].decode()
        outcome = self.outcomes.pop(0) if self.outcomes else "served"
        self.tracked[token] = (text, outcome)
        self.uncounted.append(list(uncounted))
        self.log.append(("tracked_write", text))
        return token

    def clipboard_wait_served_app(self, token, after, timeout_ms):
        _, outcome = self.tracked[token]
        if token not in self.chorded:
            self.log.append(("presettle", token, after))
            return (self.stray, outcome == "lost")
        if self.gate is not None:
            self.gate.wait(5)
        self.log.append(("wait", token, after))
        if outcome == "never":
            return (self.stray, False)
        if outcome == "lost":
            return (self.stray, True)
        if outcome == "served_lost":
            return (self.stray + 1, after > self.stray)
        return (self.stray + 1, False)

    def clipboard_release_tracked_app(self, token):
        self.released.append(token)

    def clipboard_write_app(self, display, entries):
        self.app_writes.append(entries[0][1])
        self.log.append(("app_write", entries[0][1]))


def make_handler(vk_error: bool = True, separate: bool = True,
                 clipboard=None, write_ok: bool = True) -> WebRTCInput:
    """A WebRTCInput whose injection dependencies are recording fakes.

    Args:
        vk_error: Whether the virtual keyboard raises PixelfluxVkUnavailable,
            forcing the clipboard-paste fallback.
        separate: Whether a nested app compositor is reported.
        clipboard: The `(data, mime)` the pre-paste save reads, or None.
        write_ok: Whether clipboard writes succeed.
    """
    h = WebRTCInput.__new__(WebRTCInput)
    h.is_wayland = True
    h.wayland_input = FakeWaylandInput()
    h.active_modifiers = set()
    h.atomically_typed_keys = set()
    h._wl_text_routed = {}
    h.max_pressed_keys = 1024
    h.keyboard_queue = asyncio.Queue()
    h._clipboard_inject_lock = asyncio.Lock()
    h._clipboard_inject_active = False
    h._clipboard_inject_owner = None
    h._clipboard_deferred_write = None
    h._clipboard_inject_snapshot = (None, None)
    h._bg_tasks = set()
    h._clipboard_last_bytes = None
    h._clipboard_self_write = None
    h.keys = []
    h.typed = []
    h.writes = []
    h.clipboard = clipboard

    async def send(keysym, down=True, neutralize=None):
        h.keys.append((keysym, down))
    h.send_x11_keypress = send

    async def wl_type(text):
        if vk_error:
            raise PixelfluxVkUnavailable(
                "app compositor does not advertise zwp_virtual_keyboard_manager_v1")
        h.typed.append(text)
    h._wl_type_text = wl_type

    async def read_clipboard(use_binary=False):
        return h.clipboard if h.clipboard else (None, None)
    h.read_clipboard = read_clipboard

    async def write_clipboard(data, mime_type="text/plain"):
        if not write_ok:
            return False
        h.writes.append((data, mime_type))
        return True
    h.write_clipboard = write_clipboard

    h._has_separate_app_compositor = lambda: separate
    h._app_wayland_display = lambda: "wayland-app"

    async def no_owner():
        return None
    h._ensure_wayland_keymap_owner = no_owner
    return h


async def run_worker(h: WebRTCInput, items: list, settle: float = 0.15) -> None:
    """Feed `items` through the keyboard worker, then cancel it after `settle`."""
    task = asyncio.create_task(h._keyboard_worker())
    for item in items:
        h.keyboard_queue.put_nowait(item)
    await asyncio.sleep(settle)
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


def chord_of(keys: list) -> list:
    """Just the Shift/Insert events, for comparing against PASTE_CHORD."""
    return [k for k in keys if k[0] in (SHIFT_L, INSERT)]


PASTE_CHORD = [(SHIFT_L, True), (INSERT, True), (INSERT, False), (SHIFT_L, False)]


async def main() -> None:
    h = make_handler(clipboard=("before", "text/plain"))
    ks = [0x01000000 | ord(c) for c in "한국어"]
    await run_worker(h, [("kd", k) for k in ks] + [("ku", k) for k in ks])
    check("buffered keysyms paste as one clipboard write",
          [w[0] for w in h.writes][:1] == ["한국어"], h.writes)
    check("paste chord is Shift+Insert in order", chord_of(h.keys) == PASTE_CHORD, h.keys)
    check("previous clipboard is restored after the paste",
          h.writes[-1] == ("before", "text/plain"), h.writes)
    check("unicode keyups are swallowed",
          all(k[0] in (SHIFT_L, INSERT) for k in h.keys), h.keys)

    h = make_handler(clipboard=("before", "text/plain"))
    await run_worker(h, [("kd", 0x01000000 | ord("가")), ("kd", 0x01000000 | ord("나")),
                         ("kd", BACKSPACE)])
    check("backspace pops the buffer before it flushes",
          [w[0] for w in h.writes][:1] == ["가"], h.writes)

    h = make_handler(clipboard=None)
    await run_worker(h, [("co_end", "組み合わせ")])
    check("composition text takes the same clipboard route",
          [w[0] for w in h.writes] == ["組み合わせ"], h.writes)
    check("an empty clipboard is cleared, not repopulated",
          h.wayland_input.cleared == ["wayland-app"] and len(h.writes) == 1,
          (h.wayland_input.cleared, h.writes))

    h = make_handler(clipboard=("before", "text/plain"))
    h.active_modifiers = {CTRL_L}
    await run_worker(h, [("kd", 0x01000000 | ord("ㅎ"))])
    lifted = h.keys and h.keys[0] == (CTRL_L, False)
    restored = h.keys and h.keys[-1] == (CTRL_L, True)
    check("held modifier is lifted before the chord and restored after",
          lifted and restored and chord_of(h.keys) == PASTE_CHORD, h.keys)

    h = make_handler(clipboard=(b"\x89PNG", "image/png"))
    await run_worker(h, [("co_end", "text")])
    check("binary clipboard is restored under its own mime",
          h.writes[-1] == (b"\x89PNG", "image/png"), h.writes)

    h = make_handler(write_ok=False)
    await run_worker(h, [("co_end", "text")])
    check("failed clipboard write sends no chord", chord_of(h.keys) == [], h.keys)

    h = make_handler(vk_error=False, clipboard=("before", "text/plain"))
    await run_worker(h, [("co_end", "text")])
    check("working virtual keyboard bypasses the clipboard entirely",
          h.typed == ["text"] and h.writes == [], (h.typed, h.writes))

    h = make_handler(clipboard=("before", "text/plain"))
    h._clipboard_inject_active = True
    h._clipboard_inject_owner = asyncio.current_task()
    ok = await h._inject_text_via_clipboard("text")
    check("reentry from the injecting task's own key path is refused",
          ok is False and h.writes == [], h.writes)

    h = make_handler(clipboard=("before", "text/plain"))
    await h._type_keysym_fallback(0x20AC, down=True)
    check("single-keysym fallback pastes through the clipboard too",
          [w[0] for w in h.writes][:1] == ["€"] and chord_of(h.keys) == PASTE_CHORD,
          (h.writes, h.keys))

    h = make_handler(clipboard=("before", "text/plain"), separate=False)
    ok = await h._inject_text_via_clipboard("direct")
    check("non-nested topology injects and restores the same way",
          ok and [w[0] for w in h.writes] == ["direct", "before"], h.writes)

    await tracked_cases()


def make_tracked(outcomes=None, gate=None, real_write=False, clipboard=("before", "text/plain"),
                 stray: int = 0):
    """A handler on the tracked route; `real_write` keeps the real
    write_clipboard so its hold-during-injection gate is exercised."""
    h = make_handler(clipboard=clipboard)
    log: list = []
    h.wayland_input = TrackedWaylandInput(log, outcomes, gate, stray)
    h.log = log

    async def send(keysym, down=True, neutralize=None):
        h.keys.append((keysym, down))
        if keysym == INSERT and down:
            h.wayland_input.chorded.add(len(h.wayland_input.tracked))
            log.append(("chord",))
    h.send_x11_keypress = send

    if real_write:
        h.write_clipboard = WebRTCInput.write_clipboard.__get__(h)
        h._invalidate_app_wl_display_if_dead = lambda d: None
    else:
        async def write_clipboard(data, mime_type="text/plain"):
            h.writes.append((data, mime_type))
            log.append(("restore", data))
            return True
        h.write_clipboard = write_clipboard
    return h


async def tracked_cases() -> None:
    h = make_tracked()
    ok = await h._inject_text_via_clipboard("中文")
    order = [e[0] for e in h.log]
    check("tracked paste: write, quiet period, chord, delivery wait, then restore",
          ok and order[:4] == ["tracked_write", "presettle", "chord", "wait"]
          and order[-1] == "restore" and h.writes == [("before", "text/plain")], h.log)
    check("the KDE password hint is offered and left uncounted",
          h.wayland_input.uncounted == [["x-kde-passwordManagerHint"]], h.wayland_input.uncounted)

    h = make_tracked(outcomes=["never"], stray=1)
    ok = await h._inject_text_via_clipboard("经理读了")
    check("a fetch before the chord (clipboard manager) is not taken as delivery",
          ok is False and h.writes == [], h.log)

    h = make_tracked(outcomes=["served"], stray=1)
    ok = await h._inject_text_via_clipboard("经理读了也送达")
    check("a paste after a clipboard manager's fetch still counts as delivery",
          ok and h.writes == [("before", "text/plain")], h.log)
    check("tracked ledger is released", h.wayland_input.released == [1],
          h.wayland_input.released)

    h = make_tracked(outcomes=["never"])
    ok = await h._inject_text_via_clipboard("没人取")
    check("unfetched paste reports failure and keeps the text on the clipboard",
          ok is False and h.writes == [] and h.wayland_input.cleared == []
          and h.wayland_input.released == [1], (h.writes, h.log))

    h = make_tracked(outcomes=["lost"])
    ok = await h._inject_text_via_clipboard("被抢")
    check("selection lost before any fetch is not delivered and not restored",
          ok is False and h.writes == [], h.writes)

    h = make_tracked(outcomes=["served_lost"])
    ok = await h._inject_text_via_clipboard("取后被抢")
    check("fetched paste whose selection then moved on is delivered, not restored",
          ok is True and h.writes == [], h.writes)

    h = make_tracked(outcomes=["served", "served"])
    a = asyncio.create_task(h._inject_text_via_clipboard("第一"))
    b = asyncio.create_task(h._inject_text_via_clipboard("第二"))
    ra, rb = await asyncio.gather(a, b)
    tracked = [e[1] for e in h.log if e[0] == "tracked_write"]
    check("concurrent injections queue instead of dropping",
          ra and rb and tracked == ["第一", "第二"], h.log)

    gate = threading.Event()
    h = make_tracked(gate=gate, real_write=True)
    inj = asyncio.create_task(h._inject_text_via_clipboard("正在打"))
    while not any(e[0] == "chord" for e in h.log):
        await asyncio.sleep(0.005)
    await h.write_clipboard("用户新复制")
    held = not h.wayland_input.app_writes
    gate.set()
    ok = await inj
    check("client clipboard write during an injection is held, then replaces the restore",
          ok and held and h.wayland_input.app_writes == [b"\xe7\x94\xa8\xe6\x88\xb7\xe6\x96\xb0\xe5\xa4\x8d\xe5\x88\xb6"]
          and h._clipboard_deferred_write is None, h.log)

    gate = threading.Event()
    h = make_tracked(outcomes=["never"], gate=gate, real_write=True)
    inj = asyncio.create_task(h._inject_text_via_clipboard("没送达"))
    while not any(e[0] == "chord" for e in h.log):
        await asyncio.sleep(0.005)
    await h.write_clipboard("用户新复制")
    gate.set()
    ok = await inj
    check("an undelivered paste keeps its text over a held client write",
          ok is False and h.wayland_input.app_writes == [], h.log)

    gate = threading.Event()
    h = make_tracked(gate=gate)
    real_read = WebRTCInput.read_clipboard.__get__(h)
    inj = asyncio.create_task(h._inject_text_via_clipboard("别读我"))
    while not any(e[0] == "chord" for e in h.log):
        await asyncio.sleep(0.005)
    seen = await real_read(use_binary=True)
    gate.set()
    ok = await inj
    check("a client clipboard read during an injection sees the pre-injection content",
          ok and seen == ("before", "text/plain"), seen)

    h = make_tracked()

    async def hung_write(data, mime_type="text/plain"):
        await asyncio.sleep(3600)
    h.write_clipboard = hung_write
    h.active_modifiers = {CTRL_L}
    task = asyncio.create_task(h._inject_text_via_clipboard("卡住"))
    await asyncio.sleep(0.2)
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    check("a cancelled injection still clears its flags",
          not h._clipboard_inject_active and h._clipboard_inject_owner is None,
          (h._clipboard_inject_active, h._clipboard_inject_owner))

    h = make_tracked(real_write=True)
    ok = await h.write_clipboard("平时")
    check("client clipboard writes outside an injection go straight through",
          ok and h.wayland_input.app_writes == ["平时".encode()], h.log)

    texts = [f"第{i}段，mixed {i} 中英。" for i in range(300)]
    h = make_tracked(outcomes=["served"] * len(texts))
    worker = asyncio.create_task(h._keyboard_worker())
    for t in texts:
        h.keyboard_queue.put_nowait(("co_end", t))
    for _ in range(400):
        if sum(1 for e in h.log if e[0] == "tracked_write") == len(texts):
            break
        await asyncio.sleep(0.02)
    await asyncio.sleep(0.1)
    worker.cancel()
    try:
        await worker
    except asyncio.CancelledError:
        pass
    tracked = "".join(e[1] for e in h.log if e[0] == "tracked_write")
    check("300 queued compositions arrive whole and in order",
          tracked == "".join(texts), f"{len(tracked)} of {len(''.join(texts))} chars")


asyncio.run(main())
failed = [r for r in results if not r[1]]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
