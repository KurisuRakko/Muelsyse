#!/usr/bin/env bash
# 从仓库的 kwin/ 与 kwin-adapter/ 构建 KWin，并把产物复制成带版本号的 prefix：
#   ~/.local/share/remote-desktop/kwin/releases/<时间戳>/bin
# 生产只跑 releases/ 里的副本（经 current 软链），不再直接从构建树跑——构建树
# 一重编就可能用旧源码盖掉双光标修复。
#
# 用法：
#   scripts/build-kwin.sh                 构建 + stage + 验收，不切 current
#   scripts/build-kwin.sh --no-build      跳过 ninja，直接 stage 构建树现有产物
#   scripts/build-kwin.sh --activate TS   只把 current 切到 releases/TS；要重启整个会话才生效
#   --jobs N                              ninja 并发（默认 3，按 15G 内存的机器定的，内存大可调高）
#
# 环境变量：MUELSYSE_KWIN_BUILD_DIR 构建树（默认 ~/build/muelsyse-kwin）；
# MUELSYSE_RUNTIME_ROOT 产物根（默认 ~/.local/share/remote-desktop/kwin），测试时指到临时目录。
# ~/.config/muelsyse/env 里写的值在环境没给时生效（见 scripts/muelsyse-env.sh）。
set -Eeuo pipefail
# 只读 git 查询不刷新 .git/index，避免和别的会话抢锁
export GIT_OPTIONAL_LOCKS=0

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/muelsyse-env.sh
source "$ROOT/scripts/muelsyse-env.sh"
muelsyse_load_env
BUILD_DIR=${MUELSYSE_KWIN_BUILD_DIR:-$HOME/build/muelsyse-kwin}
RUNTIME_ROOT=${MUELSYSE_RUNTIME_ROOT:-$HOME/.local/share/remote-desktop/kwin}
KWIN_SOURCE=$ROOT/kwin
ADAPTER_SOURCE=$ROOT/kwin-adapter

do_build=1
activate=
jobs=3

fail() {
    echo "BUILD_KWIN_FAIL $*" >&2
    exit 1
}

while (($#)); do
    case $1 in
        --no-build) do_build=0 ;;
        --activate) shift; activate=${1:-}; [[ -n "$activate" ]] || fail "--activate 要一个时间戳" ;;
        --jobs) shift; [[ ${1:-} =~ ^[1-9][0-9]*$ ]] || fail "--jobs 要一个正整数"; jobs=$1 ;;
        -h|--help) sed -n '2,/^set -Eeuo/{/^set -Eeuo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) fail "未知参数: $1" ;;
    esac
    shift
done

# 切 current 只换软链，不重启：KWin 只在会话启动时读 prefix，换了也要重启整个会话才生效。
if [[ -n "$activate" ]]; then
    release=$RUNTIME_ROOT/releases/$activate
    [[ -x "$release/bin/kwin_wayland" ]] || fail "release 不存在或不完整: $release"
    [[ -f "$release/BUILD-INFO" ]] || fail "release 缺 BUILD-INFO（没过验收？）: $release"
    previous=$(readlink "$RUNTIME_ROOT/current" 2>/dev/null || echo 无)
    ln -sfn "$release" "$RUNTIME_ROOT/current"
    echo "ACTIVATED current → $release（之前: $previous）"
    echo "需要重启整个会话才生效：systemctl --user restart remote-desktop-wayland.service（关掉所有窗口）"
    exit 0
fi

cache_value() {
    sed -n "s|^$1:[A-Z]*=||p" "$BUILD_DIR/CMakeCache.txt" | head -n 1
}

# 构建树必须配的是仓库源码：配错源码目录正是旧构建树把双光标修复盖掉的原因。
check_build_sources() {
    local home adapter
    home=$(cache_value CMAKE_HOME_DIRECTORY)
    adapter=$(cache_value SELKIES_KWIN_ADAPTER_SOURCE_DIR)
    [[ "$home" == "$KWIN_SOURCE" ]] || fail "构建树源码不是仓库: CMAKE_HOME_DIRECTORY=$home（应为 $KWIN_SOURCE）"
    [[ "$adapter" == "$ADAPTER_SOURCE" ]] || fail "构建树 adapter 源码不是仓库: $adapter（应为 $ADAPTER_SOURCE）"
}

