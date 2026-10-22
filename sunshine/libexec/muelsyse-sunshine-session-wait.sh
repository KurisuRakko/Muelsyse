#!/usr/bin/env bash
# muelsyse-sunshine-session-wait.sh —— Sunshine 的 ExecStartPre（任务 010）：开机竞态的有界等待。
#
# 安装位置：~/.local/libexec/muelsyse-sunshine-session-wait.sh（仓库源文件 sunshine/libexec/muelsyse-sunshine-session-wait.sh）
#
# 为什么需要它（实测证据，2026-09-25 那次开机）：
#   20:37:53  systemd 启动 Sunshine（包自带 ExecStartPre=/bin/sleep 5）
#   20:37:58  sunshine 启动，读到 portal restore token
#   20:38:23  [portalgrab] Failed to connect to dbus. Cannot enumerate displays, returning empty list.
#   20:38:23  Error: Unable to initialize capture method / Platform failed to initialize
#   20:38:24  Trying encoder [nvenc] -> failed；vulkan/vaapi/software 全 failed
#   20:38:25  Fatal: Unable to find display or encoder during startup.
#   之后手动 restart 就能枚举到 Virtual-0 —— 典型的"和 KWin / portal 抢跑"。
#   （journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -b）
#
# 本脚本在 Sunshine 真正启动前**有界等待**下面三个条件全部成立（默认最多 60 秒）：
#
#   1. Wayland socket 可连接：$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY
#      只判断"文件存在"不够 —— KWin 崩溃后 socket 文件会留在原地，只有 connect 才会
#      得到 ECONNREFUSED（本机 2026-09-25 21:20 实测：文件在、connect 被拒）。
#   2. session bus 可达：busctl --user status org.freedesktop.DBus
#   3. xdg-desktop-portal 前端已激活且带 ScreenCast / RemoteDesktop 接口：
#      读 org.freedesktop.portal.ScreenCast 与 .RemoteDesktop 的 version 属性。
#      发这个 method call 本身就会触发 D-Bus activation，把 portal 拉起来。
#      （只等 org.freedesktop.portal.Desktop 这个名字出现是不够的：它是 activatable，
#        真正需要的是接口在、且能应答。）
#
# 超时之后**仍然 exit 0**，只打印醒目 warning：
#   * 今天线上的行为就是"条件不满足也照常起 Sunshine"，本脚本只负责把常见的抢跑等掉，
#     不在坏环境下引入新的失败模式；
#   * 若超时还起不来，说明环境真的坏了（例如 KWin 已崩），此时让 systemd 反复重启
#     Sunshine 解决不了问题，反而会吃掉包自带 unit 的 StartLimitBurst=5 / 500s 配额，
#     最后连"手动 restart 就能好"的那条路都没了。
#
# 环境变量：
#   SUNSHINE_SESSION_WAIT=60        最长等待秒数（0 = 只探测一次，不等待）
#   SUNSHINE_SESSION_WAIT_VERBOSE=1 每次轮询都打印状态
#
# 幂等、只读：不改任何文件、不启停任何服务；唯一的副作用是 D-Bus 激活 portal。

set -uo pipefail

WAIT_MAX="${SUNSHINE_SESSION_WAIT:-60}"
VERBOSE="${SUNSHINE_SESSION_WAIT_VERBOSE:-0}"
WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-remote-desktop}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
WL_SOCKET="$RUNTIME_DIR/$WAYLAND_DISPLAY"

case "$WAIT_MAX" in
    ''|*[!0-9]*) WAIT_MAX=60 ;;
esac

log()  { printf 'muelsyse-sunshine-session-wait: %s\n' "$*"; }
warn() { printf 'muelsyse-sunshine-session-wait: %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 三个探针
# 返回 0 = 就绪，非 0 = 未就绪；每个探针自己带超时，绝不无限阻塞。
wl_socket_ok() {
    [ -S "$WL_SOCKET" ] || return 1
    if command -v python3 >/dev/null 2>&1; then
        timeout 4 python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
try:
    s.connect(sys.argv[1])
finally:
    s.close()
' "$WL_SOCKET" >/dev/null 2>&1
        return $?
    fi
    if command -v socat >/dev/null 2>&1; then
        timeout 4 socat -u /dev/null "UNIX-CONNECT:$WL_SOCKET" >/dev/null 2>&1
        return $?
    fi
    # 两个工具都没有：退化成"文件存在"，至少不比现状差
    return 0
}

bus_ok() {
    timeout 5 busctl --user --no-pager status org.freedesktop.DBus >/dev/null 2>&1
}

portal_iface_ok() {
    local iface
    for iface in org.freedesktop.portal.ScreenCast org.freedesktop.portal.RemoteDesktop; do
        timeout 10 busctl --user --no-pager get-property \
            org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop \
            "$iface" version >/dev/null 2>&1 || return 1
    done
    return 0
}

# ---------------------------------------------------------------- 等待循环
start="$(date +%s)"
deadline=$(( start + WAIT_MAX ))
attempt=0
missing=""
while :; do
    attempt=$(( attempt + 1 ))
    missing=""
    wl_socket_ok   || missing="$missing wayland-socket($WL_SOCKET)"
    bus_ok         || missing="$missing session-bus"
    portal_iface_ok|| missing="$missing xdg-desktop-portal(ScreenCast/RemoteDesktop)"

    if [ -z "$missing" ]; then
        if [ "$attempt" = 1 ]; then
            log "会话已就绪（首次探测即通过，未等待）。"
        else
            log "会话已就绪（等待 $(( $(date +%s) - start ))s，第 $attempt 次探测）。"
        fi
        exit 0
    fi

    [ "$VERBOSE" = 1 ] && log "第 $attempt 次探测未就绪：$missing"

    now="$(date +%s)"
    [ "$now" -ge "$deadline" ] && break
    sleep 1
done

warn "等待 $(( $(date +%s) - start ))s 后仍未就绪：$missing"
warn "仍然继续启动 Sunshine（不改变现状、不占用 systemd 重启配额）。"
warn "若是 Wayland socket 一直连不上，先看：systemctl --user status remote-desktop-wayland.service"
exit 0
