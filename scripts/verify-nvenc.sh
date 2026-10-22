#!/usr/bin/env bash
# verify-nvenc.sh —— 任务 007 的验收脚本：**两种模式都能验**（自动识别）。
#
# 模式（dri_mode，看运行中的内核状态，不看配置文件）：
#   intel  = 方案 A：i915 在、nvidia_drm 不在；KWin/Selkies 走 Intel 同卡 VAAPI；
#            Sunshine 走 P620 NVENC（portal 共享内存 -> cudaMemcpy2D 上传）。
#   nvidia = 纯 NVIDIA：i915 不在、nvidia_drm 在（modeset=1）；KWin/Selkies/Sunshine
#            全走 P620（Selkies 是同卡零拷贝 NVENC：EGLImage -> CUDA）。
#
# 只读脚本：不启动/停止任何服务，不改任何配置。
#
# 用法：
#   scripts/verify-nvenc.sh              # 全量检查
#   scripts/verify-nvenc.sh --quiet      # 只打 FAIL/WARN 和汇总
#
# 退出码：0 = 全部必须项通过且 SKIP=0（画面对应证据齐全）；
#         1 = 有 FAIL；2 = NVIDIA 驱动用户态尚未生效（多半还没重启，或模块/设备节点没起来）；
#         3 = 必须项通过但有 SKIP（缺出流证据，**画面未验证**）—— 不能再当成验收通过。
#
# 日志只取**本次服务启动之后**的行（Selkies 用 systemd InvocationID，
# Sunshine 用 ExecMainStartTimestamp 截断 sunshine.log）—— 旧日志一律不算证据。
# 带「需客户端」的项要真正出流后才有日志，没客户端时记 SKIP，不是失败；
# 但 enc_cfg=nvenc 而日志里根本没有编码器探测记录时记 FAIL（任务 006 §5 的 V1）。
#
# 「有客户端」= ss 看到 8090 上 Selkies 的 ESTAB（浏览器/WebSocket，含经
# cloudflared/tailscale serve/socat 从回环转发进来的连接）或 Moonlight 端口。
# 有客户端时关键项改为 FAIL（不是 SKIP）：NVENC/VAAPI 初始化成功、零拷贝路径、
# 无 Pixman/Readback/跨卡/严格模式拒绝类降级信号、KWin screencast 帧数在增长。
# 空结果/解析失败一律 skip 或 bad，不再打 ok（任务 008 的 P0-⑤）。

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

PASS=0; FAIL=0; WARN=0; SKIP=0
declare -a FAILED_ITEMS=()
declare -a SKIPPED_ITEMS=()

c_ok()   { printf '\033[32m%s\033[0m' "$1"; }
c_bad()  { printf '\033[31m%s\033[0m' "$1"; }
c_warn() { printf '\033[33m%s\033[0m' "$1"; }
c_skip() { printf '\033[36m%s\033[0m' "$1"; }

section() { [ "$QUIET" = 1 ] || printf '\n== %s ==\n' "$1"; }
# 注意：ok/bad/warn/skip 一律显式 return 0 —— 否则函数末尾的
# `[ -n "${2:-}" ] && printf` 在无第二参数时返回 1，会让 `A && bad || ok`
# 这种写法把 FAIL 和 PASS 同时打印出来（005 干跑时实测踩到）。
ok()   { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || printf '  [%s] %s\n' "$(c_ok PASS)" "$1"; return 0; }
bad()  { FAIL=$((FAIL+1)); FAILED_ITEMS+=("$1"); printf '  [%s] %s\n' "$(c_bad FAIL)" "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; return 0; }
warn() { WARN=$((WARN+1)); printf '  [%s] %s\n' "$(c_warn WARN)" "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); SKIPPED_ITEMS+=("$1"); [ "$QUIET" = 1 ] || printf '  [%s] %s\n' "$(c_skip SKIP)" "$1"; return 0; }
info() { [ "$QUIET" = 1 ] || printf '         %s\n' "$1"; return 0; }

# KWin screencast 的帧计数：pixelflux 的 KWIN_CAPTURE_STATS（frames=）与 KWin 自己的
# KWIN_SCREENCAST_STATS（queue=）都算证据；打印 "最小 最大"（没有任何统计行则无输出）。
# 最小 != 最大即证明帧数在增长（历史统计行之间），不必只靠现场观察窗口。
stat_frame_range() {
    awk '
        /KWIN_CAPTURE_STATS/    { if (match($0, /frames=[0-9]+/)) { v = substr($0, RSTART+7, RLENGTH-7)+0; if (n == 0 || v < min) min = v; if (n == 0 || v > max) max = v; n++ } }
        /KWIN_SCREENCAST_STATS/ { if (match($0, /queue=[0-9]+/))  { v = substr($0, RSTART+6, RLENGTH-6)+0; if (n == 0 || v < min) min = v; if (n == 0 || v > max) max = v; n++ } }
        END { if (n > 0) print min, max }
    '
}

# 统计行的原始文本（Selkies 本次 invocation + KWin 本次启动），供帧数增长断言用。
screencast_stat_lines() {
    { if [ -n "$SEL_INV" ]; then
          journalctl --user -u "$SELKIES_UNIT" _SYSTEMD_INVOCATION_ID="$SEL_INV" --no-pager 2>/dev/null \
              | grep -E 'KWIN_CAPTURE_STATS|KWIN_SCREENCAST_STATS'
      fi
      if [ -n "$KWIN_SINCE" ]; then
          journalctl --user -u "$WAYLAND_UNIT" --since "$KWIN_SINCE" --no-pager 2>/dev/null \
              | grep -E 'KWIN_CAPTURE_STATS|KWIN_SCREENCAST_STATS'
      fi
    } || true
}

LIBEXEC="${SELKIES_LIBEXEC_DIR:-$HOME/.local/libexec}"
RESOLVER="$LIBEXEC/dri-node-resolve.sh"

# ---------------------------------------------------------------- 0. 解析库
section "0. 节点解析库与模式识别"
RESOLVER_OK=0
if [ -r "$RESOLVER" ]; then
    # shellcheck source=/dev/null
    . "$RESOLVER"
    RESOLVER_OK=1
    ok "解析库可读：$RESOLVER"
else
    # 006 §5 的 V3：库缺失时必须报 FAIL，不能因为后面的解析结果为空就打 ok。
    bad "解析库缺失：$RESOLVER" "从仓库同步：install -m0755 scripts/dri-node-resolve.sh $LIBEXEC/"
fi

if [ "$RESOLVER_OK" = 1 ]; then
    MODE="$(dri_mode 2>/dev/null || echo unknown)"
    INTEL_NODE="$(dri_intel_render_node 2>/dev/null || true)"
    NVIDIA_NODE="$(dri_nvidia_render_node 2>/dev/null || true)"
    NVIDIA_CARD="$(dri_card_node_of_vendor 0x10de 2>/dev/null || true)"
else
    MODE="unknown"
    INTEL_NODE="$(readlink -f "/dev/dri/by-path/pci-${DRI_INTEL_PCI:-0000:00:02.0}-render" 2>/dev/null || true)"
    NVIDIA_NODE="$(readlink -f "/dev/dri/by-path/pci-${DRI_NVIDIA_PCI:-0000:01:00.0}-render" 2>/dev/null || true)"
    NVIDIA_CARD="$(ls /sys/class/drm/card[0-9]*/device/vendor 2>/dev/null | while read -r v; do [ "$(cat "$v")" = 0x10de ] && dirname "$(dirname "$v")"; done | head -n1 | xargs -r basename)"
    [ -n "$NVIDIA_CARD" ] && NVIDIA_CARD="/dev/dri/$NVIDIA_CARD"
fi
INTEL_NAME="$(basename "${INTEL_NODE:-none}")"
NVIDIA_NAME="$(basename "${NVIDIA_NODE:-none}")"

case "$MODE" in
    intel|nvidia) ok "运行模式 = $MODE" ;;
    mixed)  bad "运行模式 = mixed：i915 与 nvidia_drm 同时加载" "KWin 选卡不确定。跑 sudo rakko-gpu-mode {nvidia|intel} 后重启" ;;
    *)      bad "运行模式 = unknown：没有可用的 Intel 或 nvidia 驱动的 DRM 节点" "看 sudo rakko-gpu-mode status" ;;
