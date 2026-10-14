#!/usr/bin/env bash
# 安装主机生产运行时，但不启动服务；切换脚本在删除旧栈后再创建 marker。
# 所有运行时都放在 rakko 用户目录，不覆盖 Debian 的 KWin、Python 或 /opt/selkies。
set -Eeuo pipefail

fail() {
    echo "INSTALL_FAIL $*" >&2
    exit 1
}

# Chrome 系浏览器不认任何"选后端"的环境变量，只认命令行开关，所以下面的覆盖是让它把
# Wayland 偏好写进 Exec 行的唯一途径；当前它自己就选了 Wayland，这一步是防止以后环境
# 变动（例如会话后端偏好被改回 xcb）时它悄悄回退到 X11 运行。
#
# 覆盖文件从系统文件派生而不是整份写死：系统包升级后 Exec 里的路径或参数变化能跟着走，
# 也免得把版本号、安装路径抄进来。插入位置固定在 Exec 的可执行文件之后、字段代码
# （%U/%F 之类）之前；已经带该参数的行原样保留，所以重复安装不会越插越多。
#
# 用户可能在 ~/.local/share/applications 下自己写了同名文件，那份优先级更高，遇到就
# 跳过并提示，不做覆盖；首行的标记用来区分"本脚本生成的"与"用户手写的"。
desktop_override_marker='# generated-by: install-production-host-wayland.sh'
ozone_hint_argument='--ozone-platform-hint=auto'

