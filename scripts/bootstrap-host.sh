#!/usr/bin/env bash
# 一次性主机初始化：从旧 install-production-host-wayland.sh 拆出来的、不属于"按 manifest 部署
# 仓库文件"的那几步。默认只读（dry-run），只打印哪些会改；--apply 才写。每一步都幂等，已经是
# 目标状态的不动。
#
#   1. /usr/bin/python3.13 复制成 ~/.local/libexec/selkies-python3.13（selkies unit 与 .desktop
#      用固定路径的解释器，系统 python 升级时不会在会话中途被换掉）
#   2. kwinrc 启用 selkieskwinadapter 插件
#   3. 光标主题 breeze_cursors（2026-10-17 决定 D1）：kcminputrc、~/.icons/default/index.theme、
#      GTK gsettings（只在仍是发行版默认 Adwaita 时改）
#   4. Chrome/Chromium 的 .desktop 用户级覆盖，Exec 里加 --ozone-platform-hint=auto
#   5. kbuildsycoca6 重建菜单缓存
#
# 覆盖前的旧文件镜像进 ~/.local/share/remote-desktop/backups/<时间戳>/，与 deploy-host.sh 同一处。
# 改 kwinrc/kcminputrc 要重启整个会话才生效；本脚本不重启任何服务。
#
# 测试用环境变量：RAKKORD_DEPLOY_HOME 替代 $HOME；设了它就跳过 gsettings 和 kbuildsycoca6
# （这两个写的是真实用户的 dconf 和缓存，不跟 HOME 走）。
set -Eeuo pipefail

DEPLOY_HOME=${RAKKORD_DEPLOY_HOME:-$HOME}
TEST_HOME=0
[[ -n "${RAKKORD_DEPLOY_HOME:-}" ]] && TEST_HOME=1
# 备份目录在第一次真要备份时才建；同一秒内跑两次时加序号，免得后一次覆盖前一次的备份。
BACKUP_ROOT=$DEPLOY_HOME/.local/share/remote-desktop/backups
BACKUP_DIR=
SYSTEM_PYTHON=${RAKKORD_SYSTEM_PYTHON:-/usr/bin/python3.13}
PYTHON_ELF=$DEPLOY_HOME/.local/libexec/selkies-python3.13
CURSOR_THEME=breeze_cursors
CURSOR_SIZE=24

apply=0
changes=0

fail() {
    echo "BOOTSTRAP_FAIL $*" >&2
    exit 1
}

while (($#)); do
    case $1 in
        --apply) apply=1 ;;
        -h|--help) sed -n '2,/^set -Eeuo/{/^set -Eeuo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) fail "未知参数: $1" ;;
    esac
    shift
done

# 第一处要改的地方打印 WOULD/DO，并累计改动数；dry-run 下返回 1，调用方据此跳过真正的写入。
step() {
    changes=$((changes + 1))
    if ((apply)); then
        echo "DO $*"
        return 0
    fi
    echo "WOULD $*"
    return 1
}

ensure_backup_dir() {
    [[ -n "$BACKUP_DIR" ]] && return 0
    local stamp n=1
    stamp=$(date +%Y%m%dT%H%M%S)
    BACKUP_DIR=$BACKUP_ROOT/$stamp
    while [[ -e "$BACKUP_DIR" ]]; do
        n=$((n + 1))
        BACKUP_DIR=$BACKUP_ROOT/$stamp-$n
    done
    mkdir -p "$BACKUP_DIR"
}

backup_file() {
    local target=$1 dest
    [[ -e "$target" ]] || return 0
    ensure_backup_dir
    dest=$BACKUP_DIR$target
    mkdir -p "$(dirname "$dest")"
    cp -a -- "$target" "$dest"
    echo "  BACKUP $dest"
}

# ---- 1. 固定路径的 Python ----
install_python_elf() {
    [[ -x "$SYSTEM_PYTHON" ]] || fail "缺少 $SYSTEM_PYTHON"
    cmp -s -- "$SYSTEM_PYTHON" "$PYTHON_ELF" && [[ -x "$PYTHON_ELF" ]] && return 0
    step "复制 $SYSTEM_PYTHON → $PYTHON_ELF（需要重启 selkies）" || return 0
    backup_file "$PYTHON_ELF"
    install -D -m755 -- "$SYSTEM_PYTHON" "$PYTHON_ELF"
}

