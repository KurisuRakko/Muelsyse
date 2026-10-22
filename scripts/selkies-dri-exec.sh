#!/usr/bin/env bash
# selkies-dri-exec.sh —— Selkies 的 ExecStart 包装器（任务 005 新建，007 改为跟随 KWin）。
#
# 只做一件事：把 DRM render 节点从写死的 /dev/dri/renderD<num> 换成"**KWin 实际打开的
# 那个节点**"，并把渲染卡与编码卡设成同一个节点。
#
# 为什么要跟随 KWin（而不是按模式写死 Intel 或 NVIDIA）：
#   KWin 的 --virtual 后端只接受来自本卡渲染的 DMA-BUF，pixelflux 的 kwin.rs:542-548 对
#   非 DMA-BUF 帧直接结束线程（严格模式，禁止 SHM/CPU fallback），而跨卡时
#   lib.rs:2511-2518 判 different_gpu=true → 不建零拷贝编码器 → 渲染 tick 见 dmabuf 就
#   `return RETAINED_GPU_FRAME` 丢弃（lib.rs:3346-3352）→ **稳态黑屏**（一帧都编不出来）。
#   所以唯一安全的规则是：DRINODE = DRI_NODE = KWin 打开的那个 render 节点。
#   两种模式都成立：
#     * intel 模式（方案 A）：KWin 只看到 Intel 的 render 节点 → 同卡零拷贝 VAAPI；
#     * nvidia 模式：只剩 P620 → 同卡零拷贝 NVENC（EGLImage → CUDA，nvenc.rs）。
#
# 时序（004 §6.1）：remote-desktop-wayland.service 是 Type=simple，KWin 在 launcher 里
# 是 `&` 后台起的，Selkies 的 ExecStart 可能早于 KWin 的 EGL 初始化完成 —— 所以这里
# **有限等待**（默认 15 秒，SELKIES_DRI_WAIT 可调），等 KWin 打开节点后再定变量。
#
# 环境变量覆盖：
#   SELKIES_DRI_NODE=/dev/dri/renderDxxx   显式指定（调试/应急；不再探测 KWin）
#   SELKIES_DRI_WAIT=<秒>                  等待 KWin 的上限，默认 15，0 = 不等
#
# 退出码：永远 exec 目标命令 —— 解析失败只打日志（unit 里 AUTO_GPU 兜底，最坏软件编码），
# 绝不因为探测失败就拒绝启动。

set -uo pipefail

LIBEXEC="${SELKIES_LIBEXEC_DIR:-$HOME/.local/libexec}"
RESOLVER="$LIBEXEC/dri-node-resolve.sh"

dri_drm_driver_of() { return 1; }
dri_node_vendor()   { return 1; }

node="${SELKIES_DRI_NODE:-}"
source_ok=0

if [ -z "$node" ]; then
    if [ -r "$RESOLVER" ]; then
        # shellcheck source=/dev/null
        . "$RESOLVER"
        source_ok=1
        wait_secs="${SELKIES_DRI_WAIT:-15}"
        node="$(dri_kwin_render_node "$wait_secs" 2>/dev/null || true)"
        if [ -z "$node" ]; then
            node="$(dri_fallback_render_node 2>/dev/null || true)"
            if [ -n "$node" ]; then
                echo "selkies-dri-exec: 没探测到 KWin 打开的节点（等 ${wait_secs}s），回退到现场解析：$node" >&2
            fi
        fi
    else
        echo "selkies-dri-exec: 找不到节点解析库 $RESOLVER，DRI_NODE/DRINODE 沿用 unit 值。" >&2
    fi
fi

if [ -n "$node" ]; then
    if [ -e "$node" ]; then
        export DRINODE="$node"      # pixelflux 的 GL renderer（消费 KWin 的 DMA-BUF）
        export DRI_NODE="$node"     # pixelflux 的编码节点（编码器由 sysfs 驱动名路由）
        drv="$(dri_drm_driver_of "$node" 2>/dev/null || true)"
        vendor="$(dri_node_vendor "$node" 2>/dev/null || true)"
        echo "selkies-dri-exec: 渲染卡=编码卡=${drv:-未知驱动} $node（vendor=${vendor:-?}）" >&2
        case "$drv" in
            i915)
                echo "selkies-dri-exec: 同卡零拷贝 VAAPI 路径。" >&2
                # AUTO_GPU 只在 DRINODE 为空时才被 pixelflux 使用（lib.rs:6742-6777），
                # 这里同步一下只是让"兜底 token"与显式节点不打架。
                export AUTO_GPU=intel ;;
            nvidia)
                echo "selkies-dri-exec: 同卡零拷贝 NVENC 路径（EGLImage → CUDA）。" >&2
                export AUTO_GPU=nvidia ;;
            nouveau)
                echo "selkies-dri-exec: 警告：节点由 nouveau 驱动！nouveau 不带 NVENC/VAAPI，pixelflux 会退回 CPU 编码。请核对 /etc/modprobe.d/00-rakko-gpu-mode.conf 与是否重启过。" >&2 ;;
            *)
                echo "selkies-dri-exec: 警告：节点驱动是 ${drv:-未知}，预期 i915 或 nvidia。" >&2 ;;
        esac
    else
        echo "selkies-dri-exec: 解析出的节点 $node 不存在，DRI_NODE/DRINODE 沿用 unit 值。" >&2
    fi
else
    if [ "$source_ok" = 1 ]; then
        echo "selkies-dri-exec: 没能确定 render 节点（KWin 未就绪且现场解析失败），DRI_NODE/DRINODE 沿用 unit 值（AUTO_GPU 兜底）。" >&2
    fi
fi

exec "$@"
