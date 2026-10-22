#!/usr/bin/env bash
# 按 deploy/manifest.tsv 把仓库文件部署到本机生产路径。仓库是唯一事实源：生产上的
# unit、libexec、配置都由这里生成，手工改生产算漂移（scripts/check-drift.sh 会报）。
#
# 默认只读（dry-run）：逐行比较仓库与生产，打印会装/会改的项和 diff 摘要、会退休的
# 旧文件、unit 启用状态差异，以及汇总出的重启动作，不写任何文件。
#
#   --apply            真装。覆盖或移走的旧文件按原绝对路径镜像进
#                      ~/.local/share/remote-desktop/backups/<时间戳>/，不再到处留 .bak-*
#   --system           同时处理 owner=root 的行、system unit；每条 sudo 命令先打印
#   --retire           处理 deploy/retired.tsv：旧文件移进同一备份目录（不删）。manifest 里任何
#                      check 行没过（缺规则或读不了）就整批拒绝退休、退出码 3，其余安装照常；
#                      旧路径还被已部署 target 或 sunshine.conf 引用的单项跳过并警告
#   --restart          装完执行非 session 的重启动作（selkies、单个 unit；root 的要 --system）
#   --restart-session  连整个会话一起重启（关掉所有窗口），隐含 --restart
#   --no-drift-check   不跑 scripts/check-drift.sh
#   --diff-lines N     每项 diff 摘要最多 N 行（默认 20）
#
# manifest 列（TAB 分隔，# 注释）：repo_path target mode owner kind restart
#   target  用户文件写 ~/...，root 文件写绝对路径
#   kind    copy | render（展开占位符后按 copy 处理）| template（目标不存在才装）| build |
#           check（不装，只检查）
#           render 和 check 的仓库文件里 @HOME@ @USER@ @GROUP@ @UID@ @RAKKORD_*@ 先展开，
#           取值见 scripts/check-drift.py 的 render_values（主机值在 ~/.config/rakkord/env，
#           样例 config/rakkord.env.example）；有占位符没值就报错不装。
#           build 的 repo_path 是带 Makefile 的源码目录，写成 dir 或 dir:产物名；产物名缺省
#           取 target 的文件名。--apply 时复制到 ~/build/rakkord-<目录名> 里 make，dry-run
#           在临时目录里编，只为比较。
#           check 要求 repo 文件里每条非注释行（去首尾空白）都在 target 里出现。
#   restart session | selkies | unit:<user unit> | system-unit:<unit> | udev-reload |
#           nft-reload | reboot | none
#
# 测试用环境变量：RAKKORD_DEPLOY_HOME 替代 $HOME（展开 ~ 和备份目录根），设了它就跳过
# 所有 root 行；RAKKORD_DEPLOY_MANIFEST/RETIRED/UNITS 指定输入表；RAKKORD_DEPLOY_SYSTEMCTL
# 替代 systemctl；RAKKORD_DEPLOY_DRIFT_SCRIPT 替代漂移检查脚本。
set -Eeuo pipefail
shopt -s extglob

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST=${RAKKORD_DEPLOY_MANIFEST:-$ROOT/deploy/manifest.tsv}
RETIRED=${RAKKORD_DEPLOY_RETIRED:-$ROOT/deploy/retired.tsv}
UNITS=${RAKKORD_DEPLOY_UNITS:-$ROOT/deploy/units.tsv}
DRIFT_SCRIPT=${RAKKORD_DEPLOY_DRIFT_SCRIPT:-$ROOT/scripts/check-drift.sh}
# 占位符展开只有 check-drift.py 一份实现，部署和漂移检查按同一个结果比较。
RENDERER=$ROOT/scripts/check-drift.py
DEPLOY_HOME=${RAKKORD_DEPLOY_HOME:-$HOME}
SYSTEMCTL=${RAKKORD_DEPLOY_SYSTEMCTL:-systemctl}
# 测试只允许碰临时 HOME，root 行一律跳过，免得测试去读写 /etc。
TEST_HOME=0
[[ -n "${RAKKORD_DEPLOY_HOME:-}" ]] && TEST_HOME=1
USER_UNIT_DIR=$DEPLOY_HOME/.config/systemd/user
SYSTEM_UNIT_DIR=/etc/systemd/system
# 备份目录在第一次真要备份时才建；同一秒内跑两次时加序号，免得后一次覆盖前一次的备份。
BACKUP_ROOT=$DEPLOY_HOME/.local/share/remote-desktop/backups
BACKUP_DIR=

