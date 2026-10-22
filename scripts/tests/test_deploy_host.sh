#!/usr/bin/env bash
# scripts/deploy-host.sh 的离线测试：把脚本复制进临时假仓库，用 MUELSYSE_DEPLOY_HOME 指向
# 临时 HOME、用假 systemctl 记录调用，全程不碰真实生产、不调 sudo、不重启任何服务。
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY=$SCRIPT_DIR/../deploy-host.sh
RENDERER=$SCRIPT_DIR/../check-drift.py
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-deploy-host.XXXXXX")
passed=0

fail() {
    echo "TEST_FAIL $*" >&2
    echo "临时目录保留在 $tmp" >&2
    exit 1
}

pass() {
    echo "ok - $*"
    passed=$((passed + 1))
}

assert_contains() {
    local haystack=$1 needle=$2 what=$3
    grep -Fq -- "$needle" <<< "$haystack" || { printf '%s\n' "$haystack" >&2; fail "$what：输出里没有「$needle」"; }
}

assert_not_contains() {
    local haystack=$1 needle=$2 what=$3
    if grep -Fq -- "$needle" <<< "$haystack"; then
        printf '%s\n' "$haystack" >&2
        fail "$what：输出里不该有「$needle」"
    fi
}

snapshot() {
    find "$1" -printf '%p %s %m %T@ %l\n' | sort
}

repo=$tmp/repo
home=$tmp/home
state=$tmp/systemctl-state
mkdir -p "$repo/scripts" "$repo/deploy" "$repo/files" "$repo/src/hello" "$home" "$state"
cp "$DEPLOY" "$repo/scripts/deploy-host.sh"
# render/check 行的占位符由同仓库的 check-drift.py 展开
cp "$RENDERER" "$repo/scripts/check-drift.py"

# 假 systemctl：is-enabled/is-active 看状态目录里的标记文件，其余调用只记日志。
cat > "$tmp/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/systemctl.log"
[[ \$1 == --user ]] && shift
case \$1 in
    is-enabled) if [[ -e "$state/\$2.enabled" ]]; then echo enabled; else echo disabled; exit 1; fi ;;
    is-active) [[ \$2 == --quiet ]] && shift; [[ -e "$state/\$2.active" ]] ;;
    enable) touch "$state/\$2.enabled" ;;
    disable) rm -f "$state/\$2.enabled" ;;
esac
exit 0
EOF
chmod +x "$tmp/systemctl"

printf 'new session script\n' > "$repo/files/session.sh"
printf '[Service]\nExecStart=/bin/true\n' > "$repo/files/foo.service"
printf 'Environment=A=new\n' > "$repo/files/selkies.conf"
printf 'template default\n' > "$repo/files/remote.env"
printf 'fresh template\n' > "$repo/files/fresh.env"
printf '# 片段\n    allow @MUELSYSE_PORT@\n' > "$repo/files/rule.nft"
printf '#!/bin/sh\nexec @HOME@/bin/x --port @MUELSYSE_PORT@ --lan @MUELSYSE_LAN_BIND@ # @USER@:@GROUP@ @UID@ user@example.org\n' > "$repo/files/rendered.sh"
printf 'bind @MUELSYSE_NOT_SET@\n' > "$repo/files/needs-var.conf"
printf 'built from source\n' > "$repo/src/hello/hello.in"
printf 'hello-bin: hello.in\n\tcp hello.in hello-bin\n' > "$repo/src/hello/Makefile"

tab=$'\t'
cat > "$repo/deploy/manifest.tsv" <<EOF
# repo_path	target	mode	owner	kind	restart
files/session.sh${tab}~/.local/libexec/session${tab}755${tab}user${tab}copy${tab}session
files/foo.service${tab}~/.config/systemd/user/foo.service${tab}644${tab}user${tab}copy${tab}unit:foo.service
files/selkies.conf${tab}~/.config/systemd/user/remote-desktop-selkies.service.d/a.conf${tab}644${tab}user${tab}copy${tab}selkies
files/remote.env${tab}~/.config/selkies/remote.env${tab}600${tab}user${tab}template${tab}selkies
files/fresh.env${tab}~/.config/selkies/fresh.env${tab}600${tab}user${tab}template${tab}none
files/rule.nft${tab}~/nftables.conf${tab}644${tab}user${tab}check${tab}nft-reload
files/rendered.sh${tab}~/.local/libexec/rendered.sh${tab}755${tab}user${tab}render${tab}none
src/hello${tab}~/.local/bin/hello-bin${tab}755${tab}user${tab}build${tab}none
system/x.service${tab}/etc/systemd/system/x.service${tab}644${tab}root${tab}copy${tab}system-unit:x.service
EOF
cat > "$repo/deploy/retired.tsv" <<EOF
# old_target	replaced_by_repo_path	note
~/.config/systemd/user/old-bridge.service${tab}files/foo.service${tab}改名
~/.local/libexec/gone-already${tab}-${tab}已经不在
EOF
cat > "$repo/deploy/units.tsv" <<EOF
foo.service${tab}user${tab}yes
missing.service${tab}user${tab}yes
socat-selkies.service${tab}system${tab}yes
EOF

