# Cursor pipeline

The default KWin screencast bakes the compositor's cursor into every
video frame. That's the wrong contract for a remote desktop client: the
browser wants to draw its own zero-latency CSS cursor at the local
pointer position, but it still needs to know the *host's* cursor shape
(text I-beam, resize handles, etc.) to draw the right one. This needed a
change on both the encoding side (pixelflux) and the compositor side
(KWin), referred to below as M1 and M2.

## M1 — cursor shape as metadata, not pixels (pixelflux)

`pixelflux` switches the `zkde_screencast` pointer mode to `metadata` (4),
which asks the compositor for a `SPA_META_Cursor` alongside each buffer
instead of compositing the cursor into the frame. A cursor-only update
(`SPA_CHUNK_FLAG_CORRUPTED`) is metadata with no new video content and is
never handed to the encoder.

`wayland/host_cursor.rs` owns everything downstream of that:

- **Safe parsing.** It copies the cursor bitmap out of the raw
  `spa_buffer` with bounds checks on every offset, stride, and size;
  malformed metadata just drops the bitmap rather than reading out of
  bounds. The maximum accepted bitmap side (256px) matches KWin's own
  fixed allocation for `SPA_META_Cursor` in `screencaststream.cpp`, so a
  buffer claiming to be larger is rejected outright as invalid.
- **A small delivery state machine** so the callback only fires on an
  actual change: a hidden cursor (`id == 0`) is reported once, not every
  frame; an unchanged bitmap+hotspot pair produces nothing; a hotspot-only
  change reuses the last bitmap instead of re-encoding it.
- **Reuse of the existing encode path.** The bitmap is scaled and PNG
  encoded with premultiplied alpha through the same `cap_and_encode`
  helper the desktop-compositor capture path already used, and delivered
  to Python through the same `cb(msg_type, png, hot_x, hot_y)` callback
  contract — the KWin host path is a second producer for a channel that
  already existed, not a new protocol.

## M2 — suppressing the compositor's own cursor layer (KWin)

Cursor metadata alone isn't enough: KWin's virtual backend still paints
its own software cursor layer into the composited frame (there's no
cursor hardware plane on a virtual output), which would show the cursor
twice — once baked into the video, once drawn by the browser. KWin adds:

- `Output::isSoftwareCursorSuppressed()` / `setSoftwareCursorSuppressed()`
  and a `softwareCursorSuppressedChanged` signal on `Output`.
- `WaylandCompositor` ANDs this flag into the cursor layer's visibility
  check, on both the hardware-cursor and forced-software-cursor code
  paths, and reevaluates immediately when the signal fires.

This is deliberately independent of `Cursors::isCursorHidden()`:
suppressing the *painted* cursor on one output does not make
`OutputScreenCastSource::includesCursor()` false, so the metadata channel
above keeps working normally. It's a per-output flag, not a global "hide
the cursor" switch.

## Wiring it together

`kwin-adapter` exposes the suppression toggle as `op=cursor` (`hidden`,
plus optional `output_index`/`output_name`) on the same Unix-socket
protocol described in [`capture-pipeline.md`](capture-pipeline.md).
`KWinOutputController::set_cursor_visible()` on the pixelflux side calls
it and logs a one-time warning — not a hard error — if an older adapter
build doesn't understand the op, so an unpatched deployment just keeps
the previous (baked-in-cursor) video behavior instead of failing capture.

On the Selkies side, `HostCursorController` (`selkies/src/selkies/host_cursor.py`)
is a small idempotent, best-effort state machine that reconciles several
independent triggers into one desired visibility:

- the client's `SET_NATIVE_CURSOR_RENDERING` toggle,
- the WebRTC media pipeline's `set_pointer_visible`,
- capture start/stop and client disconnect (which restores the video
  cursor so KWin doesn't stay stuck hidden with nobody watching).

It only does anything when the deployment actually is KWin host capture
(`wayland_host_backend == "kwin"` with a display configured); a pixelflux
build without the host-cursor API, or an adapter that rejects `op=cursor`,
degrades to the pre-M1/M2 behavior instead of raising.
