# Deployment

Muelsyse can be deployed two ways: as a native host session that talks to
a patched KWin, or as a self-contained container that needs no host
patches at all. Both keep Selkies listening on loopback only and expect a
reverse proxy or tunnel in front of them for remote/public access —
neither Selkies' own basic-auth nor its HTTPS toggle is meant to be the
outward-facing auth layer; that belongs to whatever you put in front.

## Option A — native host session (KWin host capture)

This is the path the design docs in [`../design/`](../design/) describe:
a private KDE Plasma Wayland session drives a patched KWin, and Selkies
captures it directly through `zkde_screencast` instead of running its own
bundled desktop.

Components, all under this repository:

- `kwin/` + `kwin-adapter/` — patched KWin and the adapter plugin that
  exposes dynamic output modes and cursor suppression to it (see
  [`../design/capture-pipeline.md`](../design/capture-pipeline.md)).
- `pixelflux/` — the capture/encode backend Selkies uses.
- `selkies/` — the remote desktop server and web client.
- `scripts/start-wayland-session.sh` — launches the KWin + Plasma
  session; picks between a `kwin_wayland` built at
  `$SELKIES_KWIN_PREFIX` and the system one, and prepares KWin's own
  managed Xwayland listener (`scripts/selkies-xwayland-listen.py`) rather
  than reusing a stray `/tmp/.X11-unix` socket.
- `scripts/build-kwin.sh` — builds `kwin/` + `kwin-adapter/` into a
  timestamped release under the user's own directories (never the
  distro's KWin), records a `BUILD-INFO`, and with `--activate` only
  repoints the `current` symlink that the session runs from.
- `scripts/build-release.sh` — the same for Selkies + pixelflux: web
  client build, pixelflux release build, an immutable release directory
  and an import check; `--activate` switches the `site` symlink, and
  rolling back is pointing it at an older release.
- `deploy/manifest.tsv` + `scripts/deploy-host.sh` — every file that is
  installed on the host (units, drop-ins, libexec scripts, `.desktop`
  files, `system/` root files, the Sunshine side path) is one manifest
  row: repo path, target, mode, owner, kind, and what has to restart.
  `deploy-host.sh` is read-only by default and prints what would change;
  `--apply` installs and mirrors anything it overwrites into a
  timestamped backup directory; root-owned rows need `--system`.
  `scripts/check-drift.sh` compares the host against the same manifest
  and `systemd/muelsyse-drift-check.timer` runs it daily.
- `scripts/bootstrap-host.sh` — one-time host setup (dedicated Selkies Python, KWin config,
  cursor theme, browser launcher) that doesn't belong in the manifest.
- `systemd/remote-desktop-wayland.service` +
  `systemd/remote-desktop-selkies.service` — the two long-running units;
  the Selkies unit `Requires=`/`BindsTo=` the Wayland one so they start
  and stop together. Both are gated on a marker file
  (`~/.config/selkies/remote-desktop.production-enabled`) that isn't
  created automatically, so an accidentally-enabled unit stays inert
  until an operator has actually verified the deployment.
- `config/remote-desktop-selkies.env.example` — copy to
  `~/.config/selkies/remote-desktop.env` (`chmod 600`); it's only for the
  handful of settings meant to vary per install (e.g. a Selkies
  basic-auth password if you choose to use one), everything
  resolution/backend/feature-related is pinned directly in the unit file
  so a stray environment file can't silently change it.
- `desktop/*.desktop` — launcher entries. KWin only exposes privileged
  protocols such as `org_kde_kwin_fake_input` to a client whose
  executable matches a `.desktop` file's `Exec=`, so these files are part
  of the permission model, not just menu entries.
- `scripts/selkies-dri-exec.sh` — wraps the Selkies `ExecStart` and points
  both rendering and encoding at the render node KWin actually opened
  (Intel VAAPI or NVIDIA NVENC).

Selkies ends up listening on `127.0.0.1` only (`SELKIES_ADDR`/`SELKIES_PORT`
in the unit file); put your reverse proxy, tunnel, or SSH port-forward in
front of that.

### Development/verification scripts

`scripts/run-kwin-poc.sh`, `scripts/run-kwin-adapter-poc.sh`, and
`scripts/run-kwin-media-poc.sh` are the isolated bring-up harness used
while building the capture pipeline: each spins up a throwaway KWin/
Selkies instance on its own socket and unit, asserts against text
output only (protocol fields, PipeWire/VAAPI log lines, measured FPS —
never a screenshot), and cleans up after itself without touching a
production instance. `scripts/verify-live-text.sh` is the equivalent
read-only check for an already-running production deployment (checks the
services are active and Selkies is bound to loopback only). They're not
needed to run Muelsyse; they're what was used to validate it during
development.

### Optional side paths

- `scripts/muelsyse-imecaret.py` + `systemd/muelsyse-imecaret.service` —
  reports the caret rectangle of the focused Qt app (over the fcitx
  D-Bus portal) so the browser's IME candidate window can follow it.
  Without it the client falls back to its own estimate.
- `sunshine/` — Sunshine/Moonlight against the same KWin session. The
  input bridge reads Sunshine's virtual evdev devices and replays them
  through KWin's `fake_input`, because `kwin_wayland --virtual` opens no
  input devices of its own.

## Option B — containerized (no host KWin patch)

[`../../deploy/remote-desktop/`](../../deploy/remote-desktop/) runs the
official `ghcr.io/selkies-project/selkies-egl-desktop` image, which
brings its own bundled Plasma/Wayland session — no patched KWin, no
`kwin-adapter`, and none of the host-cursor or capture-pipeline work in
[`../design/`](../design/) applies to it. See that directory's own
`README.md` for the exact `docker compose` invocation, GPU passthrough
(`/dev/dri` plus the host's `render`/`video` group GIDs), and which
environment variables are locked to keep the client from silently
degrading a 4K/60 target.

## A shared networking note

If you run anything else in Docker alongside either deployment, remember
that a container's *published* ports are DNAT + `FORWARD` rules — they
don't pass through your host firewall's plain `INPUT`-chain policy, so a
default-deny `INPUT` chain does not by itself keep a container's exposed
port off the network. Control container-exposed ports with an explicit
bind address in `ports:` (e.g. `127.0.0.1:PORT:PORT`) or with rules in
the `DOCKER-USER` chain, not by assuming the host firewall already covers
them.
