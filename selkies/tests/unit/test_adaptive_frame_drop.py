#!/usr/bin/env python3
"""Adaptive frame drop: what a congested WebSocket client is allowed to lose.

The relay already skips ahead on a byte budget. Adaptive drop adds a
latency-triggered layer on top: the backpressure loop samples every 0.5s, and
a relay enters `dropping` only after two consecutive samples see a queue older
than 180ms or an ACK desync past max(6, fps*0.25), and leaves it only after
three consecutive healthy samples (1.5s) under 80ms and max(2, fps*0.08). A
healthy link therefore never loses a frame, and a recovering one does not
oscillate.

What may be lost is bounded by the decode chain. A frame group (the stripes of
one capture, H.264 rows or JPEG blocks, all sharing a frame_id) is dropped
whole or not at all, and the group already being written to the socket is
always finished. Dropping H.264 data re-gates every stripe row, so a delta is
never delivered against a reference the client did not receive; each row
reopens on its own IDR. Pressure state is per relay, so a slow viewer cannot
make the controller drop, and only video passes through relays at all --
audio, input, clipboard, settings and cursor metadata take other paths.

Usage: python3 tests/unit/test_adaptive_frame_drop.py
"""
import os
import re
import sys
import time

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))

passed = failed = 0


def check(label: str, ok, detail="") -> None:
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"{'PASS' if ok else 'FAIL'}  [adaptive-drop] {label}  {detail}", flush=True)


try:
    from selkies.selkies import (
        _VideoRelay, DataStreamingServer, ADAPTIVE_DROP_ENTER_SAMPLES,
        ADAPTIVE_DROP_EXIT_SAMPLES, ADAPTIVE_DROP_ENTER_QUEUE_MS,
        ADAPTIVE_DROP_EXIT_QUEUE_MS)
except ModuleNotFoundError as exc:
    # Reported as a skip, never as a pass: the server's own dependencies
    # (aiohttp and friends) live in the selkies install, so a source checkout
    # without one has not checked the rule, it just could not look.
    print(f"SKIP {exc.name} not installed, so the video relay cannot be imported",
          flush=True)
    sys.exit(77)  # helpers.SKIP_EXIT, without importing the e2e helper module
except Exception as exc:  # pragma: no cover - reported, never silently passed
    print(f"FAIL  [adaptive-drop] the module imports  {exc}", flush=True)
    print("[adaptive-drop] 0/1 passed")
    sys.exit(1)


def h264(frame_id: int, row: int, idr: bool) -> dict:
    """One H.264 stripe on the wire: type, picture type, and its y_start row."""
    data = bytearray(16)
    data[0] = 0x04
    data[1] = 0x01 if idr else 0x02
    data[4] = (row >> 8) & 0xFF
    data[5] = row & 0xFF
    return {'data': memoryview(bytes(data)), 'owner': None, 'frame_id': frame_id}


def jpeg(frame_id: int, block: int) -> dict:
    """One JPEG block; no reference chain, so it is never row-gated."""
    data = bytearray(16)
    data[0] = 0x03
    data[4] = block
    return {'data': memoryview(bytes(data)), 'owner': None, 'frame_id': frame_id}


class FakeServer:
    """The two registries a relay and the sampler read, and nothing else."""

    def __init__(self):
        self.display_clients = {}
        self.video_relay_groups = {}
        self._bytes_sent_in_interval = 0

    _update_adaptive_relay_state = DataStreamingServer._update_adaptive_relay_state
    _update_adaptive_relays = DataStreamingServer._update_adaptive_relays
    _reset_adaptive_relay = DataStreamingServer._reset_adaptive_relay
    _log_adaptive_relay_state = DataStreamingServer._log_adaptive_relay_state
    adaptive_relay_snapshot = DataStreamingServer.adaptive_relay_snapshot


