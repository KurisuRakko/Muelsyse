#!/usr/bin/env bash
# 把原先手抄的 Selkies 发版命令固化下来：
#   前端 lint + build → pixelflux release 构建 → stage 不可变 release → BUILD-INFO → import 断言。
# release 写到 ~/.local/share/remote-desktop/selkies-kwin/releases/<时间戳>/，默认不切 site 软链、
# 不重启任何服务；只动代码，不碰 unit、desktop 文件、kwinrc（那些归 deploy-host.sh / bootstrap-host.sh）。
#
# 用法：
#   scripts/build-release.sh                       构建 + stage + 断言
#   --skip-web                                     不跑前端 lint/build，用 selkies/src/selkies/selkies_web 现有产物
#   --pixelflux-so PATH                            不跑 cargo，直接用现成的 pixelflux .so
#   scripts/build-release.sh --activate TS         只把 site 软链切到 releases/TS
#   scripts/build-release.sh --activate TS --restart
#                                                  切链后只重启 remote-desktop-selkies（浏览器断几秒，窗口不丢）
#
# 环境变量：MUELSYSE_RUNTIME_ROOT 产物根（默认 ~/.local/share/remote-desktop/selkies-kwin），测试时指到
# 临时目录；MUELSYSE_NODE_BIN 前端用的 node（默认 ~/.local/node-v24.21.0-linux-x64/bin，不存在时
# 用 PATH 里 node 所在的目录）；MUELSYSE_PIXELFLUX_TARGET 固定的 CARGO_TARGET_DIR（默认
# ~/build/muelsyse-pixelflux-target）；MUELSYSE_SELKIES_VENV 装 selkies 第三方依赖的 venv（默认
# /opt/selkies）。~/.config/muelsyse/env 里写的值在环境没给时生效（见 scripts/muelsyse-env.sh）。
set -Eeuo pipefail
# 只读 git 查询不刷新 .git/index，避免和别的会话抢锁
export GIT_OPTIONAL_LOCKS=0

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SELKIES=$ROOT/selkies
PIXELFLUX_CRATE=$ROOT/pixelflux/pixelflux
# shellcheck source=scripts/muelsyse-env.sh
source "$ROOT/scripts/muelsyse-env.sh"
muelsyse_load_env
RUNTIME_ROOT=${MUELSYSE_RUNTIME_ROOT:-$HOME/.local/share/remote-desktop/selkies-kwin}
NODE_BIN=${MUELSYSE_NODE_BIN:-$HOME/.local/node-v24.21.0-linux-x64/bin}
if [[ -z "${MUELSYSE_NODE_BIN:-}" && ! -x "$NODE_BIN/npm" ]] && command -v node >/dev/null 2>&1; then
    NODE_BIN=$(dirname -- "$(command -v node)")
fi
PIXELFLUX_TARGET=${MUELSYSE_PIXELFLUX_TARGET:-$HOME/build/muelsyse-pixelflux-target}
PYTHON=/usr/bin/python3.13
# 生产 PYTHONPATH 的第二项：selkies 的第三方依赖装在这个 venv 里，release 只遮住 selkies/pixelflux 本身。
DEPS_SITE=${MUELSYSE_SELKIES_VENV:-/opt/selkies}/lib/python3.13/site-packages

skip_web=0
pixelflux_so=
activate=
restart=0

fail() {
    echo "BUILD_RELEASE_FAIL $*" >&2
    exit 1
}

while (($#)); do
    case $1 in
        --skip-web) skip_web=1 ;;
        --pixelflux-so) shift; pixelflux_so=${1:-}; [[ -n "$pixelflux_so" ]] || fail "--pixelflux-so 要一个路径" ;;
        --activate) shift; activate=${1:-}; [[ -n "$activate" ]] || fail "--activate 要一个时间戳" ;;
        --restart) restart=1 ;;
        -h|--help) sed -n '2,/^set -Eeuo/{/^set -Eeuo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) fail "未知参数: $1" ;;
    esac
    shift
done

((restart)) && [[ -z "$activate" ]] && fail "--restart 只能和 --activate 一起用"

# 切链是原子的；回滚就是把软链指回旧 release 再重启 selkies，release 目录只增不删。
if [[ -n "$activate" ]]; then
    release=$RUNTIME_ROOT/releases/$activate
    [[ -d "$release/site/selkies" ]] || fail "release 不存在或不完整: $release"
    [[ -f "$release/BUILD-INFO" ]] || fail "release 缺 BUILD-INFO（没过断言？）: $release"
    previous=$(readlink "$RUNTIME_ROOT/site" 2>/dev/null || echo 无)
    ln -sfn "$release/site" "$RUNTIME_ROOT/site"
    echo "ACTIVATED site → $release/site"
    if [[ "$previous" != 无 ]]; then
        echo "回滚：ln -sfn $previous $RUNTIME_ROOT/site && systemctl --user restart remote-desktop-selkies.service"
    fi
    if ((restart)); then
        # 只重启 selkies；不要重启 wayland，那会重开 KWin + Plasma，桌面窗口全丢。
        systemctl --user restart remote-desktop-selkies.service
        systemctl --user is-active remote-desktop-selkies.service
    else
        echo "需要：只重启 selkies（systemctl --user restart remote-desktop-selkies.service），或加 --restart"
    fi
    exit 0
