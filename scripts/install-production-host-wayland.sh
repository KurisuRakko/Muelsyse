#!/usr/bin/env bash
# 已拆分（2026-10-17）。旧脚本会用仓库里过时的 unit 覆盖生产、写死 renderD128，默认输入还指向
# ~/src/*-poc 两棵 POC 树，不能再跑。各部分的去处：
echo "install-production-host-wayland.sh 已拆分，不再执行任何安装：" >&2
echo "  文件部署（unit、libexec、desktop、配置）：scripts/deploy-host.sh（默认 dry-run，--apply 才装）" >&2
echo "  Selkies 发版（前端、pixelflux、release 软链）：scripts/build-release.sh" >&2
echo "  KWin 构建与版本化 prefix：scripts/build-kwin.sh" >&2
echo "  一次性主机初始化（selkies-python3.13、kwinrc、光标主题、Chrome .desktop、kbuildsycoca6）：scripts/bootstrap-host.sh" >&2
exit 1