esac
info "Intel  0000:00:02.0 -> ${INTEL_NODE:-<解析失败>}"
info "NVIDIA 0000:01:00.0 -> ${NVIDIA_NODE:-<解析失败>}（card 节点：${NVIDIA_CARD:-<无>}）"
info "当前 /dev/dri: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"

# 本模式期望的"渲染卡节点"（KWin 与 Selkies 都必须是它）
case "$MODE" in
    nvidia) EXPECT_NODE="$NVIDIA_NODE" ;;
    intel)  EXPECT_NODE="$INTEL_NODE" ;;
    *)      EXPECT_NODE="" ;;
esac
EXPECT_NAME="$(basename "${EXPECT_NODE:-none}")"

# ---------------------------------------------------------------- 1. 驱动门禁
section "1. NVIDIA 驱动用户态是否已生效（门禁）"
if [ -d /sys/module/nvidia ] && [ -c /dev/nvidiactl ] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    DRIVER_LIVE=1
    ok "nvidia 模块已加载、/dev/nvidiactl 存在、nvidia-smi 可用"
else
    printf '  [%s] NVIDIA 驱动用户态尚未生效（多半是还没重启，或模块/设备节点没起来）\n' "$(c_bad FAIL)"
    printf '         lsmod:        %s\n' "$(lsmod | awk '$1 ~ /^nvidia/ {printf "%s ", $1}')"
    printf '         /dev/nvidia*: %s\n' "$(ls /dev/nvidia* 2>/dev/null | tr '\n' ' ')"
    printf '         nouveau:      %s\n' "$(lsmod | awk '$1=="nouveau"{print "已加载"}')"
    printf '         modules-load: %s\n' "$(systemctl is-active systemd-modules-load.service 2>/dev/null)"
    printf '         节点 unit:    %s (%s)\n' "$(systemctl is-active rakko-nvidia-device-nodes.service 2>/dev/null)" \
                                             "$(systemctl show -p ConditionResult --value rakko-nvidia-device-nodes.service 2>/dev/null)"
    printf '         先重启机器再跑本脚本；若已重启仍如此，见 tasks/gpu-nvenc/007.report.md 的「没把握的点」。\n'
    exit 2
fi
info "nvidia-smi: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -n1)"

# 任务 010：驱动分支核对。580 是最后一个支持 Pascal（P620/GP107）的分支，590+ 不支持；
# 安装侧用 NVIDIA 官方的 nvidia-driver-pinning-580 把 apt 锁在 580*。
# 这里只做**提示**不做 FAIL —— 回退到 Debian 550 驱动时
# 分支号本来就不是 580，不该因此判失败。
# modinfo 在 /usr/sbin（= ../bin/kmod），普通用户 PATH 里没有，这里显式解析。
MODINFO_BIN="$(command -v modinfo 2>/dev/null || true)"
if [ -z "$MODINFO_BIN" ]; then
    for _c in /usr/sbin/modinfo /sbin/modinfo; do
        [ -x "$_c" ] && { MODINFO_BIN="$_c"; break; }
    done
fi
MODINFO_BIN="${MODINFO_BIN:-modinfo}"
DISK_NV_VER="$("$MODINFO_BIN" -F version nvidia 2>/dev/null || true)"
RUN_NV_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
info "内核模块版本: ${DISK_NV_VER:-（读不到）}   用户态版本: ${RUN_NV_VER:-（读不到）}"
case "$DISK_NV_VER" in
    580.*) ok "驱动分支 = 580（Pascal 的最后一个支持分支）" ;;
    '')    warn "读不到 /lib/modules 里的 nvidia 模块版本" ;;
    *)     warn "驱动分支不是 580（当前 $DISK_NV_VER）：P620/GP107 只被 ≤580 支持" \
                "若这是有意的回退（Debian 550），忽略；否则查 dpkg -l nvidia-kernel-dkms 与 /etc/apt/preferences.d/nvidia-driver-pin" ;;
esac
# 两套驱动并存检测（010 要求"不要留两套"）：Debian 打包的 nvidia-current* 应该已经被清掉。
if "$MODINFO_BIN" -k "$(uname -r)" nvidia-current >/dev/null 2>&1 \
   || compgen -G "/lib/modules/$(uname -r)/updates/dkms/nvidia-current*.ko*" >/dev/null 2>&1 \
   || compgen -G "/usr/lib/modules/$(uname -r)/updates/dkms/nvidia-current*.ko*" >/dev/null 2>&1; then
    warn "内核里同时存在 Debian 打包的 nvidia-current*（两套驱动）" \
         "dpkg -l | grep nvidia-kernel-dkms；任务 010 用了 NVIDIA 官方 580，应该只剩真名 nvidia*.ko"
fi

# ---------------------------------------------------------------- 2. 模块
section "2. 内核模块（按模式断言）"
lsmod_names="$(lsmod | awk 'NR>1{print $1}')"
if grep -qx nouveau <<<"$lsmod_names"; then
    bad "nouveau 仍在加载（nvidia 驱动应该取代它）" "检查 /etc/modprobe.d/nvidia-blacklists-nouveau.conf 与 /etc/modprobe.d/00-rakko-gpu-mode.conf，并确认重启过"
