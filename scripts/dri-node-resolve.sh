#!/usr/bin/env bash
# dri-node-resolve.sh —— 把 DRM render 节点的稳定标识（PCI 地址）解析成当前这次
# 启动里真实的 /dev/dri/renderD<num> 路径。
#
# 为什么不能直接写 by-path 符号链接：
#   * Selkies 的 display_utils.parse_dri_node_to_index()（selkies/src/selkies/display_utils.py:2581）
#     硬性要求字符串以 '/dev/dri/renderD' 开头，再 split('renderD') 取数字；传符号链接
#     会直接 return -1（= 关闭硬件编码）。
#   * pixelflux 的 get_gpu_driver() / get_pci_bus_id()（pixelflux/pixelflux/src/lib.rs:921、
#     src/encoders/nvenc.rs:906）同样按 '/sys/class/drm/renderD{128+index}' 读 sysfs，
#     编码器选择只认整数 index。
#   所以符号链接必须**在启动前解析成真实路径**再用。
#
# 解析顺序（逐级兜底）：
#   1. /dev/dri/by-path/pci-<addr>-render   —— udev 按 PCI 地址生成的稳定链接，首选
#   2. 扫 /sys/class/drm/renderD*/device 的 uevent PCI_SLOT_NAME 匹配 PCI 地址
#   3. 按 /sys/class/drm/renderD*/device/vendor 匹配 PCI vendor id（最后兜底）
#
# 任务 007 后的消费者（两种模式都要对）：
#   * scripts/selkies-dri-exec.sh —— **跟随 KWin 实际打开的 render 节点**
#     （渲染卡=编码卡；跨卡时 KWin 后端每帧丢帧）；
#   * sunshine/libexec/rakkord-sunshine-nvenc-prep.sh —— adapter_name 按当前模式指向对应卡；
#   * scripts/verify-nvenc.sh —— 按 dri_mode() 分支断言两种模式的模块/节点/选卡；
#   * system/sbin/rakko-gpu-mode（装到 /usr/local/sbin） —— 只写 /etc/modprobe.d、/etc/modules-load.d，不用本库。
#
# 模式（dri_mode）：
#   nvidia = i915 不在、nvidia_drm 在（KWin / Selkies / Sunshine 全走 P620）；
#   intel  = i915 在、nvidia_drm 不在（任务 005 的方案 A：KWin/Selkies 走 Intel，
#            NVIDIA 只提供 CUDA/NVENC，Sunshine 走共享内存上传）。
#
# 用法（既可 source 也可直接执行）：
#   source dri-node-resolve.sh
#   dri_render_node 0000:00:02.0 0x8086      # -> /dev/dri/renderD129
#   ./dri-node-resolve.sh --selftest
#
# 解析不到时输出空串并返回 1 —— 调用方必须自己决定兜底，不要假设一定有值。

# 把 '0000:00:02.0' / '00:02.0' / '0:2:0' 等写法归一成 '0000:00:02.0'
dri_normalize_pci() {
    local a="${1:-}"
    case "$a" in
        *:*:*.*) ;;                      # 已含域或为 b:d.f
        *) return 1 ;;
    esac
    local domain bus devfn
    domain="${a%%:*}"
    local rest="${a#*:}"
    bus="${rest%%:*}"
    devfn="${rest#*:}"
    printf '%04x:%02x:%s\n' "$((16#$domain))" "$((16#$bus))" "$devfn"
}

