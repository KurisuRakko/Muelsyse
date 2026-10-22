# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Delay-driven video bitrate control for one WebSockets display.

The only signal that crosses the whole path is the frame acknowledgement: the
server stamps each frame as it is written and the client acks the id it last
received, reporting how long it held that id before the ack timer fired. The
send-to-ack time minus that hold is the frame's round trip, and its excess over
a per-display floor is the queue the video stands behind. That queue lives
wherever the path is slowest -- a TLS-terminating proxy, a tunnel, a Wi-Fi
hop -- and the server's own socket reads empty while it grows, which is why the
relay's byte budget and queue age cannot see it. The floor is LEDBAT's base
delay, the minimum over the minute buckets of the last `FLOOR_BUCKETS` minutes
(the rule `stream_server.UplinkGauge` applies to bulk transfers, aged by time
rather than by count so an idle stretch cannot keep a stale path's floor).

The controller has two modes. ``quality`` leaves the encoder on the display's
own rate control (constant quality for the default CRF mode): nothing is
padded and a healthy link carries whatever the content needs. A queue standing
above `ENTER_QUEUE_MS` for `ENTER_TICKS` consecutive ticks (two seconds, so a
spike is left to the relay's adaptive frame drop) moves the display to
``adaptive``, a bitrate-capped encode (variable bitrate under the cap where
the encoder offers it, constant otherwise) whose target starts at the larger
of `ENTER_GOODPUT_SHARE` of the goodput the acks measured over the last
`GOODPUT_WINDOW_S` (inside the congested stretch that triggered it) and
`ENTER_CEILING_SHARE` of the ceiling, and then follows the queue: a cut by `CUT_FACTOR` while it stands above `CUT_QUEUE_MS` (one per
`CUT_HOLD_S`, the time a cut takes to drain), growth by `GROW_FACTOR` per
`GROW_INTERVAL_S` while it stays under `CLEAR_QUEUE_MS`, never below
`MIN_KBPS` (under it the VA-API rate control skips frames at a 2600x1440
framebuffer, measured at 34 fps for a 700 kbps target). Growth after a cut
stops at `PROBE_SHARE` of the bitrate the cut was taken at and holds there
for `PROBE_HOLD_S` before probing past it (TCP's ssthresh): climbing straight
back into the rate that just congested would saw-tooth around it, and every
tooth is a re-opened codec and a keyframe. Under a variable bitrate the
encoder spends less than the target on easy content, so the target is the cap
the queue allows rather than what is sent. The bitrate mode is the point of
the switch: its small VBV caps every keyframe at a couple of
frames' budget, where a constant-quality keyframe of a large framebuffer is
hundreds of kilobytes and a congested link takes the better part of a second
to carry it. A target that has climbed back to the ceiling and held a clear
queue for `EXIT_CLEAR_S` returns the display to ``quality``.

A standing queue while the acks measure under `ENTER_MIN_GOODPUT_KBPS` does not
enter: a stream sending that little is not what fills the path, and a cap of
at least half the ceiling over it would change nothing but cost a keyframe per
retarget.

The goodput is only a lower bound on the path's capacity: a desktop encoded at
constant quality is application-limited, and a still screen sends a few
hundred kilobits over a link that carries many megabits. Starting from it
alone would put a fast link at `MIN_KBPS` for the tens of seconds growth takes
to climb back. A start that is too high costs little by comparison, since a
real bottleneck keeps the queue standing and the cuts bring the target down by
`CUT_FACTOR` a second.

The acks after a silence measure the client catching up, not the path: a
backgrounded tab's timers are throttled and a tab brought back to the front
spends its first moments decoding a keyframe and laying out, so the round
trips of that stretch run hundreds of milliseconds over a link a few
milliseconds long. A sample arriving more than `RESUME_GAP_S` after the previous
one (or the first since the controller was built or its path reset) opens a
`RESUME_GRACE_S` grace whose samples are dropped while the display is in
``quality``: they neither lower the floor nor count toward entering
``adaptive``. A display already ``adaptive`` keeps every sample, since a
silence there can be the congestion itself and the controller must not be
blinded to it. A client asking for a keyframe is resyncing the same way (a
decoder error, a newly joined viewer, a resize) and opens the same grace.

A queue our own bitrate does not explain is a longer path, not congestion: when
`REBASE_FLAT_CUTS` cuts in a row each leave it above `REBASE_FLAT_RATIO` of
what it was at the previous cut, the floor is re-based to the delay now
measured. Without that, a path that got longer mid-session (a network switch,
a relay taking over) reads as a standing queue for the whole floor history and
drives the bitrate to `MIN_KBPS`; a gradient-based estimator would ignore a
constant offset the same way.

Each applied bitrate change re-opens the VA-API codec context and so costs a
keyframe, which the small VBV keeps cheap; changes under `APPLY_MIN_RATIO` or
closer together than `APPLY_MIN_INTERVAL_S` are held back so the stream is not
re-anchored for nothing. Growth is held to `GROW_APPLY_MIN_RATIO`, about every
second step, since a rate that is merely low costs nothing visible while each
re-anchor blurs the screen; a cut, a target that has stopped at its bound
(the ceiling or the probe cap) and the return to the ceiling after
`reset_path` go out at `APPLY_MIN_RATIO`. A display whose user already picked
constant bitrate never switches modes: the controller steers its bitrate under
the user's pick.

The class is pure state and arithmetic over caller-supplied monotonic times, so
it is tested without an event loop; `DataStreamingServer` feeds it from the ack
handler and the per-display backpressure loop and applies its decisions.
"""
from collections import deque
from typing import Deque, Dict, List, Optional, Tuple

ENTER_QUEUE_MS = 100.0
ENTER_TICKS = 4
CUT_QUEUE_MS = 60.0
CLEAR_QUEUE_MS = 25.0
CUT_FACTOR = 0.75
CUT_HOLD_S = 1.0
GROW_FACTOR = 1.12
GROW_INTERVAL_S = 1.0
ENTER_GOODPUT_SHARE = 0.8
ENTER_CEILING_SHARE = 0.5
MIN_KBPS = 1000
ENTER_MIN_GOODPUT_KBPS = MIN_KBPS
APPLY_MIN_RATIO = 0.1
GROW_APPLY_MIN_RATIO = 0.25
APPLY_MIN_INTERVAL_S = 1.0
EXIT_CLEAR_S = 10.0
PROBE_SHARE = 0.9
PROBE_HOLD_S = 15.0
REBASE_FLAT_CUTS = 2
REBASE_FLAT_RATIO = 0.85
FLOOR_BUCKET_SECONDS = 60.0
FLOOR_BUCKETS = 10
GOODPUT_WINDOW_S = 1.0
RESUME_GAP_S = 2.0
RESUME_GRACE_S = 3.0


class AdaptiveBitrateController:
    """Queue-delay controller for one display's video bitrate.

    Attributes:
        mode: ``quality`` (the display's own rate control) or ``adaptive``
            (constant bitrate at `target_kbps`).
        target_kbps: The bitrate the controller wants while adaptive.
        applied_kbps: The bitrate last handed to the encoder.
        queue_ms: The queue delay measured at the last tick, or None.
    """

    def __init__(self, user_cbr: bool = False) -> None:
        """Args:
            user_cbr: Whether the user picked constant bitrate, in which case
                the controller steers that bitrate and never switches modes.
        """
        self.user_cbr = user_cbr
        self.mode = 'adaptive' if user_cbr else 'quality'
        self.target_kbps = 0.0
        self.applied_kbps = 0
        self.queue_ms: Optional[float] = None
        self._buckets: Deque[List[float]] = deque(maxlen=FLOOR_BUCKETS)
        self._tick_samples: List[float] = []
        self._delivered: Deque[Tuple[float, int]] = deque()
        self._enter_ticks = 0
        self._hold_until = 0.0
        self._last_grow = 0.0
        self._last_apply = 0.0
        self._clear_at_ceiling_since: Optional[float] = None
        self._last_cut_queue: Optional[float] = None
        self._flat_cuts = 0
        self._probe_cap: Optional[float] = None
        self._probe_cap_reached: Optional[float] = None
        self._last_rtt_at: Optional[float] = None
        self._resume_until = 0.0
        self._apply_now = False

    def reset_path(self) -> None:
        """Forget the measured path (a new connection took the display over).

        The mode is kept, since leaving ``adaptive`` rebuilds the capture, but
        an ``adaptive`` target goes back to the ceiling (the user's bitrate
        under constant bitrate) with no probe cap, applied at the next tick
        that has samples: the bitrate the old connection's queue pushed down
        says nothing about the new one, and a real queue on it cuts again
        within seconds.
        """
        self._buckets.clear()
        self._tick_samples = []
        self._delivered.clear()
        self._enter_ticks = 0
        self._clear_at_ceiling_since = None
        self._last_rtt_at = None
        if self.mode == 'adaptive':
            # tick() clamps the target to the ceiling it is handed.
            self.target_kbps = float('inf')
            self._probe_cap = None
            self._probe_cap_reached = None
            self._last_cut_queue = None
            self._flat_cuts = 0
            self._last_apply = float('-inf')
            self._apply_now = True

    def on_client_resync(self, now: float) -> None:
        """Open a resume grace for a client that asked for a keyframe (see the
        module docstring)."""
        self._resume_until = max(self._resume_until, now + RESUME_GRACE_S)
        self._enter_ticks = 0

    def on_rtt(self, rtt_ms: float, now: float) -> None:
        """Fold one acknowledged frame's round trip (hold already removed),
        dropping it in ``quality`` during a resume grace (see the module
        docstring)."""
        if self._last_rtt_at is None or now - self._last_rtt_at > RESUME_GAP_S:
            self._resume_until = now + RESUME_GRACE_S
            self._enter_ticks = 0
        self._last_rtt_at = now
        if self.mode == 'quality' and now < self._resume_until:
            return
        bucket = int(now // FLOOR_BUCKET_SECONDS)
        while self._buckets and self._buckets[0][0] <= bucket - FLOOR_BUCKETS:
            self._buckets.popleft()
        if self._buckets and self._buckets[-1][0] == bucket:
            self._buckets[-1][1] = min(self._buckets[-1][1], rtt_ms)
        else:
            self._buckets.append([bucket, rtt_ms])
        self._tick_samples.append(rtt_ms)

    def on_delivered(self, cumulative_bytes: int, now: float) -> None:
        """Record the stream's cumulative bytes up to the frame just acked."""
        self._delivered.append((now, cumulative_bytes))
        while self._delivered and now - self._delivered[0][0] > GOODPUT_WINDOW_S:
            self._delivered.popleft()

    def goodput_kbps(self) -> Optional[float]:
        """Acked bytes per second over the last `GOODPUT_WINDOW_S`, in kbps."""
        if len(self._delivered) < 2:
            return None
        (t0, b0), (t1, b1) = self._delivered[0], self._delivered[-1]
        if t1 - t0 < 0.25 or b1 < b0:
            return None
        return (b1 - b0) * 8 / 1000.0 / (t1 - t0)

    def _rebase(self, now: float, rtt_ms: float) -> None:
        """Take `rtt_ms` as the path's new floor (see the module docstring)."""
        self._buckets.clear()
        self._buckets.append([int(now // FLOOR_BUCKET_SECONDS), rtt_ms])
        self._last_cut_queue = None
        self._flat_cuts = 0
        self._probe_cap = None
        self._probe_cap_reached = None
        self.queue_ms = 0.0

    def _floor(self) -> Optional[float]:
        return min(b[1] for b in self._buckets) if self._buckets else None

    def tick(self, now: float, ceiling_kbps: float) -> Optional[Dict[str, object]]:
        """Measure the queue since the last tick and decide.

        Args:
            now: Monotonic seconds.
            ceiling_kbps: The highest bitrate the display may use (the user's
                bitrate setting).

        Returns:
            None to change nothing, or a decision: ``{"action": "enter",
            "kbps": k}`` to switch to constant bitrate at ``k``,
            ``{"action": "exit"}`` to return to the display's own rate
            control, ``{"action": "set", "kbps": k}`` to retarget a constant-
            bitrate encode, ``{"action": "rebase"}`` when the floor was re-based
            (nothing to apply). Every decision also carries ``reason``.
        """
        ceiling = max(float(MIN_KBPS), float(ceiling_kbps))
        samples, self._tick_samples = self._tick_samples, []
        floor = self._floor()
        if not samples or floor is None:
            self.queue_ms = None
            return None
        samples.sort()
        self.queue_ms = max(0.0, samples[len(samples) // 2] - floor)
        q = self.queue_ms

        if self.mode == 'quality':
            self._enter_ticks = self._enter_ticks + 1 if q > ENTER_QUEUE_MS else 0
            if self._enter_ticks < ENTER_TICKS:
                return None
            self._enter_ticks = 0
            goodput = self.goodput_kbps()
            if goodput is not None and goodput < ENTER_MIN_GOODPUT_KBPS:
                return None
            start = max((goodput or 0.0) * ENTER_GOODPUT_SHARE, ceiling * ENTER_CEILING_SHARE)
            self.target_kbps = min(ceiling, max(float(MIN_KBPS), start))
            self.mode = 'adaptive'
            self._hold_until = now + CUT_HOLD_S
            self._last_grow = now
            self._last_apply = now
            self._clear_at_ceiling_since = None
            self.applied_kbps = int(round(self.target_kbps))
            return {"action": "enter", "kbps": self.applied_kbps,
                    "reason": f"queue {q:.0f} ms, goodput {goodput or 0:.0f} kbps"}

        if not self.applied_kbps:
            self.target_kbps = ceiling
            self.applied_kbps = int(round(ceiling))
        self.target_kbps = min(self.target_kbps or ceiling, ceiling)
        reason = ''
        at_bound = False
        if q > CUT_QUEUE_MS:
            self._clear_at_ceiling_since = None
            if now >= self._hold_until:
                flat = (self._last_cut_queue is not None
                        and q > self._last_cut_queue * REBASE_FLAT_RATIO)
                self._flat_cuts = self._flat_cuts + 1 if flat else 0
                self._last_cut_queue = q
                if self._flat_cuts >= REBASE_FLAT_CUTS:
                    self._rebase(now, samples[len(samples) // 2])
                    return {"action": "rebase",
                            "reason": f"queue {q:.0f} ms did not follow the cuts; new floor"}
                self._probe_cap = max(float(MIN_KBPS), self.applied_kbps * PROBE_SHARE)
                self._probe_cap_reached = None
                self.target_kbps = max(float(MIN_KBPS), self.target_kbps * CUT_FACTOR)
                self._hold_until = now + CUT_HOLD_S
                self._last_grow = now
                reason = f"cut: queue {q:.0f} ms"
        elif q < CLEAR_QUEUE_MS:
            self._last_cut_queue = None
            self._flat_cuts = 0
            if now >= self._hold_until and now - self._last_grow >= GROW_INTERVAL_S:
                bound = ceiling
                if self._probe_cap is not None:
                    if self.target_kbps >= self._probe_cap - 1e-6:
                        if self._probe_cap_reached is None:
                            self._probe_cap_reached = now
                        elif now - self._probe_cap_reached >= PROBE_HOLD_S:
                            self._probe_cap = None
                    if self._probe_cap is not None:
                        bound = min(ceiling, self._probe_cap)
                grown = min(bound, self.target_kbps * GROW_FACTOR)
                if grown > self.target_kbps:
                    self.target_kbps = grown
                    reason = f"grow: queue {q:.0f} ms"
                at_bound = self.target_kbps >= bound - 1e-6
                self._last_grow = now
            if not self.user_cbr and self.target_kbps >= ceiling - 1e-6:
                if self._clear_at_ceiling_since is None:
                    self._clear_at_ceiling_since = now
                elif now - self._clear_at_ceiling_since >= EXIT_CLEAR_S:
                    self.mode = 'quality'
                    self._clear_at_ceiling_since = None
                    self.applied_kbps = 0
                    self.target_kbps = 0.0
                    return {"action": "exit",
                            "reason": f"clear at ceiling for {EXIT_CLEAR_S:.0f} s"}
        else:
            self._clear_at_ceiling_since = None

        want = int(round(self.target_kbps))
        change = abs(want - self.applied_kbps) / max(1, self.applied_kbps)
        is_cut = want < self.applied_kbps
        prompt = is_cut or at_bound or self._apply_now
        self._apply_now = False
        if change < (APPLY_MIN_RATIO if prompt else GROW_APPLY_MIN_RATIO):
            return None
        if not is_cut and now - self._last_apply < APPLY_MIN_INTERVAL_S:
            return None
        self._last_apply = now
        self.applied_kbps = want
        return {"action": "set", "kbps": want, "reason": reason or f"queue {q:.0f} ms"}
