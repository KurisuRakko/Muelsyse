#!/usr/bin/env bash
# check-drift 的离线测试：在 mktemp -d 里造假仓库、假 HOME 和假 manifest，不碰真实生产。
# 用法: scripts/tests/test_check_drift.sh
set -Eeuo pipefail

here=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
checker="$here/../check-drift.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

failures=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; failures=$((failures + 1)); }

# 期望某状态行出现（状态 + target）
expect_line() {
    local out=$1 status=$2 target=$3
    if grep -qE "^$status ${target//./[.]}( |$)" <<<"$out"; then
        ok "$status $target"
    else
        bad "缺少 '$status $target'"
    fi
}

expect_no_line() {
    local out=$1 pattern=$2
    if grep -qE "$pattern" <<<"$out"; then
        bad "不应出现 '$pattern'"
    else
        ok "没有 '$pattern'"
    fi
}

repo="$work/repo"
home="$work/home"
mkdir -p "$repo/deploy" "$repo/systemd" "$repo/scripts" "$repo/system" "$repo/src/thing"
mkdir -p "$home/.config/systemd/user/remote-desktop-wayland.service.d" "$home/.local/libexec" "$home/.local/bin" "$home/etc"

# 仓库侧
printf '[Service]\nExecStart=/bin/true\n' >"$repo/systemd/remote-desktop-wayland.service"
printf '[Service]\nNice=5\n' >"$repo/systemd/remote-desktop-selkies.service"
printf '#!/bin/sh\necho repo\n' >"$repo/scripts/dri-node-resolve.sh"
printf '#!/bin/sh\necho mode\n' >"$repo/scripts/selkies-dri-exec.sh"
printf 'TEMPLATE=@HOME@\n' >"$repo/system/env.in"
printf '[Service]\nExecStart=/bin/true\n' >"$repo/systemd/muelsyse-imecaret.service"
printf '# 注释\nip saddr @MUELSYSE_LAN_CIDR@ tcp dport @MUELSYSE_PORT@ accept\n\ntcp dport 8444 accept\n' >"$repo/system/fw.nft"
# render：占位符展开后再比；@MUELSYSE_PORT@ 走内置默认 8090，@MUELSYSE_LAN_CIDR@ 来自主机 env 文件
printf '[Unit]\nConditionUser=@USER@\n[Service]\nExecStart=@HOME@/bin/x\nEnvironment=XDG_RUNTIME_DIR=/run/user/@UID@ G=@GROUP@ P=@MUELSYSE_PORT@\nEnvironment=MAIL=a@example.com@x\n' >"$repo/systemd/render.service"
printf 'listen @MUELSYSE_UNSET_THING@\n' >"$repo/system/needs-var.conf"
printf 'int main(void){return 0;}\n' >"$repo/src/thing/main.c"

# 生产侧
mkdir -p "$home/.config/muelsyse"
printf '# 主机参数\nMUELSYSE_LAN_CIDR="198.51.100.0/24"\nexport MUELSYSE_EXTRA=1\n' >"$home/.config/muelsyse/env"
me=$(id -un); my_uid=$(id -u); my_group=$(id -gn)
rendered_service="[Unit]
ConditionUser=$me
[Service]
ExecStart=$home/bin/x
Environment=XDG_RUNTIME_DIR=/run/user/$my_uid G=$my_group P=8090
Environment=MAIL=a@example.com@x"
printf '%s\n' "$rendered_service" >"$home/.config/systemd/user/render-same.service" && chmod 644 "$home/.config/systemd/user/render-same.service"    # SAME（展开后相同）
cp "$repo/systemd/render.service" "$home/.config/systemd/user/render-raw.service" && chmod 644 "$home/.config/systemd/user/render-raw.service"   # DRIFT（装的是没展开的原文）
printf 'listen x\n' >"$home/etc/needs-var.conf" && chmod 644 "$home/etc/needs-var.conf"                                          # RENDER_FAIL
cp "$repo/systemd/remote-desktop-wayland.service" "$home/.config/systemd/user/"            # SAME
printf '[Service]\nNice=10\n' >"$home/.config/systemd/user/remote-desktop-selkies.service"  # DRIFT
cp "$repo/scripts/selkies-dri-exec.sh" "$home/.local/libexec/" && chmod 600 "$home/.local/libexec/selkies-dri-exec.sh"  # MODE
printf 'TEMPLATE=/home/x\n' >"$home/.config/remote-desktop.env" && chmod 644 "$home/.config/remote-desktop.env"        # TEMPLATE_OK
printf 'table inet filter {\n  ip saddr 198.51.100.0/24   tcp dport 8090 accept\n  tcp dport 8444 accept\n}\n' >"$home/etc/fw-ok.conf"   # CHECK_OK
printf 'table inet filter {\n  tcp dport 8444 accept\n}\n' >"$home/etc/fw-bad.conf"                                        # CHECK_FAIL
printf 'binary\n' >"$home/.local/bin/thing" && touch -d '2000-01-01' "$home/.local/bin/thing"                              # BUILD_STALE
printf 'old\n' >"$home/.local/libexec/selkies-old-wrapper"                                                                # RETIRED_PRESENT
printf 'x\n' >"$home/.local/libexec/sunshine-extra.sh"                                                                    # UNMANAGED
printf 'x\n' >"$home/.config/systemd/user/remote-desktop-wayland.service.d/extra.conf"                                    # UNMANAGED（.d 内）
printf 'x\n' >"$home/.config/systemd/user/remote-desktop-wayland.service.bak-20260918"                                   # JUNK
printf 'x\n' >"$home/.config/systemd/user/remote-desktop-wayland.service.d/10-x.conf.disabled-1"                         # JUNK
printf 'x\n' >"$home/.local/libexec/selkies-python3.13"                                                                   # 白名单
printf 'x\n' >"$home/.local/libexec/unrelated-tool"                                                                       # 不在扫描范围
chmod 644 "$home/.config/systemd/user/remote-desktop-wayland.service"

