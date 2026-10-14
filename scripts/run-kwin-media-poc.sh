#!/usr/bin/env bash
# 在私有 D-Bus、Wayland socket 和临时 systemd unit 中运行完整媒体 POC。
# 该脚本只验证 Plasma + KWin + Selkies，不修改生产服务、网关或现有容器。
set -Eeuo pipefail

fail() {
    echo "MEDIA_POC_FAIL $*" >&2
    exit 1
}

[[ "$(id -un)" == "rakko" ]] || fail "必须以 rakko 身份运行"
[[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]] || fail "XDG_RUNTIME_DIR 不可用"
grep -qE '^VERSION_ID="?13([.]|"|$)' /etc/os-release || fail "当前主机不是 Debian 13"

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_ROOT=${KWIN_MEDIA_POC_BUILD_ROOT:-$HOME/build/kwin-adapter}
KWIN_BIN=${KWIN_MEDIA_POC_KWIN_BIN:-$BUILD_ROOT/bin/kwin_wayland}
PYTHON_BIN=${SELKIES_MEDIA_POC_PYTHON:-/opt/selkies/bin/python3}
SELKIES_SOURCE=${SELKIES_MEDIA_POC_SOURCE:-$HOME/src/selkies-kwin-pipewire-poc}
PIXELFLUX_SO=${SELKIES_MEDIA_POC_PIXELFLUX_SO:-$HOME/src/pixelflux-kwin-poc/pixelflux/target/release/libpixelflux.so}
WEB_ROOT=${SELKIES_MEDIA_POC_WEB_ROOT:-/opt/selkies/lib/python3.13/site-packages/selkies/selkies_web}
PACER_SOURCE=${SELKIES_MEDIA_POC_PACER_SOURCE:-$ROOT/scripts/wayland-frame-pacer.c}
PROBE_EXE=${SELKIES_MEDIA_POC_PROBE_EXE:-$HOME/src/pixelflux-kwin-poc/pixelflux/target/release/examples/kwin-pipewire-poc}
TARGET_WIDTH=${MEDIA_POC_TARGET_WIDTH:-2560}
TARGET_HEIGHT=${MEDIA_POC_TARGET_HEIGHT:-1440}
MIN_FPS=${MEDIA_POC_MIN_FPS:-59}
KWIN_PERF_LOG=${MEDIA_POC_KWIN_PERF_LOG:-false}
KWIN_SCREENCAST_STATS=${MEDIA_POC_KWIN_SCREENCAST_STATS:-false}

[[ -x "$KWIN_BIN" ]] || fail "找不到隔离 KWin: $KWIN_BIN"
[[ -x "$PYTHON_BIN" ]] || fail "找不到 Selkies Python: $PYTHON_BIN"
[[ -d "$SELKIES_SOURCE/src/selkies" ]] || fail "找不到 Selkies 源码: $SELKIES_SOURCE"
[[ -f "$PIXELFLUX_SO" ]] || fail "找不到 release pixelflux: $PIXELFLUX_SO"
[[ -f "$WEB_ROOT/index.html" ]] || fail "找不到已安装 Selkies Web 资源: $WEB_ROOT"
command -v systemd-run >/dev/null || fail "缺少 systemd-run"
command -v wayland-info >/dev/null || fail "缺少 wayland-info"
command -v kbuildsycoca6 >/dev/null || fail "缺少 kbuildsycoca6"
command -v curl >/dev/null || fail "缺少 curl"
command -v cc >/dev/null || fail "缺少 C 编译器 cc"
command -v wayland-scanner >/dev/null || fail "缺少 wayland-scanner"
command -v pkg-config >/dev/null || fail "缺少 pkg-config"
[[ -f "$PACER_SOURCE" ]] || fail "找不到 Wayland 帧源: $PACER_SOURCE"
[[ "$TARGET_WIDTH" =~ ^[0-9]+$ && "$TARGET_HEIGHT" =~ ^[0-9]+$ && "$MIN_FPS" =~ ^[0-9]+([.][0-9]+)?$ ]] \
    || fail "目标尺寸或最低实测 FPS 参数无效"
[[ "$KWIN_PERF_LOG" == true || "$KWIN_PERF_LOG" == false ]] || fail "KWIN 性能日志开关无效"
[[ "$KWIN_SCREENCAST_STATS" == true || "$KWIN_SCREENCAST_STATS" == false ]] || fail "KWin screencast 统计开关无效"