else
    ok "nouveau 未加载"
fi
for m in nvidia nvidia_uvm; do
    grep -qx "$m" <<<"$lsmod_names" && ok "模块 $m 已加载" || bad "模块 $m 未加载"
done
if [ "$MODE" = nvidia ]; then
    if grep -qx i915 <<<"$lsmod_names"; then
        bad "i915 **被加载了**（nvidia 模式要求不加载）" \
            "查 /etc/modprobe.d/00-rakko-gpu-mode.conf 的 install i915 /bin/true 是否生效（sudo modprobe -n -v i915）并 update-initramfs -u；也可能是别的模块把 i915 拉起来了（modprobe --show-depends <mod>）"
    else
        ok "模块 i915 未加载（纯 NVIDIA 模式）"
    fi
    for m in nvidia_drm nvidia_modeset; do
        grep -qx "$m" <<<"$lsmod_names" && ok "模块 $m 已加载" || bad "模块 $m 未加载（nvidia 模式必需）" \
            "nvidia-drm 提供 GBM/EGL 与 card 节点；查 /etc/modprobe.d/00-rakko-gpu-mode.conf 的 options ... modeset=1 与 /etc/modules-load.d/zz-rakko-nvidia-drm.conf"
    done
else
    for m in nvidia_drm nvidia_modeset; do
        if grep -qx "$m" <<<"$lsmod_names"; then
            bad "模块 $m **被加载了**（intel 模式要求不加载）" \
                "它一加载 NVIDIA 就有 DRM 节点，KWin 可能改选 NVIDIA。查 /etc/modprobe.d/00-rakko-gpu-mode.conf 是否排在 nvidia.conf 之前、并 update-initramfs -u"
        else
            ok "模块 $m 未加载"
        fi
    done
    grep -qx i915 <<<"$lsmod_names" && ok "模块 i915 已加载（intel 模式）" || bad "模块 i915 未加载（intel 模式必需）"
fi
for d in /dev/nvidiactl /dev/nvidia0 /dev/nvidia-uvm; do
    [ -c "$d" ] && ok "$d 存在" || bad "$d 缺失" \
        "由 /etc/systemd/system/rakko-nvidia-device-nodes.service 创建；可手动跑 /usr/bin/nvidia-modprobe -c 0 -c 255 与 -u -c 0 复现"
done
LDCONFIG=/sbin/ldconfig          # 普通用户 shell 的 PATH 里没有 /sbin（004 §4），必须绝对路径
[ -x "$LDCONFIG" ] || LDCONFIG=/usr/sbin/ldconfig
LIBS="$("$LDCONFIG" -p 2>/dev/null)"
if [ -z "$LIBS" ]; then
    warn "$LDCONFIG -p 无输出，改用文件存在性检查"
    LIBS="$(ls /usr/lib/x86_64-linux-gnu/libcuda.so.1 /usr/lib/x86_64-linux-gnu/libnvidia-encode.so.1 2>/dev/null)"
fi
for l in 'libcuda\.so\.1' 'libnvidia-encode\.so\.1'; do
    grep -q "$l" <<<"$LIBS" && ok "用户态库 $l 可见" || bad "用户态库 $l 不在 ldconfig 缓存里"
done
if systemctl is-active --quiet nvidia-persistenced.service 2>/dev/null; then
    ok "nvidia-persistenced active（非必须项）"
else
    warn "nvidia-persistenced 未 active（不影响 NVENC；它只是持久化模式守护进程）"
fi

# ---------------------------------------------------------------- 3. DRM 节点
section "3. DRM 节点映射（按模式断言）"
if [ "$MODE" = nvidia ]; then
    [ -n "$NVIDIA_NODE" ] && [ -e "$NVIDIA_NODE" ] && ok "NVIDIA render 节点存在（$NVIDIA_NODE）" \
        || bad "NVIDIA render 节点解析/打开失败" "nvidia-drm 是否加载？（lsmod | grep nvidia_drm）"
    [ "$(dri_drm_driver_of "$NVIDIA_NODE" 2>/dev/null)" = nvidia ] && ok "NVIDIA 节点驱动 = nvidia" \
        || bad "NVIDIA 节点驱动 = $(dri_drm_driver_of "$NVIDIA_NODE" 2>/dev/null)（预期 nvidia；nouveau 说明 nvidia 没接管）"
    if [ -n "$NVIDIA_CARD" ] && [ -e "$NVIDIA_CARD" ]; then
        ok "NVIDIA card 节点存在（$NVIDIA_CARD）—— Sunshine 的 NVENC_GL 零拷贝路径可用"
    else
        warn "没有 NVIDIA card 节点（nvidia-drm 没以 modeset=1 加载？）" \
             "Sunshine 的 display_is_nvidia 路径需要 card 节点（cuda.cpp:354-393 只找 card*）：缺了会让 NVENC_GL 初始化失败、nvenc 探测失败。KWin 的 GBM 也可能起不来"
    fi
    INTEL_DRM="$(dri_drm_nodes_of_vendor 0x8086 2>/dev/null || true)"
    if [ -z "$INTEL_DRM" ]; then
        ok "Intel(0x8086) 没有任何 DRM 节点（i915 确实没加载）"
    else
        bad "Intel(0x8086) 仍有 DRM 节点：$(printf '%s' "$INTEL_DRM" | tr '\n' ' ')" \
            "i915 没被挡住：sudo modprobe -n -v i915 应打印 install /bin/true；改完 update-initramfs -u 并重启"
    fi
else
    [ -n "$INTEL_NODE" ] && [ -e "$INTEL_NODE" ] && ok "Intel render 节点存在" || bad "Intel render 节点解析/打开失败"
    [ "$(dri_drm_driver_of "$INTEL_NODE" 2>/dev/null)" = i915 ] && ok "Intel 节点驱动 = i915" \
        || bad "Intel 节点驱动 = $(dri_drm_driver_of "$INTEL_NODE" 2>/dev/null)（预期 i915）"
    NV_DRM_NODES="$(dri_drm_nodes_of_vendor 0x10de 2>/dev/null || true)"
    if [ -z "$NV_DRM_NODES" ]; then
        ok "NVIDIA(0x10de) 没有任何 DRM 节点（card*/renderD*）—— KWin 不可能选到它"
    else
        bad "NVIDIA(0x10de) 仍有 DRM 节点：$(printf '%s' "$NV_DRM_NODES" | tr '\n' ' ')" \
            "nvidia_drm 没被挡住：确认 /etc/modprobe.d/00-rakko-gpu-mode.conf 生效（modprobe -n -v nvidia-drm 应打印 install /bin/true）并 update-initramfs -u；若驱动显示 nouveau，说明 nvidia 没接管显卡"
    fi
    info "nvidia 驱动持有的 DRM 节点：$(dri_drm_nodes_with_driver nvidia 2>/dev/null | tr '\n' ' ')（空 = 预期）"