# 生产现状：session 是旧内容、a.conf 内容相同但权限不对、remote.env 已存在、
# 一个已启用且在跑的旧 unit 待退休、nft 规则在。
mkdir -p "$home/.local/libexec" "$home/.config/systemd/user/remote-desktop-selkies.service.d" "$home/.config/selkies"
printf 'old session script\n' > "$home/.local/libexec/session"
chmod 755 "$home/.local/libexec/session"
cp "$repo/files/selkies.conf" "$home/.config/systemd/user/remote-desktop-selkies.service.d/a.conf"
chmod 664 "$home/.config/systemd/user/remote-desktop-selkies.service.d/a.conf"
printf 'user secret\n' > "$home/.config/selkies/remote.env"
printf '[Service]\nExecStart=/bin/false\n' > "$home/.config/systemd/user/old-bridge.service"
touch "$state/old-bridge.service.enabled" "$state/old-bridge.service.active"
printf 'table inet filter {\n  chain input {\n\tallow 8090\n  }\n}\n' > "$home/nftables.conf"
# 主机参数文件：MUELSYSE_PORT 不写，走内置默认 8090
mkdir -p "$home/.config/muelsyse"
printf '# 本机\nMUELSYSE_LAN_BIND=192.0.2.7\n' > "$home/.config/muelsyse/env"
rendered_sh="#!/bin/sh
exec $home/bin/x --port 8090 --lan 192.0.2.7 # $(id -un):$(id -gn) $(id -u) user@example.org"

export MUELSYSE_DEPLOY_HOME=$home MUELSYSE_DEPLOY_SYSTEMCTL=$tmp/systemctl
export MUELSYSE_DEPLOY_DRIFT_SCRIPT=$tmp/no-drift-script
run() { bash "$repo/scripts/deploy-host.sh" "$@" 2>&1; }

# 1. dry-run 不写任何文件，也不调用 systemctl 的写操作。
before=$(snapshot "$home")
out=$(run)
after=$(snapshot "$home")
[[ "$before" == "$after" ]] || { diff <(echo "$before") <(echo "$after") >&2; fail "dry-run 改动了 HOME"; }
if [[ -f "$tmp/systemctl.log" ]] && grep -Eq '^--user (enable|disable|daemon-reload|restart|stop)' "$tmp/systemctl.log"; then
    fail "dry-run 调用了 systemctl 写操作"
fi
[[ ! -e "$home/build" ]] || fail "dry-run 不该在 ~/build 里编"
assert_contains "$out" "DEPLOY_MODE dry-run" "dry-run 模式行"
assert_contains "$out" "UPDATE $home/.local/libexec/session" "dry-run 列出内容变化"
assert_contains "$out" "+new session script" "dry-run 带 diff 摘要"
assert_contains "$out" "CHMOD $home/.config/systemd/user/remote-desktop-selkies.service.d/a.conf → 644" "dry-run 列出权限变化"
assert_contains "$out" "INSTALL $home/.config/systemd/user/foo.service" "dry-run 列出新文件"
assert_contains "$out" "INSTALL $home/.local/bin/hello-bin" "dry-run 编 build 行再比较"
assert_contains "$out" "KEEP $home/.config/selkies/remote.env" "template 已存在不覆盖"
assert_contains "$out" "INSTALL $home/.config/selkies/fresh.env" "template 缺失时装"
assert_contains "$out" "CHECK_OK $home/nftables.conf" "check 行只检查"
assert_contains "$out" "INSTALL $home/.local/libexec/rendered.sh ← files/rendered.sh" "render 行缺失时装"
assert_contains "$out" "RETIRE_PENDING $home/.config/systemd/user/old-bridge.service" "dry-run 列出待退休"
assert_not_contains "$out" "gone-already" "已不存在的退休项不提"
assert_not_contains "$out" "/etc/systemd/system/x.service" "测试 HOME 下跳过 root 行"
assert_not_contains "$out" "socat-selkies" "测试 HOME 下跳过 system unit"
assert_contains "$out" "ENABLE foo.service" "新 unit 会 enable"
assert_contains "$out" "UNIT_MISSING missing.service" "缺 unit 文件要报"
assert_contains "$out" "DAEMON_RELOAD user" "unit 变化会 daemon-reload"
pass "dry-run 只报告不写"