# dri_render_node <pci-addr> [vendor-id]
#   pci-addr  : '0000:00:02.0' 形式（也接受 '00:02.0'）
#   vendor-id : 可选，'0x8086' 形式，最后兜底用
dri_render_node() {
    local pci_addr vendor_id norm
    pci_addr="${1:-}"
    vendor_id="${2:-}"
    [ -n "$pci_addr" ] || return 1
    norm="$(dri_normalize_pci "$pci_addr")" || return 1

    # 1) by-path 稳定链接
    local link="/dev/dri/by-path/pci-${norm}-render"
    if [ -L "$link" ] || [ -e "$link" ]; then
        local target
        target="$(readlink -f "$link" 2>/dev/null)"
        if [ -n "$target" ] && [ -e "$target" ]; then
            printf '%s\n' "$target"
            return 0
        fi
    fi

    # 2) 扫 sysfs：uevent 里的 PCI_SLOT_NAME
    local dev slot base
    for dev in /sys/class/drm/renderD*/device; do
        [ -e "$dev" ] || continue
        slot="$(sed -n 's/^PCI_SLOT_NAME=//p' "$dev/uevent" 2>/dev/null | head -n1)"
        if [ -z "$slot" ]; then
            slot="$(basename "$(readlink -f "$dev" 2>/dev/null)")"
        fi
        if [ -n "$slot" ] && [ "$slot" = "$norm" ]; then
            base="$(basename "$(dirname "$dev")")"
            [ -e "/dev/dri/$base" ] && { printf '/dev/dri/%s\n' "$base"; return 0; }
        fi
    done

    # 3) 按 vendor id 兜底
    if [ -n "$vendor_id" ]; then
        for dev in /sys/class/drm/renderD*/device; do
            [ -e "$dev" ] || continue
            if [ "$(cat "$dev/vendor" 2>/dev/null)" = "$vendor_id" ]; then
                base="$(basename "$(dirname "$dev")")"
                [ -e "/dev/dri/$base" ] && { printf '/dev/dri/%s\n' "$base"; return 0; }
            fi
        done
    fi

    return 1
}

# 这台机器的固定拓扑：Intel UHD 630 (00:02.0) + NVIDIA Quadro P620 (01:00.0)
# 这两条是**硬件**事实，与驱动/节点编号无关，重启不会变。
DRI_INTEL_PCI="${DRI_INTEL_PCI:-0000:00:02.0}"
DRI_INTEL_VENDOR="${DRI_INTEL_VENDOR:-0x8086}"
DRI_NVIDIA_PCI="${DRI_NVIDIA_PCI:-0000:01:00.0}"
DRI_NVIDIA_VENDOR="${DRI_NVIDIA_VENDOR:-0x10de}"

dri_intel_render_node()  { dri_render_node "$DRI_INTEL_PCI"  "$DRI_INTEL_VENDOR"; }
dri_nvidia_render_node() { dri_render_node "$DRI_NVIDIA_PCI" "$DRI_NVIDIA_VENDOR"; }

# 打印某个 DRM 节点（/dev/dri/renderD129、renderD129、card1…）的内核驱动名。
# 连接器（card1-DP-5 之类）没有 dev 属性，会返回空串。
dri_drm_driver_of() {
    local name
    name="$(basename "${1:-}")"
    [ -n "$name" ] && [ -e "/sys/class/drm/$name/dev" ] || return 1
    local drv
    drv="$(readlink -f "/sys/class/drm/$name/device/driver" 2>/dev/null)"
    [ -n "$drv" ] || return 1
    basename "$drv"
}