# ---- 2/3. KDE 配置：kwriteconfig6 写，kreadconfig6 先读，已是目标值就不动 ----
kde_config() {
    local file=$1 group=$2 key=$3 value=$4 current=
    if command -v kreadconfig6 >/dev/null 2>&1; then
        current=$(kreadconfig6 --file "$file" --group "$group" --key "$key" 2>/dev/null) || current=
    fi
    [[ "$current" == "$value" ]] && return 0
    if ! command -v kwriteconfig6 >/dev/null 2>&1; then
        echo "SKIP 缺少 kwriteconfig6，跳过 $file [$group] $key"
        return 0
    fi
    step "$file [$group] $key: ${current:-（未设）} → $value（需要重启整个会话）" || return 0
    backup_file "$file"
    kwriteconfig6 --file "$file" --group "$group" --key "$key" "$value" || \
        echo "SKIP kwriteconfig6 写 $file 失败"
}

# 光标主题与 KDE 默认的 Breeze 对齐，不覆盖用户自己的选择：
#   1. KDE 侧写 kcminputrc；
#   2. 用户级 index.theme 兜底继承（系统那份 Inherits=Adwaita，拿不到 XCURSOR_THEME 的
#      进程会落成 Adwaita 光标）；
#   3. GTK 侧只在仍是发行版默认的 Adwaita 时才改。
install_cursor_theme_config() {
    local theme_file=$DEPLOY_HOME/.icons/default/index.theme gtk_raw gtk_theme

    kde_config "$DEPLOY_HOME/.config/kcminputrc" Mouse cursorTheme "$CURSOR_THEME"
    kde_config "$DEPLOY_HOME/.config/kcminputrc" Mouse cursorSize "$CURSOR_SIZE"

    if ! { [[ -f "$theme_file" ]] && grep -qx "Inherits=$CURSOR_THEME" "$theme_file"; }; then
        if step "写 $theme_file（Inherits=$CURSOR_THEME）"; then
            backup_file "$theme_file"
            mkdir -p "$(dirname "$theme_file")"
            printf '[Icon Theme]\nName=Default\nComment=Default cursor theme\nInherits=%s\n' "$CURSOR_THEME" > "$theme_file"
            chmod 644 "$theme_file"
        fi
    fi

    if ((TEST_HOME)); then
        echo "SKIP gsettings（测试 HOME）"
        return 0
    fi
    if ! command -v gsettings >/dev/null 2>&1; then
        echo "SKIP 缺少 gsettings，跳过 GTK 侧光标配置"
        return 0
    fi
    gtk_raw=$(gsettings get org.gnome.desktop.interface cursor-theme 2>/dev/null) || gtk_raw=''
    gtk_theme=${gtk_raw//\'/}
    if [[ -z "$gtk_theme" ]]; then
        echo "SKIP gsettings 未读到 GTK 光标主题"
    elif [[ "$gtk_theme" == Adwaita ]]; then
        if step "gsettings cursor-theme Adwaita → $CURSOR_THEME，cursor-size → $CURSOR_SIZE"; then
            gsettings set org.gnome.desktop.interface cursor-theme "'$CURSOR_THEME'" || echo "SKIP gsettings 写入失败"
            gsettings set org.gnome.desktop.interface cursor-size "$CURSOR_SIZE" || echo "SKIP gsettings 写入失败"
        fi
    elif [[ "$gtk_theme" != "$CURSOR_THEME" ]]; then
        echo "KEEP GTK 光标主题为 ${gtk_theme}，保留用户选择"
    fi
}

# ---- 4. Chrome/Chromium .desktop 覆盖 ----
# Chrome 系浏览器不认任何"选后端"的环境变量，只认命令行开关，所以这份覆盖是让它把
# Wayland 偏好写进 Exec 行的唯一途径；当前它自己就选了 Wayland，这一步是防止以后环境
# 变动（例如会话后端偏好被改回 xcb）时它悄悄回退到 X11 运行。
#
# 覆盖文件从系统文件派生而不是整份写死：系统包升级后 Exec 里的路径或参数变化能跟着走，
# 也免得把版本号、安装路径抄进来。插入位置固定在 Exec 的可执行文件之后、字段代码
# （%U/%F 之类）之前；已经带该参数的行原样保留，所以重复执行不会越插越多。
#
# 用户可能在 ~/.local/share/applications 下自己写了同名文件，那份优先级更高，遇到就
# 跳过并提示，不做覆盖；首行的标记用来区分"本脚本生成的"与"用户手写的"。旧安装脚本
# 生成的文件首行是旧标记，同样认作本脚本生成。
desktop_override_marker='# generated-by: bootstrap-host.sh'
legacy_desktop_override_marker='# generated-by: install-production-host-wayland.sh'
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

render_desktop_override() {
    local source=$1 line
    printf '%s\n' "$desktop_override_marker"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == Exec=* ]]; then
            printf 'Exec=%s\n' "$(insert_ozone_platform_hint "${line#Exec=}")"
        else
            printf '%s\n' "$line"
        fi
    done < "$source"
}