fi

# ---------------------------------------------------------------- 4. KWin
section "4. KWin 虚拟会话的选卡（必须打开 $EXPECT_NAME）"
KWIN_PID=""
for p in $(pgrep -x kwin_wayland 2>/dev/null); do
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- '--virtual'; then KWIN_PID="$p"; break; fi
done
KWIN_OPENED=""
if [ -z "$KWIN_PID" ]; then
    skip "没找到 kwin_wayland --virtual 进程"
else
    info "kwin_wayland PID=$KWIN_PID"
    # KWin 与我们在同一用户下，/proc/<pid>/fd 通常直接可读；不可读时才用 sudo -n 兜底
    KWIN_OPENED="$(ls -l "/proc/$KWIN_PID/fd" 2>/dev/null | grep -oE '/dev/dri/(renderD|card)[0-9]+' | sort -u | tr '\n' ' ')"
    if [ -z "$KWIN_OPENED" ]; then
        KWIN_OPENED="$(sudo -n ls -l "/proc/$KWIN_PID/fd" 2>/dev/null | grep -oE '/dev/dri/(renderD|card)[0-9]+' | sort -u | tr '\n' ' ')"
    fi
    if [ -z "$KWIN_OPENED" ]; then
        warn "读不到 KWin 打开的 DRM 节点（权限或它还没初始化完）"
    else
        info "KWin 打开的 DRM 节点: $KWIN_OPENED"
        if [ -n "$EXPECT_NODE" ]; then
            case " $KWIN_OPENED " in
                *" $EXPECT_NODE "*) ok "KWin 打开的是期望节点 ($EXPECT_NAME)" ;;
                *) bad "KWin 没有打开期望节点 ($EXPECT_NAME)" "它打开了: $KWIN_OPENED" ;;
            esac
        fi
        # 反向断言：另一种卡的节点不该出现（无论哪个模式）
        case "$MODE" in
            nvidia) case " $KWIN_OPENED " in
                        *" $INTEL_NODE "*) bad "KWin 打开了 Intel 节点" "nvidia 模式下 i915 不该在" ;;
                    esac ;;
            intel)  case " $KWIN_OPENED " in
                        *" $NVIDIA_NODE "*) bad "KWin 打开了 NVIDIA 节点 ($NVIDIA_NAME)" "与方案冲突：Selkies 会跨卡黑屏（004 §1）" ;;
                    esac ;;
        esac
    fi
fi

# ---------------------------------------------------------------- 5. Selkies
section "5. Selkies（渲染卡 = 编码卡 = KWin 的卡）"
SELKIES_UNIT=remote-desktop-selkies.service
WAYLAND_UNIT=remote-desktop-wayland.service
SEL_INV=""; KWIN_SINCE=""

# 客户端快照（§5/§6/§7 共用）：8090 上 Selkies 的 ESTAB —— 服务 Listen 在 127.0.0.1，
# 浏览器/WebSocket 客户端经 cloudflared/tailscale serve/socat 从回环转发进来，所以看的是
# 连接归属的 selkies-python3 进程，而不是对端 IP；没有进程归属时才退回"对端非回环"。
# Moonlight：配对/控制/串流端口（47984/47989/48010 + 视频/控制/音频 47998-48002）。
SELKIES_CLIENT=0; MOONLIGHT_CLIENT=0
selkies_ss=""; moon_ss=""
if command -v ss >/dev/null 2>&1; then
    selkies_ss="$(ss -tnp 2>/dev/null | awk '$1=="ESTAB" && ($4 ~ /:8090$/ || $5 ~ /:8090$/)')"
    moon_ss="$(ss -tnp 2>/dev/null | awk '$1=="ESTAB" && ($4 ~ /:(47984|47989|48010|47998|47999|48000|48002)$/ || $5 ~ /:(47984|47989|48010|47998|47999|48000|48002)$/)')"
else
    warn "找不到 ss，无法探测 8090/Moonlight 客户端连接"
fi
if [ -n "$selkies_ss" ]; then
    if grep -q 'selkies-python3' <<<"$selkies_ss"; then
        SELKIES_CLIENT=1
    elif printf '%s\n' "$selkies_ss" | awk '$5 !~ /^127\./ && $5 !~ /^\[::1\]/ {found=1} END{exit !found}'; then
        SELKIES_CLIENT=1
    fi
fi
[ -n "$moon_ss" ] && MOONLIGHT_CLIENT=1
info "客户端快照：Selkies(8090)=$([ "$SELKIES_CLIENT" = 1 ] && echo 有 || echo 无)  Moonlight=$([ "$MOONLIGHT_CLIENT" = 1 ] && echo 有 || echo 无)"
[ -n "$selkies_ss" ] && info "  ss 8090: $(head -n1 <<<"$selkies_ss" | tr -s ' ')"
[ -n "$moon_ss" ] && info "  ss Moonlight: $(head -n1 <<<"$moon_ss" | tr -s ' ')"

if ! systemctl --user is-active --quiet "$SELKIES_UNIT"; then
    bad "$SELKIES_UNIT 未在运行"
