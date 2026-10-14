#!/usr/bin/env bash
# 生产切换后的只读文本验收；没有 POC 通过证据时不要运行它。
set -Eeuo pipefail

fail() {
    echo "VERIFY_FAIL $*" >&2
    exit 1
}

[[ "$(id -un)" == "rakko" ]] || fail "运行用户不是 rakko"
grep -qE '^VERSION_ID="?13([.]|"|$)' /etc/os-release || fail "当前主机不是 Debian 13"
systemctl --user is-active --quiet remote-desktop-wayland.service || fail "Wayland service 未 active"
systemctl --user is-active --quiet remote-desktop-selkies.service || fail "Selkies service 未 active"

PORT=${1:-8090}
loopback_listener=$(ss -ltnH | awk -v target="127.0.0.1:$PORT" '$4 == target {print $4}')
[[ "$loopback_listener" == "127.0.0.1:$PORT" ]] || fail "没有 loopback listener 127.0.0.1:$PORT"
non_loopback=$(ss -ltnH | awk -v port=":$PORT" '$4 ~ port "$" && $4 !~ /^127[.]0[.]0[.]1:/ {print $4}')
[[ -z "$non_loopback" ]] || fail "Selkies 监听了非 loopback 地址: $non_loopback"

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

service_log=$(journalctl --user -u remote-desktop-selkies.service -n 300 --no-pager)
grep -Eqi 'DMA-BUF|dmabuf|zero-copy' <<<"$service_log" || fail "Selkies 日志没有 DMA-BUF/zero-copy"
grep -Eqi 'VAAPI|vaapi.*h264|h264.*vaapi' <<<"$service_log" || fail "Selkies 日志没有 Intel VAAPI H.264"
if grep -Eqi 'capturing locally|SHM fallback|CPU fallback|software.*fallback' <<<"$service_log"; then
    fail "日志出现禁止的本地/CPU fallback"
fi

echo "VERIFY_PASS user=rakko debian=13 listener=127.0.0.1:$PORT wayland=KDE pipewire=present vaapi=h264"
