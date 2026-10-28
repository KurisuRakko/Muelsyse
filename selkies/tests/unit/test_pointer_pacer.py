#!/usr/bin/env python3
"""KWin host pointer pacer: bursts of absolute moves spread over display beats.

Drives `_PointerPacer` and `WebRTCInput._route_pointer_message` against a fake
clock and sleep: a move after a quiet interval is injected at once, a burst is
queued and injected one position per beat, a backlog shrinks by a third
of itself each beat, a click or wheel flushes only the newest queued position ahead of
itself, and relative moves, other backends and `MUELSYSE_POINTER_PACE_MS=0`
pass straight through.
"""
import asyncio
import os
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))

from selkies.input_handler import (  # noqa: E402
    WebRTCInput, _PointerPacer, pointer_pace_interval_s,
)

# A power of two, so sums of beats on the fake clock compare exactly.
INTERVAL = 1.0 / 64.0

results = []


def check(label: str, ok, detail="") -> None:
    results.append((label, bool(ok)))
    print(f"{'PASS' if ok else 'FAIL'}  {label}  {detail}", flush=True)


class FakeTime:
    """A clock that moves only when the test advances it, with sleeps that wake on it."""

    def __init__(self) -> None:
        self.now = 100.0
        self._sleepers = []

    def clock(self) -> float:
        return self.now

    async def sleep(self, delay: float) -> None:
        fut = asyncio.get_running_loop().create_future()
        self._sleepers.append((self.now + delay, fut))
        await fut

    async def advance(self, dt: float) -> None:
        """Move the clock by dt, wake due sleepers, and let the loop settle."""
        self.now += dt
        due = [s for s in self._sleepers if s[0] <= self.now + 1e-9]
        self._sleepers = [s for s in self._sleepers if s not in due]
        for _, fut in due:
            if not fut.done():
                fut.set_result(None)
        for _ in range(10):
            await asyncio.sleep(0)


def make_pacer(t: FakeTime):
    log = []

    async def inject(x, y, button_mask, display_id):
        log.append((x, y, button_mask, display_id))

    return _PointerPacer(inject, INTERVAL, clock=t.clock, sleep=t.sleep), log


def make_handler(kwin: bool = True, t: FakeTime = None):
    """A WebRTCInput shell whose send_x11_mouse only records its calls."""
    h = WebRTCInput.__new__(WebRTCInput)
    h._external_wayland_host = kwin
    h._wayland_host_backend = "kwin" if kwin else "protocol"
    h.button_mask = 0
    h.log = []

    async def send_x11_mouse(x, y, button_mask, scroll_magnitude, relative=False,
                             display_id='primary'):
        h.log.append((x, y, button_mask, scroll_magnitude, relative, display_id))
        h.button_mask = button_mask

    h.send_x11_mouse = send_x11_mouse
    if t is not None:
        async def inject(x, y, button_mask, display_id):
            await h.send_x11_mouse(x, y, button_mask, 0, False, display_id=display_id)
        h._pointer_pacer = _PointerPacer(inject, INTERVAL, clock=t.clock, sleep=t.sleep)
    return h