else
    ok "$SELKIES_UNIT active"
    SPID="$(systemctl --user show -p MainPID --value "$SELKIES_UNIT")"
    SENV="$(tr '\0' '\n' < "/proc/$SPID/environ" 2>/dev/null || true)"
    [ -z "$SENV" ] && SENV="$(sudo -n tr '\0' '\n' < "/proc/$SPID/environ" 2>/dev/null || true)"
    sdri="$(printf '%s\n' "$SENV" | sed -n 's/^DRI_NODE=//p')"
    sren="$(printf '%s\n' "$SENV" | sed -n 's/^DRINODE=//p')"
    info "进程环境 DRI_NODE=$sdri  DRINODE=$sren"
    # 核心断言（与模式无关）：渲染卡 = 编码卡，且跟 KWin 一致。
    if [ -n "$KWIN_OPENED" ] && [ -n "$EXPECT_NODE" ]; then
        [ "$sdri" = "$EXPECT_NODE" ] && ok "Selkies 编码卡 = KWin 的卡 ($sdri)" \
            || bad "Selkies DRI_NODE=$sdri，预期 $EXPECT_NODE" "看 journalctl --user -u $SELKIES_UNIT | grep selkies-dri-exec"
        [ "$sren" = "$EXPECT_NODE" ] && ok "Selkies 渲染卡 = KWin 的卡 ($sren)" \
            || bad "Selkies DRINODE=$sren，预期 $EXPECT_NODE"
        [ "$sdri" = "$sren" ] && ok "渲染卡 = 编码卡（同卡，pixelflux 不会走跨卡丢帧路径）" \
            || bad "渲染卡 ≠ 编码卡（DRI_NODE=$sdri, DRINODE=$sren）—— KWin 后端下会稳态黑屏（004 §1）"
    elif [ -n "$sdri" ] && [ "$sdri" = "$sren" ]; then
        skip "KWin 节点未知，只能确认 Selkies 内部渲染卡 = 编码卡（$sdri）"
    else
        bad "Selkies 的 DRI_NODE/DRINODE 不相等或为空（DRI_NODE=$sdri, DRINODE=$sren）"
    fi

    # 只看本次启动的日志：systemd InvocationID（004 §3.1 的 P0-3 修法）
    SEL_INV="$(systemctl --user show -p InvocationID --value "$SELKIES_UNIT" 2>/dev/null)"
    SEL_SINCE="$(systemctl --user show -p ExecMainStartTimestamp --value "$SELKIES_UNIT" 2>/dev/null)"
    if [ -n "$SEL_INV" ]; then
        LOGS="$(journalctl --user -u "$SELKIES_UNIT" _SYSTEMD_INVOCATION_ID="$SEL_INV" --no-pager 2>/dev/null)"
        info "日志范围：本次 invocation $SEL_INV（$(printf '%s\n' "$LOGS" | wc -l) 行）"
    else
        LOGS="$(journalctl --user -u "$SELKIES_UNIT" --since "$SEL_SINCE" --no-pager 2>/dev/null)"
        info "日志范围：--since $SEL_SINCE"
    fi
    if [ -z "$LOGS" ]; then
        if [ "$SELKIES_CLIENT" = 1 ]; then
            bad "有 Selkies 客户端但读不到本次启动的 $SELKIES_UNIT 日志 —— 无法验证画面" \
                "journalctl --user -u $SELKIES_UNIT 应能读到；检查 InvocationID 与日志权限"
        else
            skip "读不到本次启动的 Selkies 日志，所有日志类检查都没做"
        fi
    else
        # 降级信号：出现任意一条就是"没画面 / CPU 回退 / 跨卡"的直接证据（008 的 P0-⑤）。
        # RETAINED_GPU_FRAME 是 pixelflux 内部的返回码，不单独打印，所以把它的降级/恢复
        # 文案（demoting … readback、rebuilding readback HW encoder）一并算作信号。
        degrade_hits=""
        for pat in 'Rendering and Encoding GPUs differ' 'Forcing Readback' 'Readback path' \
                   'Pixman' '严格模式拒绝' 'RETAINED_GPU_FRAME' 'RETAINED_CPU_FRAME' \
                   'PipeWire 协商结果没有 DMA-BUF modifier' \
                   'demoting the zero-copy encoder to readback' 'demoting to readback encode' \
                   'rebuilding readback HW encoder'; do
            if grep -qF -- "$pat" <<<"$LOGS"; then
                degrade_hits+="$(grep -F -- "$pat" <<<"$LOGS" | tail -n1)"$'\n'
            fi
        done
        if [ -n "$degrade_hits" ]; then
            bad "Selkies 本次启动的日志里有降级信号（$(printf '%s' "$degrade_hits" | grep -c .) 类）" \
                "$(printf '%s' "$degrade_hits" | head -n3 | tr '\n' '|')"
        elif [ "$SELKIES_CLIENT" = 1 ] || grep -qE 'Encoder initialized successfully|Decision: .*path active' <<<"$LOGS"; then
            ok "没有 Pixman/Readback/跨卡/严格模式拒绝/RETAINED_GPU_FRAME 类降级信号"
        else
            skip "日志里还没有编码器/路径决策记录，无法断言降级信号不存在（需客户端出流）"
        fi
        gl_line="$(grep -oE 'Initializing GL Renderer using device: [^ ]+' <<<"$LOGS" | tail -n1)"
        if [ -z "$gl_line" ]; then
            if [ "$SELKIES_CLIENT" = 1 ]; then
                bad "有 Selkies 客户端但本次日志里没有 'Initializing GL Renderer' 行" \
                    "客户端可能只打开了页面还没开始串流；先开始一次串流再跑"
            else
                skip "日志里还没有 GL Renderer 行（需客户端：出流时才初始化 capture）"
            fi
        elif [ -n "$EXPECT_NAME" ] && grep -q "$EXPECT_NAME" <<<"$gl_line"; then
            ok "GL Renderer 用的是期望节点（$gl_line）"
        else
            bad "GL Renderer 不是期望节点 $EXPECT_NAME：$gl_line"
        fi
        enc_line="$(grep -oE 'Encode Node Index: [0-9]+ \| Driver: .*' <<<"$LOGS" | tail -n1)"
        if [ -z "$enc_line" ]; then
            if [ "$SELKIES_CLIENT" = 1 ]; then
                bad "有 Selkies 客户端但本次日志里没有 'Encode Node Index' 行" \
                    "客户端可能只打开了页面还没开始串流；先开始一次串流再跑"
            else
                skip "日志里还没有 'Encode Node Index' 行（需客户端）"
            fi
        elif [ "$MODE" = nvidia ]; then
            grep -q 'nvidia' <<<"$enc_line" && ok "编码节点驱动 = nvidia（$enc_line）" \
                || bad "编码节点驱动不是 nvidia：$enc_line"
        else
            grep -q 'i915' <<<"$enc_line" && ok "编码节点驱动 = i915（$enc_line）" \
                || bad "编码节点驱动不是 i915：$enc_line（跨卡会黑屏，见 004 §1）"
        fi
        if [ "$MODE" = nvidia ]; then
            if grep -q 'NVENC Encoder initialized successfully' <<<"$LOGS"; then
                ok "Selkies 日志: NVENC Encoder initialized successfully"
            elif grep -qE 'Failed to init NVENC' <<<"$LOGS"; then
                bad "Selkies 日志: Failed to init NVENC" "$(grep -E 'Failed to init NVENC' <<<"$LOGS" | tail -n1)"
            elif [ "$SELKIES_CLIENT" = 1 ]; then
                bad "有 Selkies 客户端但本次日志里没有 NVENC 初始化成功 —— 无法证明走了 NVENC" \
                    "客户端可能只打开了页面还没开始串流；先开始一次串流再跑"
            else
                skip "日志里还没有 NVENC 初始化结果（需客户端）"
            fi
            if grep -q 'VAAPI Encoder initialized successfully' <<<"$LOGS"; then
                bad "Selkies 竟然初始化了 VAAPI（nvidia 模式下没有 Intel，说明选卡错了）"
            elif grep -q 'NVENC Encoder initialized successfully' <<<"$LOGS"; then
                ok "没有 VAAPI 初始化行（符合纯 NVIDIA 模式）"
            else
                skip "日志里还没有编码器初始化结果，无法断言没有 VAAPI（需客户端出流）"
            fi
        else
            if grep -q 'VAAPI Encoder initialized successfully' <<<"$LOGS"; then
                ok "Selkies 日志: VAAPI Encoder initialized successfully"
            elif grep -qE 'Failed to init VAAPI' <<<"$LOGS"; then
                bad "Selkies 日志: Failed to init VAAPI" "$(grep -E 'Failed to init VAAPI' <<<"$LOGS" | tail -n1)"
            elif [ "$SELKIES_CLIENT" = 1 ]; then
                bad "有 Selkies 客户端但本次日志里没有 VAAPI 初始化成功 —— 无法证明走了硬编" \
                    "客户端可能只打开了页面还没开始串流；先开始一次串流再跑"
            else
                skip "日志里还没有 VAAPI 初始化结果（需客户端）"
            fi
            if grep -q 'NVENC Encoder initialized successfully' <<<"$LOGS"; then
                bad "Selkies 竟然初始化了 NVENC（intel 模式要求 Intel VAAPI）"
            elif grep -q 'VAAPI Encoder initialized successfully' <<<"$LOGS"; then
                ok "没有 NVENC 初始化行（符合 intel 模式）"
            else
                skip "日志里还没有编码器初始化结果，无法断言没有 NVENC（需客户端出流）"
            fi
        fi
        # 有客户端时必须看到零拷贝路径；空结果不再打 ok（008 P0-⑤）。
        if grep -q 'Decision: Zero-Copy path active.' <<<"$LOGS"; then
            ok "Selkies 日志: Decision: Zero-Copy path active."
        elif [ "$SELKIES_CLIENT" = 1 ]; then
            bad "有 Selkies 客户端但日志里没有 'Decision: Zero-Copy path active.'" \
                "没有零拷贝证据 = 可能走了 CPU/readback；看上面的降级信号与 $SELKIES_UNIT 日志"
        else
            skip "日志里还没有路径决策行（需客户端出流）"
        fi
    fi
fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8090/ 2>/dev/null)"
[ "$code" = 200 ] && ok "curl 127.0.0.1:8090 -> 200" || bad "curl 127.0.0.1:8090 -> ${code:-无响应}"

# nvidia 模式 + 有 Selkies 客户端：必须证明 KWin screencast 真的在出 DMA-BUF 帧 ——
# 统计行的帧计数在增长（历史统计行已能证明就不必等；否则现场观察 7 秒）。
# 008 的 P0-⑤；静态桌面可能没有新帧，FAIL 文案会提示先动一下。
if [ "$MODE" = nvidia ] && [ "$SELKIES_CLIENT" = 1 ]; then
    KW_SINCE_RAW="$(systemctl --user show -p ExecMainStartTimestamp --value "$WAYLAND_UNIT" 2>/dev/null)"
    KWIN_SINCE="$(date -d "$KW_SINCE_RAW" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
    stats_all="$(screencast_stat_lines)"
    range1="$(printf '%s\n' "$stats_all" | stat_frame_range)"
    min1="${range1%% *}"; max1="${range1##* }"
    [ -n "$range1" ] || { min1=""; max1=""; }
    grew=""
    if [ -n "$range1" ] && [ "$min1" != "$max1" ]; then
        grew="历史统计行 $min1 -> $max1"
    else
        info "KWin screencast 统计：窗口前 $(printf '%s\n' "$stats_all" | grep -c .) 行，max_frames=${max1:-无}；观察 7s…"
        sleep 7
        stats2="$(screencast_stat_lines)"
        stats_all="$stats_all"$'\n'"$stats2"
        range2="$(printf '%s\n' "$stats2" | stat_frame_range)"
        max2="${range2##* }"
        [ -n "$range2" ] || max2=0
        if [ "$max2" -gt "${max1:-0}" ]; then
            grew="观察窗口 ${max1:-0} -> $max2"
        fi
    fi
    if [ -z "$(printf '%s\n' "$stats_all" | grep -E 'KWIN_CAPTURE_STATS|KWIN_SCREENCAST_STATS')" ]; then
        bad "有 Selkies 客户端但没有任何 KWin screencast 统计行（KWIN_CAPTURE_STATS/KWIN_SCREENCAST_STATS）—— 无法证明在出 DMA-BUF 帧" \
            "确认 $SELKIES_UNIT 的 PIXELFLUX_KWIN_STATS=1；统计行每 300 帧打印一次，出流后才有"
    elif [ -n "$grew" ]; then
        ok "KWin screencast 帧数在增长（$grew）"
        if grep -q 'KWIN_CAPTURE_STATS' <<<"$stats_all"; then
            grep -q 'dmabuf=true' <<<"$stats_all" \
                && ok "pixelflux 统计行带 dmabuf=true（DMA-BUF 帧）" \
                || bad "pixelflux 的 KWIN_CAPTURE_STATS 行没有 dmabuf=true —— 不是 DMA-BUF 帧"
        else
            ok "KWin 自己的 KWIN_SCREENCAST_STATS 在增长（KWin screencast 只发 DMA-BUF，SHM 会被 严格模式拒绝）"
        fi
    else
        bad "KWin screencast 帧数没有增长（统计行 max=${max1:-无}）" \
            "静态桌面可能没有新帧（动一下鼠标/播个视频再跑）；也可能客户端没真的出流"
    fi
fi

# ---------------------------------------------------------------- 6. Sunshine
section "6. Sunshine（encoder=nvenc，走 P620）"
SUN_UNIT=app-dev.lizardbyte.app.Sunshine.service
SUN_CONF="$HOME/.config/sunshine/sunshine.conf"
SUN_LOG="$HOME/.config/sunshine/sunshine.log"
enc_cfg="$(sed -n 's/^[[:space:]]*encoder[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$SUN_CONF" 2>/dev/null | head -n1)"
ada_cfg="$(sed -n 's/^[[:space:]]*adapter_name[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$SUN_CONF" 2>/dev/null | head -n1)"
info "sunshine.conf: encoder=$enc_cfg  adapter_name=$ada_cfg"
[ "$enc_cfg" = nvenc ] && ok "encoder = nvenc" || bad "encoder = $enc_cfg（预期 nvenc）" "看 $LIBEXEC/rakkord-sunshine-nvenc-prep.sh 的输出与 $SUN_CONF.bak-before-nvenc-prep"
if [ -n "$EXPECT_NODE" ]; then
    [ "$ada_cfg" = "$EXPECT_NODE" ] && ok "adapter_name 指向本模式的渲染卡（$EXPECT_NODE）" \
        || bad "adapter_name=$ada_cfg，本模式预期 $EXPECT_NODE" "prep 会在下次 Sunshine 启动时改写；也可手动核对 $LIBEXEC/rakkord-sunshine-nvenc-prep.sh"