RUN_ID=${SELKIES_MEDIA_POC_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$$}
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/selkies-kwin-media-poc.XXXXXX")
CONFIG_HOME="$TMP_DIR/config"
DATA_HOME="$TMP_DIR/data"
SITE_DIR="$TMP_DIR/site"
SELKIES_EXE="$TMP_DIR/selkies-python"
PACER_DIR="$TMP_DIR/frame-pacer"
PACER_EXE="$PACER_DIR/wayland-frame-pacer"
RUN_LOG_DIR=${MEDIA_POC_LOG_DIR:-$HOME/.local/state/selkies-kwin-media-poc/$RUN_ID}

KWIN_UNIT="kwin-selkies-media-poc-$RUN_ID"
PLASMA_UNIT="plasma-selkies-media-poc-$RUN_ID"
CONTENT_UNIT="content-selkies-media-poc-$RUN_ID"
PROBE_UNIT="probe-selkies-media-poc-$RUN_ID"
SELKIES_UNIT="selkies-media-poc-$RUN_ID"
BUS_UNIT="dbus-selkies-media-poc-$RUN_ID"
WAYLAND_DISPLAY="kwin-selkies-media-poc-$RUN_ID"
WAYLAND_SOCKET="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
ADAPTER_SOCKET="$XDG_RUNTIME_DIR/selkies-kwin-media-poc-$RUN_ID.sock"
BUS_SOCKET="$XDG_RUNTIME_DIR/selkies-kwin-media-poc-$RUN_ID.bus"
BUS_ADDRESS="unix:path=$BUS_SOCKET"
SELKIES_SITE="$SITE_DIR/selkies"
SELKIES_LOG="$TMP_DIR/selkies.log"
KWIN_LOG="$TMP_DIR/kwin.log"
PLASMA_LOG="$TMP_DIR/plasma.log"
WAYLAND_INFO_LOG="$TMP_DIR/wayland-info.log"
STATUS_LOG="$TMP_DIR/status.json"
PW_CLI_LOG="$TMP_DIR/pw-cli.log"
PW_TOP_LOG="$TMP_DIR/pw-top.log"
SS_LOG="$TMP_DIR/ss.log"
PROBE_LOG="$TMP_DIR/direct-probe.log"

umask 077
mkdir -p "$CONFIG_HOME" "$DATA_HOME/applications" "$SITE_DIR" "$PACER_DIR" "$RUN_LOG_DIR"
started_units=()

save_logs() {
    set +e
    journalctl --user -u "$BUS_UNIT.service" -n 300 --no-pager >"$RUN_LOG_DIR/dbus-journal.log" 2>&1
    journalctl --user -u "$KWIN_UNIT.service" -n 500 --no-pager >"$RUN_LOG_DIR/kwin-journal.log" 2>&1
    journalctl --user -u "$PLASMA_UNIT.service" -n 500 --no-pager >"$RUN_LOG_DIR/plasma-journal.log" 2>&1
    journalctl --user -u "$CONTENT_UNIT.service" -n 300 --no-pager >"$RUN_LOG_DIR/content-journal.log" 2>&1
    journalctl --user -u "$PROBE_UNIT.service" -n 300 --no-pager >"$RUN_LOG_DIR/probe-journal.log" 2>&1
    journalctl --user -u "$SELKIES_UNIT.service" -n 1200 --no-pager >"$RUN_LOG_DIR/selkies-journal.log" 2>&1
    cp -f "$WAYLAND_INFO_LOG" "$RUN_LOG_DIR/wayland-info.log" 2>/dev/null || true
    cp -f "$RUN_LOG_DIR/kwin perf statistics Virtual-0.csv" "$RUN_LOG_DIR/kwin-performance.csv" 2>/dev/null || true
    cp -f "$STATUS_LOG" "$RUN_LOG_DIR/status.json" 2>/dev/null || true
    cp -f "$PW_CLI_LOG" "$RUN_LOG_DIR/pw-cli.log" 2>/dev/null || true
    cp -f "$PW_TOP_LOG" "$RUN_LOG_DIR/pw-top.log" 2>/dev/null || true
    cp -f "$SS_LOG" "$RUN_LOG_DIR/ss.log" 2>/dev/null || true
    cp -f "$PROBE_LOG" "$RUN_LOG_DIR/direct-probe.log" 2>/dev/null || true
}