apply=0
system=0
retire=0
restart=0
restart_session=0
drift_check=1
diff_lines=20

usage() {
    sed -n '2,/^set -Eeuo/{/^set -Eeuo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"
}

fail() {
    echo "DEPLOY_FAIL $*" >&2
    exit 1
}

while (($#)); do
    case $1 in
        --apply) apply=1 ;;
        --system) system=1 ;;
        --retire) retire=1 ;;
        --restart) restart=1 ;;
        --restart-session) restart=1; restart_session=1 ;;
        --no-drift-check) drift_check=0 ;;
        --diff-lines) shift; [[ ${1:-} =~ ^[0-9]+$ ]] || fail "--diff-lines 要一个数字"; diff_lines=$1 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数: $1（--help 看用法）" ;;
    esac
    shift
done

((restart && !apply)) && fail "--restart/--restart-session 只能和 --apply 一起用"
((TEST_HOME && system)) && fail "设了 RAKKORD_DEPLOY_HOME 时不处理 root 行，不能加 --system"
[[ -f "$MANIFEST" ]] || fail "manifest 不存在: $MANIFEST"

# dry-run 里 build 行要在临时目录编一次才能比较；退出时只清自己建的这个目录。
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rakkord-deploy.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

mode_label() { ((apply)) && echo apply || echo dry-run; }

# 每条 sudo 命令执行前原样打印，方便 Rakko 在终端里看清楚到底以 root 做了什么。
run_sudo() {
    printf 'SUDO'; printf ' %q' "$@"; printf '\n'
    sudo "$@"
}

run_systemctl_user() {
    printf 'RUN systemctl --user'; printf ' %q' "$@"; printf '\n'
    "$SYSTEMCTL" --user "$@"
}

