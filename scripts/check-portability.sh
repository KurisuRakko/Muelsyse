#!/usr/bin/env bash
# 可移植性检查：在已跟踪文件里找写死的本机信息（家目录、主机名、本用户的运行时目录、
# 局域网与 Tailscale 地址、公网域名、udev 里写死的属主）。有命中就逐行打印并退出 1。
#
# 主机相关的值应写成占位符（@HOME@ @USER@ @GROUP@ @UID@ @MUELSYSE_*@，部署时按
# ~/.config/muelsyse/env 展开，见 config/muelsyse.env.example）或运行时变量（$HOME、
# ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}、${MUELSYSE_*:-默认}）。
#
# 要找的值全在运行时从本机推导（id、hostname、~/.config/muelsyse/env），本文件不带任何本机字面量。
# 不查的：上游源码（kwin/ selkies/ pixelflux/）和 public/exclude.txt 里列出的不公开路径。
set -Eeuo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/muelsyse-env.sh
source "$ROOT/scripts/muelsyse-env.sh"
muelsyse_load_env

ere_escape() { sed -e 's/[][\.*^$+?(){}|/]/\\&/g' <<< "$1"; }

user=$(id -un)
host=$(hostname)
pats=(
    "/home/$(ere_escape "$user")"
    "$(ere_escape "$host")"
    "/run/user/$(id -u)/"
    "/run/user/$(id -u)\$"
    "OWNER=\"$(ere_escape "$user")\""
    '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'
)
[[ "${host%%.*}" != "$host" ]] && pats+=("$(ere_escape "${host%%.*}")")
[[ -n "${MUELSYSE_LAN_BIND:-}" ]] && pats+=("$(ere_escape "$MUELSYSE_LAN_BIND")")
if [[ -n "${MUELSYSE_LAN_CIDR:-}" ]]; then
    # 网段前缀：/24 取前三段 "a.b.c."，/16 取前两段，以此类推（至少一段）。
    bits=${MUELSYSE_LAN_CIDR#*/}; [[ "$bits" == "$MUELSYSE_LAN_CIDR" ]] && bits=24
    n=$((bits / 8)); ((n < 1)) && n=1
    IFS=. read -r -a oct <<< "${MUELSYSE_LAN_CIDR%/*}"
    prefix=$(IFS=.; echo "${oct[*]:0:n}").
    pats+=("$(ere_escape "$prefix")")
fi
[[ -n "${MUELSYSE_TAILNET_BIND:-}" ]] && pats+=("$(ere_escape "$MUELSYSE_TAILNET_BIND")")
[[ -n "${MUELSYSE_PUBLIC_HOST:-}" ]] && pats+=("$(ere_escape "$MUELSYSE_PUBLIC_HOST")")
PATTERN=$(IFS='|'; echo "${pats[*]}")

# 排除：上游源码，加上 public/exclude.txt（bash glob，结尾 / 表示目录）转成的正则。
excl=('(kwin|selkies|pixelflux)/')
if [[ -r "$ROOT/public/exclude.txt" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}; line=${line//[[:space:]]/}
        [[ -z "$line" ]] && continue
        re=$(ere_escape "$line")
        re=${re//\\\*\\\*/.*}; re=${re//\\\*/[^/]*}
        [[ "$line" == */ ]] && excl+=("$re") || excl+=("$re\$")
    done < "$ROOT/public/exclude.txt"
fi
EXCLUDE="^($(IFS='|'; echo "${excl[*]}"))"

hits=$(git -C "$ROOT" ls-files -z \
    | grep -zvE "$EXCLUDE" \
    | (cd "$ROOT" && xargs -0 -r grep -nIE -- "$PATTERN" 2>/dev/null) || true)

if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    echo "PORTABILITY_FAIL $(wc -l <<< "$hits") 处写死的本机信息" >&2
    exit 1
fi
echo "PORTABILITY_OK"