# 2. 重启汇总文本：session、selkies、单个 unit 都列出来，nft-reload（check 行）和 none 不列。
assert_contains "$out" "NEED 重启整个会话" "汇总整个会话重启"
assert_contains "$out" "NEED 只重启 selkies" "汇总 selkies 重启"
assert_contains "$out" "NEED 重启 user unit foo.service" "汇总单个 unit 重启"
assert_not_contains "$out" "nft reload" "check 行不触发重启"
[[ $(grep -c '^NEED 只重启 selkies' <<< "$out") == 1 ]] || fail "selkies 重启应去重"
pass "重启汇总文本"

# 3. 漂移检查存在时前后各跑一次，退出码 1 只是"有漂移"。
printf '#!/usr/bin/env bash\necho "DRIFT a"\necho "DRIFT_SUMMARY drift=1"\nexit 1\n' > "$tmp/drift.sh"
out_drift=$(MUELSYSE_DEPLOY_DRIFT_SCRIPT=$tmp/drift.sh run)
assert_contains "$out_drift" "DRIFT_CHECK[before] 有漂移: DRIFT_SUMMARY drift=1" "dry-run 前跑漂移检查"
assert_not_contains "$out_drift" "DRIFT_CHECK[after]" "dry-run 不跑 after"
out_nodrift=$(MUELSYSE_DEPLOY_DRIFT_SCRIPT=$tmp/drift.sh run --no-drift-check)
assert_not_contains "$out_nodrift" "DRIFT_CHECK" "--no-drift-check 关掉漂移检查"
pass "漂移检查接入"

# 4. --apply：安装、备份、template 不覆盖、daemon-reload、enable 不 --now、不重启。
: > "$tmp/systemctl.log"
out=$(run --apply)
assert_contains "$out" "DEPLOY_MODE apply" "apply 模式行"
cmp -s "$repo/files/session.sh" "$home/.local/libexec/session" || fail "session 没装上"
[[ $(stat -c %a "$home/.local/libexec/session") == 755 ]] || fail "session 权限不对"
[[ $(stat -c %a "$home/.config/systemd/user/remote-desktop-selkies.service.d/a.conf") == 644 ]] || fail "a.conf 权限没改"
[[ $(stat -c %a "$home/.config/selkies/fresh.env") == 600 ]] || fail "fresh.env 没按 600 装"
[[ $(cat "$home/.config/selkies/remote.env") == "user secret" ]] || fail "template 覆盖了已有文件"
[[ $(cat "$home/.local/bin/hello-bin") == "built from source" ]] || fail "build 行没装上"
[[ $(cat "$home/.local/libexec/rendered.sh") == "$rendered_sh" ]] || { cat "$home/.local/libexec/rendered.sh" >&2; fail "render 行没按展开结果装"; }
[[ $(stat -c %a "$home/.local/libexec/rendered.sh") == 755 ]] || fail "render 行权限不对"
[[ -f "$home/build/muelsyse-hello/hello-bin" ]] || fail "build 行应在 ~/build/muelsyse-hello 编"
backup_dir=$(sed -n 's/^BACKUP_DIR //p' <<< "$out")
[[ -n "$backup_dir" && "$backup_dir" == "$home/.local/share/remote-desktop/backups/"* ]] || fail "没打印备份目录: $backup_dir"
[[ $(cat "$backup_dir$home/.local/libexec/session") == "old session script" ]] || fail "旧 session 没按原路径备份"
[[ -f "$backup_dir$home/.config/systemd/user/remote-desktop-selkies.service.d/a.conf" ]] || fail "chmod 前也要备份"
[[ ! -e "$backup_dir$home/.config/selkies/remote.env" ]] || fail "template 未动不该备份"
find "$home" -name '*.bak-*' | grep -q . && fail "不该再留 .bak-*"
grep -qx -- '--user daemon-reload' "$tmp/systemctl.log" || fail "没 daemon-reload"
grep -qx -- '--user enable foo.service' "$tmp/systemctl.log" || fail "没 enable foo.service"
grep -q -- '--now' "$tmp/systemctl.log" && fail "enable 不该带 --now"
grep -Eq -- '--user (restart|stop)' "$tmp/systemctl.log" && fail "不加 --restart 不该重启"
[[ -e "$home/.config/systemd/user/old-bridge.service" ]] || fail "不加 --retire 不该退休"
assert_contains "$out" "RETIRE_PENDING" "不加 --retire 时只列出"
assert_contains "$out" "NEED 重启整个会话" "apply 后打印重启汇总"
pass "apply 安装与备份"