def new_relay(server, ws="ws", display_id="primary", budget=4 * 1024 * 1024):
    relay = _VideoRelay(server, display_id, ws, budget)
    server.video_relay_groups.setdefault(display_id, {})[ws] = relay
    server.display_clients.setdefault(display_id, {
        'ws': ws, 'adaptive_frame_drop': True, 'backpressure_enabled': True,
    })
    return relay


def drain(relay):
    """Pop the backlog the way the send task does, without a socket."""
    out = []
    while relay.backlog:
        _at, item = relay.backlog.popleft()
        relay.backlog_bytes -= len(item['data'])
        if item['frame_id'] != relay._sending_frame_id:
            relay.adaptive_drop_sent_frames += 1
        relay._sending_frame_id = item['frame_id']
        out.append(item)
    return out


def age(relay, queue_ms):
    """Plant one backlog entry whose enqueue stamp is `queue_ms` in the past."""
    relay.backlog.clear()
    relay.backlog_bytes = 0
    if queue_ms > 0:
        item = h264(0, 0, True)
        relay.backlog.append((time.monotonic() - queue_ms / 1000.0, item))
        relay.backlog_bytes = len(item['data'])


def sample(server, relay, queue_ms, desync, fps=60.0):
    """One 0.5s sampler tick against a backlog aged to `queue_ms`."""
    age(relay, queue_ms)
    server._update_adaptive_relay_state(relay, desync, fps, True, False)


# --- a healthy link never drops a frame ---------------------------------
server = FakeServer()
relay = new_relay(server)
for tick in range(10):
    sample(server, relay, 12.0, 0.5)
check("a healthy link stays out of the drop state",
      relay.adaptive_drop_state == 'normal', relay.adaptive_drop_state)
age(relay, 0)

# An IDR opens row 0, then 40 delta frames arrive and are drained in turn.
relay.offer(h264(1, 0, True))
drain(relay)
for fid in range(2, 42):
    relay.offer(h264(fid, 0, False))
    check_ok = len(relay.backlog) == 1
    drain(relay)
    if not check_ok:
        break
check("and every frame it is offered reaches the socket",
      relay.adaptive_drop_dropped_frames == 0 and relay.adaptive_drop_sent_frames == 41,
      f"dropped={relay.adaptive_drop_dropped_frames} sent={relay.adaptive_drop_sent_frames}")

# --- hysteresis ---------------------------------------------------------
server = FakeServer()
relay = new_relay(server)
states = []
for _ in range(ADAPTIVE_DROP_ENTER_SAMPLES):
    sample(server, relay, ADAPTIVE_DROP_ENTER_QUEUE_MS + 20, 0.0)
    states.append(relay.adaptive_drop_state)
check("one pressured sample is not enough to start dropping",
      states[0] == 'normal', states)
check(f"{ADAPTIVE_DROP_ENTER_SAMPLES} consecutive pressured samples are",
      states[-1] == 'dropping', states)

sample(server, relay, ADAPTIVE_DROP_ENTER_QUEUE_MS + 20, 0.0)
sample(server, relay, 10.0, 0.0)
sample(server, relay, ADAPTIVE_DROP_ENTER_QUEUE_MS + 20, 0.0)
check("a single healthy sample does not end the drop state",
      relay.adaptive_drop_state == 'dropping', relay.adaptive_drop_state)

recovery = []
for _ in range(ADAPTIVE_DROP_EXIT_SAMPLES):
    sample(server, relay, ADAPTIVE_DROP_EXIT_QUEUE_MS - 20, 0.0)
    recovery.append(relay.adaptive_drop_state)
check(f"{ADAPTIVE_DROP_EXIT_SAMPLES} consecutive healthy samples (1.5s) do",
      recovery[-1] == 'normal' and recovery[0] == 'dropping', recovery)

# The desync trigger has a floor, so a slow client is judged in frames it can
# actually consume: max(6, fps*0.25).
server = FakeServer()
relay = new_relay(server)
for _ in range(ADAPTIVE_DROP_ENTER_SAMPLES):
    sample(server, relay, 0.0, 5.0, fps=10.0)
