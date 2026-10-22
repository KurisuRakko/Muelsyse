# Known limitations

This grew out of one machine, and it has only been run there: Debian 13,
KWin 6.3.6, an Intel iGPU for VAAPI and an NVIDIA card for NVENC. Treat
anything outside that as untested.

## Host-specific values

Paths, the deployment user and similar per-host values are meant to come
from the environment rather than from the files themselves: scripts take
`${VAR:-$HOME/...}` defaults, and manifest rows of kind `render` have
`@HOME@`/`@USER@`/`@RAKKORD_*@` placeholders filled in by
`scripts/deploy-host.sh` from `~/.config/rakkord/env`. Some files were
copied verbatim from the author's host (the `system/` fragments, the
Sunshine config, the isolated KWin bring-up scripts) and may still assume
its layout, LAN range or GPU; read them before installing.

## Pinned versions

The KWin patches are against `v6.3.6` and are not upstreamed; the session
runs the patched build from its own prefix rather than replacing the
distro's KWin. Selkies and pixelflux are pinned to the revisions in
`source-revisions.env`. Moving any of them means re-applying the changes
summarized in the top-level README.

## Input paths

Smooth scrolling sends fractional axis values only on the Wayland
(`fake_input`) path; X11 and uinput still accumulate them into whole
wheel clicks. The IME caret relay only knows about Qt apps that talk to
the fcitx portal; other apps fall back to the client's own estimate.

## Build artifacts aren't in the repository

The compiled `.so`/binaries this project produces (`libpixelflux.so`,
`selkieskwinadapter.so`, a patched `kwin_wayland`, the Sunshine input
bridge) are not committed — `.gitignore` excludes them on purpose. You
build `kwin/` + `kwin-adapter/` and `pixelflux/` yourself; see
[`deploy/README.md`](deploy/README.md) for how the pieces fit together at
runtime.
