#!/usr/bin/env bash
# 运行独立的 KWin/PipeWire/DMA-BUF 文本 POC。
#
# 这个脚本故意不碰生产 unit、8090、TigerVNC、Docker 或 1Password。动态
# output mode 失败时返回 42，并把旧栈留在原地。
set -Eeuo pipefail

die() {
    echo "POC_FAIL $*" >&2
    exit 1
}

[[ "$(id -un)" == "rakko" ]] || die "必须以 rakko 身份运行"
[[ "${HOME:-}" == "/home/rakko" ]] || die "需要 /home/rakko 作为 HOME"
[[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]] || die "XDG_RUNTIME_DIR 不可用"
grep -qE '^VERSION_ID="?13([.]|"|$)' /etc/os-release || die "当前主机不是 Debian 13"

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROBE_BIN=${KWIN_POC_PROBE_BIN:-$HOME/src/pixelflux-kwin-poc/pixelflux/target/debug/examples/kwin-pipewire-poc}
SESSION_BIN=${KWIN_POC_SESSION_BIN:-$HOME/src/pixelflux-kwin-poc/pixelflux/target/debug/examples/kwin-host-session-poc}
[[ -x "$PROBE_BIN" ]] || die "找不到 probe binary: $PROBE_BIN"
[[ -x "$SESSION_BIN" ]] || die "找不到 host-session binary: $SESSION_BIN"
command -v kwin_wayland >/dev/null || die "缺少 kwin_wayland"
command -v wayland-info >/dev/null || die "缺少 wayland-info"
command -v kbuildsycoca6 >/dev/null || die "缺少 kbuildsycoca6"

UNIT=kwin-kwin-poc
WAYLAND_DISPLAY=kwin-kwin-poc
POC_EXE=$HOME/.local/libexec/selkies-kwin-poc
DESKTOP=$HOME/.local/share/applications/selkies-kwin-poc.desktop
LOG_DIR=${POC_LOG_DIR:-$HOME/.local/state/selkies-kwin-poc}
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/selkies-kwin-poc.XXXXXX")
WAYLAND_INFO_LOG=$TMP_DIR/wayland-info.log
PROBE_LOG=$TMP_DIR/probe.log
INTEGRATION_LOG=$TMP_DIR/host-session.log
CREATED_EXE=0
CREATED_DESKTOP=0
UNIT_STARTED=0

# 先检查，再注册清理钩子，避免误停用户原本正在运行的同名 unit。
if systemctl --user is-active --quiet "$UNIT.service"; then
    rm -rf -- "$TMP_DIR"
    die "$UNIT.service 已经运行，拒绝复用"
fi

save_logs() {
    mkdir -p "$LOG_DIR"
    [[ -f "$WAYLAND_INFO_LOG" ]] && cp -f "$WAYLAND_INFO_LOG" "$LOG_DIR/wayland-info.log"
    [[ -f "$PROBE_LOG" ]] && cp -f "$PROBE_LOG" "$LOG_DIR/probe.log"
    [[ -f "$INTEGRATION_LOG" ]] && cp -f "$INTEGRATION_LOG" "$LOG_DIR/host-session.log"
    journalctl --user -u "$UNIT.service" -n 200 --no-pager >"$LOG_DIR/kwin-journal.log" 2>&1 || true
}