fi

[[ -x "$PYTHON" ]] || fail "缺少 $PYTHON"
[[ -d "$SELKIES/src/selkies" ]] || fail "selkies 源码不存在: $SELKIES/src/selkies"

# 1. 前端：产物写进 selkies/src/selkies/selkies_web（被 gitignore），下面再复制进 release。
if ((skip_web)); then
    echo "SKIP_WEB 用现有前端产物"
else
    [[ -x "$NODE_BIN/npm" ]] || fail "找不到 npm: $NODE_BIN/npm"
    (cd "$SELKIES" && PATH=$NODE_BIN:$PATH sh scripts/ci/lint-web.sh && PATH=$NODE_BIN:$PATH sh scripts/ci/build-web.sh)
fi
web_root=$SELKIES/src/selkies/selkies_web
[[ -f "$web_root/index.html" ]] || fail "前端产物不存在: $web_root/index.html"

# 2. pixelflux：固定 CARGO_TARGET_DIR，增量编；不再每个任务各开一个几 G 的 target 目录。
if [[ -n "$pixelflux_so" ]]; then
    [[ -f "$pixelflux_so" ]] || fail "--pixelflux-so 不存在: $pixelflux_so"
    # 记真实路径：常见用法是指向当前 site 软链里的 .so，切链后那条路径就指别处了。
    pixelflux_source=$(readlink -f -- "$pixelflux_so")
else
    command -v cargo >/dev/null || fail "缺少 cargo"
    (cd "$PIXELFLUX_CRATE" && CARGO_TARGET_DIR=$PIXELFLUX_TARGET \
        systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 -p CPUWeight=idle \
        nice -n 19 cargo build --offline --locked --release)
    pixelflux_so=$PIXELFLUX_TARGET/release/libpixelflux.so
    [[ -f "$pixelflux_so" ]] || fail "cargo 没产出 $pixelflux_so"
    pixelflux_source="cargo $PIXELFLUX_TARGET"
fi

# 3. stage：先写进 .partial，断言通过再改名，免得留下半套 release 被人当成可用版本。
ext_suffix=$("$PYTHON" -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or ".so")')
run_id=$(date +%Y%m%dT%H%M%S)
releases=$RUNTIME_ROOT/releases
release=$releases/$run_id
staging=$releases/.$run_id.partial
[[ ! -e "$release" ]] || fail "release 已存在: $release"
mkdir -p "$staging/site"
cp -a "$SELKIES/src/selkies" "$staging/site/selkies"
rm -rf "$staging/site/selkies/selkies_web"
find "$staging/site/selkies" -name __pycache__ -type d -prune -exec rm -rf {} +
cp -a "$web_root" "$staging/site/selkies_web"
install -m755 "$pixelflux_so" "$staging/site/pixelflux$ext_suffix"
install -m644 "$ROOT/source-revisions.env" "$staging/source-revisions.env"

# 4. BUILD-INFO：source-revisions.env 只记上游 tag，回滚时要靠这里知道是 Muelsyse 哪个提交。
if [[ -n "$(git -C "$ROOT" status --porcelain -- selkies pixelflux)" ]]; then
    dirty=1
else
    dirty=0
fi
{
    echo "muelsyse_commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "dirty=$dirty"
    echo "built_at=$(date -Is)"
    echo "web=$( ((skip_web)) && echo skipped || echo built)"
    echo "pixelflux_source=$pixelflux_source"
    echo "sha256_pixelflux=$(sha256sum "$staging/site/pixelflux$ext_suffix" | cut -d' ' -f1)"
} > "$staging/BUILD-INFO"

mv -- "$staging" "$release"

# 5. 断言运行时确实加载 release 里的产物，而不是 selkies venv 里的旧模块。
if ! (cd / && RUNTIME_ROOT=$RUNTIME_ROOT PYTHONPATH="$release/site:$DEPS_SITE" "$PYTHON" -s - <<'PY'
import os

import pixelflux
import selkies

prefix = os.path.realpath(os.path.join(os.environ["RUNTIME_ROOT"], "releases"))
assert os.path.realpath(pixelflux.__file__).startswith(prefix + os.sep), pixelflux.__file__
assert os.path.realpath(selkies.__file__).startswith(prefix + os.sep), selkies.__file__
print("RUNTIME_IMPORT_PASS pixelflux=%s selkies=%s" % (pixelflux.__file__, selkies.__file__))
PY
); then
    mv -- "$release" "$releases/$run_id.rejected"
    fail "import 断言失败（产物留在 $releases/$run_id.rejected）"
fi

echo "STAGED $release（dirty=$dirty）"
echo "切换：scripts/build-release.sh --activate $run_id --restart（只重启 selkies）"
