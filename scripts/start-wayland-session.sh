#!/usr/bin/env bash
# 启动同一用户下的 KWin virtual backend 与 Plasma shell，并让任一进程退出
# 时整个临时/生产会话结束。脚本不创建第二个 compositor。
set -Eeuo pipefail

kwin_prefix=${SELKIES_KWIN_PREFIX:-}
kwin_bin=${SELKIES_KWIN_BIN:-${kwin_prefix:+$kwin_prefix/bin/kwin_wayland}}
kwin_bin=${kwin_bin:-/usr/bin/kwin_wayland}
plasma_bin=${SELKIES_PLASMASHELL_BIN:-/usr/bin/plasmashell}
activity_bin=${SELKIES_ACTIVITYMANAGER_BIN:-/usr/lib/x86_64-linux-gnu/libexec/kactivitymanagerd}
wayland_display=${WAYLAND_DISPLAY:-wayland-remote-desktop}
socket_path="${XDG_RUNTIME_DIR:?}/${wayland_display}"
xwayland_bin=${SELKIES_XWAYLAND_BIN:-/usr/bin/Xwayland}
x_display=${SELKIES_XWAYLAND_DISPLAY:-:0}
xauth_file="${XDG_RUNTIME_DIR:?}/selkies-xauth"
xprep_bin=${SELKIES_XWAYLAND_PREP:-$(dirname "$0")/selkies-xwayland-listen.py}
x11_socket_dir=${SELKIES_X11_SOCKET_DIR:-/tmp/.X11-unix}
x11_lock_dir=${SELKIES_X11_LOCK_DIR:-/tmp}
x_lock_file="$x11_lock_dir/.X${x_display#:}-lock"
x_socket_file="$x11_socket_dir/X${x_display#:}"

[[ -x "$kwin_bin" ]] || { echo "WAYLAND_SESSION_FAIL KWin binary not executable: $kwin_bin" >&2; exit 1; }
[[ -x "$plasma_bin" ]] || { echo "WAYLAND_SESSION_FAIL plasmashell not executable: $plasma_bin" >&2; exit 1; }
[[ -x "$activity_bin" ]] || { echo "WAYLAND_SESSION_FAIL activity manager not executable: $activity_bin" >&2; exit 1; }
[[ -x "$xwayland_bin" ]] || { echo "WAYLAND_SESSION_FAIL Xwayland binary not executable: $xwayland_bin" >&2; exit 1; }
[[ -f "$xprep_bin" ]] || { echo "WAYLAND_SESSION_FAIL Xwayland prep helper missing: $xprep_bin" >&2; exit 1; }

if [[ -n "$kwin_prefix" ]]; then
    # 隔离构建的 KWin 插件位于 bin/kwin/plugins；同时保留 Qt 的常规插件目录。
    plugin_paths=("$kwin_prefix/bin/kwin/plugins" "$kwin_prefix/bin" "$kwin_prefix/lib/x86_64-linux-gnu/qt6/plugins" "$kwin_prefix/lib/qt6/plugins")
    existing_plugin_path=${QT_PLUGIN_PATH:-}
    QT_PLUGIN_PATH=$(IFS=:; echo "${plugin_paths[*]}${existing_plugin_path:+:$existing_plugin_path}")
    export QT_PLUGIN_PATH
    XDG_DATA_DIRS="$kwin_prefix/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    export XDG_DATA_DIRS
fi

# 本会话的 pid 先归零并立刻装上 trap：下面任何一步提前退出都要能走到 cleanup，
# 早退路径同样需要它（例如助手发现 display 被占而失败时）。
kwin_pid=0
plasma_pid=0
activity_pid=0