if ((do_build)); then
    command -v ninja >/dev/null || fail "缺少 ninja"
    if [[ ! -f "$BUILD_DIR/build.ninja" ]]; then
        # 选项与旧生产构建树的 CMakeCache 一致：RelWithDebInfo、Ninja、
        # 不编测试，其余都是 KWin 默认值；只把源码换成仓库。
        command -v cmake >/dev/null || fail "缺少 cmake"
        cmake -S "$KWIN_SOURCE" -B "$BUILD_DIR" -G Ninja \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo \
            -DBUILD_TESTING=OFF \
            -DSELKIES_KWIN_ADAPTER_SOURCE_DIR="$ADAPTER_SOURCE"
    fi
    check_build_sources
    # 全量编 KWin 很吃内存：限 4G、不许换页、idle 优先级，免得把桌面会话挤 OOM。
    systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 -p CPUWeight=idle \
        nice -n 19 ninja -C "$BUILD_DIR" -j"$jobs"
else
    [[ -f "$BUILD_DIR/CMakeCache.txt" ]] || fail "构建树没有 CMakeCache.txt: $BUILD_DIR"
    check_build_sources
fi

bin=$BUILD_DIR/bin
[[ -d "$bin" ]] || fail "构建树没有 bin/: $bin"

# 复制集合即 KWin 构建树 bin/ 的全部顶层条目：
#   kwin_wayland、libkwin.so*、libkcmkwincommon.so*（kcm 用）、kwin/（插件、effects、scripts、
#   decorations）、org/ 与 org.kde.kdecoration3*/（QML 模块）、kf6/、overview/、plasma/。
# 会话脚本 start-wayland-session.sh 只从 prefix 读 bin/kwin_wayland、bin/kwin/plugins、bin/，
# lib/*/qt6/plugins 和 share/ 在当前生产里也不存在，不需要。
# 唯一不复制的是 qtwaylandscanner_kde：它是构建期的代码生成器，运行时用不到。
required=(kwin_wayland kwin/plugins/selkieskwinadapter.so kwin/plugins/screencast.so)
optional_dirs=(kf6 kwin org org.kde.kdecoration3 org.kde.kdecoration3.kcm overview plasma)
build_only=(qtwaylandscanner_kde)

for path in "${required[@]}"; do
    [[ -f "$bin/$path" ]] || fail "构建产物缺 $bin/$path"
done
libkwin_real=$(find "$bin" -maxdepth 1 -type f -name 'libkwin.so.*' | sort | tail -n 1)
[[ -n "$libkwin_real" ]] || fail "构建产物缺 libkwin.so.*"

run_id=$(date +%Y%m%dT%H%M%S)
releases=$RUNTIME_ROOT/releases
release=$releases/$run_id
staging=$releases/.$run_id.partial
[[ ! -e "$release" ]] || fail "release 已存在: $release"
mkdir -p "$staging/bin"

copy_entries=(kwin_wayland)
while IFS= read -r -d '' entry; do
    copy_entries+=("$(basename "$entry")")
done < <(find "$bin" -maxdepth 1 \( -name 'libkwin.so*' -o -name 'libkcmkwincommon.so*' \) -print0 | sort -z)
for entry in "${optional_dirs[@]}"; do
    if [[ -e "$bin/$entry" ]]; then
        copy_entries+=("$entry")
    else
        echo "WARN 构建产物没有 $entry/，生产 prefix 里有它"
    fi
done
# 构建树多出生产没有的顶层条目时只提示，不复制：新增东西要先确认运行时真的要。
while IFS= read -r -d '' entry; do
    name=$(basename "$entry")
    known=0
    for wanted in "${copy_entries[@]}" "${build_only[@]}"; do
        [[ "$name" == "$wanted" ]] && known=1 && break
    done
    ((known)) || echo "WARN 构建树 bin/ 有未登记的条目，没有复制: $name"
done < <(find "$bin" -mindepth 1 -maxdepth 1 -print0)

for entry in "${copy_entries[@]}"; do
    cp -a -- "$bin/$entry" "$staging/bin/"
done

# 验收：双光标修复和 cursor-shape-only 开关必须真在二进制里，否则就是又编错了源码。
count_marker() {
    grep -ac -- "$1" "$2" || true
}
staged_libkwin=$staging/bin/$(basename "$libkwin_real")
staged_adapter=$staging/bin/kwin/plugins/selkieskwinadapter.so
staged_screencast=$staging/bin/kwin/plugins/screencast.so
reject() {
    mv -- "$staging" "$releases/$run_id.rejected"
    fail "$*（产物留在 $releases/$run_id.rejected）"
}
(($(count_marker SoftwareCursorSuppressed "$staged_libkwin") > 0)) || reject "libkwin 里没有 SoftwareCursorSuppressed"
(($(count_marker SoftwareCursorSuppressed "$staged_adapter") > 0)) || reject "adapter 里没有 SoftwareCursorSuppressed"
(($(count_marker KWIN_SCREENCAST_CURSOR_SHAPE_ONLY "$staged_screencast") > 0)) || reject "screencast.so 里没有 KWIN_SCREENCAST_CURSOR_SHAPE_ONLY"

