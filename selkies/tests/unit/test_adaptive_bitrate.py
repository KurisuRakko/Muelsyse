#!/usr/bin/env python3
"""The delay-driven bitrate controller of a WebSockets display.

A queue that stands behind the video has to move the display off constant
quality onto a bitrate the path carries, starting at what the acks just
measured or half the ceiling, whichever is higher (the goodput of a desktop is
application-limited); a queue that keeps standing cuts the bitrate again, a clear one grows
it back, and a display back at its ceiling for long enough returns to constant
quality. Jitter around the floor must change nothing, a static screen (no acks)
must hold, and small or too-frequent retargets must be held back, since each
one costs a keyframe. The acks right after a silence measure a client catching
up, so they must not switch a display out of constant quality, and a new
connection taking a display over must get its ceiling back. A client asking
for a keyframe opens the same grace, a short spike or a queue over a stream
that sends almost nothing must not switch, growth is applied only in large
steps while cuts and a takeover go out at once. Times are fed explicitly, so
this runs without a loop.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "src"))
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import helpers as H

from selkies import adaptive_bitrate as ab
from selkies.adaptive_bitrate import AdaptiveBitrateController

BASE_RTT = 40.0


def feed(ctl, t0, seconds, rtt_ms, kbps_delivered=None, cum=None, step=0.05):
    """Ack every `step` seconds at `rtt_ms`; returns the new time and byte count."""
    t = t0
    cum = cum or 0
    while t < t0 + seconds - 1e-9:
        t += step
        ctl.on_rtt(rtt_ms, t)
        if kbps_delivered is not None:
            cum += int(kbps_delivered * 1000 / 8 * step)
            ctl.on_delivered(cum, t)
    return t, cum


def run_ticks(ctl, t, seconds, rtt_ms, ceiling, kbps_delivered=None, cum=0):
    """Alternate 0.5 s of acks with a tick; collect the decisions."""
    decisions = []
    end = t + seconds
    while t < end - 1e-9:
        t, cum = feed(ctl, t, 0.5, rtt_ms, kbps_delivered, cum)
        d = ctl.tick(t, ceiling)
        if d:
            decisions.append((round(t, 2), d))
    return t, cum, decisions


def main() -> "H.Results":
    res = H.Results("adaptive-bitrate")

    ctl = AdaptiveBitrateController()
    t, cum, ds = run_ticks(ctl, 0.0, 10, BASE_RTT, 8000, kbps_delivered=6000)
    res.check("a steady path changes nothing", not ds and ctl.mode == 'quality', ds)

    t, cum, ds = run_ticks(ctl, t, 5, BASE_RTT + 20, 8000, kbps_delivered=6000, cum=cum)
    res.check("jitter under the entry threshold stays in quality mode",
              not ds and ctl.mode == 'quality', ds)

    t, cum, ds = run_ticks(ctl, t, 1.5, BASE_RTT + 300, 8000, kbps_delivered=3000, cum=cum)
    res.check("a queue spike of three ticks does not switch yet", not ds, ds)
    t, cum, ds = run_ticks(ctl, t, 0.5, BASE_RTT + 300, 8000, kbps_delivered=3000, cum=cum)
    enter = ds[0][1] if ds else {}
    res.check("a queue standing for four ticks switches to constant bitrate",
              enter.get("action") == "enter" and ctl.mode == 'adaptive', ds)
    res.check("an entry goodput under half the ceiling starts at half the ceiling",
              enter and enter["kbps"] == 8000 * ab.ENTER_CEILING_SHARE, enter)

    t, cum, ds = run_ticks(ctl, t, 4, BASE_RTT + 200, 8000, kbps_delivered=1500, cum=cum)
    cuts = [d for _, d in ds if d["action"] == "set"]
    res.check("a queue that keeps standing cuts the bitrate",
              cuts and all(c["kbps"] < enter["kbps"] for c in cuts), cuts)
    times = [ts for ts, d in ds if d["action"] == "set"]
    res.check("cuts are spaced by the drain hold",
              all(b - a >= ab.CUT_HOLD_S - 1e-6 for a, b in zip(times, times[1:])), times)
    low = ctl.applied_kbps

    t, cum, ds = run_ticks(ctl, t, 6, BASE_RTT + 5, 8000, kbps_delivered=1000, cum=cum)
    grows = [d for _, d in ds if d["action"] == "set"]
    res.check("a clear queue grows the bitrate back",
              grows and grows[-1]["kbps"] > low, grows)
    times = [ts for ts, d in ds if d["action"] == "set"]
    res.check("growth is applied no more than once per interval",
              all(b - a >= ab.APPLY_MIN_INTERVAL_S - 1e-6 for a, b in zip(times, times[1:])), times)
    res.check("every applied change is at least the minimum step",
              all(abs(b["kbps"] - a["kbps"]) / a["kbps"] >= ab.APPLY_MIN_RATIO - 1e-6
                  for a, b in zip(grows, grows[1:])), [g["kbps"] for g in grows])

    t, cum, ds = run_ticks(ctl, t, 60, BASE_RTT, 8000, kbps_delivered=8000, cum=cum)
    exits = [d for _, d in ds if d["action"] == "exit"]
    res.check("a display clear at its ceiling long enough returns to quality",
              exits and ctl.mode == 'quality', [d for _, d in ds][-3:])

    d = ctl.tick(t + 0.5, 8000)
    res.check("a tick without acks (static screen) holds", d is None and ctl.queue_ms is None, d)

    floor_ctl = AdaptiveBitrateController()
    t2, cum2, ds = run_ticks(floor_ctl, 0.0, 3, 300.0, 8000, kbps_delivered=2000)
    res.check("a long but steady path is its own floor, not congestion",
              not ds and floor_ctl.mode == 'quality', ds)

    floor_ctl = AdaptiveBitrateController()
    t3 = 0.0
    t3, _ = feed(floor_ctl, t3, ab.RESUME_GRACE_S + 1, BASE_RTT)
    floor_ctl.tick(t3, 8000)
    t3, _ = feed(floor_ctl, t3 + 11 * 60, ab.RESUME_GRACE_S + 1, BASE_RTT + 150)
    floor_ctl.tick(t3, 8000)
    res.check("the floor forgets a path older than its bucket history",
              floor_ctl.queue_ms is not None and floor_ctl.queue_ms < ab.ENTER_QUEUE_MS,
              floor_ctl.queue_ms)

    cbr = AdaptiveBitrateController(user_cbr=True)
    t4, cum4, ds = run_ticks(cbr, 0.0, 2, BASE_RTT, 6000, kbps_delivered=6000)
    t4, cum4, ds = run_ticks(cbr, t4, 3, BASE_RTT + 200, 6000, kbps_delivered=2000, cum=cum4)
    res.check("a user-picked constant bitrate is steered without a mode switch",
              ds and all(d["action"] == "set" for _, d in ds) and cbr.mode == 'adaptive', ds)
    t4, cum4, ds = run_ticks(cbr, t4, 60, BASE_RTT, 6000, kbps_delivered=6000, cum=cum4)
    res.check("and it never leaves constant bitrate",
              cbr.mode == 'adaptive' and not any(d["action"] == "exit" for _, d in ds),
              cbr.applied_kbps)
    res.check("and growth stops at the user's bitrate", cbr.applied_kbps <= 6000, cbr.applied_kbps)

    saw = AdaptiveBitrateController(user_cbr=True)
    t7, cum7, _ = run_ticks(saw, 0.0, 2, BASE_RTT, 8000, kbps_delivered=6000)
    t7, cum7, _ = run_ticks(saw, t7, 1.0, BASE_RTT + 120, 8000, kbps_delivered=5000, cum=cum7)
    cap = 8000 * ab.PROBE_SHARE
    t7, cum7, ds = run_ticks(saw, t7, 40, BASE_RTT + 2, 8000, kbps_delivered=5000, cum=cum7)
    sets = [(ts, d["kbps"]) for ts, d in ds if d["action"] == "set"]
    above = next((ts for ts, k in sets if k > cap + 1), None)
    below = [ts for ts, k in sets if above is None or ts < above]
    res.check("after a cut, growth stays at or below the probe cap until the hold ends",
              below and all(k <= cap + 1 for ts, k in sets if ts in below), sets)
    res.check("and the probe past it comes a full hold after the last retarget",
              above is not None and above - max(below) >= ab.PROBE_HOLD_S - ab.GROW_INTERVAL_S,
              (below, above))

    longer = AdaptiveBitrateController(user_cbr=True)
    t6, cum6, _ = run_ticks(longer, 0.0, 2, BASE_RTT, 8000, kbps_delivered=6000)
    t6, cum6, ds = run_ticks(longer, t6, 12, BASE_RTT + 90, 8000, kbps_delivered=2000, cum=cum6)
    actions = [d["action"] for _, d in ds]
    res.check("a longer path (constant extra delay) re-bases the floor instead of cutting to the bottom",
              "rebase" in actions and longer.applied_kbps > 2 * ab.MIN_KBPS, (actions, longer.applied_kbps))
    t6, cum6, ds = run_ticks(longer, t6, 6, BASE_RTT + 90, 8000, kbps_delivered=2000, cum=cum6)
    res.check("and after the re-base the same delay reads as clear and the bitrate climbs back",
              longer.queue_ms is not None and longer.queue_ms < ab.CLEAR_QUEUE_MS
              and longer.applied_kbps >= 0.85 * 8000, (longer.queue_ms, longer.applied_kbps))

    high = AdaptiveBitrateController()
    t8, cum8, _ = run_ticks(high, 0.0, 5, BASE_RTT, 8000, kbps_delivered=7000)
    t8, cum8, ds = run_ticks(high, t8, 0.5 * ab.ENTER_TICKS, BASE_RTT + 300, 8000, kbps_delivered=7000, cum=cum8)
    enter = ds[0][1] if ds else {}
    res.check("an entry goodput over half the ceiling starts near the goodput",
              enter.get("action") == "enter"
              and 0.9 * 7000 * ab.ENTER_GOODPUT_SHARE <= enter["kbps"] <= 7000 * ab.ENTER_GOODPUT_SHARE * 1.1,
              enter)

    idle = AdaptiveBitrateController()
    t9, cum9, _ = run_ticks(idle, 0.0, 5, BASE_RTT, 8000, kbps_delivered=1500)
    t9 += 5 * 60
    t9, cum9, ds = run_ticks(idle, t9, ab.RESUME_GRACE_S - 0.5, BASE_RTT + 250, 8000,
                             kbps_delivered=1500, cum=cum9)
    res.check("a queue in the grace after an ack silence does not leave quality",
              not ds and idle.mode == 'quality', ds)
    t9, cum9, ds = run_ticks(idle, t9, 0.5 + 0.5 * ab.ENTER_TICKS, BASE_RTT + 250, 8000,
                             kbps_delivered=1500, cum=cum9)
    res.check("and a queue still standing after the grace does",
              [d["action"] for _, d in ds] == ["enter"] and idle.mode == 'adaptive', ds)

    blind = AdaptiveBitrateController(user_cbr=True)
    t10, cum10, _ = run_ticks(blind, 0.0, 2, BASE_RTT, 8000, kbps_delivered=6000)
    t10 += 5
    t10, cum10, ds = run_ticks(blind, t10, 1, BASE_RTT + 200, 8000, kbps_delivered=2000, cum=cum10)
    res.check("an adaptive display keeps cutting through an ack silence",
              [d["action"] for _, d in ds][:1] == ["set"] and blind.applied_kbps < 8000, ds)

    stuck = AdaptiveBitrateController()
    t11, cum11, _ = run_ticks(stuck, 0.0, 5, BASE_RTT, 8000, kbps_delivered=1500)
    t11, cum11, _ = run_ticks(stuck, t11, 0.5 * ab.ENTER_TICKS, BASE_RTT + 300, 8000,
                              kbps_delivered=1500, cum=cum11)
    queue = 300.0
    while queue > ab.CUT_QUEUE_MS:
        # Each cut drains part of the queue, so it is congestion and not a longer path.
        t11, cum11, _ = run_ticks(stuck, t11, 1, BASE_RTT + queue, 8000, kbps_delivered=500, cum=cum11)
        queue *= 0.8
    t11, cum11, _ = run_ticks(stuck, t11, 2, BASE_RTT, 8000, kbps_delivered=500, cum=cum11)
    low = stuck.applied_kbps
    res.check("a congested adaptive display is held under a probe cap",
              stuck.mode == 'adaptive' and low < 2000 and stuck._probe_cap is not None,
              (stuck.mode, low, stuck._probe_cap))
    stuck.reset_path()
    t11, cum11, ds = run_ticks(stuck, t11, 0.5, BASE_RTT, 8000, kbps_delivered=500, cum=cum11)
    res.check("a takeover puts the adaptive display back at its ceiling on the next tick",
              [(d["action"], d.get("kbps")) for _, d in ds] == [("set", 8000)]
              and stuck.mode == 'adaptive', ds)

    resync = AdaptiveBitrateController()
    t12, cum12, _ = run_ticks(resync, 0.0, 5, BASE_RTT, 8000, kbps_delivered=3000)
    resync.on_client_resync(t12)
    t12, cum12, ds = run_ticks(resync, t12, ab.RESUME_GRACE_S - 0.5, BASE_RTT + 300, 8000,
                               kbps_delivered=3000, cum=cum12)
    res.check("a queue in the grace after a keyframe request does not leave quality",
              not ds and resync.mode == 'quality', ds)
    t12, cum12, ds = run_ticks(resync, t12, 0.5 + 0.5 * ab.ENTER_TICKS, BASE_RTT + 300, 8000,
                               kbps_delivered=3000, cum=cum12)
    res.check("and a queue still standing after that grace does",
              [d["action"] for _, d in ds] == ["enter"], ds)

    starved = AdaptiveBitrateController()
    t13, cum13, _ = run_ticks(starved, 0.0, 5, BASE_RTT, 8000, kbps_delivered=70)
    t13, cum13, ds = run_ticks(starved, t13, 5, BASE_RTT + 300, 8000, kbps_delivered=70, cum=cum13)
    res.check("a standing queue under the entry goodput does not leave quality",
              not ds and starved.mode == 'quality' and starved._enter_ticks < ab.ENTER_TICKS, ds)
    unmeasured = AdaptiveBitrateController()
    t13, _, _ = run_ticks(unmeasured, 0.0, 5, BASE_RTT, 8000)
    t13, _, ds = run_ticks(unmeasured, t13, 0.5 * ab.ENTER_TICKS, BASE_RTT + 300, 8000)
    res.check("while a standing queue with no goodput measured still does",
              [d["action"] for _, d in ds] == ["enter"], ds)

    grow = AdaptiveBitrateController(user_cbr=True)
    t14, cum14, _ = run_ticks(grow, 0.0, 2, BASE_RTT, 8000, kbps_delivered=2000)
    grow.target_kbps = 2000.0
    grow.applied_kbps = 2000
    t14, cum14, ds = run_ticks(grow, t14, 6, BASE_RTT, 8000, kbps_delivered=2000, cum=cum14)
    sets = [d["kbps"] for _, d in ds if d["action"] == "set"]
    steps = [b / a - 1 for a, b in zip([2000] + sets, sets)]
    res.check("growth under its bound is applied only every second step",
              sets and all(st >= ab.GROW_FACTOR ** 2 - 1 - 0.01 for st in steps), sets)
    grow.target_kbps = 1150.0
    grow.applied_kbps = 1150
    t14, cum14, ds = run_ticks(grow, t14, 0.5, BASE_RTT + 200, 8000, kbps_delivered=2000, cum=cum14)
    res.check("while a cut under the growth minimum is applied on its tick",
              [(d["action"], d["kbps"]) for _, d in ds] == [("set", ab.MIN_KBPS)], ds)

    near = AdaptiveBitrateController(user_cbr=True)
    t15, _, _ = run_ticks(near, 0.0, 2, BASE_RTT, 8000)
    near.target_kbps = 7000.0
    near.applied_kbps = 7000
    near.reset_path()
    for rtt in (BASE_RTT, BASE_RTT + 40, BASE_RTT + 40):
        t15 += 0.1
        near.on_rtt(rtt, t15)
    d = near.tick(t15, 8000)
    res.check("a takeover is applied at once even when the ceiling is within the growth minimum",
              d and d["action"] == "set" and d["kbps"] == 8000, (near.queue_ms, d))

    leave = AdaptiveBitrateController()
    t16, cum16, _ = run_ticks(leave, 0.0, 5, BASE_RTT, 8000, kbps_delivered=7000)
    t16, cum16, _ = run_ticks(leave, t16, 0.5 * ab.ENTER_TICKS, BASE_RTT + 300, 8000,
                              kbps_delivered=7000, cum=cum16)
    at_ceiling = left = None
    while left is None and t16 < 60:
        t16, cum16, ds = run_ticks(leave, t16, 0.5, BASE_RTT, 8000, kbps_delivered=7000, cum=cum16)
        if at_ceiling is None and leave.target_kbps >= 8000:
            at_ceiling = t16
        if any(d["action"] == "exit" for _, d in ds):
            left = t16
    res.check("a display clear at its ceiling returns to quality after the exit hold",
              ab.EXIT_CLEAR_S == 10.0 and at_ceiling is not None and left is not None
              and ab.EXIT_CLEAR_S - 1e-6 <= left - at_ceiling <= ab.EXIT_CLEAR_S + 1.0,
              (at_ceiling, left))

    bottom = AdaptiveBitrateController(user_cbr=True)
    t5, cum5, _ = run_ticks(bottom, 0.0, 1, BASE_RTT, 8000)
    t5, cum5, _ = run_ticks(bottom, t5, 30, BASE_RTT + 500, 8000)
    res.check("cuts stop at the floor bitrate", bottom.applied_kbps >= ab.MIN_KBPS, bottom.applied_kbps)

    res.summary()
    return res


if __name__ == "__main__":
    r = main()
    sys.exit(0 if not r.failed() else 1)