refresh_logs() {
    journalctl --user -u "$SELKIES_UNIT.service" -n 1200 --no-pager >"$SELKIES_LOG" 2>&1 || true
    journalctl --user -u "$KWIN_UNIT.service" -n 500 --no-pager >"$KWIN_LOG" 2>&1 || true
    journalctl --user -u "$PLASMA_UNIT.service" -n 500 --no-pager >"$PLASMA_LOG" 2>&1 || true
    journalctl --user -u "$PROBE_UNIT.service" -n 300 --no-pager >"$PROBE_LOG" 2>&1 || true
}

cleanup() {
    set +e
    refresh_logs
    save_logs
    for ((index=${#started_units[@]} - 1; index >= 0; index--)); do
        systemctl --user stop "${started_units[index]}.service" >/dev/null 2>&1 || true
    done
    rm -rf -- "$TMP_DIR"
    rm -f -- "$ADAPTER_SOCKET" "$BUS_SOCKET" "$WAYLAND_SOCKET"
}
trap cleanup EXIT INT TERM

# 用固定路径的专用副本作为 KWin 权限匹配对象，不给通用 Python 解释器授权。
install -m755 "$PYTHON_BIN" "$SELKIES_EXE"
cp -a "$SELKIES_SOURCE/src/selkies" "$SITE_DIR/"
ln -s "$WEB_ROOT" "$SELKIES_SITE/selkies_web"
EXT_SUFFIX=$("$PYTHON_BIN" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or ".so")')
ln -s "$PIXELFLUX_SO" "$SITE_DIR/pixelflux${EXT_SUFFIX}"

PYTHONPATH_VALUE="$SITE_DIR:/opt/selkies/lib/python3.13/site-packages"
PYTHONPATH="$PYTHONPATH_VALUE" "$PYTHON_BIN" - <<'PY'
import pixelflux
assert hasattr(pixelflux, "ScreenCapture")
assert pixelflux.SOFTWARE_H264_ENCODER == "x264"
print("PIXELFLUX_POC_IMPORT=true")
PY

printf '%s\n' '[Plugins]' 'selkieskwinadapterEnabled=true' >"$CONFIG_HOME/kwinrc"
install -m644 "$ROOT/desktop/selkies-kwin-wayland.desktop" "$DATA_HOME/applications/selkies-kwin-wayland.desktop"
sed -i -E "s#^Exec=.*#Exec=$SELKIES_EXE -m selkies#" "$DATA_HOME/applications/selkies-kwin-wayland.desktop"
if [[ "${MEDIA_POC_DIRECT_PROBE:-false}" == "true" ]]; then
    [[ -x "$PROBE_EXE" ]] || fail "找不到 KWin 直接探针: $PROBE_EXE"
    install -m644 "$ROOT/desktop/kwin-pipewire-poc.desktop" "$DATA_HOME/applications/kwin-pipewire-poc.desktop"
    sed -i -E "s#^Exec=.*#Exec=$PROBE_EXE#" "$DATA_HOME/applications/kwin-pipewire-poc.desktop"
fi

export XDG_CONFIG_HOME="$CONFIG_HOME"
export XDG_DATA_HOME="$DATA_HOME"
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_DESKTOP=KDE
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_CLASS=user
export XDG_MENU_PREFIX=plasma-
export QT_QPA_PLATFORM=wayland
export WAYLAND_DISPLAY
export DBUS_SESSION_BUS_ADDRESS="$BUS_ADDRESS"
export SELKIES_KWIN_ADAPTER_SOCKET="$ADAPTER_SOCKET"
export QT_PLUGIN_PATH="$BUILD_ROOT/bin:$BUILD_ROOT/bin/kwin/plugins:$BUILD_ROOT/lib/x86_64-linux-gnu/qt6/plugins:${QT_PLUGIN_PATH:-}"
export XDG_DATA_DIRS="$BUILD_ROOT/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export PYTHONPATH="$PYTHONPATH_VALUE"

common_env=(
    "--setenv=HOME=$HOME"
    "--setenv=USER=rakko"
    "--setenv=LOGNAME=rakko"
    "--setenv=XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
    "--setenv=DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"
    "--setenv=XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
    "--setenv=XDG_DATA_HOME=$XDG_DATA_HOME"
    "--setenv=XDG_DATA_DIRS=$XDG_DATA_DIRS"
    "--setenv=QT_PLUGIN_PATH=$QT_PLUGIN_PATH"
    "--setenv=XDG_CURRENT_DESKTOP=$XDG_CURRENT_DESKTOP"
    "--setenv=XDG_SESSION_DESKTOP=$XDG_SESSION_DESKTOP"
    "--setenv=XDG_SESSION_TYPE=$XDG_SESSION_TYPE"
    "--setenv=XDG_SESSION_CLASS=$XDG_SESSION_CLASS"
    "--setenv=XDG_MENU_PREFIX=$XDG_MENU_PREFIX"
    "--setenv=QT_QPA_PLATFORM=$QT_QPA_PLATFORM"
    "--setenv=WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    "--setenv=SELKIES_KWIN_ADAPTER_SOCKET=$SELKIES_KWIN_ADAPTER_SOCKET"
)

# 私有 session bus 防止 POC 的 Plasma 与宿主现有桌面会话互相接管。
systemd-run --user --unit="$BUS_UNIT" --collect "${common_env[@]}" /usr/bin/dbus-daemon --session --address="$BUS_ADDRESS" --nofork --nopidfile >/dev/null
started_units+=("$BUS_UNIT")
for _ in $(seq 1 100); do
    [[ -S "$BUS_SOCKET" ]] && break
    systemctl --user is-active --quiet "$BUS_UNIT.service" || fail "私有 D-Bus 已退出"
    sleep 0.1
done
[[ -S "$BUS_SOCKET" ]] || fail "私有 D-Bus socket 未出现"

kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

kwin_run_options=()
kwin_env_options=()
if [[ "$KWIN_PERF_LOG" == true ]]; then
    kwin_run_options+=("--working-directory=$RUN_LOG_DIR")
    kwin_env_options+=("--setenv=KWIN_LOG_PERFORMANCE_DATA=1")
fi
if [[ "$KWIN_SCREENCAST_STATS" == true ]]; then
    kwin_env_options+=("--setenv=KWIN_SCREENCAST_STATS=1")
fi
systemd-run --user --unit="$KWIN_UNIT" --collect "${kwin_run_options[@]}" "${common_env[@]}" \
    "${kwin_env_options[@]}" \
    --setenv=QT_LOGGING_RULES='kwin.selkies.adapter.debug=true;kwin_screencast.debug=true' \
    "$KWIN_BIN" --virtual --socket="$WAYLAND_DISPLAY" --width=3840 --height=2160 --scale=1 \
    --no-lockscreen --no-global-shortcuts >/dev/null
started_units+=("$KWIN_UNIT")
for _ in $(seq 1 120); do
    if [[ -S "$WAYLAND_SOCKET" && -S "$ADAPTER_SOCKET" ]]; then
        break
    fi
    systemctl --user is-active --quiet "$KWIN_UNIT.service" || fail "隔离 KWin 已退出"
    sleep 0.1
done
[[ -S "$WAYLAND_SOCKET" ]] || fail "隔离 Wayland socket 未出现"
[[ -S "$ADAPTER_SOCKET" ]] || fail "KWin adapter socket 未出现"

WAYLAND_DISPLAY="$WAYLAND_DISPLAY" wayland-info >"$WAYLAND_INFO_LOG" 2>&1 || fail "wayland-info 失败"
grep -q 'kde_output_management_v2' "$WAYLAND_INFO_LOG" || fail "没有 KDE output-management-v2"
grep -Eq '3840x2160|3840 x 2160|logical_width: 3840, logical_height: 2160|width: 3840 px, height: 2160 px' "$WAYLAND_INFO_LOG" || fail "隔离 KWin 初始输出不是 3840x2160"

systemd-run --user --unit="$PLASMA_UNIT" --collect "${common_env[@]}" /usr/bin/plasmashell --no-respawn >/dev/null
started_units+=("$PLASMA_UNIT")
sleep 3
systemctl --user is-active --quiet "$PLASMA_UNIT.service" || fail "Plasma shell 已退出"

# 测试内容只在隔离会话中运行，便于统计真实持续帧，不保存图像。
if [[ "${MEDIA_POC_CONTENT:-true}" == "true" ]]; then
    # 用一个小型 Wayland shm 客户端按 frame callback 改色，避免把终端文本
    # 生成速度误当成 KWin/PipeWire 的刷新上限。测试仍然只看日志和计数。
    XDG_XML=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
    [[ -f "$XDG_XML" ]] || fail "找不到 xdg-shell 协议 XML"
    wayland-scanner client-header "$XDG_XML" "$PACER_DIR/xdg-shell-client-protocol.h"
    wayland-scanner private-code "$XDG_XML" "$PACER_DIR/xdg-shell-protocol.c"
    cc -O2 -Wall -Wextra -I"$PACER_DIR" "$PACER_SOURCE" \
        "$PACER_DIR/xdg-shell-protocol.c" \
        $(pkg-config --cflags --libs wayland-client) -o "$PACER_EXE"
    systemd-run --user --unit="$CONTENT_UNIT" --collect "${common_env[@]}" \
        "$PACER_EXE" >/dev/null
    started_units+=("$CONTENT_UNIT")
    for _ in $(seq 1 40); do
        if journalctl --user -u "$CONTENT_UNIT.service" -n 30 --no-pager 2>/dev/null \
            | grep -q 'FRAME_PACER_READY'; then
            break
        fi
        systemctl --user is-active --quiet "$CONTENT_UNIT.service" \
            || fail "连续 Wayland 帧源已退出"
        sleep 0.1
    done
    journalctl --user -u "$CONTENT_UNIT.service" -n 30 --no-pager 2>/dev/null \
        | grep -q 'FRAME_PACER_READY' || fail "连续 Wayland 帧源没有就绪"
fi

if [[ "${MEDIA_POC_DIRECT_PROBE:-false}" == "true" ]]; then
    systemd-run --user --unit="$PROBE_UNIT" --collect "${common_env[@]}" \
        "$PROBE_EXE" "$WAYLAND_DISPLAY" "$TARGET_WIDTH" "$TARGET_HEIGHT" 60 "${MEDIA_POC_DIRECT_PROBE_SECONDS:-20}" >/dev/null
    started_units+=("$PROBE_UNIT")
    # 先让不持有 DMA-BUF 的直接探针完成，避免与完整 Selkies 流程互相影响测量。
    sleep "$(( ${MEDIA_POC_DIRECT_PROBE_SECONDS:-20} + 2 ))"
fi

selkies_env=(
    "${common_env[@]}"
    "--setenv=PYTHONPATH=$PYTHONPATH_VALUE"
    "--setenv=SELKIES_ADDR=127.0.0.1"
    "--setenv=SELKIES_PORT=18090"
    "--setenv=SELKIES_MODE=websockets"
    "--setenv=SELKIES_WEB_ROOT=$SELKIES_SITE/selkies_web"
    "--setenv=PIXELFLUX_WAYLAND=true"
    "--setenv=PIXELFLUX_KWIN_STATS=1"
    "--setenv=SELKIES_WAYLAND_HOST_DISPLAY=$WAYLAND_DISPLAY"
    "--setenv=SELKIES_WAYLAND_HOST_BACKEND=kwin"
    "--setenv=DRI_NODE=/dev/dri/renderD128"
    "--setenv=DRINODE=/dev/dri/renderD128"
    "--setenv=AUTO_GPU=intel"
    "--setenv=SELKIES_GPU_ID=0"
    "--setenv=SELKIES_ENCODER=h264enc"
    "--setenv=SELKIES_AUDIO_ENABLED=true"
    "--setenv=SELKIES_AUDIO_ON_START=true"
    "--setenv=SELKIES_MICROPHONE_ENABLED=false"
    "--setenv=SELKIES_MICROPHONE_ON_START=false"
    "--setenv=SELKIES_WEBCAM_ENABLED=false"
    "--setenv=SELKIES_WEBCAM_ON_START=false"
    "--setenv=SELKIES_GAMEPAD_ENABLED=false"
    "--setenv=SELKIES_GAMEPAD_ON_START=false"
    "--setenv=SELKIES_FILE_TRANSFERS=none"
    "--setenv=SELKIES_COMMAND_ENABLED=false"
    "--setenv=SELKIES_ENABLE_CLIPBOARD=true"
    "--setenv=SELKIES_ENABLE_BINARY_CLIPBOARD=true"
    "--setenv=SELKIES_ENABLE_RESIZE=true"
    "--setenv=SELKIES_ENABLE_BASIC_AUTH=false"
    "--setenv=SELKIES_ENABLE_HTTPS=false"
)

# 故意不设置 manual-resolution、固定宽高或 SELKIES_SCALING_DPI，
# 让浏览器保留动态分辨率与网页端 DPI 选择权。
systemd-run --user --unit="$SELKIES_UNIT" --collect "${selkies_env[@]}" "$SELKIES_EXE" -m selkies >/dev/null
started_units+=("$SELKIES_UNIT")

for _ in $(seq 1 120); do
    if curl -fsS --max-time 2 http://127.0.0.1:18090/api/status >"$STATUS_LOG" 2>/dev/null; then
        break
    fi
    systemctl --user is-active --quiet "$SELKIES_UNIT.service" || fail "Selkies 已退出"
    sleep 0.25
done
[[ -s "$STATUS_LOG" ]] || fail "备用端口 18090 未响应"

ss -ltn >"$SS_LOG" 2>&1 || true
grep -Eq '127\.0\.0\.1:18090|127\.0\.0\.1:[[:space:]]*18090' "$SS_LOG" || fail "18090 没有绑定 127.0.0.1"
if grep -Eq '0\.0\.0\.0:18090|\*:18090|\[::\]:18090' "$SS_LOG"; then
    fail "18090 出现非 loopback 监听"
fi

echo "MEDIA_POC_READY port=18090 target=${TARGET_WIDTH}x${TARGET_HEIGHT}@60 run_id=$RUN_ID log_dir=$RUN_LOG_DIR"
echo "MEDIA_POC_ATTACH ssh -N -L 18090:127.0.0.1:18090 <user>@<host>"
sleep "${POC_HOLD_SECONDS:-240}"

refresh_logs
ss -ltn >"$SS_LOG" 2>&1 || true
pw-cli list-objects Node >"$PW_CLI_LOG" 2>&1 || true
timeout 8 pw-top -b -n 1 >"$PW_TOP_LOG" 2>&1 || true

grep -q 'VAAPI Encoder initialized successfully' "$SELKIES_LOG" || fail "未观察到 Intel VAAPI 初始化成功"
grep -q 'Decision: Zero-Copy path active' "$SELKIES_LOG" || fail "未观察到 pixelflux zero-copy 路径"
grep -q 'DMA-BUF' "$SELKIES_LOG" || fail "Selkies 日志没有 DMA-BUF 证据"
grep -Eq 'KWIN_CAPTURE_(STATS|SUMMARY).*dmabuf=true' "$SELKIES_LOG" || fail "没有持续 KWin DMA-BUF 帧统计"
if grep -Eqi 'capturing locally|SHM fallback|CPU fallback|CPU encoding selected|Falling back to CPU|Failed to init VAAPI' "$SELKIES_LOG"; then
    fail "完整媒体日志出现 CPU/本地捕获回退"
fi

if ! awk -v target_width="$TARGET_WIDTH" -v target_height="$TARGET_HEIGHT" -v min_fps="$MIN_FPS" '
/KWIN_CAPTURE_STATS/ {
    width = height = fps = "";
    for (i = 1; i <= NF; i++) {
        split($i, pair, "=");
        if (pair[1] == "width") width = pair[2];
        if (pair[1] == "height") height = pair[2];
        if (pair[1] == "fps") fps = pair[2];
    }
    if (width == target_width && height == target_height && fps + 0 >= min_fps) good = 1;
}
END { exit good ? 0 : 1 }' "$SELKIES_LOG"; then
    fail "${TARGET_WIDTH}x${TARGET_HEIGHT} 没有观察到至少 ${MIN_FPS} FPS 的实测 KWin 捕获统计"
fi

echo "MEDIA_POC_PASS Plasma KWin PipeWire DMA-BUF VAAPI H264 audio resize target=${TARGET_WIDTH}x${TARGET_HEIGHT}@60 logs=$RUN_LOG_DIR"