else
    warn "期望节点未知，无法核对 adapter_name=$ada_cfg"
fi
systemctl --user is-active --quiet "$SUN_UNIT" && ok "$SUN_UNIT active" || bad "$SUN_UNIT 未在运行"

# 只读本次启动之后的 sunshine.log：ExecMainStartTimestamp 截断（004 §3.2 的 P0-3 修法）
SUN_SINCE_RAW="$(systemctl --user show -p ExecMainStartTimestamp --value "$SUN_UNIT" 2>/dev/null)"
SUN_SINCE="$(date -d "$SUN_SINCE_RAW" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
if [ -z "$SUN_SINCE" ] || [ ! -r "$SUN_LOG" ]; then
    warn "拿不到服务启动时间或读不到 $SUN_LOG，跳过 Sunshine 日志检查"
    SUN_LOGS=""
else
    SUN_LOGS="$(awk -v since="$SUN_SINCE" '
        /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
            keep = (substr($0, 2, 19) >= since)
        }
        keep { print }
    ' "$SUN_LOG" 2>/dev/null)"
    info "日志范围：$SUN_LOG 中 >= $SUN_SINCE 的 $(printf '%s\n' "$SUN_LOGS" | grep -c .) 行（不读 .log.1）"
fi
if [ -n "${SUN_LOGS:-}" ]; then
    # 006 §5 的 V1：enc_cfg=nvenc 时不能因为"日志里没有 nvenc 失败行"就 PASS；
    # 必须看到本次启动的编码器探测证据，且它必须指向 nvenc。
    # 009：有 Moonlight 客户端时，"没有成功证据"一律 FAIL（不是 SKIP）。
    nvenc_found="$(grep -E 'Found (H\.264|HEVC) encoder: (h264|hevc)_nvenc' <<<"$SUN_LOGS" | tail -n1)"
    nvenc_create="$(grep -E 'Creating encoder \[(h264|hevc)_nvenc\]' <<<"$SUN_LOGS" | tail -n1)"
    other_create="$(grep -E 'Creating encoder \[' <<<"$SUN_LOGS" | tail -n1)"
    if [ -n "$nvenc_found" ]; then
        ok "Sunshine 日志: $nvenc_found"
    elif [ -n "$nvenc_create" ]; then
        bad "Sunshine 创建了 nvenc 编码器，但日志里没有 'Found ... encoder: h264_nvenc/hevc_nvenc' 成功行" "$nvenc_create"
    elif grep -qE 'Trying encoder \[nvenc\]' <<<"$SUN_LOGS"; then
        bad "Sunshine 试过 nvenc 但没成功" "$(grep -E 'nvenc|Encoder' <<<"$SUN_LOGS" | tail -n3 | tr '\n' '|')"
    elif [ -z "$other_create" ] && ! grep -q 'Trying encoder \[' <<<"$SUN_LOGS"; then
        if [ "$MOONLIGHT_CLIENT" = 1 ]; then
            bad "有 Moonlight 客户端但本次启动的日志里没有任何编码器探测记录 —— 无法证明 nvenc 生效" \
                "看 $SUN_LOG；也可能是日志被轮转过，不要只看配置文件就判定通过"
        elif [ "$enc_cfg" = nvenc ]; then
            bad "encoder=nvenc 但本次启动的日志里没有任何编码器探测记录 —— 无法证明 nvenc 生效" \
                "要么还没有客户端出流（此时应连一次 Moonlight 再跑），要么 sunshine.log 被轮转过；不要只看配置文件就判定通过"
        else
            skip "本次启动的日志里还没有编码器探测结果（需客户端：串流开始才探测）"
        fi
    else
        bad "encoder=$enc_cfg，但本次日志里探测的是别的编码器" "$(grep -E 'Trying encoder \[|Found .* encoder' <<<"$SUN_LOGS" | tail -n3 | tr '\n' '|')"
    fi
    if grep -qE 'Encoder \[nvenc\] failed' <<<"$SUN_LOGS"; then
        bad "本次启动的日志里有 'Encoder [nvenc] failed'"
    elif [ -n "$other_create" ] || [ "$MOONLIGHT_CLIENT" = 1 ]; then
        ok "本次启动的日志里没有 'Encoder [nvenc] failed'"
    else
        skip "本次启动的日志里没有编码器记录，无法断言 'Encoder [nvenc] failed' 不存在"
    fi
    if [ "$MODE" = nvidia ]; then
        # nvidia 模式特有：Sunshine 应该走 DMA-BUF（display_is_nvidia=true）
        if grep -q 'Pure NVIDIA system - DMA-BUF will be enabled for CUDA' <<<"$SUN_LOGS"; then
            ok "Sunshine 日志: Pure NVIDIA system - DMA-BUF 已启用（零拷贝 NVENC_GL 路径）"
        elif grep -q 'Hybrid GPU system detected' <<<"$SUN_LOGS"; then
            bad "Sunshine 仍判定为混合显卡系统（display_is_nvidia=false）" "capture 会走共享内存上传而不是 DMA-BUF；检查 /sys/class/drm/card*/device/vendor 是否还有 0x8086"
        else
            skip "本次日志里没有 GPU 判定行（需客户端：capture 初始化时才打印）"
        fi
    fi
else
    if [ "$MOONLIGHT_CLIENT" = 1 ]; then
        bad "有 Moonlight 客户端但读不到本次启动的 Sunshine 日志（$SUN_LOG）—— 无法证明 h264_nvenc/hevc_nvenc"
    else
        skip "Sunshine 日志为空（本次启动还没写过日志）"
    fi
fi
web_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 https://127.0.0.1:47990/ 2>/dev/null)"
if [ -n "$web_code" ] && [ "$web_code" != 000 ]; then
    ok "Sunshine Web UI 47990 可达（HTTP $web_code；未认证时 401 正常）"
else
    bad "Sunshine Web UI 47990 无响应（${web_code:-无}）"
fi