cleanup() {
    set +e
    # 逐个判断 pid > 0：pid 为 0 时 kill 的信号目标是整个进程组，会连带杀掉调用方与
    # 其它会话的进程，并且会让本函数再次被触发、一路递归下去。
    for _pid in "$plasma_pid" "$activity_pid" "$kwin_pid"; do
        ((_pid > 0)) && kill "$_pid" 2>/dev/null
    done
    for _pid in "$plasma_pid" "$activity_pid" "$kwin_pid"; do
        ((_pid > 0)) && wait "$_pid" 2>/dev/null
    done
    # 只清本会话自己的 X11 残留：助手写 lock 时用的是自己的 pid，而它随后 exec 成了
    # KWin，所以 lock 里记的 pid 就是本会话的 $kwin_pid。pid 对不上说明这个号属于别的
    # 会话（助手可能压根没占到号，或号已被复用），绝不能删——删了会破坏正在运行的会话。
    if [[ -f "$x_lock_file" ]] \
        && [[ "$(tr -d '[:space:]' < "$x_lock_file" 2>/dev/null)" == "$kwin_pid" ]]; then
        rm -f "$x_socket_file" "$x_lock_file"
        # DISPLAY/XAUTHORITY 是本会话发布上去的，只有确认号是我们的才由我们撤掉。
        systemctl --user unset-environment DISPLAY XAUTHORITY || true
    fi
    return 0
}
trap cleanup EXIT INT TERM

# Xwayland 由 KWin 自己带起来（--xwayland），但 socket、lock、cookie 必须先由助手
# 准备好并把 fd 交给 KWin，KWin 才会给 Xwayland 传 -auth；助手随后 exec 成 KWin，
# 所以 $! 仍然是 KWin 自己的 pid，下面的存活检查与 kill 都不用改。
python3 "$xprep_bin" --display "$x_display" --xauth-file "$xauth_file" \
    --socket-dir "$x11_socket_dir" --lock-dir "$x11_lock_dir" -- \
    "$kwin_bin" --virtual --socket="$wayland_display" --width=3840 --height=2160 --scale=1 \
    --no-lockscreen --no-global-shortcuts &
kwin_pid=$!

for _ in $(seq 1 100); do
    [[ -S "$socket_path" ]] && break
    kill -0 "$kwin_pid" 2>/dev/null || { echo "WAYLAND_SESSION_FAIL KWin exited" >&2; exit 1; }
    sleep 0.1
done
[[ -S "$socket_path" ]] || { echo "WAYLAND_SESSION_FAIL Wayland socket missing: $socket_path" >&2; exit 1; }

# KWin 自己不会把 DISPLAY/XAUTHORITY 推到 systemd user manager 或 D-Bus 激活环境。
# 菜单和 krunner 起的应用走 app-*.service，只认这里的值，不发布就会出现"X11 应用
# 起不来但手动在终端里能跑"这种怪现象。顺带把会话类型改回 wayland：原来的
# DISPLAY=:2 与 XDG_SESSION_TYPE=x11 是已经拆除的 TigerVNC 残留，留着会让应用按
# X11 会话走错分支。unset VNCDESKTOP 同理，那个变量已经没有任何生产者。
#
# 发布前先让 launcher 自身环境成为唯一真源：launcher 是从 user manager 继承环境启动
# 的，里面可能带着陈旧的 DISPLAY（例如已拆除的 TigerVNC 留下的 :2）。
#
# 下面两条命令都必须用显式赋值（VAR=VALUE）而不是只给变量名：按名取值的
# dbus-update-activation-environment 是从调用者的进程环境里读值再写回 systemd 的，
# 只给名字就会把我们刚要覆盖掉的陈旧 :2 又写回去，把 set-environment 的结果冲掉。
# 这种覆盖只在陈旧值存在时才发生，所以表现为"整机重启后自愈、之后某次 restart 又复现"。
#
# 桌面身份变量同理必须在这里发布：浏览器（Chromium 与 Firefox）按会话的桌面身份判断
# 要不要请求服务端装饰，而它们由 app-*.service 拉起、只认 user manager 与 D-Bus 激活
# 环境里的值；身份缺失时就退回自绘的客户端装饰，表现为顶栏变成应用自己的蓝色标题栏、
# 最小化/最大化按钮消失。KDE_FULL_SESSION 是 KDE 应用与部分第三方程序判断"当前是不是
# KDE 会话"的标志，XDG_MENU_PREFIX 决定菜单定义（applications.menu）的查找前缀，
# 缺了它菜单会异常。
#
# 后端偏好给的是回退列表而不是单个后端：某个后端不可用时（升级后 GDK/Qt 的 Wayland
# 平台插件缺失、插件路径被改坏、合成器还没起来）列表里的下一个后端还能让应用落回去
# 启动；只写 wayland 等于把这条退路堵死，应用就直接起不来。
#
# Qt 的这份列表用分号分隔，而分号在 shell 里是命令分隔符：整条赋值必须带双引号，
# 否则 shell 会在分号处断句，把后半截当成命令去执行。
#
# 后面启动 activity manager 与 plasmashell 的两行仍把 Qt 平台钉在 wayland、不跟随这份
# 回退列表：它们是本会话合成器的组成部分，必须挂在本会话的 Wayland 上，回落到 xcb 只会
# 连到宿主残留的 X11 显示上去；那两行也已经各自带上本会话的 DISPLAY/XAUTHORITY。
export DISPLAY="$x_display" XAUTHORITY="$xauth_file" WAYLAND_DISPLAY="$wayland_display" \
    XDG_SESSION_TYPE=wayland DESKTOP_SESSION=plasma \
    XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE KDE_FULL_SESSION=true \
    XDG_MENU_PREFIX=plasma- "GDK_BACKEND=wayland,x11" "QT_QPA_PLATFORM=wayland;xcb" \
    ELECTRON_OZONE_PLATFORM_HINT=auto MOZ_GTK_TITLEBAR_DECORATION=system