# DT_RPATH 先于 LD_LIBRARY_PATH，会让 kwin_wayland 绕过 prefix 去构建树取 libkwin；
# DT_RUNPATH 排在 LD_LIBRARY_PATH 之后，生产 unit 设了 LD_LIBRARY_PATH=<prefix>/bin 就够。
dynamic_path() {
    local out
    out=$(readelf -d "$1" 2>/dev/null | sed -n 's/.*(\(RPATH\|RUNPATH\)).*\[\(.*\)\].*/\1:\2/p')
    printf '%s\n' "${out:-none}"
}
declare -A runpaths=()
for path in kwin_wayland "$(basename "$libkwin_real")" kwin/plugins/selkieskwinadapter.so kwin/plugins/screencast.so; do
    runpaths[$path]=$(dynamic_path "$staging/bin/$path")
    [[ "${runpaths[$path]}" == RPATH:* ]] && reject "$path 用的是 DT_RPATH（${runpaths[$path]#RPATH:}），会压过 LD_LIBRARY_PATH，需要先处理"
done

if [[ -n "$(git -C "$ROOT" status --porcelain -- kwin kwin-adapter)" ]]; then
    dirty=1
else
    dirty=0
fi
# HEAD 只说明 stage 时仓库在哪；kwin_source_commit 才是最后一次改到 KWin 源码的提交。
kwin_source_commit=$(git -C "$ROOT" log -1 --format=%H -- kwin kwin-adapter)
# --no-build 时构建树可能是旧源码编的：产物比被跟踪源码里最新的文件还旧就提醒。
if ((!do_build)); then
    newest_src=0
    while IFS= read -r -d '' f; do
        [[ -f "$ROOT/$f" ]] || continue
        m=$(stat -c %Y -- "$ROOT/$f")
        ((m > newest_src)) && newest_src=$m
    done < <(git -C "$ROOT" ls-files -z -- kwin kwin-adapter)
    oldest_bin=$(find "$bin" -type f -printf '%T@\n' | sort -n | head -n 1)
    oldest_bin=${oldest_bin%.*}
    if [[ -n "$oldest_bin" ]] && ((oldest_bin < newest_src)); then
        echo "WARN 构建产物可能比源码旧：$bin 里最旧的产物 $(date -Is -d "@$oldest_bin")，源码最新改动 $(date -Is -d "@$newest_src")；去掉 --no-build 重编" >&2
    fi
fi
sha() { sha256sum "$1" | cut -d' ' -f1; }
{
    echo "muelsyse_commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "kwin_source_commit=$kwin_source_commit"
    echo "dirty=$dirty"
    echo "built_at=$(date -Is -r "$staging/bin/kwin_wayland")"
    echo "staged_at=$(date -Is)"
    echo "build_dir=$BUILD_DIR"
    echo "sha256_kwin_wayland=$(sha "$staging/bin/kwin_wayland")"
    echo "sha256_libkwin=$(sha "$staged_libkwin")"
    echo "sha256_screencast=$(sha "$staged_screencast")"
    echo "sha256_selkieskwinadapter=$(sha "$staged_adapter")"
    echo "dynpath_kwin_wayland=${runpaths[kwin_wayland]}"
    echo "dynpath_libkwin=${runpaths[$(basename "$libkwin_real")]}"
    echo "dynpath_selkieskwinadapter=${runpaths[kwin/plugins/selkieskwinadapter.so]}"
    echo "dynpath_screencast=${runpaths[kwin/plugins/screencast.so]}"
    if [[ " ${runpaths[*]} " == *" RUNPATH:"* ]]; then
        echo "# DT_RUNPATH 指向构建树；生产 unit 的 LD_LIBRARY_PATH=<prefix>/bin 优先于它，所以库只从本 release 取。"
    fi
} > "$staging/BUILD-INFO"

mv -- "$staging" "$release"
echo "STAGED $release（dirty=$dirty）"
echo "切换：scripts/build-kwin.sh --activate $run_id，然后重启整个会话"