expand_target() {
    local target=$1
    case $target in
        '~') printf '%s\n' "$DEPLOY_HOME" ;;
        '~/'*) printf '%s/%s\n' "$DEPLOY_HOME" "${target#'~/'}" ;;
        /*) printf '%s\n' "$target" ;;
        *) return 1 ;;
    esac
}

is_unit_path() {
    case $1 in
        "$USER_UNIT_DIR"/*|"$SYSTEM_UNIT_DIR"/*) return 0 ;;
    esac
    return 1
}

# 汇总的重启动作去重后保持首次出现的顺序。
declare -a restart_actions=()
declare -A restart_seen=()
add_restart() {
    local action=$1
    [[ "$action" == none ]] && return 0
    [[ -n "${restart_seen[$action]:-}" ]] && return 0
    restart_seen[$action]=1
    restart_actions+=("$action")
}

user_units_changed=0
system_units_changed=0
pending=0
errors=0
warnings=0
declare -A planned_targets=()
declare -a retired_units_active=()
# 没过的 check 行（"target<TAB>repo"）；非空时拒绝退休，免得配置还指着旧文件就把它移走。
declare -a check_failed=()
retire_blocked=0

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

backup_path() {
    local target=$1
    printf '%s%s\n' "$BACKUP_DIR" "$target"
}

# 旧文件按原绝对路径镜像进备份目录；root 文件读不了时用 sudo 复制。
# backup_path 常在 $(...) 里调用，子 shell 改不了 BACKUP_DIR，所以先在当前 shell 里定好目录。
backup_file() {
    local target=$1 dest
    ensure_backup_dir
    dest=$(backup_path "$target")
    mkdir -p "$(dirname "$dest")"
    if [[ -r "$target" || -L "$target" ]]; then
        cp -a -- "$target" "$dest"
    else
        run_sudo cp -a -- "$target" "$dest"
    fi
    echo "  BACKUP $dest"
}

# 把仓库文件展开占位符后写进临时目录，打印展开结果的路径；失败时错误打到 stderr。
render_source() {
    local repo=$1 out
    out=$work_dir/render/$repo
    mkdir -p "$(dirname "$out")"
    RAKKORD_DRIFT_HOME=$DEPLOY_HOME /usr/bin/python3 -I "$RENDERER" --render "$ROOT/$repo" > "$out" || return 1
    printf '%s\n' "$out"
}

# 空文件也算文本：grep -I 对空文件返回失败，会被误判成二进制。
is_text() { [[ ! -s "$1" ]] || grep -Iq . "$1" 2>/dev/null; }

show_diff() {
    local old=$1 new=$2
    ((diff_lines > 0)) || return 0
    if is_text "$old" && is_text "$new"; then
        diff -u --label "生产 $old" --label "仓库 $new" "$old" "$new" | head -n "$diff_lines" | sed 's/^/    /' || true
    else
        printf '    二进制不同: 生产 %s → 仓库 %s\n' \
            "$(sha256sum < "$old" | cut -c1-12)" "$(sha256sum < "$new" | cut -c1-12)"
    fi
}

# check 行：片段里每条非注释、非空行（去首尾空白）都要在目标里原样出现。
check_fragment() {
    local fragment=$1 target=$2 line missing=0 normalized
    local -a wanted=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z "$line" || "$line" == \#* ]] && continue
        wanted+=("$line")
    done < "$fragment"
    normalized=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "$target")
    for line in "${wanted[@]}"; do
        if ! grep -Fxq -- "$line" <<< "$normalized"; then
            echo "    缺少: $line"
            missing=1
        fi
    done
    return "$missing"
}

# build 行：dry-run 在临时目录编（不碰 ~/build），--apply 在 ~/build/rakkord-<目录名> 编。
build_artifact() {
    local repo=$1 target=$2 src_dir artifact build_dir log
    src_dir=$ROOT/${repo%%:*}
    if [[ "$repo" == *:* ]]; then
        artifact=${repo#*:}
    else
        artifact=$(basename "$target")
    fi
    [[ -f "$src_dir/Makefile" ]] || { echo "  ERROR build 源码目录没有 Makefile: $src_dir" >&2; return 1; }
    if ((apply)); then
        build_dir=$DEPLOY_HOME/build/rakkord-$(basename "$src_dir")
    else
        build_dir=$work_dir/build-$(basename "$src_dir")
    fi
    mkdir -p "$build_dir"
    cp -a -- "$src_dir/." "$build_dir/"
    log=$build_dir/rakkord-deploy-build.log
    if ! make -C "$build_dir" "$artifact" > "$log" 2>&1; then
        echo "  ERROR make $artifact 失败，日志: $log" >&2
        tail -n 20 "$log" | sed 's/^/    /' >&2
        return 1
    fi
    [[ -f "$build_dir/$artifact" ]] || { echo "  ERROR make 没产出 $build_dir/$artifact" >&2; return 1; }
    printf '%s\n' "$build_dir/$artifact"
}

install_file() {
    local src=$1 target=$2 mode=$3 is_root=$4
    if ((is_root)); then
        run_sudo install -D -m "$mode" -o root -g root -- "$src" "$target"
    else
        install -D -m "$mode" -- "$src" "$target"
    fi
}

drift_check_run() {
    local stage=$1 output rc=0
    ((drift_check)) || return 0
    [[ -f "$DRIFT_SCRIPT" ]] || return 0
    output=$(bash "$DRIFT_SCRIPT" 2>&1) || rc=$?
    case $rc in
        0) echo "DRIFT_CHECK[$stage] 无漂移: $(tail -n 1 <<< "$output")" ;;
        # 退出码 1 只表示有漂移，部署前后都可能有，不当错误。
        1) echo "DRIFT_CHECK[$stage] 有漂移: $(tail -n 1 <<< "$output")" ;;
        *) echo "DRIFT_CHECK[$stage] 检查脚本异常退出 rc=$rc: $(tail -n 1 <<< "$output")"; warnings=$((warnings + 1)) ;;
    esac
}

process_manifest_row() {
    local repo=$1 target_raw=$2 mode=$3 owner=$4 kind=$5 restart_spec=$6
    local target src is_root=0 status current_mode current_owner check_output

    target=$(expand_target "$target_raw") || { echo "ERROR target 必须是 ~/... 或绝对路径: $target_raw"; errors=$((errors + 1)); return 0; }
    [[ "$owner" == root ]] && is_root=1
    [[ "$mode" =~ ^0?[0-7]{3,4}$ ]] || { echo "ERROR $target_raw 的 mode 不合法: $mode"; errors=$((errors + 1)); return 0; }
    mode=${mode#0}
    planned_targets[$target]=1

    if ((is_root && TEST_HOME)); then
        return 0
    fi

    case $kind in
        copy|render|template|check)
            src=$ROOT/$repo
            [[ -f "$src" ]] || { echo "ERROR 仓库文件不存在: $repo"; errors=$((errors + 1)); return 0; }
            if [[ "$kind" == render || "$kind" == check ]]; then
                src=$(render_source "$repo") || { echo "ERROR 展开占位符失败: $repo"; errors=$((errors + 1)); return 0; }
            fi
            ;;
        build)
            src=$(build_artifact "$repo" "$target") || { errors=$((errors + 1)); return 0; }
            ;;
        *)
            echo "ERROR 未知 kind: $kind（$repo）"; errors=$((errors + 1)); return 0 ;;
    esac

    if [[ "$kind" == check ]]; then
        if [[ ! -r "$target" ]]; then
            echo "CHECK_SKIP $target（不存在或不可读）"
            check_failed+=("$target"$'\t'"$repo")
            warnings=$((warnings + 1))
        elif check_output=$(check_fragment "$src" "$target"); then
            echo "CHECK_OK $target ← $repo"
        else
            echo "CHECK_MISSING $target 缺 $repo 里的规则（本脚本不改它，要人工补回）"
            printf '%s\n' "$check_output"
            check_failed+=("$target"$'\t'"$repo")
            warnings=$((warnings + 1))
        fi
        return 0
    fi

    # 先判断差在哪：NEW 缺文件、UPDATE 内容不同、CHMOD 只差权限或属主。
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        status=NEW
    elif [[ "$kind" == template ]]; then
        echo "KEEP $target（template，已存在不覆盖）"
        return 0
    elif [[ ! -r "$target" ]]; then
        echo "UNREADABLE $target（root 文件读不了，按需更新处理）"
        status=UPDATE
    elif ! cmp -s -- "$src" "$target"; then
        status=UPDATE
    else
        current_mode=$(stat -L -c %a -- "$target")
        current_owner=$(stat -L -c %U -- "$target")
        if [[ "$current_mode" != "$mode" ]] || { ((is_root)) && [[ "$current_owner" != root ]]; }; then
            status=CHMOD
        else
            return 0
        fi
    fi

    if ((is_root && !system)); then
        echo "SYSTEM_PENDING $status $target ← $repo（root 文件，要加 --system）"
        [[ "$status" == UPDATE && -r "$target" ]] && show_diff "$target" "$src"
        pending=$((pending + 1))
        add_restart "$restart_spec"
        return 0
    fi

    case $status in
        NEW) echo "INSTALL $target ← $repo（mode $mode，restart $restart_spec）" ;;
        UPDATE) echo "UPDATE $target ← $repo（mode $mode，restart $restart_spec）"
            [[ -r "$target" ]] && show_diff "$target" "$src" ;;
        CHMOD) echo "CHMOD $target → $mode（内容相同，restart $restart_spec）" ;;
    esac
    pending=$((pending + 1))
    add_restart "$restart_spec"
    if is_unit_path "$target"; then
        if ((is_root)); then system_units_changed=1; else user_units_changed=1; fi
    fi

    ((apply)) || return 0
    [[ "$status" != NEW ]] && backup_file "$target"
    install_file "$src" "$target" "$mode" "$is_root"
}

process_retired_row() {
    local old_raw=$1 replaced_by=$2 note=$3 old is_root=1 name state
    old=$(expand_target "$old_raw") || { echo "ERROR retired 路径必须是 ~/... 或绝对路径: $old_raw"; errors=$((errors + 1)); return 0; }
    [[ "$old" == "$DEPLOY_HOME"/* ]] && is_root=0
    ((is_root && TEST_HOME)) && return 0
    [[ -e "$old" || -L "$old" ]] || return 0

    # 旧路径还被已部署 target 或 sunshine.conf 引用（如 global_prep_cmd）就不动它。
    local refs
    refs=$(retired_references "$old")
    if [[ -n "$refs" ]]; then
        echo "RETIRE_SKIP $old 仍被引用，先改掉这些引用再退休："
        printf '%s\n' "$refs" | sed 's/^/    /'
        warnings=$((warnings + 1))
        return 0
    fi

    if ((apply && retire && retire_blocked)); then
        echo "RETIRE_SKIP $old（有 check 行没过，本次不退休）"
        retire_skipped_by_check=$((retire_skipped_by_check + 1))
        return 0
    fi

    if ! ((apply && retire)) || ((is_root && !system)); then
        echo "RETIRE_PENDING $old（由 ${replaced_by:--} 取代；${note:-无备注}）$( ((retire)) || echo '，要加 --retire')$( ((is_root && !system)) && echo '，root 文件要加 --system')"
        pending=$((pending + 1))
        return 0
    fi

    echo "RETIRE $old（由 ${replaced_by:--} 取代）"
    name=$(basename "$old")
    if [[ "$(dirname "$old")" == "$USER_UNIT_DIR" && "$name" == *.@(service|timer|socket|path|target) ]]; then
        # unit 本身是软链时 disable 会把这条主链接一起删掉（RakkoOps 踩过），交给人处理。
        [[ -L "$old" ]] && fail "退休的 unit 是软链，不自动 disable: $old"
        state=$("$SYSTEMCTL" --user is-enabled "$name" 2>/dev/null || true)
        [[ "$state" == enabled ]] && run_systemctl_user disable "$name"
        if "$SYSTEMCTL" --user is-active --quiet "$name" 2>/dev/null; then
            retired_units_active+=("$name")
        fi
    fi
    ensure_backup_dir
    mkdir -p "$(dirname "$(backup_path "$old")")"
    if ((is_root)); then
        run_sudo mv -- "$old" "$(backup_path "$old")"
    else
        mv -- "$old" "$(backup_path "$old")"
    fi
    echo "  MOVED → $(backup_path "$old")"
    is_unit_path "$old" && { if ((is_root)); then system_units_changed=1; else user_units_changed=1; fi; }
    return 0
}

# 列出还引用旧路径的文件：manifest 里已部署的 target，加上 manifest 管不到内容的 sunshine.conf。
retired_references() {
    local old=$1 f
    local -a files=()
    for f in "${!planned_targets[@]}" "$DEPLOY_HOME/.config/sunshine/sunshine.conf"; do
        [[ "$f" == "$old" ]] && continue
        [[ -f "$f" && -r "$f" ]] && files+=("$f")
    done
    ((${#files[@]})) || return 0
    grep -rlF -- "$old" "${files[@]}" 2>/dev/null | sort -u || true
}

unit_enabled_ok() {
    case $1 in
        enabled|enabled-runtime|static|indirect|generated|alias) return 0 ;;
    esac
    return 1
}

process_unit_row() {
    local unit=$1 scope=$2 want=$3 state unit_path
    case $scope in
        user) unit_path=$USER_UNIT_DIR/$unit
            state=$("$SYSTEMCTL" --user is-enabled "$unit" 2>/dev/null || true) ;;
        system)
            ((TEST_HOME)) && return 0
            unit_path=$SYSTEM_UNIT_DIR/$unit
            state=$("$SYSTEMCTL" is-enabled "$unit" 2>/dev/null || true) ;;
        *) echo "ERROR units.tsv scope 不合法: $scope（$unit）"; errors=$((errors + 1)); return 0 ;;
    esac
    state=${state:-not-found}

    if [[ "$want" == yes ]]; then
        unit_enabled_ok "$state" && return 0
        if [[ ! -e "$unit_path" && -z "${planned_targets[$unit_path]:-}" ]]; then
            echo "UNIT_MISSING $unit（$scope，应 enabled，但 unit 文件不存在、manifest 也不装）"
            warnings=$((warnings + 1))
            return 0
        fi
        if [[ "$scope" == system ]] && ((!system)); then
            echo "SYSTEM_PENDING ENABLE $unit（当前 $state，要加 --system）"
            pending=$((pending + 1))
            return 0
        fi
        echo "ENABLE $unit（$scope，当前 $state，不 --now）"
        pending=$((pending + 1))
        ((apply)) || return 0
        if [[ "$scope" == user ]]; then
            run_systemctl_user enable "$unit"
        else
            run_sudo systemctl enable "$unit"
        fi
    elif [[ "$want" == no ]]; then
        [[ "$state" == enabled ]] || return 0
        if [[ "$scope" == system ]] && ((!system)); then
            echo "SYSTEM_PENDING DISABLE $unit（要加 --system）"
            pending=$((pending + 1))
            return 0
        fi
        echo "DISABLE $unit（$scope）"
        pending=$((pending + 1))
        ((apply)) || return 0
        [[ -L "$unit_path" ]] && fail "unit 本身是软链，不自动 disable: $unit_path"
        if [[ "$scope" == user ]]; then
            run_systemctl_user disable "$unit"
        else
            run_sudo systemctl disable "$unit"
        fi
    else
        echo "ERROR units.tsv enabled 只能是 yes/no: $want（$unit）"
        errors=$((errors + 1))
    fi
}

describe_restart() {
    case $1 in
        session) echo "重启整个会话：systemctl --user restart remote-desktop-wayland.service（关掉所有窗口，Sunshine 跟着重启）" ;;
        selkies) echo "只重启 selkies：systemctl --user restart remote-desktop-selkies.service（浏览器断几秒，窗口还在）" ;;
        unit:*) echo "重启 user unit ${1#unit:}：systemctl --user restart ${1#unit:}" ;;
        system-unit:*) echo "重启 system unit ${1#system-unit:}：sudo systemctl restart ${1#system-unit:}" ;;
        udev-reload) echo "udev reload：sudo udevadm control --reload-rules && sudo udevadm trigger --action=change --subsystem-match=misc --subsystem-match=input --subsystem-match=hidraw" ;;
        nft-reload) echo "nft reload：sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables" ;;
        reboot) echo "重启机器（本脚本从不自动做）" ;;
        *) echo "未知重启动作 $1" ;;
    esac
}

execute_restart() {
    local action=$1
    case $action in
        session)
            if ((restart_session)); then
                run_systemctl_user restart remote-desktop-wayland.service
            else
                echo "SKIP 会话重启要加 --restart-session（会关掉所有窗口）"
            fi ;;
        selkies) run_systemctl_user restart remote-desktop-selkies.service ;;
        unit:*) run_systemctl_user restart "${action#unit:}" ;;
        system-unit:*|udev-reload|nft-reload)
            if ((!system)); then
                echo "SKIP $action 要加 --system"
                return 0
            fi
            case $action in
                system-unit:*) run_sudo systemctl restart "${action#system-unit:}" ;;
                udev-reload)
                    run_sudo udevadm control --reload-rules
                    run_sudo udevadm trigger --action=change --subsystem-match=misc \
                        --subsystem-match=input --subsystem-match=hidraw ;;
                nft-reload)
                    run_sudo nft -c -f /etc/nftables.conf
                    run_sudo systemctl reload nftables ;;
            esac ;;
        reboot) echo "SKIP 重启机器要手动做" ;;
    esac
}

echo "DEPLOY_MODE $(mode_label) system=$system retire=$retire home=$DEPLOY_HOME manifest=$MANIFEST"
drift_check_run before

echo "== 文件"
while IFS=$'\t' read -r repo target mode owner kind restart_spec _ || [[ -n "${repo:-}" ]]; do
    [[ -z "${repo//[[:space:]]/}" || "$repo" == \#* ]] && continue
    if [[ -z "${restart_spec:-}" ]]; then
        echo "ERROR manifest 行少列: $repo"
        errors=$((errors + 1))
        continue
    fi
    process_manifest_row "$repo" "$target" "$mode" "$owner" "$kind" "$restart_spec"
done < "$MANIFEST"

if [[ -f "$RETIRED" ]]; then
    echo "== 退休"
    retire_skipped_by_check=0
    if ((${#check_failed[@]})); then
        retire_blocked=1
        if ((retire)); then
            echo "RETIRE_BLOCKED 有 ${#check_failed[@]} 条 check 行没过，$( ((apply)) && echo 拒绝 || echo '--apply 时会拒绝')执行退休（其余安装照常）："
        else
            echo "RETIRE_BLOCKED 有 ${#check_failed[@]} 条 check 行没过，加 --retire 也会拒绝退休："
        fi
        for row in "${check_failed[@]}"; do
            echo "    ${row%%$'\t'*} 缺 ${row#*$'\t'} 里的规则：手工把片段里的行补进目标（本脚本不改它），重跑确认 CHECK_OK 后再 --retire"
        done
    fi
    while IFS=$'\t' read -r old replaced_by note || [[ -n "${old:-}" ]]; do
        [[ -z "${old//[[:space:]]/}" || "$old" == \#* ]] && continue
        process_retired_row "$old" "${replaced_by:-}" "${note:-}"
    done < "$RETIRED"
fi

# 先 daemon-reload 再对齐 enable 状态：新装的 unit 要被 systemd 认出来才能 enable。
if ((apply)); then
    ((user_units_changed)) && run_systemctl_user daemon-reload
    if ((system_units_changed && system)); then
        run_sudo systemctl daemon-reload
    fi
else
    ((user_units_changed)) && echo "DAEMON_RELOAD user（--apply 时执行）"
    ((system_units_changed)) && echo "DAEMON_RELOAD system（--apply --system 时执行）"
fi

if [[ -f "$UNITS" ]]; then
    echo "== unit 启用状态"
    while IFS=$'\t' read -r unit scope want _ || [[ -n "${unit:-}" ]]; do
        [[ -z "${unit//[[:space:]]/}" || "$unit" == \#* ]] && continue
        process_unit_row "$unit" "${scope:-}" "${want:-}"
    done < "$UNITS"
fi

((apply)) && drift_check_run after

echo "== 需要的重启"
if ((${#restart_actions[@]} == 0 && ${#retired_units_active[@]} == 0)); then
    echo "RESTART_NONE 不需要重启"
else
    for action in "${restart_actions[@]}"; do
        echo "NEED $(describe_restart "$action")"
    done
    for unit in "${retired_units_active[@]}"; do
        echo "NEED 停掉已退休但还在跑的 unit：systemctl --user stop $unit"
    done
fi

if ((restart)); then
    echo "== 执行重启"
    # 会话先重启：它会顺带拉起 selkies 等依赖，之后单独的重启再按需补一次。
    for unit in "${retired_units_active[@]}"; do
        run_systemctl_user stop "$unit"
    done
    [[ -n "${restart_seen[session]:-}" ]] && execute_restart session
    for action in "${restart_actions[@]}"; do
        [[ "$action" == session ]] && continue
        execute_restart "$action"
    done
fi

[[ -n "$BACKUP_DIR" ]] && echo "BACKUP_DIR $BACKUP_DIR"
echo "DEPLOY_SUMMARY mode=$(mode_label) pending=$pending warnings=$warnings errors=$errors"
((errors == 0)) || exit 1
if ((${retire_skipped_by_check:-0})); then
    echo "DEPLOY_RETIRE_BLOCKED check 行没过，${retire_skipped_by_check} 个旧文件未退休（退出码 3）" >&2
    exit 3
fi
