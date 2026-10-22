# Development

## Host configuration

Host-specific values (ports, LAN/Tailscale bind addresses, the Selkies venv,
the Node toolchain, the DRI node, Sunshine output and modes) live in
`~/.config/muelsyse/env`, never in the repository. Start from
[`config/muelsyse.env.example`](../config/muelsyse.env.example).

Files whose kind is `render` or `check` in
[`deploy/manifest.tsv`](../deploy/manifest.tsv) carry placeholders such as
`@HOME@`, `@USER@` and `@MUELSYSE_*@`; `scripts/check-drift.py --render`
expands them, and `scripts/deploy-host.sh` uses the same code to install them.

## Build and test

Two prerequisites:

- The web front-end build and lint need `npm`, taken from
  `$MUELSYSE_NODE_BIN`.
- `selkies/tests/unit/*` need the Selkies venv (`$MUELSYSE_SELKIES_VENV`,
  default `/opt/selkies`); a bare system Python lacks `aiohttp`/`aiofiles`.

```sh
cd selkies
export PATH=$MUELSYSE_NODE_BIN:$PATH
sh scripts/ci/lint-web.sh      # eslint x2 + tsc -b
sh scripts/ci/build-web.sh     # core + classic + wish -> src/selkies/selkies_web
python3 scripts/generate-settings-doc.py --check
${MUELSYSE_SELKIES_VENV:-/opt/selkies}/bin/python3 tests/unit/<suite>.py
```

Host tooling tests:

```sh
bash scripts/tests/test_check_drift.sh
bash scripts/tests/test_deploy_host.sh
bash scripts/check-portability.sh   # no host-specific literals in tracked files
```

## Releases and deployment

- `scripts/build-release.sh` builds pixelflux + Selkies into a versioned
  release; `--activate <stamp> --restart` switches the symlink and restarts
  only the Selkies service.
- `scripts/build-kwin.sh` does the same for the patched KWin; activating a
  KWin release needs a full session restart.
- `scripts/deploy-host.sh` installs units, drop-ins and helper scripts listed
  in the manifest, and removes paths listed in `deploy/retired.tsv`.
- `scripts/check-drift.py` (run daily by `muelsyse-drift-check.timer`)
  reports any drift between the repository and the installed host.
