# Capture pipeline

How a frame gets from the KWin compositor to the browser, and why the
`kwin-adapter` plugin exists at all.

## The chain

```
KWin (zkde_screencast_unstable_v1)
  -> PipeWire (DMA-BUF only)
    -> pixelflux (KWinCaptureSource)
      -> hardware H.264 (Intel VAAPI) or software encoder
        -> Selkies (WebRTC / WebSocket)
```

`pixelflux` refuses to fall back to SHM, a CPU copy, or the local
(non-KWin) compositor path when it's configured for KWin host capture
(`SELKIES_WAYLAND_HOST_BACKEND=kwin`): if the DMA-BUF path can't be
negotiated, capture stops instead of silently degrading to a slower path.

## Component boundaries

- **`KWinCaptureSource`** (`pixelflux/pixelflux/src/wayland/kwin.rs`) opens
  the `zkde_screencast` stream and only accepts DMA-BUF buffers.
- **`KWinOutputController`** (`pixelflux/pixelflux/src/wayland/kwin_output.rs`)
  talks to the compositor over KDE's standard `output-management-v2`
  protocol to negotiate the output mode (resolution/refresh rate) Selkies
  asked for, and waits for the server to report `applied` or `failed`
  rather than assuming success.
- **`kwin-adapter`** is a small in-process KWin plugin, not a general
  remote-control surface. It listens on a Unix socket
  (`$XDG_RUNTIME_DIR/selkies-kwin-adapter.sock`, overridable via
  `SELKIES_KWIN_ADAPTER_SOCKET`) for single-line JSON requests, and only
  accepts Unix peers with KWin's own UID:

  ```json
  {"op": "status"}
  {"op": "prepare", "output_index": 0, "width": 1920, "height": 1080, "refresh_mhz": 60000}
  {"op": "cursor", "hidden": true}
  ```

  It does not run shell commands, does not listen on TCP, and does not
  touch video, audio, input, or credentials. See
  [`cursor-pipeline.md`](cursor-pipeline.md) for `op=cursor`.

## Why the adapter exists: dynamic output modes

KWin 6.3's virtual output only exposes the mode it was started with;
`output-management-v2` at the protocol version KWin 6.3 ships (v12) does
not advertise support for creating custom modes on that output. Asking a
stock KWin 6.3 to resize the virtual output when the browser window
resizes therefore fails outright — this is a protocol-version gate, not a
PipeWire, VAAPI, or capture problem. `kwin-adapter`'s `prepare` op runs
in-process (same address space as KWin, linked against the same build)
and prepares the target `OutputMode` directly; Selkies then requests that
already-prepared mode through the normal `output-management-v2` API and
waits for it to apply.

## Refresh-rate pacing

KWin reports `Output::refreshRate()` in millihertz; PipeWire's
`maxFramerate` is in hertz. An early version of the capture path compared
the two without converting units, which made an output that was already
running at 60 Hz get re-throttled through a jittery `QTimer` on top of its
own native vsync pacing. The fix (`kwin/src/compositor_wayland.cpp` /
`kwin/src/core/output.{h,cpp}`) is to follow the output's own repaint
events directly once the native refresh rate already satisfies the
negotiated framerate; a genuinely lower framerate request still goes
through the timer-based throttle.

## DMA-BUF ownership

`pixelflux` holds a bounded two-slot ownership queue for DMA-BUF buffers:
it does not hand a buffer back to KWin until encoding has finished reading
it, so the compositor can't reuse (and overwrite) a GPU frame that's still
in flight through the encoder.
