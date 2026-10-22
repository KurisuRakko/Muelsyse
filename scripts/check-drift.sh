#!/usr/bin/env bash
# 只读漂移检查的入口；逻辑在同目录的 check-drift.py（只用标准库，-I 隔离运行）。
set -Eeuo pipefail

here=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
exec /usr/bin/python3 -I "$here/check-drift.py" "$@"