# 列出当前由指定驱动（如 nvidia / i915）持有的 DRM 设备节点，每行一个 /dev/dri/<name>。
# 用 /sys/class/drm/<name>/dev 是否存在来区分 DRM 设备与连接器。
dri_drm_nodes_with_driver() {
    local want="${1:-}" d name drv
    [ -n "$want" ] || return 1
    for d in /sys/class/drm/*; do
        [ -e "$d/dev" ] || continue
        name="$(basename "$d")"
        drv="$(readlink -f "$d/device/driver" 2>/dev/null)"
        [ -n "$drv" ] || continue
        [ "$(basename "$drv")" = "$want" ] || continue
        [ -e "/dev/dri/$name" ] && printf '/dev/dri/%s\n' "$name"
    done
}

# 列出指定 PCI vendor（如 0x10de）持有的 DRM 设备节点，每行一个 "/dev/dri/<name>（<driver>）"。
# 用 vendor 而不是驱动名，是为了在"nvidia 驱动没接管（nouveau 还在）"时也能发现问题：
# 方案要求 NVIDIA 这块卡**不论谁驱动都不该有 DRM 节点**。
dri_drm_nodes_of_vendor() {
    local want="${1:-}" d name vendor drv
    [ -n "$want" ] || return 1
    for d in /sys/class/drm/*; do
        [ -e "$d/dev" ] || continue
        name="$(basename "$d")"
        vendor="$(cat "$d/device/vendor" 2>/dev/null)"
        [ "$vendor" = "$want" ] || continue
        [ -e "/dev/dri/$name" ] || continue
        drv="$(readlink -f "$d/device/driver" 2>/dev/null)"
        printf '/dev/dri/%s（%s）\n' "$name" "$(basename "${drv:-未知}")"
    done
}

# ldconfig 的绝对路径：普通用户 shell 的 PATH 里没有 /sbin（004 §4），
# 而 systemd user service 的 PATH 里有 /usr/sbin —— 两条路都要能用。
dri_ldconfig() {
    if [ -x /sbin/ldconfig ]; then printf '/sbin/ldconfig\n'
    elif [ -x /usr/sbin/ldconfig ]; then printf '/usr/sbin/ldconfig\n'
    else command -v ldconfig 2>/dev/null
    fi
}

# NVIDIA 专有驱动的用户态是否就绪（nouveau 不提供 /dev/nvidia*，也不带 NVENC）。
# 判据（任务 005 定的四条）：/dev/nvidiactl、/dev/nvidia0、/dev/nvidia-uvm + libcuda。
# /dev/nvidia-uvm 必须在场：CUDA 初始化需要它，而它不会由内核/udev 自动创建
# （见 /etc/systemd/system/rakko-nvidia-device-nodes.service 的注释）。
# 设备节点不全时直接返回，避免每次启动都跑一遍 ldconfig 缓存扫描。
dri_nvidia_userspace_ready() {
    [ -c /dev/nvidiactl ] && [ -c /dev/nvidia0 ] && [ -c /dev/nvidia-uvm ] || return 1
    local ldc cache
    ldc="$(dri_ldconfig)" || return 1
    [ -n "$ldc" ] || return 1
    cache="$("$ldc" -p 2>/dev/null)" || return 1
    # 用 here-string，不要用 `printf | grep -q`：grep -q 命中即退出会让 printf 收到
    # SIGPIPE，在 set -o pipefail 下整条管道返回非 0 → 就绪判据恒为假（实测踩到，
    # 后果是重启后 Sunshine 永远停在 vaapi）。
    grep -q 'libcuda\.so\.1' <<<"$cache" || return 1
    grep -q 'libnvidia-encode\.so\.1' <<<"$cache" || return 1
    return 0
}

# 某个 DRM 节点的 PCI vendor id（'0x8086' / '0x10de'），失败输出空串。
dri_node_vendor() {
    local name
    name="$(basename "${1:-}")"
    [ -n "$name" ] && [ -e "/sys/class/drm/$name/device/vendor" ] || return 1
    cat "/sys/class/drm/$name/device/vendor" 2>/dev/null
}

# 某个 vendor 的 **card**（primary）节点。Sunshine 的 display_is_nvidia 路径要用它：
# src/platform/linux/cuda.cpp:354-393 的 open_drm_fd_for_cuda_device() 在
# /sys/bus/pci/devices/<pci>/drm/ 下只认 "card*"，拿不到就返回 -1 -> NVENC_GL 初始化失败。
# 所以 nvidia 模式下 nvidia-drm 必须 modeset=1（只有它注册 card 节点）。
dri_card_node_of_vendor() {
    local want="${1:-}" d name
    [ -n "$want" ] || return 1
    for d in /sys/class/drm/card[0-9]*; do
        [ -e "$d/dev" ] || continue
        name="$(basename "$d")"
        [ "$(cat "$d/device/vendor" 2>/dev/null)" = "$want" ] || continue
        [ -e "/dev/dri/$name" ] && { printf '/dev/dri/%s\n' "$name"; return 0; }
    done
    return 1
}

# 当前**运行中**的模式：nvidia / intel / mixed / unknown。
# 先看模块组合（这才是"模式"的定义），再看 DRM 节点兜底：
#   * i915 在 + nvidia_drm 不在            -> intel（NVIDIA 上可能还有 nouveau 节点，不影响）
#   * i915 不在 + nvidia_drm 在            -> nvidia
#   * 两个都在                             -> mixed（配置错了，verify 会报 FAIL）
#   * 两个都不在                           -> 看节点：只有 NVIDIA 节点且驱动是 nvidia 才算
#                                            nvidia（nouveau 抢卡时判 unknown，verify 报 FAIL）
dri_mode() {
    local names i915=0 nvdrm=0 has_intel=0 has_nv=0 nv_nodes
    names="$(lsmod 2>/dev/null | awk 'NR>1{print $1}')"
    grep -qx i915 <<<"$names" && i915=1
    grep -qx nvidia_drm <<<"$names" && nvdrm=1
    [ -n "$(dri_drm_nodes_of_vendor 0x8086 2>/dev/null || true)" ] && has_intel=1
    nv_nodes="$(dri_drm_nodes_with_driver nvidia 2>/dev/null || true)"
    [ -n "$nv_nodes" ] && has_nv=1

    if [ "$i915" = 1 ] && [ "$nvdrm" = 1 ]; then printf 'mixed\n'; return 0; fi
    if [ "$i915" = 1 ] && [ "$nvdrm" = 0 ]; then printf 'intel\n'; return 0; fi
    if [ "$i915" = 0 ] && [ "$nvdrm" = 1 ]; then printf 'nvidia\n'; return 0; fi
    # 两个模块都不在：只认"nvidia 驱动持有节点"这一种 nvidia 情况
    if [ "$has_nv" = 1 ] && [ "$has_intel" = 0 ]; then printf 'nvidia\n'; return 0; fi
    if [ "$has_intel" = 1 ] && [ "$has_nv" = 0 ]; then printf 'intel\n'; return 0; fi
    printf 'unknown\n'
}

# kwin_wayland --virtual 的 PID（只认 -x 精确进程名 + cmdline 含 --virtual：
# pgrep -f 会匹配到调用它的 bash 自己，见 004 §6.2）。
dri_kwin_pid() {
    local p
    for p in $(pgrep -x kwin_wayland 2>/dev/null); do
        if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- '--virtual'; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# KWin 此刻打开的 render 节点（读 /proc/<pid>/fd，同用户可读；不行就返回失败）。
# 这是"渲染卡"的唯一权威来源：KWin 后端只接受源自同一张卡的 DMA-BUF。
dri_kwin_render_node_now() {
    local pid fd target
    pid="$(dri_kwin_pid)" || return 1
    for fd in /proc/"$pid"/fd/*; do
        [ -e "$fd" ] || continue
        target="$(readlink -f "$fd" 2>/dev/null)" || continue
        case "$target" in
            /dev/dri/renderD*) printf '%s\n' "$target"; return 0 ;;
        esac
    done
    return 1
}

# 有限等待 KWin 打开 render 节点（默认 15 秒，每 0.2 秒探测一次）。
# 004 §6.1 的时序问题：remote-desktop-wayland.service 是 Type=simple，KWin 在 launcher
# 里是 `&` 后台起的，Selkies 的 ExecStart 可能早于 KWin 的 EGL 初始化完成。
# 用法：dri_kwin_render_node [timeout_sec]
dri_kwin_render_node() {
    local timeout="${1:-15}" i max node
    case "$timeout" in ''|*[!0-9]*) timeout=15 ;; esac
    max=$(( timeout * 5 ))
    for ((i = 0; i < max; i++)); do
        node="$(dri_kwin_render_node_now 2>/dev/null)" && { printf '%s\n' "$node"; return 0; }
        sleep 0.2
    done
    return 1
}

# 在"跟随 KWin"失败时的保守回退：两张卡都在 -> Intel（方案 A 的行为）；
# 只有 NVIDIA -> NVIDIA；都没有 -> 失败。
dri_fallback_render_node() {
    local intel nv
    intel="$(dri_intel_render_node 2>/dev/null || true)"
    nv="$(dri_nvidia_render_node 2>/dev/null || true)"
    if [ -n "$intel" ] && [ "$(dri_drm_driver_of "$intel" 2>/dev/null)" = i915 ]; then
        printf '%s\n' "$intel"; return 0
    fi
    if [ -n "$nv" ]; then
        printf '%s\n' "$nv"; return 0
    fi
    return 1
}

dri_selftest() {
    local a b nv_nodes intel_nodes mode kwin_node nv_card
    a="$(dri_intel_render_node)"  || true
    b="$(dri_nvidia_render_node)" || true
    mode="$(dri_mode)"
    printf '运行模式: %s\n' "$mode"
    printf 'Intel  %s -> %s\n' "$DRI_INTEL_PCI"  "${a:-<解析失败>}"
    printf 'NVIDIA %s -> %s\n' "$DRI_NVIDIA_PCI" "${b:-<解析失败>}"
    printf 'Intel card 节点: %s\n' "$(dri_card_node_of_vendor 0x8086 || echo '<无>')"
    printf 'NVIDIA card 节点: %s\n' "$(dri_card_node_of_vendor 0x10de || echo '<无>')"
    printf 'i915 持有的 DRM 节点: %s\n' "$(dri_drm_nodes_with_driver i915 | tr '\n' ' ')"
    nv_nodes="$(dri_drm_nodes_with_driver nvidia | tr '\n' ' ')"
    intel_nodes="$(dri_drm_nodes_of_vendor 0x8086 | tr '\n' ' ')"
    printf 'nvidia 持有的 DRM 节点: %s\n' "${nv_nodes:-<无>}"
    printf '0x8086 持有的 DRM 节点: %s\n' "${intel_nodes:-<无>}"
    kwin_node="$(dri_kwin_render_node_now 2>/dev/null || true)"
    printf 'KWin 打开的 render 节点: %s\n' "${kwin_node:-<没探测到>}"
    nv_card="$(dri_card_node_of_vendor 0x10de || true)"
    case "$mode" in
        intel)  printf '（方案 A：nvidia_drm 不该加载；NVIDIA 上若还有节点，驱动应是 nouveau，KWin 不该用它）\n' ;;
        nvidia) printf '（纯 NVIDIA 模式：i915 不该在，NVIDIA 应有 renderD + card 节点，驱动应是 nvidia）\n' ;;
        mixed)  printf '（异常：i915 与 nvidia_drm 同时加载 —— KWin 选卡不确定，跑 verify-nvenc.sh 确认）\n' ;;
        *)      printf '（异常：既没有可用的 Intel 也没有 nvidia 驱动的 DRM 节点）\n' ;;
    esac
    # 退出码：intel 模式看 Intel 节点；nvidia 模式看 NVIDIA 节点（且要有 card 节点）。
    case "$mode" in
        nvidia) [ -n "$b" ] && [ -n "$nv_card" ] ;;
        *)      [ -n "$a" ] ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        --selftest) dri_selftest ;;
        --mode)     dri_mode ;;
        --kwin-node) shift; dri_kwin_render_node "${1:-15}" ;;
        "")         dri_selftest ;;
        *)          dri_render_node "$@" ;;
    esac
fi