# ---------------------------------------------------------------- 7. NVENC 会话/显存
section "7. NVENC 编码会话与显存（需客户端）"
SUN_PID="$(systemctl --user show -p MainPID --value "$SUN_UNIT" 2>/dev/null)"
SEL_PID="$(systemctl --user show -p MainPID --value "$SELKIES_UNIT" 2>/dev/null)"
# nvidia-smi 在驱动不可用时会把这句错误打到 **stdout**，所以必须校验它是纯数字，
# 否则会把错误文本当成"有编码会话"而误报 PASS（005 干跑时实测踩到）。
sess="$(nvidia-smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ')"
case "$sess" in ''|*[!0-9]*) sess_valid=0 ;; *) sess_valid=1 ;; esac
[ "$sess_valid" = 1 ] || sess="N/A"
# 会话归因：pmon 按 PID 取（Sunshine 与 nvidia 模式下的 Selkies 各查各的）。
sun_pmon_line=""; sel_pmon_line=""
_pmon="$(nvidia-smi pmon -c 1 2>/dev/null)"
if [ -n "$SUN_PID" ] && [ "$SUN_PID" != 0 ]; then
    sun_pmon_line="$(awk -v p="$SUN_PID" '$1 !~ /^#/ && $2 == p && $6 != "-" && $6+0 > 0 {print}' <<<"$_pmon")"
fi
if [ -n "$SEL_PID" ] && [ "$SEL_PID" != 0 ]; then
    sel_pmon_line="$(awk -v p="$SEL_PID" '$1 !~ /^#/ && $2 == p && $6 != "-" && $6+0 > 0 {print}' <<<"$_pmon")"
fi
# 有 Moonlight 客户端：必须看到 Sunshine 的编码会话（只有 Selkies 的会话不算）。
if [ "$MOONLIGHT_CLIENT" = 1 ]; then
    if [ -n "$sun_pmon_line" ]; then
        ok "nvidia-smi pmon 看到 Sunshine($SUN_PID) 在用编码器：$sun_pmon_line"
    elif [ "$sess_valid" = 1 ] && [ "$sess" -gt 0 ] 2>/dev/null && [ "$SELKIES_CLIENT" = 0 ]; then
        ok "nvidia-smi 报告编码会话数 $sess（此刻只有 Moonlight 客户端，可归因于 Sunshine）"
    else
        bad "有 Moonlight 客户端但 nvidia-smi 看不到 Sunshine 的编码会话（Sunshine PID=${SUN_PID:-?}，sessionCount=${sess:-N/A}，Selkies 客户端=$SELKIES_CLIENT）" \
            "pmon 的 enc 列要在 Sunshine PID 上非 0；同时看 $SUN_LOG 的 nvenc 行"
    fi
fi
# nvidia 模式下 Selkies 也在 P620 上编码，必须能看到它的会话；intel 模式走 VAAPI，不查。
if [ "$MODE" = nvidia ] && [ "$SELKIES_CLIENT" = 1 ]; then
    if [ -n "$sel_pmon_line" ]; then
        ok "nvidia-smi pmon 看到 Selkies($SEL_PID) 在用编码器：$sel_pmon_line"
    elif [ "$sess_valid" = 1 ] && [ "$sess" -gt 0 ] 2>/dev/null && [ "$MOONLIGHT_CLIENT" = 0 ]; then
        ok "nvidia-smi 报告编码会话数 $sess（nvidia 模式且只有 Selkies 客户端，可归因于 Selkies）"
    else
        bad "nvidia 模式下有 Selkies 客户端但 nvidia-smi 看不到它的 NVENC 会话（Selkies PID=${SEL_PID:-?}，sessionCount=${sess:-N/A}）" \
            "pmon 的 enc 列要在 Selkies PID 上非 0；同时看 §5 的 NVENC 初始化与降级信号"
    fi
fi
if [ "$MOONLIGHT_CLIENT" = 0 ] && { [ "$SELKIES_CLIENT" = 0 ] || [ "$MODE" != nvidia ]; }; then
    skip "当前没有会走 NVENC 的客户端（intel 模式的 Selkies 走 VAAPI；sessionCount=${sess:-N/A}）—— **画面未验证**"
fi
# 显存：nvidia-smi 失败时会把错误文本打到 stdout，必须校验格式再显示（005 踩过同类问题）。
MEM="$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | head -n1)"
case "$MEM" in ''|*[!0-9MiaB,idx.\ ]*) MEM="" ;; esac
info "显存占用: ${MEM:-<读不到>}（P620 共 2 GiB；见 tasks/gpu-nvenc/007.report.md 的显存预算）"
if [ "$QUIET" = 1 ]; then :; else
    info "nvidia-smi pmon 摘要："
    if nvidia-smi -L >/dev/null 2>&1; then
        nvidia-smi pmon -c 1 2>/dev/null | awk 'NR<=2 || $6!="-"' | sed 's/^/         /'
    else
        info "（nvidia-smi 不可用，跳过）"
    fi
fi

# ---------------------------------------------------------------- 汇总
printf '\n== 汇总 ==\n'
printf '  模式: %s（期望渲染卡 %s）\n' "$MODE" "${EXPECT_NAME:-未知}"
printf '  客户端: Selkies(8090)=%s  Moonlight=%s\n' \
    "$([ "${SELKIES_CLIENT:-0}" = 1 ] && echo 有 || echo 无)" \
    "$([ "${MOONLIGHT_CLIENT:-0}" = 1 ] && echo 有 || echo 无)"
printf '  PASS=%d  FAIL=%d  WARN=%d  SKIP=%d\n' "$PASS" "$FAIL" "$WARN" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '  失败项：\n'
    for i in "${FAILED_ITEMS[@]}"; do printf '    - %s\n' "$i"; done
    printf '\n  回退：sudo rakko-gpu-mode %s && sudo reboot（详见 tasks/gpu-nvenc/007.report.md）\n' \
        "$([ "$MODE" = nvidia ] && echo intel || echo nvidia)"
    exit 1
fi
if [ "$SKIP" -gt 0 ]; then
    # 008 的 P0-⑤：SKIP>0 代表"缺出流证据"，退出码必须是 3，不能再被当成验收通过。
    printf '  %s必须项通过，但有 %d 项缺出流证据被跳过 —— **画面未验证**（exit 3）。%s\n' \
        "$(c_warn '')" "$SKIP" ''
    printf '  未验证的项：\n'
    for i in "${SKIPPED_ITEMS[@]}"; do printf '    - %s\n' "$i"; done
    printf '  连客户端（浏览器开 8090 + Moonlight 连一次）并开始一次串流后重跑；只有 exit 0（SKIP=0）才算验收通过。\n'
    exit 3
fi
printf '  全部必须项通过且 SKIP=0（含客户端出流后的日志、screencast 帧增长与会话检查）。\n'
exit 0
