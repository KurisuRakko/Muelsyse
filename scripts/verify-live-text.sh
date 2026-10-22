#!/usr/bin/env bash
# 生产切换后的只读文本验收；没有 POC 通过证据时不要运行它。
set -Eeuo pipefail

fail() {
    echo "VERIFY_FAIL $*" >&2
    exit 1
}

# 以跑远程桌面 user unit 的那个用户运行（下面的 systemctl --user 查的是自己的 user manager）
(( EUID != 0 )) || fail "不要以 root 运行"
grep -qE '^VERSION_ID="?13([.]|"|$)' /etc/os-release || fail "当前主机不是 Debian 13"
systemctl --user is-active --quiet remote-desktop-wayland.service || fail "Wayland service 未 active"
systemctl --user is-active --quiet remote-desktop-selkies.service || fail "Selkies service 未 active"

# shellcheck source=scripts/rakkord-env.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/rakkord-env.sh"
rakkord_load_env
PORT=${1:-${RAKKORD_PORT:-8090}}
loopback_listener=$(ss -ltnH | awk -v target="127.0.0.1:$PORT" '$4 == target {print $4}')
[[ "$loopback_listener" == "127.0.0.1:$PORT" ]] || fail "没有 loopback listener 127.0.0.1:$PORT"
# 只看 selkies 进程自己的监听；:$PORT 上的 socat、tailscaled 是设计如此的对外入口，不归它管
selkies_pid=$(systemctl --user show -p MainPID --value remote-desktop-selkies.service)
[[ "$selkies_pid" =~ ^[1-9][0-9]*$ ]] || fail "取不到 remote-desktop-selkies 的 MainPID（得到 '${selkies_pid}'）"
selkies_listeners=$(ss -ltnpH | awk -v pid="pid=$selkies_pid," 'index($0, pid) {print $4}' | sort -u)
[[ -n "$selkies_listeners" ]] || fail "Selkies 进程 pid=$selkies_pid 没有任何 TCP 监听"
unexpected=$(grep -vxF "127.0.0.1:$PORT" <<<"$selkies_listeners" || true)
[[ -z "$unexpected" ]] || fail "Selkies 进程 pid=$selkies_pid 监听了 127.0.0.1:$PORT 以外的地址: $(tr '\n' ' ' <<<"$unexpected")"

if ps -eo user=,args= | awk '$1 == "ubuntu" && /kwin_wayland|selkies|pixelflux/ {found=1} END {exit found ? 0 : 1}'; then
    fail "发现 ubuntu 进程"
fi

wayland_info="${TMPDIR:-/tmp}/remote-desktop-wayland-info.$$.log"
pw_log="${TMPDIR:-/tmp}/remote-desktop-pw.$$.log"
ffmpeg_log="${TMPDIR:-/tmp}/remote-desktop-ffmpeg.$$.log"
trap 'rm -f -- "$wayland_info" "$pw_log" "$ffmpeg_log"' EXIT
WAYLAND_DISPLAY=wayland-remote-desktop wayland-info >"$wayland_info" 2>&1 \
    || fail "wayland-info 失败"
grep -q 'kde_output_management_v2' "$wayland_info" || fail "没有 KDE output-management-v2"
grep -Eq '3840x2160|[0-9]+x[0-9]+' "$wayland_info" || fail "没有 Wayland output mode"

pw-cli list-objects Node >"$pw_log" 2>&1 || fail "pw-cli 失败"
grep -q 'PipeWire' "$pw_log" || fail "没有 PipeWire node"
ffmpeg -hide_banner -encoders >"$ffmpeg_log" 2>&1 || fail "ffmpeg encoder 查询失败"
grep -qi 'h264_vaapi' "$ffmpeg_log" || fail "ffmpeg 没有 h264_vaapi encoder"

# 只看当前这次启动的日志：-n 300 在服务跑久之后会把启动时打印的 DMA-BUF/VAAPI 行挤出去。
service_log=$(journalctl --user -u remote-desktop-selkies.service --invocation=0 --no-pager)
grep -Eqi 'DMA-BUF|dmabuf|zero-copy' <<<"$service_log" || fail "Selkies 日志没有 DMA-BUF/zero-copy"
grep -Eqi 'VAAPI|vaapi.*h264|h264.*vaapi' <<<"$service_log" || fail "Selkies 日志没有 Intel VAAPI H.264"
if grep -Eqi 'capturing locally|SHM fallback|CPU fallback|software.*fallback' <<<"$service_log"; then
    fail "日志出现禁止的本地/CPU fallback"
fi

echo "VERIFY_PASS user=$(id -un) debian=13 listener=127.0.0.1:$PORT wayland=KDE pipewire=present vaapi=h264"