# 5. 第二遍 dry-run 应该没有待办（幂等），只剩退休项。
out=$(run)
assert_not_contains "$out" "UPDATE " "幂等：无内容变化"
assert_not_contains "$out" "INSTALL " "幂等：无新文件"
assert_not_contains "$out" "ENABLE " "幂等：unit 已 enable"
assert_not_contains "$out" "NEED 重启" "幂等：无重启"
pass "重复部署幂等"

# 6. --retire：旧 unit 先 disable 再移入备份目录；仍在跑的提示 stop。
: > "$tmp/systemctl.log"
out=$(run --apply --retire)
[[ ! -e "$home/.config/systemd/user/old-bridge.service" ]] || fail "旧 unit 没移走"
backup_dir=$(sed -n 's/^BACKUP_DIR //p' <<< "$out")
[[ -f "$backup_dir$home/.config/systemd/user/old-bridge.service" ]] || fail "旧 unit 没进备份目录"
grep -qx -- '--user disable old-bridge.service' "$tmp/systemctl.log" || fail "没 disable 旧 unit"
grep -qx -- '--user daemon-reload' "$tmp/systemctl.log" || fail "退休 unit 后没 daemon-reload"
assert_contains "$out" "NEED 停掉已退休但还在跑的 unit：systemctl --user stop old-bridge.service" "提示 stop 旧 unit"
(($(find "$home/.local/share/remote-desktop/backups" -mindepth 1 -maxdepth 1 -type d | wc -l) >= 2)) || fail "两次 apply 应各有自己的备份目录"
pass "retire 移入备份"

# 7. 退休的 unit 本身是软链时停下报错，不 disable。
ln -s "$repo/files/foo.service" "$home/.config/systemd/user/old-bridge.service"
touch "$state/old-bridge.service.enabled"
: > "$tmp/systemctl.log"
if out=$(run --apply --retire); then
    fail "软链 unit 退休应失败"
fi
assert_contains "$out" "退休的 unit 是软链" "软链 unit 报错"
grep -q 'disable' "$tmp/systemctl.log" && fail "软链 unit 不该 disable"
[[ -L "$home/.config/systemd/user/old-bridge.service" ]] || fail "软链 unit 不该被移走"
rm "$home/.config/systemd/user/old-bridge.service" "$state/old-bridge.service.enabled"
pass "软链 unit 不自动 disable"

# 8. --restart 只做非 session 的；--restart-session 才重启会话。
printf 'newer\n' >> "$repo/files/session.sh"
printf 'Environment=A=newer\n' > "$repo/files/selkies.conf"
: > "$tmp/systemctl.log"
out=$(run --apply --restart)
grep -qx -- '--user restart remote-desktop-selkies.service' "$tmp/systemctl.log" || fail "--restart 没重启 selkies"
grep -q 'remote-desktop-wayland' "$tmp/systemctl.log" && fail "--restart 不该重启会话"
assert_contains "$out" "SKIP 会话重启要加 --restart-session" "提示会话重启要另加参数"
printf 'newest\n' >> "$repo/files/session.sh"
: > "$tmp/systemctl.log"
run --apply --restart-session > /dev/null
grep -qx -- '--user restart remote-desktop-wayland.service' "$tmp/systemctl.log" || fail "--restart-session 没重启会话"
if run --restart > /dev/null; then fail "--restart 没 --apply 应拒绝"; fi
pass "restart 选项"

# 9. check 行缺规则时报 CHECK_MISSING，不改目标文件。
printf 'table inet filter {}\n' > "$home/nftables.conf"
out=$(run)
assert_contains "$out" "CHECK_MISSING $home/nftables.conf" "缺规则要报"
assert_contains "$out" "缺少: allow 8090" "列出缺的规则"
[[ $(cat "$home/nftables.conf") == "table inet filter {}" ]] || fail "check 不该改目标"
pass "check 行"

