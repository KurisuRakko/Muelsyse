#!/usr/bin/env bash
# 起一个临时 KWin（带 Selkies adapter、独立 wayland/adapter socket、私有 session bus），
# 对它跑 muelsyse-displayd + muelsyse-display 的集成测试。不碰生产会话：
# 生产的 wayland-remote-desktop、selkies-kwin-adapter.sock、muelsyse-display.sock 都不用。
#
# 配方见方案 009「阶段 0 结果」：私有 dbus-daemon（不和生产会话抢 org.kde.KWin，也不让
# kscreen-doctor 连到生产会话的 kscreen 后端）、临时 XDG_CONFIG_HOME 里开 adapter 插件、
# QT_PLUGIN_PATH 同 start-wayland-session.sh、LD_LIBRARY_PATH=<prefix>/bin（否则第一次
# prepare 时 adapter 插件 undefined symbol，KWin 退出 127）。
#
# 用法: scripts/tests/run-test-kwin.sh
# KWin 前缀：SELKIES_KWIN_PREFIX，默认 $HOME/.local/share/remote-desktop/kwin/current。
set -Eeuo pipefail

fail() {
    echo "TEST_KWIN_FAIL $*" >&2
    exit 1
}

(( EUID != 0 )) || fail "不要以 root 运行"
[[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]] || fail "XDG_RUNTIME_DIR 不可用"

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PREFIX=${SELKIES_KWIN_PREFIX:-$HOME/.local/share/remote-desktop/kwin/current}
KWIN_BIN="$PREFIX/bin/kwin_wayland"
[[ -x "$KWIN_BIN" ]] || fail "找不到 KWin: $KWIN_BIN"
for cmd in dbus-daemon kscreen-doctor systemd-run python3; do
    command -v "$cmd" >/dev/null || fail "缺少 $cmd"
done

UNIT=muelsyse-test-kwin
TAG="muelsyse-test-$$"
WAYLAND_NAME="$TAG"
ADAPTER_SOCKET="$XDG_RUNTIME_DIR/selkies-kwin-adapter-$TAG.sock"
DISPLAY_SOCKET="$XDG_RUNTIME_DIR/muelsyse-display-$TAG.sock"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/muelsyse-test-kwin.XXXXXX")
CONFIG_HOME="$TMP_DIR/config"
DAEMON_LOG="$TMP_DIR/displayd.log"

# 同名 unit 已存在（在跑，或上次失败后没清）就拒绝，免得停掉别人的东西。
load_state=$(systemctl --user show -p LoadState --value "$UNIT.service" 2>/dev/null || true)
if [[ "$load_state" != "not-found" ]]; then
    fail "$UNIT.service 已存在（LoadState=$load_state）；确认不是别人在用后 systemctl --user reset-failed $UNIT.service"
fi

