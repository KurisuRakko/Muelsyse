# Adaptive frame dropping (WebSocket video relay)

A shared video relay can only move as fast as its slowest client — a
client that can't keep up otherwise makes the whole backlog grow, adding
latency for every viewer of that display, not just the slow one.

## The state machine

`_VideoRelay` (one instance per client+display pair, in
`selkies/src/selkies/selkies.py`) runs a small hysteresis state machine,
controlled by the `adaptive_frame_drop` setting (on by default) and
sampled on the same ~0.5s cadence as the existing ACK/backpressure loop:

- It enters the **dropping** phase after 2 consecutive over-threshold
  samples (queued age above 180ms, or the client's ACK lag past a
  desync-frame floor).
- It exits back to **normal** after 3 consecutive healthy samples (queued
  age below 80ms and a smaller desync fraction).

The enter/exit thresholds and sample counts are intentionally asymmetric
so the relay doesn't flap in and out of dropping on borderline traffic.
Queue age is measured directly from a monotonic timestamp on each
backlog entry rather than estimated from the configured bitrate, since a
CRF-mode encoder's configured bitrate doesn't reliably predict its actual
output rate — a rate-derived estimate would systematically disagree with
how long data has actually been sitting in the queue.

## Pruning without tearing

While in the dropping phase, a new frame's arrival prunes stale entries
from the backlog **as whole groups**, keyed by `frame_id`: a single
frame's H.264 stripes or JPEG chunks all share one `frame_id`, and
dropping only some of them would hand the client a torn frame. The group
currently being sent is always kept intact. If any dropped chunk was
H.264 data, `live_rows` is cleared so that the next delta chunks wait for
a fresh IDR instead of referencing reference frames the client never
received — a torn or gapped decode chain would otherwise persist as
visible artifacts long after the backlog recovers.

## Scope

Only the WebSocket video relay is affected. Audio, input, clipboard, and
cursor metadata (see [`cursor-pipeline.md`](cursor-pipeline.md)) don't go
through `_VideoRelay` and are untouched by backpressure on the video
path. Each client's relay tracks its own state independently, so one slow
viewer entering the dropping phase has no effect on other clients or
other displays.
