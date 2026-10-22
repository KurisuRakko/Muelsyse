#!/usr/bin/env bash
# muelsyse-sunshine-port-wait.sh —— Sunshine 的 ExecStartPost：启动看门狗。
#
# 安装位置：~/.local/libexec/muelsyse-sunshine-port-wait.sh
# 仓库源文件：sunshine/libexec/muelsyse-sunshine-port-wait.sh
#
# 为什么需要它（2026-10-02 实测）：
#   9/30 16:11 KWin 会话崩溃后重启，Sunshine 的 portal restore token 失效，
#   xdg-desktop-portal-kde 改为弹授权框（"MegaAuth: No entry for remote-desktop"），
#   而这个 headless 会话没人点 → Sunshine 停在 "[portalgrab] Loaded portal restore token from disk"，
#   两天没监听 47989/47990，systemd 却一直显示 active，Restart=on-failure 不会触发。
#   根治靠权限库预授权（kde-authorized / remote-desktop / dev.lizardbyte.app.Sunshine = yes），
#   本脚本兜底：等到 HTTPS 管理端口能连上；超时 exit 1，让 unit 失败、交给 Restart=on-failure。
#
# 环境变量：
#   SUNSHINE_PORT_WAIT=90     最长等待秒数
#   SUNSHINE_PORT_WAIT_PORT=47990
#
# 只读：只做 TCP connect，不改文件、不启停服务。

set -uo pipefail

WAIT_MAX="${SUNSHINE_PORT_WAIT:-90}"
PORT="${SUNSHINE_PORT_WAIT_PORT:-47990}"
case "$WAIT_MAX" in ''|*[!0-9]*) WAIT_MAX=90 ;; esac
case "$PORT" in ''|*[!0-9]*) PORT=47990 ;; esac

port_ok() {
    timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" >/dev/null 2>&1
}

start=$SECONDS
while :; do
    if port_ok; then
        printf 'muelsyse-sunshine-port-wait: 127.0.0.1:%s 已监听（%ss）\n' "$PORT" "$((SECONDS - start))"
        exit 0
    fi
    if [ $((SECONDS - start)) -ge "$WAIT_MAX" ]; then
        printf 'muelsyse-sunshine-port-wait: %ss 内 127.0.0.1:%s 仍未监听——Sunshine 多半卡在 portal 授权，判定启动失败\n' \
            "$WAIT_MAX" "$PORT" >&2
        exit 1
    fi
    sleep 2
done