# 第一个参数是系统 applications 目录，默认 /usr/share/applications（测试里指向伪造目录）。
# 目标一律写到用户级目录，不碰 /usr。
install_chrome_desktop_overrides() {
    local system_datadir=${1:-/usr/share/applications}
    local target_datadir=$DEPLOY_HOME/.local/share/applications
    local candidate source target first rendered generated=0

    for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
        source=$system_datadir/$candidate.desktop
        target=$target_datadir/$candidate.desktop
        [[ -f "$source" ]] || continue
        if [[ -e "$target" ]]; then
            first=$(head -n 1 "$target" 2>/dev/null) || first=
            if [[ "$first" != "$desktop_override_marker" && "$first" != "$legacy_desktop_override_marker" ]]; then
                echo "SKIP_DESKTOP_OVERRIDE $target（已存在且非本脚本生成）"
                continue
            fi
        fi
        rendered=$(render_desktop_override "$source")
        [[ -e "$target" && "$rendered" == "$(cat "$target")" ]] && continue
        step "生成 $target（Exec 加 $ozone_hint_argument）" || continue
        backup_file "$target"
        mkdir -p "$target_datadir"
        printf '%s\n' "$rendered" > "$target"
        chmod 644 "$target"
        generated=1
    done

    # 有桌面数据库工具就让它把新文件收进去；缺工具或失败都不算失败。
    if ((generated)) && command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$target_datadir" >/dev/null 2>&1 || true
    fi
    return 0
}

# 供测试 source 本文件时只取函数定义，不跑下面的主流程。
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

# 装的是跑远程桌面的那个用户自己的文件：以该用户运行，不要 sudo。
((TEST_HOME)) || ((EUID != 0)) || fail "不要以 root 运行，用跑远程桌面的那个用户运行"
[[ -d "$DEPLOY_HOME" && -w "$DEPLOY_HOME" ]] || fail "HOME 不存在或不可写: $DEPLOY_HOME"
echo "BOOTSTRAP_MODE $( ((apply)) && echo apply || echo dry-run) home=$DEPLOY_HOME"

install_python_elf
kde_config "$DEPLOY_HOME/.config/kwinrc" Plugins selkieskwinadapterEnabled true
install_cursor_theme_config
install_chrome_desktop_overrides

# 菜单缓存放在 .desktop 覆盖之后，一次收全；有改动才重建。
if ((changes > 0)); then
    if ((TEST_HOME)); then
        echo "SKIP kbuildsycoca6（测试 HOME）"
    elif command -v kbuildsycoca6 >/dev/null 2>&1; then
        if step "kbuildsycoca6 --noincremental"; then
            kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
        fi
    fi
fi

[[ -n "$BACKUP_DIR" ]] && echo "BACKUP_DIR $BACKUP_DIR"
echo "BOOTSTRAP_SUMMARY mode=$( ((apply)) && echo apply || echo dry-run) changes=$changes"
