#!/usr/bin/env bash
# 在隔离的 KWin 6.3.6 构建前缀中验证 Selkies adapter 的动态 virtual mode。
# 不启动生产 unit，不触碰 8090、TigerVNC、Docker、网关或 1Password。
set -Eeuo pipefail

fail() {
    echo "ADAPTER_POC_FAIL $*" >&2
    exit 1
}

[[ "$(id -un)" == "rakko" ]] || fail "必须以 rakko 身份运行"
[[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]] || fail "XDG_RUNTIME_DIR 不可用"
grep -qE '^VERSION_ID="?13([.]|"|$)' /etc/os-release || fail "当前主机不是 Debian 13"

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_ROOT=${KWIN_ADAPTER_POC_BUILD_ROOT:-$HOME/build/kwin-adapter}
KWIN_BIN=${KWIN_ADAPTER_POC_BIN:-$BUILD_ROOT/bin/kwin_wayland}
PROBE_BIN=${KWIN_POC_PROBE_BIN:-$HOME/src/pixelflux-kwin-poc/pixelflux/target/debug/examples/kwin-pipewire-poc}
SESSION_BIN=${KWIN_POC_SESSION_BIN:-$HOME/src/pixelflux-kwin-poc/pixelflux/target/debug/examples/kwin-host-session-poc}
[[ -x "$KWIN_BIN" ]] || fail "找不到隔离 KWin: $KWIN_BIN"
[[ -x "$PROBE_BIN" ]] || fail "找不到 probe binary: $PROBE_BIN"
[[ -x "$SESSION_BIN" ]] || fail "找不到 host-session binary: $SESSION_BIN"
command -v wayland-info >/dev/null || fail "缺少 wayland-info"
command -v kbuildsycoca6 >/dev/null || fail "缺少 kbuildsycoca6"

UNIT=kwin-selkies-adapter-poc
WAYLAND_DISPLAY=kwin-selkies-adapter-poc
ADAPTER_SOCKET="$XDG_RUNTIME_DIR/selkies-kwin-adapter-poc.sock"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/selkies-kwin-adapter-poc.XXXXXX")
CONFIG_HOME="$TMP_DIR/config"
DATA_HOME="$TMP_DIR/data"
POC_EXE="$TMP_DIR/selkies-kwin-poc"
RUN_ID=$(date +%Y%m%dT%H%M%S)
LOG_DIR=${POC_LOG_DIR:-$HOME/.local/state/selkies-kwin-adapter-poc/$RUN_ID}
WAYLAND_INFO_LOG="$TMP_DIR/wayland-info.log"
ADAPTER_STATUS_LOG="$TMP_DIR/adapter-status.log"
PROBE_LOG="$TMP_DIR/probe.log"
INTEGRATION_LOG="$TMP_DIR/host-session.log"

systemctl --user is-active --quiet "$UNIT.service" && fail "$UNIT.service 已经运行，拒绝复用"
mkdir -p "$CONFIG_HOME" "$DATA_HOME/applications" "$LOG_DIR"
printf '%s\n' '[Plugins]' 'selkieskwinadapterEnabled=true' >"$CONFIG_HOME/kwinrc"
install -m755 "$PROBE_BIN" "$POC_EXE"
install -Dm644 "$ROOT/desktop/selkies-kwin-poc.desktop" "$DATA_HOME/applications/selkies-kwin-poc.desktop"
sed -i "s#Exec=/home/rakko/.local/libexec/selkies-kwin-poc#Exec=$POC_EXE#" \
    "$DATA_HOME/applications/selkies-kwin-poc.desktop"