tab=$'\t'
{
    echo "# repo_path${tab}target${tab}mode${tab}owner${tab}kind${tab}restart"
    echo "systemd/remote-desktop-wayland.service${tab}~/.config/systemd/user/remote-desktop-wayland.service${tab}0644${tab}user${tab}copy${tab}session"
    echo "systemd/remote-desktop-selkies.service${tab}~/.config/systemd/user/remote-desktop-selkies.service${tab}0644${tab}user${tab}copy${tab}selkies"
    echo "scripts/dri-node-resolve.sh${tab}~/.local/libexec/dri-node-resolve.sh${tab}0755${tab}user${tab}copy${tab}selkies"
    echo "scripts/selkies-dri-exec.sh${tab}~/.local/libexec/selkies-dri-exec.sh${tab}0755${tab}user${tab}copy${tab}selkies"
    echo "system/env.in${tab}~/.config/remote-desktop.env${tab}0644${tab}user${tab}template${tab}session"
    echo "systemd/muelsyse-imecaret.service${tab}~/.config/systemd/user/muelsyse-imecaret.service${tab}0644${tab}user${tab}template${tab}unit:muelsyse-imecaret.service"
    echo "system/fw.nft${tab}~/etc/fw-ok.conf${tab}0644${tab}user${tab}check${tab}nft-reload"
    echo "system/fw.nft${tab}~/etc/fw-bad.conf${tab}0644${tab}user${tab}check${tab}nft-reload"
    echo "src/thing${tab}~/.local/bin/thing${tab}0755${tab}user${tab}build${tab}none"
    echo "systemd/render.service${tab}~/.config/systemd/user/render-same.service${tab}0644${tab}user${tab}render${tab}none"
    echo "systemd/render.service${tab}~/.config/systemd/user/render-raw.service${tab}0644${tab}user${tab}render${tab}none"
    echo "system/needs-var.conf${tab}~/etc/needs-var.conf${tab}0644${tab}user${tab}render${tab}none"
} >"$repo/deploy/manifest.tsv"
printf '~/.local/libexec/selkies-old-wrapper\tscripts/selkies-dri-exec.sh\t旧包装\n~/.local/libexec/gone\t\t已删\n' >"$repo/deploy/retired.tsv"

run() {
    set +e
    out=$(MUELSYSE_DRIFT_HOME="$home" "$checker" --no-runtime --manifest "$repo/deploy/manifest.tsv" "$@" 2>&1)
    rc=$?
    set -e
}

run --all
echo "----- check-drift --all 输出 -----"
echo "$out"
echo "----------------------------------"
expect_line "$out" SAME "~/.config/systemd/user/remote-desktop-wayland.service"
expect_line "$out" DRIFT "~/.config/systemd/user/remote-desktop-selkies.service"
expect_line "$out" MISSING "~/.local/libexec/dri-node-resolve.sh"
expect_line "$out" MISSING "~/.config/systemd/user/muelsyse-imecaret.service"
expect_line "$out" MODE "~/.local/libexec/selkies-dri-exec.sh"
expect_line "$out" TEMPLATE_OK "~/.config/remote-desktop.env"
expect_line "$out" CHECK_OK "~/etc/fw-ok.conf"
expect_line "$out" CHECK_FAIL "~/etc/fw-bad.conf"
expect_line "$out" BUILD_STALE "~/.local/bin/thing"
expect_line "$out" SAME "~/.config/systemd/user/render-same.service"
expect_line "$out" DRIFT "~/.config/systemd/user/render-raw.service"
expect_line "$out" RENDER_FAIL "~/etc/needs-var.conf"
grep -q '^RENDER_FAIL .*MUELSYSE_UNSET_THING' <<<"$out" && ok "RENDER_FAIL 点名缺的变量" || bad "RENDER_FAIL 没说缺哪个变量"
expect_line "$out" RETIRED_PRESENT "~/.local/libexec/selkies-old-wrapper"
expect_line "$out" UNMANAGED "~/.local/libexec/sunshine-extra.sh"
expect_line "$out" UNMANAGED "~/.config/systemd/user/remote-desktop-wayland.service.d/extra.conf"
expect_line "$out" JUNK "~/.config/systemd/user/remote-desktop-wayland.service.bak-20260918"
expect_line "$out" JUNK "~/.config/systemd/user/remote-desktop-wayland.service.d/10-x.conf.disabled-1"
expect_no_line "$out" "selkies-python3.13"
expect_no_line "$out" "unrelated-tool"
expect_no_line "$out" "libexec/gone"
expect_no_line "$out" "^(UNMANAGED|JUNK) .*selkies-old-wrapper"
[[ $rc -eq 1 ]] && ok "有漂移时退出码 1" || bad "有漂移时退出码应为 1，实际 $rc"
tail -n1 <<<"$out" | grep -q '^SUMMARY result=FAIL ' && ok "汇总行" || bad "汇总行格式"