unset VNCDESKTOP

systemctl --user set-environment "DISPLAY=$x_display" "XAUTHORITY=$xauth_file" \
    "WAYLAND_DISPLAY=$wayland_display" XDG_SESSION_TYPE=wayland DESKTOP_SESSION=plasma \
    XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE KDE_FULL_SESSION=true \
    XDG_MENU_PREFIX=plasma- "GDK_BACKEND=wayland,x11" "QT_QPA_PLATFORM=wayland;xcb" \
    ELECTRON_OZONE_PLATFORM_HINT=auto MOZ_GTK_TITLEBAR_DECORATION=system
systemctl --user unset-environment VNCDESKTOP || true
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    # --systemd 让 systemd user manager 与 D-Bus 激活环境拿到同一份值，避免两处不一致。
    dbus-update-activation-environment --systemd "DISPLAY=$x_display" "XAUTHORITY=$xauth_file" \
        "WAYLAND_DISPLAY=$wayland_display" XDG_SESSION_TYPE=wayland DESKTOP_SESSION=plasma \
        XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE KDE_FULL_SESSION=true \
        XDG_MENU_PREFIX=plasma- "GDK_BACKEND=wayland,x11" "QT_QPA_PLATFORM=wayland;xcb" \
        ELECTRON_OZONE_PLATFORM_HINT=auto MOZ_GTK_TITLEBAR_DECORATION=system || true
fi

# plasmashell 在没有 activity manager 时会主动放弃加载，结果就是黑屏但鼠标仍可见。
# 这里以本会话自己的 Wayland/Xwayland 环境启动系统组件，显式给出 DISPLAY/XAUTHORITY，
# 让它们派生的 X11 子进程能连上这套会话的 Xwayland。
env DISPLAY="$x_display" XAUTHORITY="$xauth_file" QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$wayland_display" "$activity_bin" &
activity_pid=$!
for _ in $(seq 1 50); do
    if busctl --user status org.kde.ActivityManager >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "$activity_pid" 2>/dev/null; then
        echo "WAYLAND_SESSION_FAIL activity manager exited" >&2
        exit 1
    fi
    sleep 0.1
done
busctl --user status org.kde.ActivityManager >/dev/null 2>&1 || {
    echo "WAYLAND_SESSION_FAIL activity manager D-Bus name missing" >&2
    exit 1
}

# 同样显式给出本会话的 DISPLAY/XAUTHORITY，避免 Plasma 在重绘或拉起 X11 客户端时
# 误选宿主登录会话残留的 X11 display。
env DISPLAY="$x_display" XAUTHORITY="$xauth_file" QT_QPA_PLATFORM=wayland WAYLAND_DISPLAY="$wayland_display" "$plasma_bin" --no-respawn &
plasma_pid=$!

while kill -0 "$kwin_pid" 2>/dev/null; do
    if ! kill -0 "$plasma_pid" 2>/dev/null; then
        echo "WAYLAND_SESSION_FAIL plasmashell exited" >&2
        exit 1
    fi
    sleep 1
done

wait "$kwin_pid"