dbus_pid=0
daemon_pid=0
kwin_started=0
cleanup() {
    set +e
    ((daemon_pid > 0)) && kill "$daemon_pid" 2>/dev/null && wait "$daemon_pid" 2>/dev/null
    if ((kwin_started)); then
        systemctl --user stop "$UNIT.service" >/dev/null 2>&1
        systemctl --user reset-failed "$UNIT.service" >/dev/null 2>&1
    fi
    ((dbus_pid > 0)) && kill "$dbus_pid" 2>/dev/null
    rm -f -- "$ADAPTER_SOCKET" "$DISPLAY_SOCKET" "$XDG_RUNTIME_DIR/$WAYLAND_NAME" "$XDG_RUNTIME_DIR/$WAYLAND_NAME.lock"
    if [[ -s "$DAEMON_LOG" ]]; then
        echo "--- displayd 日志 ---"
        cat "$DAEMON_LOG"
    fi
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$CONFIG_HOME"
printf '%s\n' '[Plugins]' 'selkieskwinadapterEnabled=true' >"$CONFIG_HOME/kwinrc"

# 私有 session bus：第一行地址，第二行 pid。
mapfile -t dbus_info < <(dbus-daemon --session --fork --print-address=1 --print-pid=1)
DBUS_ADDR=${dbus_info[0]:-}
dbus_pid=${dbus_info[1]:-0}
[[ -n "$DBUS_ADDR" && "$dbus_pid" =~ ^[0-9]+$ && "$dbus_pid" -gt 0 ]] || fail "私有 dbus-daemon 起不来"

plugin_paths=("$PREFIX/bin/kwin/plugins" "$PREFIX/bin" "$PREFIX/lib/x86_64-linux-gnu/qt6/plugins" "$PREFIX/lib/qt6/plugins")
QT_PLUGIN_PATH_TEST=$(IFS=:; echo "${plugin_paths[*]}${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}")

kwin_started=1
systemd-run --user --unit="$UNIT" --collect -q \
    -p MemoryMax=1G -p MemorySwapMax=0 \
    --setenv=HOME="$HOME" \
    --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    --setenv=DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" \
    --setenv=XDG_CONFIG_HOME="$CONFIG_HOME" \
    --setenv=XDG_DATA_DIRS="$PREFIX/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" \
    --setenv=QT_PLUGIN_PATH="$QT_PLUGIN_PATH_TEST" \
    --setenv=LD_LIBRARY_PATH="$PREFIX/bin" \
    --setenv=XDG_SESSION_TYPE=wayland \
    --setenv=QT_QPA_PLATFORM=wayland \
    --setenv=SELKIES_KWIN_ADAPTER_SOCKET="$ADAPTER_SOCKET" \
    "$KWIN_BIN" --virtual --socket="$WAYLAND_NAME" --width=1920 --height=1080 --scale=1 \
    --no-lockscreen --no-global-shortcuts

for _ in $(seq 1 150); do
    [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_NAME" && -S "$ADAPTER_SOCKET" ]] && break
    systemctl --user is-active --quiet "$UNIT.service" || break
    sleep 0.1
done
[[ -S "$XDG_RUNTIME_DIR/$WAYLAND_NAME" ]] || fail "临时 KWin 的 wayland socket 没出现"
[[ -S "$ADAPTER_SOCKET" ]] || fail "adapter socket 没出现（插件没加载？）"

# 之后的 kscreen-doctor（脚本里的核对和 displayd 起的）都只连临时 KWin 和私有 bus。
export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR"
export KSCREEN_BACKEND_INPROCESS=1
kj() { WAYLAND_DISPLAY="$WAYLAND_NAME" QT_QPA_PLATFORM=wayland timeout 10 kscreen-doctor -j; }

# 读 -j 里 Virtual-0 的 "WxH scale"。
current() {
    kj | python3 -c '
import json, sys
o = next(o for o in json.load(sys.stdin)["outputs"] if o["name"] == "Virtual-0")
m = next(m for m in o["modes"] if str(m["id"]) == str(o["currentModeId"]))
print("%dx%d %g" % (m["size"]["width"], m["size"]["height"], o["scale"]))'
}

# 安全闸：必须看到的是临时 KWin 的 1920x1080，不是生产屏。
first=$(current) || fail "kscreen-doctor 读不到临时 KWin"
[[ "$first" == "1920x1080 1" ]] || fail "kscreen-doctor 读到的是 $first，不是临时 KWin 的 1920x1080，停止"

export MUELSYSE_DISPLAY_SOCKET="$DISPLAY_SOCKET"
export MUELSYSE_DISPLAY_WAYLAND="$WAYLAND_NAME"
export MUELSYSE_DISPLAY_ADAPTER="$ADAPTER_SOCKET"
export MUELSYSE_DISPLAY_STATE="$TMP_DIR/display.json"
export MUELSYSE_DISPLAY_SELKIES_UNIT="$TAG-no-such-selkies.service"
python3 -I "$ROOT/scripts/muelsyse-displayd.py" >"$DAEMON_LOG" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 50); do
    [[ -S "$DISPLAY_SOCKET" ]] && break
    sleep 0.1
done
[[ -S "$DISPLAY_SOCKET" ]] || fail "displayd 没起来"

CLI=(python3 -I "$ROOT/scripts/muelsyse-display")
pass=0
check() {  # check <描述> <期望 "WxH scale">
    local got
    got=$(current)
    [[ "$got" == "$2" ]] || fail "$1：kscreen-doctor -j 是 $got，期望 $2"
    echo "ok  $1（$got）"
    pass=$((pass + 1))
}
expect_out() {  # expect_out <描述> <期望 stdout> <命令...>
    local desc=$1 want=$2 out
    shift 2
    out=$("$@") || fail "$desc：退出码 $?"
    [[ "$out" == "$want" ]] || fail "$desc：输出 '$out'，期望 '$want'"
}
expect_reject() {  # expect_reject <描述> <reason> <命令...>
    local desc=$1 reason=$2 rc=0 err
    shift 2
    err=$("$@" 2>&1 >/dev/null) || rc=$?
    ((rc == 1)) || fail "$desc：退出码 $rc，期望 1（$err）"
    [[ "$err" == "rejected: $reason"* ]] || fail "$desc：$err"
}

# T1 status 与 -j 一致
st=$("${CLI[@]}" status --json)
python3 -c '
import json, sys
st = json.loads(sys.argv[1])
assert st["ok"] and st["mode"]["w"] == 1920 and st["mode"]["h"] == 1080 and st["scale"] == 1, st
assert st["selkies"] == {"service_active": False, "clients": "no"}, st
assert st["policy"] == "follow" and st["pin"] is None, st' "$st" || fail "status 不对: $st"
check "T1 status" "1920x1080 1"

# T2 新尺寸：prepare → 切换 → 校验
expect_out "set 1600x900" "applied 1600x900 scale 1" "${CLI[@]}" set 1600x900
check "T2 set 1600x900" "1600x900 1"
expect_out "set 1280x720 --scale 1.5" "applied 1280x720 scale 1.5" "${CLI[@]}" set 1280x720 --scale 1.5
check "T2 set 1280x720 --scale 1.5" "1280x720 1.5"
expect_out "unchanged" "unchanged 1280x720 scale 1.5" "${CLI[@]}" set 1280x720 --scale 1.5
check "unchanged" "1280x720 1.5"

# T3 非法值不动输出
expect_reject "奇数" invalid "${CLI[@]}" set 1601x901
expect_reject "超上限" invalid "${CLI[@]}" set 4096x2160
expect_reject "scale 1.3" invalid "${CLI[@]}" set --scale 1.3
check "T3 非法值后不变" "1280x720 1.5"

# T5 pin / follow
expect_out "pin 1920x1080 --scale 1.25" "applied 1920x1080 scale 1.25" "${CLI[@]}" pin 1920x1080 --scale 1.25
check "T5 pin" "1920x1080 1.25"
reply=$(python3 -c '
import json, os, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(os.environ["MUELSYSE_DISPLAY_SOCKET"])
s.sendall(b"{\"op\":\"request\",\"w\":1600,\"h\":900,\"source\":\"selkies\"}\n")
print(json.loads(s.makefile().readline())["reason"])')
[[ "$reply" == "pinned" ]] || fail "pinned 下 selkies 请求没被拒: $reply"
check "T5 pinned 拒绝 selkies" "1920x1080 1.25"
expect_out "follow" "follow" "${CLI[@]}" follow
expect_out "set --scale 1" "applied 1920x1080 scale 1" "${CLI[@]}" set --scale 1
check "T5 follow 后放行" "1920x1080 1"

echo "TEST_KWIN_OK $pass 项"