check("a desync under the six-frame floor is not pressure",
      relay.adaptive_drop_state == 'normal', relay.adaptive_drop_state)
for _ in range(ADAPTIVE_DROP_ENTER_SAMPLES):
    sample(server, relay, 0.0, 20.0, fps=60.0)
check("and one past a quarter second of frames is",
      relay.adaptive_drop_state == 'dropping', relay.adaptive_drop_state)

# --- H.264: a drop waits for an IDR -------------------------------------
server = FakeServer()
relay = new_relay(server)
relay.offer(h264(1, 0, True))          # opens row 0
relay.offer(h264(2, 0, False))         # queued behind it
relay.adaptive_drop_state = 'dropping'
requested_sync = relay.offer(h264(3, 0, False))
check("a drop asks for a keyframe", requested_sync is True, requested_sync)
check("and discards the stale queue", len(relay.backlog) == 0, len(relay.backlog))
check("a delta after a drop is not delivered, IDR or nothing",
      relay.offer(h264(4, 0, False)) is not None and not relay.backlog,
      len(relay.backlog))
relay.offer(h264(5, 0, True))
check("the row reopens on its own IDR", len(relay.backlog) == 1, len(relay.backlog))
drain(relay)
relay.adaptive_drop_state = 'normal'
relay.offer(h264(6, 0, False))
check("and its deltas flow again", len(relay.backlog) == 1, len(relay.backlog))

# --- striped H.264: rows recover one at a time --------------------------
server = FakeServer()
relay = new_relay(server)
for row in (0, 1, 2):
    relay.offer(h264(1, row, True))
drain(relay)
relay.offer(h264(2, 0, False))
relay.adaptive_drop_state = 'dropping'
relay.offer(h264(3, 0, False))         # drops frame 2, gates every row
check("a striped drop gates every row, not just the one it dropped",
      relay.live_rows == set(), relay.live_rows)
relay.offer(h264(4, 1, True))
rows_open = {item['data'][5] for _t, item in relay.backlog}
relay.offer(h264(4, 2, False))
check("only the row whose IDR arrived is ungated",
      rows_open == {1} and len(relay.backlog) == 1,
      f"{rows_open} backlog={len(relay.backlog)}")
relay.offer(h264(4, 2, True))
check("and each remaining row reopens on its own",
      len(relay.backlog) == 2, len(relay.backlog))

# --- JPEG: whole frame groups only --------------------------------------
server = FakeServer()
relay = new_relay(server)
for block in range(4):
    relay.offer(jpeg(1, block))
_at, first = relay.backlog.popleft()          # the group starts going out
relay.backlog_bytes -= len(first['data'])
relay._sending_frame_id = first['frame_id']
relay.adaptive_drop_state = 'dropping'
for block in range(4):
    relay.offer(jpeg(2, block))
relay.offer(jpeg(3, 0))
queued = sorted(item['frame_id'] for _t, item in relay.backlog)
check("the group already being written is finished, never torn",
      queued.count(1) == 3, queued)
check("a whole stale group is dropped, never half of one",
      queued.count(2) == 0 and queued.count(3) == 1, queued)
check("and one logical frame is counted, not four blocks",
      relay.adaptive_drop_dropped_frames == 1, relay.adaptive_drop_dropped_frames)

# --- per-client isolation ------------------------------------------------
server = FakeServer()
owner = new_relay(server, ws="owner")
viewer = _VideoRelay(server, "primary", "viewer", 4 * 1024 * 1024)
server.video_relay_groups["primary"]["viewer"] = viewer
for _ in range(ADAPTIVE_DROP_ENTER_SAMPLES):
    age(owner, 0)
    age(viewer, ADAPTIVE_DROP_ENTER_QUEUE_MS + 50)
    server._update_adaptive_relays(
        "primary", server.display_clients["primary"],
        desync_frames=0.0, client_fps=60.0, ack_ready=True)
