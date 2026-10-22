#!/usr/bin/env bash
# 把局域网地址 @RAKKORD_LAN_BIND@:@RAKKORD_PORT@ 转发到 Selkies 远程桌面的回环端口。
#
# 为什么需要这个：Selkies 的监听地址由 user unit 写死
# （remote-desktop-selkies.service 里的 SELKIES_ADDR=127.0.0.1），
# 刻意不让一个旧环境文件把它改掉，所以对外入口只能由转发器提供。
#
# 为什么只绑局域网地址、不绑 0.0.0.0 也不绑 Tailscale 地址：
#   Tailscale 那一路已经由 `tailscale serve --http=@RAKKORD_PORT@` 提供
#   （tailscaled 在 @RAKKORD_TAILNET_BIND@:@RAKKORD_PORT@ 与 fd7a:...:@RAKKORD_PORT@ 上监听），
#   这里再绑一次会直接 EADDRINUSE。
#
# 历史背景：内网这条路原本由 wechat-selkies 容器（host 网络，3000/3001）提供，
# 2026-09-16 容器被卸载、nftables 里 { 3000, 3001 } 的放行也一并删掉，内网入口从此消失。
# 本单元连同 nftables 的 @RAKKORD_PORT@ 放行是它的替代品。
#
# 安全边界：这个桌面是 SELKIES_ENABLE_BASIC_AUTH=false|locked 的无认证 KDE 会话，
# 跑在 sudo 组用户 @USER@ 下。开放范围完全由 nftables 的 INPUT policy drop 决定：
# 只有 @RAKKORD_LAN_CIDR@ 能进来（见 /etc/nftables.conf）。同网段内任何设备都能直接接管桌面。
set -euo pipefail

LAN_ADDR="@RAKKORD_LAN_BIND@"
LISTEN_PORT=@RAKKORD_PORT@
BACKEND="127.0.0.1:@RAKKORD_PORT@"

pids=()
cleanup() {
    for pid in "${pids[@]:-}"; do
        kill "${pid}" 2>/dev/null || true
    done
}
trap cleanup EXIT TERM INT

socat "TCP-LISTEN:${LISTEN_PORT},bind=${LAN_ADDR},reuseaddr,fork" "TCP:${BACKEND}" &
pids+=("$!")

# 任一监听退出就让整个单元退出，交给 systemd 的 Restart=always 收尾
wait -n