# 10. check 行没过时 --apply --retire 不退休任何文件，退出码 3，其余安装照常。
printf '[Service]\nExecStart=/bin/old\n' > "$home/.config/systemd/user/old-bridge.service"
printf 'newest2\n' >> "$repo/files/session.sh"
out=$(run)
assert_contains "$out" "RETIRE_BLOCKED 有 1 条 check 行没过，加 --retire 也会拒绝退休" "dry-run 预告拒绝退休"
out=$(run --retire)
assert_contains "$out" "--apply 时会拒绝执行退休" "dry-run --retire 预告拒绝"
rc=0; out=$(run --apply --retire) || rc=$?
[[ $rc == 3 ]] || { printf '%s\n' "$out" >&2; fail "check 没过时 --apply --retire 应退出 3，实际 $rc"; }
assert_contains "$out" "RETIRE_BLOCKED" "打印拒绝原因"
assert_contains "$out" "$home/nftables.conf 缺 files/rule.nft" "指出哪条 check 没过"
assert_contains "$out" "DEPLOY_RETIRE_BLOCKED" "说明退出码"
[[ -f "$home/.config/systemd/user/old-bridge.service" ]] || fail "check 没过不该退休"
cmp -s "$repo/files/session.sh" "$home/.local/libexec/session" || fail "其余安装应照常"
pass "check 没过拒绝退休"

# 11. 旧路径仍被已部署 target 或 sunshine.conf 引用时跳过该项。
printf '# 片段\n    allow 8090\n' > "$home/nftables.conf"
mkdir -p "$home/.config/sunshine"
printf 'global_prep_cmd = [{"do":"%s"}]\n' "$home/.config/systemd/user/old-bridge.service" > "$home/.config/sunshine/sunshine.conf"
rc=0; out=$(run --apply --retire) || rc=$?
[[ $rc == 0 ]] || { printf '%s\n' "$out" >&2; fail "被引用跳过不该失败，rc=$rc"; }
assert_contains "$out" "RETIRE_SKIP $home/.config/systemd/user/old-bridge.service 仍被引用" "被引用要警告"
assert_contains "$out" "$home/.config/sunshine/sunshine.conf" "列出引用文件"
[[ -f "$home/.config/systemd/user/old-bridge.service" ]] || fail "被引用的旧文件不该移走"
rm "$home/.config/sunshine/sunshine.conf"
out=$(run --apply --retire)
[[ ! -e "$home/.config/systemd/user/old-bridge.service" ]] || fail "引用去掉后应退休"
pass "仍被引用的旧路径不退休"

# 12. render 行：生产是展开结果时无待办；改了主机参数就报 UPDATE 并给出展开后的 diff；
#     占位符没值时报错、不装、退出码 1。
out=$(run)
assert_not_contains "$out" "rendered.sh" "展开结果相同不报"
printf 'MUELSYSE_LAN_BIND=192.0.2.8\n' > "$home/.config/muelsyse/env"
out=$(run)
assert_contains "$out" "UPDATE $home/.local/libexec/rendered.sh ← files/rendered.sh" "主机参数变了要更新"
assert_contains "$out" "+exec $home/bin/x --port 8090 --lan 192.0.2.8" "diff 是展开后的内容"
printf 'MUELSYSE_LAN_BIND=192.0.2.7\n' > "$home/.config/muelsyse/env"
cp "$repo/deploy/manifest.tsv" "$tmp/needs-var.tsv"
printf 'files/needs-var.conf\t~/.config/needs-var.conf\t644\tuser\trender\tnone\n' >> "$tmp/needs-var.tsv"
rc=0; out=$(MUELSYSE_DEPLOY_MANIFEST=$tmp/needs-var.tsv run --apply) || rc=$?
[[ $rc == 1 ]] || { printf '%s\n' "$out" >&2; fail "占位符没值应退出 1，实际 $rc"; }
assert_contains "$out" "ERROR 展开占位符失败: files/needs-var.conf" "报展开失败"
assert_contains "$out" "MUELSYSE_NOT_SET" "点名缺的变量"
[[ ! -e "$home/.config/needs-var.conf" ]] || fail "展开失败不该装"
pass "render 行"

echo "PASS $passed 组（临时目录 $tmp 保留）"
