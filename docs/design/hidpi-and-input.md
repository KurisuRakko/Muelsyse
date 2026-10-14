# HiDPI and input geometry

Two settings that look related but are deliberately independent, and a
coordinate-space bug that only showed up on the KWin host-capture path.

## Two independent scales

- **`scaling_dpi`** (96 / 120 / 144 / 168 / 192, default 96) sets the KWin
  virtual output's own compositor scale (`dpi / 96`). It only changes how
  large remote fonts and icons render — it has no effect on the video
  stream's resolution.
- **`render_scale`** (100 / 125 / 150 / 175 / 200, default 100) sets the
  framebuffer size as a percentage of the browser window's CSS size:
  `framebuffer = window_css_size * render_scale / 100`. It's a purely
  client-side choice — the server only stores and publishes it. 100 means
  "stream the window at its own size"; 200 supersamples it (send more
  pixels than the window's CSS size, so a scaled-down display still looks
  sharp).

These two used to be entangled behind a single `use_css_scaling` toggle:
turning "HiDPI" on or off would force-couple the render multiplier to
`devicePixelRatio`, and the multiplier dropdown would in turn flip HiDPI
on or off. `use_css_scaling` (and its client-side mirror,
`useCssScaling`/`HIDPI_SPEC`) has since been removed entirely from the
settings layer, both web cores, and both dashboards — `render_scale` is
now an absolute multiplier of the window's CSS size, with no
`devicePixelRatio` involved anywhere in the calculation, and `scaling_dpi`
is unrelated to it. A `manual` (fixed) resolution keeps the multiplier at
a constant `1`, since the operator has already picked the exact
framebuffer size.

## Pointer/touch coordinate-space bug

The client sends absolute pointer/touch coordinates in **framebuffer
pixels**. KWin's `org_kde_kwin_fake_input.pointer_motion_absolute`
expects **logical** coordinates — the two differ by the output's
compositor scale (`scaling_dpi / 96`). The built-in (non-host) capture
path already converts physical to logical coordinates before injecting
input; the KWin host-capture path skipped that conversion, so the pointer
(and, by the same code path, touch) would drift away from where the user
actually clicked whenever `scaling_dpi` was above its 96 default —
exactly proportional to the output scale.

The fix lives entirely in `input_handler.py`: right before handing a
coordinate to the mouse-injection call, it divides by that display's
current output scale, but only for the KWin host backend — every other
backend gets a no-op `1.0` factor, since only the host-capture path
bypasses the physical→logical conversion that KWin's own input path does
for everything else (e.g. its `libinput` backend converts explicitly, and
the client's own on-screen coordinate math already accounts for it).
Internal position tracking stays in framebuffer space, since that's also
the space the layout/bounding-box math uses.

## Pure functions for the coordinate math

`selkies-web-core/lib/input-geometry.js` factors the
sink-rectangle-to-stream-coordinate math (used by both mouse and touch
handling) into small pure functions that take plain rectangles and
numbers — no `window`, no DOM, no `devicePixelRatio` reads. That makes the
mapping logic exercisable with fabricated rectangle data in a fast unit
test, instead of only being reachable through a live browser + `Input`
instance.
