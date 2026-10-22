# 仓库脚本共用：读主机参数文件 ~/.config/rakkord/env（RAKKORD_ENV_FILE 可改路径；样例
# config/rakkord.env.example）。用法：source 本文件后调用 rakkord_load_env，再写 ${RAKKORD_X:-默认}。
#
# 不直接 source 那个文件：解析规则与 scripts/check-drift.py 的 load_env_file 相同（KEY=VALUE、
# # 注释、可选 export 前缀、去掉两端成对引号、不做 $ 展开），两边读出同一个值；
# 而且环境里已经给了的变量优先，命令行上临时覆盖不会被文件压回去。
# shellcheck shell=bash

rakkord_load_env() {
    local file=${RAKKORD_ENV_FILE:-$HOME/.config/rakkord/env} line key value
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == export\ * ]] && { line=${line#export }; line=${line#"${line%%[![:space:]]*}"}; }
        key=${line%%=*}
        [[ "$line" == *=* && "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            echo "rakkord-env: $file 里有一行不是 KEY=VALUE: $line" >&2
            return 1
        }
        value=${line#*=}
        if ((${#value} >= 2)) && [[ "${value:0:1}" == "${value: -1}" && "${value:0:1}" == [\'\"] ]]; then
            value=${value:1:${#value}-2}
        fi
        [[ -n "${!key+x}" ]] && continue
        printf -v "$key" '%s' "$value"
        export "${key?}"
    done < "$file"
}
