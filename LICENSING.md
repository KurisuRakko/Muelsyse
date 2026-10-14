# Licensing

This repository is a monorepo: it vendors two upstream projects alongside
original glue code, and each part keeps its own license.

| Path | License | Why |
|---|---|---|
| `kwin/` | See `kwin/LICENSES/` (GPL-2.0-or-later and related KDE licenses, per file) | Patched checkout of KDE's KWin, `v6.3.6` (see `source-revisions.env`). KWin itself is REUSE-compliant and license-tags most files individually; the license actually covering a given file is whatever `kwin/LICENSES/` says for it. |
| `selkies/` | MPL-2.0 (`selkies/LICENSE`) | Vendored Selkies, `v2.0.0rc0`. |
| `selkies/src/selkies/Xlib/` | LGPL-3.0 (`selkies/src/selkies/Xlib/LICENSE`) | python-xlib, vendored by upstream Selkies as-is. |
| `pixelflux/` | MPL-2.0 (`pixelflux/LICENSE`) | Vendored pixelflux, `v2.1.0rc0`. |
| Everything else (`kwin-adapter/`, `scripts/`, `deploy/`, `systemd/`, `config/`, `desktop/`, `docs/`, top-level docs) | GPL-2.0-or-later (`LICENSE`) | Original to this repository. `kwin-adapter/` links against and runs inside the same process as KWin, so it is licensed to match; the deployment scripts and docs default to the same license for the whole repo. |

The top-level `LICENSE` file (GPL-2.0-or-later) is the license for the
repository as a distributable whole and for everything not covered by a
more specific license above. It does not relicense `selkies/` or
`pixelflux/`, which stay MPL-2.0, or the individual KWin files, which stay
under whatever `kwin/LICENSES/` says for them.

`kwin-adapter/metadata.json` already declares `"License": "GPL-2.0-or-later"`
for the KWin plugin itself, consistent with the table above.

If you only need one license to point to for the whole repository (for
example, a GitHub license badge), use GPL-2.0-or-later — it's the strictest
of the three and the KWin plugin cannot be distributed under anything
looser anyway.

## Modifications to upstream code

`kwin/`, `selkies/` and `pixelflux/` started as unmodified checkouts of the
revisions pinned in `source-revisions.env` and have been modified in this
repository (2026). The modified files are exactly those that differ from
those upstream revisions; the README section "What I changed on top of
upstream" summarizes the changes.