# 在 Exec 的值里插入后端偏好：可执行文件允许是带空格的引号路径，先整块切出这个 token，
# 再把它原样放回，避免拆坏参数。
insert_ozone_platform_hint() {
    local value=$1 executable rest
    if [[ "$value" == *"$ozone_hint_argument"* ]]; then
        printf '%s\n' "$value"
        return 0
    fi
    if [[ "$value" == \"* ]]; then
        rest=${value#\"}
        executable="\"${rest%%\"*}\""
        rest=${rest#*\"}
    else
        executable=${value%%[[:space:]]*}
        rest=${value#"$executable"}
    fi
    printf '%s %s%s\n' "$executable" "$ozone_hint_argument" "$rest"
}

# 第一个参数是系统 applications 目录，默认 /usr/share/applications（测试里指向伪造目录，
# 生产流程不传，保持按系统文件派生）。目标一律写到用户级目录，不碰 /usr。
install_chrome_desktop_overrides() {
    local system_datadir=${1:-/usr/share/applications}
    local target_datadir=$HOME/.local/share/applications
    local candidate source target line generated=0

    mkdir -p "$target_datadir"
    for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
        source="$system_datadir/$candidate.desktop"
        target="$target_datadir/$candidate.desktop"
        [[ -f "$source" ]] || continue
        if [[ -e "$target" ]] && [[ "$(head -n 1 "$target" 2>/dev/null)" != "$desktop_override_marker" ]]; then
            echo "SKIP_DESKTOP_OVERRIDE $target（已存在且非本脚本生成）"
            continue
        fi
        {
            printf '%s\n' "$desktop_override_marker"
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" == Exec=* ]]; then
                    printf 'Exec=%s\n' "$(insert_ozone_platform_hint "${line#Exec=}")"
                else
                    printf '%s\n' "$line"
                fi
            done < "$source"
        } > "$target"
        chmod 644 "$target"
        generated=1
    done

    # 有桌面数据库工具就让它把新文件收进去；缺工具或失败都不算安装失败。
    if ((generated)) && command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$target_datadir" >/dev/null 2>&1 || true
    fi
    return 0
}

# 光标主题与 KDE 默认的 Breeze 对齐，不覆盖用户自己的选择：
#   1. KDE 侧写 kcminputrc（缺 kwriteconfig6 就跳过）；
#   2. 用户级 index.theme 兜底继承（系统那份 Inherits=Adwaita，拿不到 XCURSOR_THEME 的
#      进程会落成 Adwaita 光标）；
#   3. GTK 侧只在仍是发行版默认的 Adwaita 时才改。
# 三步都幂等，重复安装不会被越改越多。
install_cursor_theme_config() {
    local theme=breeze_cursors
    local size=24
    local theme_file=$HOME/.icons/default/index.theme
    local backup
    local gtk_raw
    local gtk_theme

    # KDE 侧：与 kwinrc 同样用 kwriteconfig6 写；kcminputrc 不存在时它会自己创建。
    # 工具存在但执行失败（例如配置文件不可写）也算跳过：本函数是"顺手对齐默认值"的
    # 附加步骤，不能因为它失败而让整个安装报错。
    if command -v kwriteconfig6 >/dev/null 2>&1; then
        kwriteconfig6 --file "$HOME/.config/kcminputrc" --group Mouse --key cursorTheme "$theme" || \
            echo "SKIP_CURSOR_CONFIG kwriteconfig6 执行失败，跳过 KDE 侧光标配置"
        kwriteconfig6 --file "$HOME/.config/kcminputrc" --group Mouse --key cursorSize "$size" || \
            echo "SKIP_CURSOR_CONFIG kwriteconfig6 执行失败，跳过 KDE 侧光标配置"
    else
        echo "SKIP_CURSOR_CONFIG 缺少 kwriteconfig6，跳过 KDE 侧光标配置"
    fi

    # 用户级兜底继承：只有能拿到 XCURSOR_THEME 的进程才会自动找到 breeze_cursors，
    # 其余进程读的是 index.theme；已经是目标值的文件不动，免得每次安装都留一份备份。
    mkdir -p "$(dirname "$theme_file")"
    if [[ -f "$theme_file" ]] && grep -q '^Inherits=breeze_cursors$' "$theme_file"; then
        :
    else
        if [[ -s "$theme_file" ]]; then
            backup="$theme_file.bak-$(date +%Y%m%dT%H%M%S)"
            cp -p "$theme_file" "$backup"
            echo "BACKUP_CURSOR_INDEX $backup"
        fi
        cat > "$theme_file" <<'EOF'
[Icon Theme]
Name=Default
Comment=Default cursor theme
Inherits=breeze_cursors
EOF
        chmod 644 "$theme_file"
    fi

    # GTK 侧：先读当前值，只在还是发行版默认的 Adwaita 时才改，用户自选过的主题保持不动。
    if command -v gsettings >/dev/null 2>&1; then
        # 每处命令替换都自兜底：本脚本 set -e，工具执行失败不能让整个安装中断。
        gtk_raw=$(gsettings get org.gnome.desktop.interface cursor-theme 2>/dev/null) || gtk_raw=''
        gtk_theme=${gtk_raw//\'/} || gtk_theme=''
        # gsettings 未设置时返回两个单引号，剥掉引号后为空，与"读取失败"一并跳过。
        if [[ "$gtk_raw" == "''" || -z "$gtk_theme" ]]; then
            echo "SKIP_CURSOR_CONFIG gsettings 未读到 GTK 光标主题，跳过 GTK 侧光标配置"
        elif [[ "$gtk_theme" == Adwaita ]]; then
            gsettings set org.gnome.desktop.interface cursor-theme "'$theme'" || \
                echo "SKIP_CURSOR_CONFIG gsettings 写入失败，跳过 GTK 侧光标配置"
            gsettings set org.gnome.desktop.interface cursor-size "$size" || \
                echo "SKIP_CURSOR_CONFIG gsettings 写入失败，跳过 GTK 侧光标配置"
        else
            echo "SKIP_CURSOR_CONFIG GTK 光标主题为 ${gtk_theme}，保留用户选择"
        fi
    else
        echo "SKIP_CURSOR_CONFIG 缺少 gsettings，跳过 GTK 侧光标配置"
    fi
    return 0
}

# 供测试 source 本文件时只取函数定义，不跑下面的安装主流程。
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

[[ "$(id -un)" == "rakko" ]] || fail "必须以 rakko 身份运行"
[[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]] || fail "XDG_RUNTIME_DIR 不可用"

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KWIN_PREFIX=${SELKIES_KWIN_PREFIX:-$HOME/build/kwin-adapter}
SELKIES_SOURCE=${SELKIES_SOURCE_DIR:-$HOME/src/selkies-kwin-pipewire-poc}
PIXELFLUX_SO=${PIXELFLUX_RELEASE_SO:-$HOME/src/pixelflux-kwin-poc/pixelflux/target/release/libpixelflux.so}
# 默认值若直接指向 /opt/selkies 原装包，手工构建的前端会在下一次重装时静默回退，
# 所以优先取本机构建产物，只有在产物缺失时才回落到 /opt 原装包。
DEFAULT_WEB_ROOT="$HOME/build/selkies-dashboard-dist"
[[ -f "$DEFAULT_WEB_ROOT/index.html" ]] || DEFAULT_WEB_ROOT=/opt/selkies/lib/python3.13/site-packages/selkies/selkies_web
WEB_ROOT=${SELKIES_WEB_ROOT_SOURCE:-$DEFAULT_WEB_ROOT}
RUNTIME_ROOT=${SELKIES_RUNTIME_ROOT:-$HOME/.local/share/remote-desktop/selkies-kwin}
PYTHON_ELF=${SELKIES_PYTHON_ELF:-$HOME/.local/libexec/selkies-python3.13}
SESSION_BIN=${SELKIES_SESSION_BIN:-$HOME/.local/libexec/selkies-wayland-session}
RUN_ID=$(date +%Y%m%dT%H%M%S)
RELEASE_ROOT="$RUNTIME_ROOT/releases/$RUN_ID"
SITE_ROOT="$RELEASE_ROOT/site"

[[ -x "$KWIN_PREFIX/bin/kwin_wayland" ]] || fail "隔离 KWin 不存在: $KWIN_PREFIX/bin/kwin_wayland"
[[ -f "$KWIN_PREFIX/bin/kwin/plugins/selkieskwinadapter.so" ]] || fail "KWin adapter plugin 不存在"
[[ -d "$SELKIES_SOURCE/src/selkies" ]] || fail "Selkies 源码不存在: $SELKIES_SOURCE"
[[ -f "$PIXELFLUX_SO" ]] || fail "pixelflux release 不存在: $PIXELFLUX_SO"
[[ -f "$WEB_ROOT/index.html" ]] || fail "Selkies Web 资源不存在: $WEB_ROOT"
[[ -x /usr/bin/python3.13 ]] || fail "缺少 /usr/bin/python3.13"
# launcher 也需要 Xwayland 本体：KWin 只负责按我们给的 fd 起它，二进制不在就整条会话失败。
xwayland_bin=${SELKIES_XWAYLAND_BIN:-/usr/bin/Xwayland}
[[ -x "$xwayland_bin" ]] || fail "Xwayland 未安装: $xwayland_bin"
command -v kwriteconfig6 >/dev/null || fail "缺少 kwriteconfig6"
command -v kbuildsycoca6 >/dev/null || fail "缺少 kbuildsycoca6"

EXT_SUFFIX=$(/usr/bin/python3.13 -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX") or ".so")')
mkdir -p "$SITE_ROOT" "$HOME/.local/libexec" "$HOME/.local/share/applications" \
    "$HOME/.config/systemd/user" "$HOME/.config/selkies" "$HOME/.config"

# 先写不可变 release 目录，再把 site 链接原子切到新版本，避免服务看到半套文件。
cp -a "$SELKIES_SOURCE/src/selkies" "$SITE_ROOT/selkies"
cp -a "$WEB_ROOT" "$SITE_ROOT/selkies_web"
install -m755 "$PIXELFLUX_SO" "$SITE_ROOT/pixelflux${EXT_SUFFIX}"
install -m755 /usr/bin/python3.13 "$PYTHON_ELF"
install -m755 "$ROOT/scripts/start-wayland-session.sh" "$SESSION_BIN"
# 助手必须与 launcher 同目录：launcher 默认按 $(dirname "$0") 找它。
install -m755 "$ROOT/scripts/selkies-xwayland-listen.py" "$(dirname "$SESSION_BIN")/selkies-xwayland-listen.py"
ln -sfn "$RELEASE_ROOT/site" "$RUNTIME_ROOT/site"

# 在切换旧服务前验证运行时实际加载的是精确源码产物，而不是系统旧模块。
RUNTIME_ROOT="$RUNTIME_ROOT" PYTHONPATH="$RUNTIME_ROOT/site:/opt/selkies/lib/python3.13/site-packages" \
    /usr/bin/python3.13 - <<'PY'
import os

import pixelflux
import selkies

release_prefix = os.path.realpath(os.path.join(os.environ["RUNTIME_ROOT"], "releases"))
assert os.path.realpath(pixelflux.__file__).startswith(release_prefix + os.sep)
assert os.path.realpath(selkies.__file__).startswith(release_prefix + os.sep)
print("RUNTIME_IMPORT_PASS pixelflux=%s selkies=%s" % (pixelflux.__file__, selkies.__file__))
PY

# 固定路径的 desktop 文件必须和实际 Wayland 客户端 ELF canonical path 一致。
install -m644 "$ROOT/desktop/selkies-kwin-wayland.desktop" \
    "$HOME/.local/share/applications/selkies-kwin-wayland.desktop"
# 浏览器那份覆盖由系统 desktop 文件派生，放在 kbuildsycoca6 之前，让菜单缓存一次收全。
install_chrome_desktop_overrides
install -m644 "$ROOT/systemd/remote-desktop-wayland.service" \
    "$HOME/.config/systemd/user/remote-desktop-wayland.service"
install -m644 "$ROOT/systemd/remote-desktop-selkies.service" \
    "$HOME/.config/systemd/user/remote-desktop-selkies.service"
if [[ ! -e "$HOME/.config/selkies/remote-desktop.env" ]]; then
    install -m600 "$ROOT/config/remote-desktop-selkies.env.example" \
        "$HOME/.config/selkies/remote-desktop.env"
fi

kwinrc_backup="$HOME/.config/kwinrc.pre-selkies-$RUN_ID"
if [[ -f "$HOME/.config/kwinrc" ]]; then
    cp -p "$HOME/.config/kwinrc" "$kwinrc_backup"
fi
kwriteconfig6 --file "$HOME/.config/kwinrc" \
    --group Plugins --key selkieskwinadapterEnabled true

# 光标主题与 kwinrc 同批写入，二者都只落用户目录，不影响系统默认。
install_cursor_theme_config

install -m644 "$ROOT/source-revisions.env" "$RUNTIME_ROOT/source-revisions.env"
# 全局单份的版本记录会在回滚到旧 release 时撒谎，同一份再固化进 release 才能追溯。
install -m644 "$ROOT/source-revisions.env" "$RELEASE_ROOT/source-revisions.env"
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
systemctl --user daemon-reload

echo "INSTALL_PASS runtime=$RUNTIME_ROOT release=$RUN_ID kwin=$KWIN_PREFIX"