check("a congested viewer drops on its own",
      viewer.adaptive_drop_state == 'dropping', viewer.adaptive_drop_state)
check("and the healthy controller does not",
      owner.adaptive_drop_state == 'normal', owner.adaptive_drop_state)

# The hard ACK gate already drops everything; adaptive must stand down there
# rather than stack a second policy on top of it.
viewer.adaptive_drop_state = 'dropping'
owner.adaptive_drop_state = 'dropping'
age(owner, 0)
age(viewer, ADAPTIVE_DROP_ENTER_QUEUE_MS + 50)
server.display_clients["primary"]['backpressure_enabled'] = False
server._update_adaptive_relays("primary", server.display_clients["primary"],
                               desync_frames=99.0, client_fps=60.0, ack_ready=True)
check("hard backpressure stands the controller's adaptive layer down",
      owner.adaptive_drop_state == 'normal', owner.adaptive_drop_state)
check("and leaves the viewers it does not gate alone",
      viewer.adaptive_drop_state == 'dropping', viewer.adaptive_drop_state)
server.display_clients["primary"]['backpressure_enabled'] = True

# Turning the setting off stops the layer outright.
server.display_clients["primary"]['adaptive_frame_drop'] = False
viewer.adaptive_drop_state = 'dropping'
check("a relay whose display disabled the setting drops nothing",
      viewer.adaptive_active() is False, viewer.adaptive_drop_state)

# --- state resets with the frame numbering -------------------------------
server = FakeServer()
relay = new_relay(server)
relay.adaptive_drop_state = 'dropping'
relay.adaptive_drop_enter_samples = 1
relay.adaptive_drop_dropped_frames = 7
relay._sending_frame_id = 40
relay.reset_adaptive_state()
check("a frame-id reset clears the hysteresis and the counters",
      (relay.adaptive_drop_state, relay.adaptive_drop_enter_samples,
       relay.adaptive_drop_dropped_frames, relay._sending_frame_id)
      == ('normal', 0, 0, None),
      relay.adaptive_drop_state)

source = open(os.path.join(REPO, "src", "selkies", "selkies.py"), encoding="utf-8").read()
check("and the reset path calls it for every relay of the display",
      re.search(r"Resetting frame IDs for display.*?reset_adaptive_state\(\)",
                source, re.S) is not None)

# --- the queue age is measured, not inferred -----------------------------
server = FakeServer()
relay = new_relay(server)
check("an empty backlog has no queued latency", relay.queue_age_ms(now=1000.0) == 0.0)
relay.offer(h264(1, 0, True))
enqueued_at = relay.backlog[0][0]
check("and a queued chunk ages by the wall clock, not by a configured bitrate",
      abs(relay.queue_age_ms(now=enqueued_at + 0.25) - 250.0) < 1e-6,
      relay.queue_age_ms(now=enqueued_at + 0.25))

snapshot = server.adaptive_relay_snapshot("primary")
check("the stats snapshot reports the layer's counters",
      set(snapshot) == {"relays", "dropping", "dropped_frames", "sent_frames", "queue_ms"}
      and snapshot["relays"] == 1, snapshot)

# --- only video passes through a relay at all ----------------------------
offers = re.findall(r"^.*\.offer\(.*$", source, re.M)
check("the only caller of relay.offer is the video fan-out",
      len(offers) == 1 and "relay.offer(item)" in offers[0], offers)
check("the fan-out that calls it is the pixelflux video callback",
      re.search(r"def queue_data_for_display\(frame\):.*?relay\.offer\(item\)",
                source, re.S) is not None)
for other in ("send_ws_cursor_data", "_broadcast_to_clients", "send_bytes"):
    check(f"{other} does not route through a relay backlog",
          not re.search(rf"{other}\([^)]*backlog", source))

print(f"[adaptive-drop] {passed}/{passed + failed} passed")
sys.exit(1 if failed else 0)