save_logs() {
    cp -f "$WAYLAND_INFO_LOG" "$LOG_DIR/wayland-info.log" 2>/dev/null || true
    cp -f "$ADAPTER_STATUS_LOG" "$LOG_DIR/adapter-status.log" 2>/dev/null || true
    cp -f "$PROBE_LOG" "$LOG_DIR/probe.log" 2>/dev/null || true
    cp -f "$INTEGRATION_LOG" "$LOG_DIR/host-session.log" 2>/dev/null || true
    journalctl --user -u "$UNIT.service" -n 300 --no-pager >"$LOG_DIR/kwin-journal.log" 2>&1 || true
}

cleanup() {
    set +e
    save_logs
    systemctl --user stop "$UNIT.service" >/dev/null 2>&1 || true
    rm -rf -- "$TMP_DIR"
    rm -f -- "$ADAPTER_SOCKET"
}
trap cleanup EXIT

export XDG_CONFIG_HOME="$CONFIG_HOME"
export XDG_DATA_HOME="$DATA_HOME"
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_TYPE=wayland
export XDG_MENU_PREFIX=plasma-
export QT_QPA_PLATFORM=wayland
export SELKIES_KWIN_ADAPTER_SOCKET="$ADAPTER_SOCKET"
export WAYLAND_DISPLAY
export QT_PLUGIN_PATH="$BUILD_ROOT/bin:$BUILD_ROOT/lib/x86_64-linux-gnu/qt6/plugins:${QT_PLUGIN_PATH:-}"
export XDG_DATA_DIRS="$BUILD_ROOT/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

systemd-run --user --unit="$UNIT" --collect \
    --setenv=HOME="$HOME" \
    --setenv=USER=rakko \
    --setenv=LOGNAME=rakko \
    --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus" \
    --setenv=XDG_CONFIG_HOME="$CONFIG_HOME" \
    --setenv=XDG_DATA_HOME="$DATA_HOME" \
    --setenv=XDG_DATA_DIRS="$XDG_DATA_DIRS" \
    --setenv=QT_PLUGIN_PATH="$QT_PLUGIN_PATH" \
    --setenv=XDG_CURRENT_DESKTOP=KDE \
    --setenv=XDG_SESSION_TYPE=wayland \
    --setenv=XDG_MENU_PREFIX=plasma- \
    --setenv=QT_QPA_PLATFORM=wayland \
    --setenv=SELKIES_KWIN_ADAPTER_SOCKET="$ADAPTER_SOCKET" \
    --setenv=WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    --setenv=QT_LOGGING_RULES='kwin.selkies.adapter.debug=true;kwin_screencast.debug=true' \
    "$KWIN_BIN" --virtual --socket="$WAYLAND_DISPLAY" --width=3840 --height=2160 \
    --scale=1 --no-lockscreen --no-global-shortcuts >/dev/null

socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
for _ in $(seq 1 100); do
    [[ -S "$socket" && -S "$ADAPTER_SOCKET" ]] && break
    sleep 0.1
done
[[ -S "$socket" ]] || fail "临时 KWin socket 未出现"
[[ -S "$ADAPTER_SOCKET" ]] || fail "Selkies KWin adapter socket 未出现；检查 plugin load 日志"

python3 - "$ADAPTER_SOCKET" >"$ADAPTER_STATUS_LOG" <<'PY'
import json
import socket
import sys

path = sys.argv[1]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.settimeout(5)
    client.connect(path)
    client.sendall(b'{"op":"status"}\n')
    print(client.makefile().readline().strip())
PY
grep -q '"ok":true' "$ADAPTER_STATUS_LOG" || fail "adapter status 失败"

python3 - "$ADAPTER_SOCKET" >>"$ADAPTER_STATUS_LOG" <<'PY'
import json
import socket
import sys

path = sys.argv[1]