async def main() -> None:
    # --- On-beat moves go straight through.
    t = FakeTime()
    p, log = make_pacer(t)
    await p.submit(1, 1, 0, "primary")
    await t.advance(INTERVAL)
    await p.submit(2, 2, 0, "primary")
    await t.advance(INTERVAL * 1.5)
    await p.submit(3, 3, 0, "primary")
    check("moves an interval apart are injected immediately",
          [e[0] for e in log] == [1, 2, 3] and p.pending == 0 and p.queued == 0,
          f"{log}")
    # A jittered 60 Hz client (a move slightly early) is not held for a beat.
    await t.advance(INTERVAL * 0.6)
    await p.submit(4, 4, 0, "primary")
    check("a slightly early move is still injected immediately",
          [e[0] for e in log] == [1, 2, 3, 4] and p.queued == 0, f"{log}")

    # --- A burst is queued and spread one position per beat.
    t = FakeTime()
    p, log = make_pacer(t)
    await p.submit(0, 0, 0, "primary")
    for i in range(1, 3):
        await p.submit(i, i, 0, "primary")
    check("burst: first injected, the rest queued",
          [e[0] for e in log] == [0] and p.pending == 2, f"{log} pending={p.pending}")
    await t.advance(INTERVAL / 2)
    check("burst: nothing injected before the beat", len(log) == 1, f"{log}")
    await t.advance(INTERVAL / 2)
    check("burst: one position on the first beat",
          [e[0] for e in log] == [0, 1], f"{log}")
    await t.advance(INTERVAL)
    check("burst: the last on the next beat, queue drained",
          [e[0] for e in log] == [0, 1, 2] and p.pending == 0, f"{log}")
    await t.advance(INTERVAL * 3)
    check("burst: the beat task stops on an empty queue",
          len(log) == 3 and (p._task is None or p._task.done()), f"task={p._task}")

    # --- A backlog of ten drains within three beats, ending on the newest.
    t = FakeTime()
    p, log = make_pacer(t)
    await p.submit(0, 0, 0, "primary")
    for i in range(1, 11):
        await p.submit(i, i, 0, "primary")
    await t.advance(INTERVAL)
    check("backlog: first beat takes ceil(10/3) and injects the last of them",
          [e[0] for e in log[1:]] == [4] and p.pending == 6, f"{log[1:]}")
    for _ in range(2):
        await t.advance(INTERVAL)
    beats = [e[0] for e in log[1:]]
    check("backlog of 10 drained in 3 beats ending on the newest",
          beats == [4, 7, 10] and p.pending == 0, f"injected={beats}")
    check("backlog counters", p.queued == 10 and p.coalesced == 10 - len(beats),
          f"queued={p.queued} coalesced={p.coalesced}")

    # --- A move on another display flushes the queue first.
    t = FakeTime()
    p, log = make_pacer(t)
    await p.submit(0, 0, 0, "primary")
    await p.submit(1, 1, 0, "primary")
    await p.submit(2, 2, 0, "primary")
    await p.submit(5, 5, 0, "display2")
    check("display change flushes the newest queued position first",
          log[:2] == [(0, 0, 0, "primary"), (2, 2, 0, "primary")]
          and p.pending == 1 and p._queue[0][3] == "display2", f"{log}")

    # --- Through the handler: a click flushes only the newest queued position.
    t = FakeTime()
    h = make_handler(kwin=True, t=t)
    await h._route_pointer_message(10, 10, 0, 0, False, "primary")
    await h._route_pointer_message(11, 11, 0, 0, False, "primary")
    await h._route_pointer_message(12, 12, 0, 0, False, "primary")
    await h._route_pointer_message(13, 13, 0, 0, False, "primary")
    await h._route_pointer_message(13, 13, 1, 0, False, "primary")
    check("click: newest queued move, then the press, nothing between",
          h.log == [(10, 10, 0, 0, False, "primary"),
                    (13, 13, 0, 0, False, "primary"),
                    (13, 13, 1, 0, False, "primary")]
          and h._pointer_pacer.pending == 0, f"{h.log}")
    await t.advance(INTERVAL * 4)
    check("click: no stale beat fires after the flush", len(h.log) == 3, f"{h.log}")

    # Moves with the button held are pure moves again and are paced.
    await h._route_pointer_message(20, 20, 1, 0, False, "primary")
    await h._route_pointer_message(21, 21, 1, 0, False, "primary")
    await h._route_pointer_message(22, 22, 1, 0, False, "primary")
    check("drag: held-button moves are paced",
          h.log[3:] == [(20, 20, 1, 0, False, "primary")]
          and h._pointer_pacer.pending == 2, f"{h.log[3:]}")
    await h._route_pointer_message(22, 22, 0, 0, False, "primary")
    check("release: flushes the newest drag position before the release",
          h.log[4:] == [(22, 22, 1, 0, False, "primary"),
                        (22, 22, 0, 0, False, "primary")], f"{h.log[4:]}")

    # --- A wheel tick flushes too.
    t = FakeTime()
    h = make_handler(kwin=True, t=t)
    await h._route_pointer_message(1, 1, 0, 0, False, "primary")
    await h._route_pointer_message(2, 2, 0, 0, False, "primary")
    await h._route_pointer_message(3, 3, 0, 0, False, "primary")
    await h._route_pointer_message(3, 3, 8, 1, False, "primary")
    check("wheel: flushes then applies the scroll message",
          h.log == [(1, 1, 0, 0, False, "primary"), (3, 3, 0, 0, False, "primary"),
                    (3, 3, 8, 1, False, "primary")], f"{h.log}")

    # --- Relative moves flush and pass through unpaced.
    t = FakeTime()
    h = make_handler(kwin=True, t=t)
    await h._route_pointer_message(1, 1, 0, 0, False, "primary")
    await h._route_pointer_message(2, 2, 0, 0, False, "primary")
    for _ in range(3):
        await h._route_pointer_message(1, 0, 0, 0, True, "primary")
    check("m2: relative moves pass straight through after a flush",
          h.log == [(1, 1, 0, 0, False, "primary"), (2, 2, 0, 0, False, "primary")]
          + [(1, 0, 0, 0, True, "primary")] * 3 and h._pointer_pacer.pending == 0,
          f"{h.log}")

    # --- Other backends never pace.
    h = make_handler(kwin=False)
    for i in range(5):
        await h._route_pointer_message(i, i, 0, 0, False, "primary")
    check("non-KWin: every move injected directly",
          [e[0] for e in h.log] == list(range(5))
          and getattr(h, "_pointer_pacer", None) is None, f"{h.log}")

    # --- MUELSYSE_POINTER_PACE_MS=0 turns the pacer off on KWin too.
    old = os.environ.get("MUELSYSE_POINTER_PACE_MS")
    try:
        os.environ["MUELSYSE_POINTER_PACE_MS"] = "0"
        h = make_handler(kwin=True)
        for i in range(5):
            await h._route_pointer_message(i, i, 0, 0, False, "primary")
        check("pace=0: every move injected directly",
              [e[0] for e in h.log] == list(range(5))
              and getattr(h, "_pointer_pacer", None) is None, f"{h.log}")
        os.environ.pop("MUELSYSE_POINTER_PACE_MS")
        check("unset: 60 Hz default",
              abs(pointer_pace_interval_s() - 1.0 / 60.0) < 1e-9, f"{pointer_pace_interval_s()}")
        os.environ["MUELSYSE_POINTER_PACE_MS"] = "8"
        check("explicit interval in ms", abs(pointer_pace_interval_s() - 0.008) < 1e-9)
        h = make_handler(kwin=True)
        h._kwin_pointer_pacer()
        check("KWin handler builds its pacer lazily from the env",
              isinstance(getattr(h, "_pointer_pacer", None), _PointerPacer)
              and abs(h._pointer_pacer.interval_s - 0.008) < 1e-9)
    finally:
        if old is None:
            os.environ.pop("MUELSYSE_POINTER_PACE_MS", None)
        else:
            os.environ["MUELSYSE_POINTER_PACE_MS"] = old


asyncio.run(main())
failed = [r for r in results if not r[1]]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
