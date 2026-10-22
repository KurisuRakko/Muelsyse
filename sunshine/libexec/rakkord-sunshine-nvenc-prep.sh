#!/usr/bin/env bash
# rakkord-sunshine-nvenc-prep.sh —— Sunshine 的 ExecStartPre（任务 007 版：模式自适应）。
#
# 每次启动前把 ~/.config/sunshine/sunshine.conf 的两个键校正到"当前这台机器此刻的
# 真实状态"，然后退出（永远 exit 0，绝不阻塞 Sunshine 启动）：
#
#   1. adapter_name = 当前模式下**渲染卡**的 render 节点（防 renderD 编号漂移）：
#        intel 模式（方案 A）-> Intel 节点；nvidia 模式 -> NVIDIA 节点。
#      Sunshine 的 nvenc 在 Linux 上不读这个键（上游 v2026.914.233613：
#      resolve_render_device() 只被 VAAPI/Vulkan/KMS/wlr 消费，见
#      src/platform/linux/misc.cpp:1492-1498 与 docs/configuration.md:936），
#      它只在 vaapi 回退时决定选卡，所以必须跟着当前模式走；两张卡都没有对应节点时
#      保持原值不动。
#
#   2. encoder = nvenc | vaapi，按 NVIDIA **用户态**是否就绪判定：
#        就绪 = /dev/nvidiactl + /dev/nvidia0 + /dev/nvidia-uvm + libcuda.so.1
#               （+ libnvidia-encode.so.1），见 dri_nvidia_userspace_ready()。
#        就绪 -> nvenc（P620）。注意两种模式下 Sunshine 的帧路径不同：
#          * intel 模式：display_is_nvidia=false -> PipeWire MemPtr -> cudaMemcpy2D 上传；
#          * nvidia 模式：display_is_nvidia=true  -> PipeWire DMA-BUF -> NVENC_GL
#            （cuda.cpp 的 gl_cuda_vram_t，需要 NVIDIA 的 **card** 节点，即
#             nvidia-drm modeset=1；缺 card 节点时 Sunshine 侧会失败并回退编码器）。
#        未就绪 -> vaapi（intel 模式可用；nvidia 模式下没有 Intel，最终会由 Sunshine
#                  自己回退到软件编码，这里只把配置写回 vaapi 并打印原因）。
#
# 设备节点自愈：nvidia 模块已加载但 /dev/nvidia* 不全时，先调 setuid 的
# nvidia-modprobe 补一次（正常路径由 /etc/systemd/system/rakko-nvidia-device-nodes.service
# 在 sysinit 阶段建好；这里是第二道保险，模块没加载时是 no-op）。
#
# 环境变量覆盖：
#   SUNSHINE_ENCODER_GPU=vaapi   强制 vaapi（应急回退）
#   SUNSHINE_ENCODER_GPU=nvenc   强制 nvenc（不检查用户态）
#   默认（未设/其它）= 自动
#   SUNSHINE_ADAPTER_NODE=/dev/dri/renderDxxx  强制 adapter_name（调试/应急）
#
# 幂等 + 原子：两个键在一次 awk 里算完，写临时文件后 rename 覆盖（不会出现
# "改了一半"的配置）；备份只在第一次改动前留一份（$CONF.bak-before-nvenc-prep），
# 之后不再覆盖，保留真正的"改动前"内容。

set -uo pipefail

CONF="${SUNSHINE_CONF:-$HOME/.config/sunshine/sunshine.conf}"
LIBEXEC="${SELKIES_LIBEXEC_DIR:-$HOME/.local/libexec}"

[ -w "$CONF" ] || { echo "rakkord-sunshine-nvenc-prep: $CONF 不可写，跳过。" >&2; exit 0; }

get_key() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p" "$CONF" | head -n1
}
has_key() { grep -qE "^[[:space:]]*$1[[:space:]]*=" "$CONF"; }

# ---- 解析库（节点解析 + 模式判定 + NVIDIA 用户态判据） ----
render_intel=""
render_nvidia=""
mode="unknown"
nvidia_ready() { return 1; }
if [ -r "$LIBEXEC/dri-node-resolve.sh" ]; then
    # shellcheck source=/dev/null
    . "$LIBEXEC/dri-node-resolve.sh"
    render_intel="$(dri_intel_render_node || true)"
    render_nvidia="$(dri_nvidia_render_node || true)"
    mode="$(dri_mode 2>/dev/null || echo unknown)"
    nvidia_ready() { dri_nvidia_userspace_ready; }
else
    echo "rakkord-sunshine-nvenc-prep: 找不到 $LIBEXEC/dri-node-resolve.sh，adapter_name 保持原值、encoder 只能按环境变量决定。" >&2
fi

# ---- 0. 设备节点自愈（模块已加载但节点缺失时才动手） ----
if [ -d /sys/module/nvidia ]; then
    missing=0
    for d in /dev/nvidiactl /dev/nvidia0 /dev/nvidia-uvm; do [ -c "$d" ] || missing=1; done
    if [ "$missing" = 1 ] && [ -x /usr/bin/nvidia-modprobe ]; then
        echo "rakkord-sunshine-nvenc-prep: NVIDIA 设备节点不全，调用 nvidia-modprobe 补齐。"
        /usr/bin/nvidia-modprobe -c 0 -c 255 || echo "rakkord-sunshine-nvenc-prep: nvidia-modprobe -c 0 -c 255 失败。" >&2
        /usr/bin/nvidia-modprobe -u -c 0     || echo "rakkord-sunshine-nvenc-prep: nvidia-modprobe -u -c 0 失败。" >&2
    fi
fi

# ---- 1. 算出两个键的目标值 ----
cur_adapter="$(get_key adapter_name)"
cur_encoder="$(get_key encoder)"