# 默认不打印 SAME/TEMPLATE_OK/CHECK_OK
run
expect_no_line "$out" "^(SAME|TEMPLATE_OK|CHECK_OK) "

# --render 把文件展开到 stdout，与漂移检查用的是同一份结果
set +e
render_out=$(MUELSYSE_DRIFT_HOME="$home" "$checker" --render "$repo/systemd/render.service")
rc=$?
set -e
[[ $rc -eq 0 && "$render_out" == "$rendered_service" ]] && ok "--render 输出展开结果" || { bad "--render 输出不对（rc=$rc）"; echo "$render_out"; }
set +e
MUELSYSE_DRIFT_HOME="$home" "$checker" --render "$repo/system/needs-var.conf" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 2 ]] && ok "--render 缺变量退出码 2" || bad "--render 缺变量退出码应为 2，实际 $rc"
set +e
MUELSYSE_ENV_FILE="$work/nope.env" MUELSYSE_DRIFT_HOME="$home" "$checker" --render "$repo/system/fw.nft" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 2 ]] && ok "MUELSYSE_ENV_FILE 指向别处时不读 HOME 下的 env" || bad "MUELSYSE_ENV_FILE 没生效，退出码 $rc"

# 修好所有失败项，只剩 JUNK → 退出码 0
printf 'MUELSYSE_UNSET_THING=x\n' >>"$home/.config/muelsyse/env"
printf '%s\n' "$rendered_service" >"$home/.config/systemd/user/render-raw.service"
cp "$repo/systemd/remote-desktop-selkies.service" "$home/.config/systemd/user/remote-desktop-selkies.service"
chmod 644 "$home/.config/systemd/user/remote-desktop-selkies.service"
cp "$repo/scripts/dri-node-resolve.sh" "$home/.local/libexec/" && chmod 755 "$home/.local/libexec/dri-node-resolve.sh"
cp "$repo/systemd/muelsyse-imecaret.service" "$home/.config/systemd/user/" && chmod 644 "$home/.config/systemd/user/muelsyse-imecaret.service"
chmod 755 "$home/.local/libexec/selkies-dri-exec.sh"
cp "$home/etc/fw-ok.conf" "$home/etc/fw-bad.conf"
touch "$home/.local/bin/thing"
rm -- "$home/.local/libexec/selkies-old-wrapper" "$home/.local/libexec/sunshine-extra.sh" \
    "$home/.config/systemd/user/remote-desktop-wayland.service.d/extra.conf"
run
[[ $rc -eq 0 ]] && ok "只剩 JUNK 时退出码 0" || { bad "只剩 JUNK 时退出码应为 0，实际 $rc"; echo "$out"; }
expect_line "$out" JUNK "~/.config/systemd/user/remote-desktop-wayland.service.bak-20260918"
tail -n1 <<<"$out" | grep -q '^SUMMARY result=OK ' && ok "汇总 OK" || bad "汇总应为 OK"

# 用法错误 → 2
run --bogus
[[ $rc -eq 2 ]] && ok "未知参数退出码 2" || bad "未知参数退出码应为 2，实际 $rc"
set +e
MUELSYSE_DRIFT_HOME="$home" "$checker" --no-runtime --manifest "$work/nope.tsv" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 2 ]] && ok "manifest 不存在退出码 2" || bad "manifest 不存在退出码应为 2，实际 $rc"
printf 'a\tb\tc\n' >"$work/broken.tsv"
set +e
MUELSYSE_DRIFT_HOME="$home" "$checker" --no-runtime --manifest "$work/broken.tsv" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 2 ]] && ok "manifest 列数不对退出码 2" || bad "manifest 列数不对退出码应为 2，实际 $rc"

# 纯只读：跑完假 HOME 里不应多出文件
before=$(find "$home" "$repo" | sort | sha256sum)
run --all
after=$(find "$home" "$repo" | sort | sha256sum)
[[ "$before" == "$after" ]] && ok "没有写文件" || bad "运行后文件树有变化"

if ((failures)); then
    echo "TEST_FAIL $failures 项失败"
    exit 1
fi
echo "TEST_PASS"
