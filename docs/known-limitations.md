# Known limitations

This grew out of one machine (a specific deployment user's home
directory), and a few things still assume that rather than reading it
from the environment. This only lists what actually affects *running*
the code — prose elsewhere that happens to show a path doesn't count.

Most scripts already take the form `${VAR:-$HOME/...}` and can be
overridden by environment variable — for example
`scripts/install-production-host-wayland.sh`'s `SELKIES_KWIN_PREFIX` /
`SELKIES_SOURCE_DIR` / `PIXELFLUX_RELEASE_SO` / `SELKIES_RUNTIME_ROOT`.
The ones below are genuinely hardcoded:

| File | What | Effect |
|---|---|---|
| `scripts/run-kwin-poc.sh:14` | `[[ "${HOME:-}" == "/home/rakko" ]] \|\| die` | **Hard-refuses** to run under any other user; fix this first if you want to run the isolated KWin PoC yourself. |
| `desktop/selkies-kwin-wayland.desktop:6` | `Exec=` | Desktop launcher entry. |
| `desktop/selkies-kwin-poc.desktop:4` | `Exec=` | Desktop launcher entry. |
| `pixelflux/desktop/selkies-kwin-poc.desktop:4` | `Exec=` | Same file, vendored a second time inside `pixelflux/` (upstream layout, left as-is). |
| `scripts/run-kwin-adapter-poc.sh:45` | `sed -i "s#Exec=/home/rakko/...#"` | The match string used to rewrite the `.desktop` file above — tied to it, so it moves together. |

None of these are fixed here — this repository documents behavior, it
doesn't refactor it as part of an unrelated cleanup. A reasonable fix, if
you want one: template the `.desktop` `Exec=` line at install time (a
`@CMAKE_INSTALL_PREFIX@`-style placeholder, substituted by whatever
installs it) and replace the `run-kwin-poc.sh` username assertion with a
check that the directories it actually needs exist, rather than checking
whose home directory it is.

## Build artifacts aren't in the repository

The compiled `.so`/binaries this project produces (`libpixelflux.so`,
`selkieskwinadapter.so`, a patched `kwin_wayland`) are not committed —
`.gitignore` excludes `build/` and `target/` on purpose. You build
`kwin/` + `kwin-adapter/` and `pixelflux/` yourself; see
[`deploy/README.md`](deploy/README.md) for how the pieces fit together at
runtime.