cleanup() {
    set +e
    save_logs
    if (( UNIT_STARTED )); then
        systemctl --user stop "$UNIT.service" >/dev/null 2>&1 || true
    fi
    if (( CREATED_DESKTOP )); then rm -f -- "$DESKTOP"; fi
    if (( CREATED_EXE )); then rm -f -- "$POC_EXE"; fi
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

[[ ! -e "$POC_EXE" ]] || die "拒绝覆盖已有 POC binary: $POC_EXE"
[[ ! -e "$DESKTOP" ]] || die "拒绝覆盖已有权限文件: $DESKTOP"

install -Dm755 "$PROBE_BIN" "$POC_EXE"
CREATED_EXE=1
install -Dm644 "$ROOT/desktop/selkies-kwin-poc.desktop" "$DESKTOP"
CREATED_DESKTOP=1
kbuildsycoca6 --noincremental >/dev/null 2>&1

systemd-run --user --unit="$UNIT" --collect \
    --setenv=HOME="$HOME" \
    --setenv=USER=rakko \
    --setenv=LOGNAME=rakko \
    --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus" \
    --setenv=XDG_CURRENT_DESKTOP=KDE \
    --setenv=XDG_SESSION_TYPE=wayland \
    --setenv=XDG_MENU_PREFIX=plasma- \
    --setenv=QT_QPA_PLATFORM=wayland \
    --setenv=WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    --setenv=QT_LOGGING_RULES='kwin_screencast.debug=true;KWIN_UTILS.debug=true' \
    /usr/bin/kwin_wayland --virtual --socket="$WAYLAND_DISPLAY" \
    --width=3840 --height=2160 --scale=1 --no-lockscreen --no-global-shortcuts >/dev/null
UNIT_STARTED=1

socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
for _ in $(seq 1 100); do
    [[ -S "$socket" ]] && break
    sleep 0.1
done
[[ -S "$socket" ]] || die "临时 KWin socket 未出现: $socket"

export WAYLAND_DISPLAY
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_TYPE=wayland
export XDG_MENU_PREFIX=plasma-
export QT_QPA_PLATFORM=wayland
wayland-info >"$WAYLAND_INFO_LOG" 2>&1 || die "wayland-info 失败"
grep -q 'kde_output_management_v2' "$WAYLAND_INFO_LOG" || die "KWin 未公告 output-management-v2"
grep -Eq '3840x2160|3840 x 2160|logical_width: 3840, logical_height: 2160|width: 3840 px, height: 2160 px' \
    "$WAYLAND_INFO_LOG" || die "未从 wayland-info 读到 3840x2160"

POC_ENV=(env
    "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
    "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    "XDG_CURRENT_DESKTOP=KDE"
    "XDG_SESSION_TYPE=wayland"
    "XDG_MENU_PREFIX=plasma-"
    "QT_QPA_PLATFORM=wayland"
)
"${POC_ENV[@]}" "$POC_EXE" "$WAYLAND_DISPLAY" 3840 2160 60 3 >"$PROBE_LOG" 2>&1 \
    || { sed -n '1,220p' "$PROBE_LOG" >&2; die "KWin PipeWire DMA-BUF probe 失败"; }
grep -q '^POC_PASS ' "$PROBE_LOG" || die "probe 没有 POC_PASS"
grep -q 'fps=60/1 max_fps=60/1' "$PROBE_LOG" || die "probe 没有 60 FPS 协商"
grep -q 'non_dmabuf_frames=0' "$PROBE_LOG" || die "probe 出现非 DMA-BUF 帧"
if grep -Eqi 'capturing locally|SHM fallback|CPU fallback' "$PROBE_LOG"; then
    die "probe 出现禁止的 fallback"
fi

# 用同一个 canonical Exec 路径换入集成探针；KWin 的权限反查不允许路径漂移。
install -m755 "$SESSION_BIN" "$POC_EXE"
kbuildsycoca6 --noincremental >/dev/null 2>&1
set +e
"${POC_ENV[@]}" "$POC_EXE" "$WAYLAND_DISPLAY" 3840 2160 1920 1080 >"$INTEGRATION_LOG" 2>&1
integration_rc=$?
set -e

grep -q 'INITIAL_FRAME width=3840 height=2160 dmabuf=true' "$INTEGRATION_LOG" \
    || die "集成探针没有 4K DMA-BUF 初始帧"
grep -q 'INPUT_SENT=true' "$INTEGRATION_LOG" \
    || die "集成探针没有确认 KWin fake-input"
if grep -Eqi 'capturing locally|SHM fallback|CPU fallback' "$INTEGRATION_LOG"; then
    die "集成探针出现禁止的 fallback"
fi

if (( integration_rc != 0 )) && grep -q \
    'output-management-v2 version 12 does not advertise custom modes; cannot realize 1920x1080@60' \
    "$INTEGRATION_LOG"; then
    echo "POC_BLOCKED KWin 6.3.6 cannot realize dynamic 1920x1080@60"
    echo "POC_BLOCKED old TigerVNC/container production stack remains untouched"
    exit 42
fi

(( integration_rc == 0 )) || { sed -n '1,240p' "$INTEGRATION_LOG" >&2; die "集成探针失败但不是已知硬闸门"; }
echo "POC_PASS KWin 4K/60 DMA-BUF dynamic-resize input"