def request(payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(path)
        client.sendall((json.dumps(payload) + "\n").encode())
        return json.loads(client.makefile().readline())

invalid = request({"op": "prepare", "output_index": 0, "width": 10000, "height": 10000, "refresh_mhz": 60000})
unknown = request({"op": "not-allowed"})
if invalid.get("ok") or unknown.get("ok"):
    raise SystemExit("adapter 接受了无效或未知请求")
print("INVALID_REQUEST_REJECTED=true")
PY
grep -q 'INVALID_REQUEST_REJECTED=true' "$ADAPTER_STATUS_LOG" || fail "adapter 没有拒绝无效请求"

WAYLAND_DISPLAY="$WAYLAND_DISPLAY" wayland-info >"$WAYLAND_INFO_LOG" 2>&1 || fail "wayland-info 失败"
grep -q 'kde_output_management_v2' "$WAYLAND_INFO_LOG" || fail "没有 KDE output-management-v2"
grep -Eq '3840x2160|3840 x 2160|logical_width: 3840, logical_height: 2160|width: 3840 px, height: 2160 px' \
    "$WAYLAND_INFO_LOG" || fail "初始输出不是 3840x2160"

POC_ENV=(env
    "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
    "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    "XDG_CONFIG_HOME=$CONFIG_HOME"
    "XDG_DATA_HOME=$DATA_HOME"
    "XDG_DATA_DIRS=$XDG_DATA_DIRS"
    "QT_PLUGIN_PATH=$QT_PLUGIN_PATH"
    "XDG_CURRENT_DESKTOP=KDE"
    "XDG_SESSION_TYPE=wayland"
    "XDG_MENU_PREFIX=plasma-"
    "QT_QPA_PLATFORM=wayland"
    "SELKIES_KWIN_ADAPTER_SOCKET=$ADAPTER_SOCKET"
)
"${POC_ENV[@]}" "$POC_EXE" "$WAYLAND_DISPLAY" 3840 2160 60 3 >"$PROBE_LOG" 2>&1 \
    || { sed -n '1,220p' "$PROBE_LOG" >&2; fail "4K DMA-BUF probe 失败"; }
grep -q '^POC_PASS ' "$PROBE_LOG" || fail "probe 没有 POC_PASS"
grep -q 'non_dmabuf_frames=0' "$PROBE_LOG" || fail "probe 出现非 DMA-BUF 帧"
if grep -Eqi 'capturing locally|SHM fallback|CPU fallback' "$PROBE_LOG"; then
    fail "probe 出现禁止的 fallback"
fi

install -m755 "$SESSION_BIN" "$POC_EXE"
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
set +e
"${POC_ENV[@]}" "$POC_EXE" "$WAYLAND_DISPLAY" 3840 2160 >"$INTEGRATION_LOG" 2>&1
integration_rc=$?
set -e
grep -q 'INITIAL_FRAME width=3840 height=2160 dmabuf=true' "$INTEGRATION_LOG" \
    || fail "集成探针没有 4K DMA-BUF 初始帧"
for expected in \
    'RESIZE_FRAME step=1 width=1920 height=1080 dmabuf=true' \
    'RESIZE_FRAME step=2 width=2560 height=1440 dmabuf=true' \
    'RESIZE_FRAME step=3 width=1733 height=977 dmabuf=true' \
    'RESIZE_FRAME step=4 width=3840 height=2160 dmabuf=true'; do
    grep -q "$expected" "$INTEGRATION_LOG" || fail "集成探针缺少 $expected"
done
grep -q 'BURST_FRAME width=1733 height=977 dmabuf=true' "$INTEGRATION_LOG" \
    || fail "集成探针没有完成连续 resize 合并"
grep -q 'INPUT_SENT=true' "$INTEGRATION_LOG" || fail "集成探针没有输入请求"
if grep -Eqi 'capturing locally|SHM fallback|CPU fallback' "$INTEGRATION_LOG"; then
    fail "集成探针出现禁止的 fallback"
fi
(( integration_rc == 0 )) || { sed -n '1,260p' "$INTEGRATION_LOG" >&2; fail "动态输出集成探针失败"; }

echo "ADAPTER_POC_PASS KWin adapter dynamic mode DMA-BUF input logs=$LOG_DIR"