# adapter_name：按模式选渲染卡；显式覆盖优先；解析不到就保持原值。
if [ -n "${SUNSHINE_ADAPTER_NODE:-}" ]; then
    want_adapter="$SUNSHINE_ADAPTER_NODE"
else
    want_adapter="$cur_adapter"
    case "$mode" in
        nvidia)
            [ -n "$render_nvidia" ] && want_adapter="$render_nvidia" ;;
        intel)
            [ -n "$render_intel" ] && want_adapter="$render_intel" ;;
        *)
            # mixed/unknown：保守，谁在本机且驱动可用就用谁（Intel 优先，与方案 A 一致）
            if [ -n "$render_intel" ]; then want_adapter="$render_intel"
            elif [ -n "$render_nvidia" ]; then want_adapter="$render_nvidia"
            fi ;;
    esac
fi

mode_env="${SUNSHINE_ENCODER_GPU:-auto}"
case "$mode_env" in
    vaapi) want_encoder=vaapi ;;
    nvenc) want_encoder=nvenc ;;
    *)
        if nvidia_ready; then
            want_encoder=nvenc
        else
            want_encoder=vaapi
            echo "rakkord-sunshine-nvenc-prep: NVIDIA 用户态未就绪（需 /dev/nvidiactl、/dev/nvidia0、/dev/nvidia-uvm、libcuda.so.1、libnvidia-encode.so.1），encoder 用 vaapi。"
        fi
        ;;
esac

# nvidia 模式下的额外说明：encoder=nvenc 时 Sunshine 会用 NVENC_GL 零拷贝，
# 它需要 NVIDIA 的 card 节点（nvidia-drm modeset=1）。缺了不阻塞（Sunshine 会回退），
# 但要明确说出来，免得重启后对着"为什么帧要过 CPU"猜。
if [ "$mode" = nvidia ] && [ "$want_encoder" = nvenc ]; then
    nv_card="$(dri_card_node_of_vendor 0x10de 2>/dev/null || true)"
    if [ -n "$nv_card" ]; then
        echo "rakkord-sunshine-nvenc-prep: nvidia 模式，NVIDIA card 节点 $nv_card 在场（NVENC_GL 零拷贝路径可用）。"
    else
        echo "rakkord-sunshine-nvenc-prep: nvidia 模式，但没有 NVIDIA card 节点（nvidia-drm 未以 modeset=1 加载？）—— NVENC 仍可用，但 DMA-BUF 转 CUDA 的零拷贝路径会退化。" >&2
    fi
fi

case "$mode" in
    nvidia) [ -z "$render_nvidia" ] && echo "rakkord-sunshine-nvenc-prep: nvidia 模式但解析不到 NVIDIA render 节点，adapter_name 保持原值 ${cur_adapter:-<空>}。" >&2 ;;
    intel)  [ -z "$render_intel" ]  && echo "rakkord-sunshine-nvenc-prep: intel 模式但解析不到 Intel render 节点，adapter_name 保持原值 ${cur_adapter:-<空>}。" >&2 ;;
esac
if ! has_key adapter_name; then
    want_adapter="$cur_adapter"
    echo "rakkord-sunshine-nvenc-prep: $CONF 里没有 adapter_name 键，不新增。" >&2
fi
if ! has_key encoder; then
    want_encoder="$cur_encoder"
    echo "rakkord-sunshine-nvenc-prep: $CONF 里没有 encoder 键，不新增。" >&2
fi

# ---- 2. 幂等：没变化就直接退出 ----
if [ "$cur_adapter" = "$want_adapter" ] && [ "$cur_encoder" = "$want_encoder" ]; then
    echo "rakkord-sunshine-nvenc-prep: 无需改动（mode=$mode, encoder=$cur_encoder, adapter_name=$cur_adapter）。"
    exit 0
fi

# ---- 3. 备份（只在第一次改动前留一份，之后不覆盖） ----
bak="$CONF.bak-before-nvenc-prep"
if [ ! -e "$bak" ]; then
    cp -p "$CONF" "$bak" && echo "rakkord-sunshine-nvenc-prep: 备份原配置 -> $bak"
fi

# ---- 4. 一次 awk 改写 + rename（原子，不出现改了一半） ----
tmp="$(mktemp "$CONF.tmp-XXXXXX")" || { echo "rakkord-sunshine-nvenc-prep: mktemp 失败，跳过。" >&2; exit 0; }
trap 'rm -f "$tmp"' EXIT

awk -v adapter="$want_adapter" -v encoder="$want_encoder" '
    {
        if (!done_a && $0 ~ /^[[:space:]]*adapter_name[[:space:]]*=/) {
            print "adapter_name = " adapter; done_a = 1; next
        }
        if (!done_e && $0 ~ /^[[:space:]]*encoder[[:space:]]*=/) {
            print "encoder = " encoder; done_e = 1; next
        }
        print
    }
' "$CONF" > "$tmp" || { echo "rakkord-sunshine-nvenc-prep: awk 改写失败，保持原文件。" >&2; exit 0; }

chmod --reference="$CONF" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
chown --reference="$CONF" "$tmp" 2>/dev/null || true
mv -f "$tmp" "$CONF" || { echo "rakkord-sunshine-nvenc-prep: mv 覆盖失败，保持原文件。" >&2; exit 0; }
trap - EXIT

[ "$cur_adapter" != "$want_adapter" ] && echo "rakkord-sunshine-nvenc-prep: adapter_name: ${cur_adapter:-<空>} -> $want_adapter"
[ "$cur_encoder" != "$want_encoder" ] && echo "rakkord-sunshine-nvenc-prep: encoder: ${cur_encoder:-<空>} -> $want_encoder"
exit 0
