#!/usr/bin/python3 -I
"""Muelsyse 只读漂移检查：按 deploy/manifest.tsv 对比仓库和生产，报告漂移、未登记文件和运行态。

用法:
    check-drift.py [--all] [--no-runtime] [--manifest PATH]
    check-drift.py --render FILE        把 FILE 的占位符展开后写到 stdout（deploy-host.sh 用）

输出一行一项 `STATUS target 说明`，默认只打印需要注意的行（SAME/TEMPLATE_OK/CHECK_OK 不打印），
`--all` 全打；最后一行是汇总。
退出码：有 DRIFT/MISSING/MODE/CHECK_FAIL/BUILD_STALE/RETIRED_PRESENT/UNMANAGED/STALE → 1；
只有 WARN/JUNK/SKIP → 0；用法或 manifest 格式错误 → 2。
环境变量 MUELSYSE_DRIFT_HOME 替代 $HOME 展开 `~`（测试用）。

占位符：kind=render 的文件和 kind=check 的片段在比较/安装前先展开 @NAME@。NAME 只认
HOME（即上面的 home）、USER、GROUP、UID（当前用户），以及 MUELSYSE_ 开头的变量，取值来自
<home>/.config/muelsyse/env（MUELSYSE_ENV_FILE 可改路径；KEY=VALUE 每行一条，# 注释，
值两端成对的引号会去掉，不做 $ 展开），没写的用 RENDER_DEFAULTS；还没值就报 RENDER_FAIL。
本脚本纯只读：不写文件、不调 sudo、只用 systemctl 的 show 查询。
"""

import argparse
import grp
import hashlib
import os
import pwd
import re
import stat
import subprocess
import sys

FAIL_STATUSES = {
    "DRIFT", "MISSING", "MODE", "CHECK_FAIL", "BUILD_STALE",
    "RETIRED_PRESENT", "UNMANAGED", "STALE", "RENDER_FAIL",
}
# 默认不打印的"正常"状态
OK_STATUSES = {"SAME", "TEMPLATE_OK", "CHECK_OK"}
STATUS_ORDER = [
    "SAME", "TEMPLATE_OK", "CHECK_OK", "DRIFT", "MISSING", "MODE", "CHECK_FAIL",
    "BUILD_STALE", "RETIRED_PRESENT", "UNMANAGED", "STALE", "RENDER_FAIL", "JUNK", "WARN", "SKIP",
]
KINDS = {"copy", "render", "template", "build", "check"}
PLACEHOLDER_RE = re.compile(r"@(HOME|USER|GROUP|UID|MUELSYSE_[A-Z0-9_]+)@")
ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# 主机 env 文件没写时的取值；要和 config/muelsyse.env.example 里注释掉的默认值一致。
# 网卡地址类（MUELSYSE_LAN_BIND 等）没有通用默认，用到又没配就 RENDER_FAIL。
RENDER_DEFAULTS = {
    "MUELSYSE_PORT": "8090",
    "MUELSYSE_SELKIES_VENV": "/opt/selkies",
    "MUELSYSE_AUTO_GPU": "intel",
    "MUELSYSE_DRI_NODE": "/dev/dri/renderD128",
    "MUELSYSE_SUNSHINE_OUTPUT": "HDMI-1",
    "MUELSYSE_SUNSHINE_MODE": "1920x1080",
    "MUELSYSE_SUNSHINE_RESTORE_MODE": "1920x1200",
}
RESTART_UNITS = {
    "session": "remote-desktop-wayland.service",
    "selkies": "remote-desktop-selkies.service",
}
# 安装脚本从系统 python 复制出来的解释器，故意不进 manifest
UNMANAGED_WHITELIST = ["~/.local/libexec/selkies-python3.13"]
# (目录, 名字前缀)；前缀为空表示目录下全部
UNMANAGED_SCAN = [
    ("~/.config/systemd/user", "remote-desktop-"),
    ("~/.config/systemd/user", "muelsyse-"),
    ("~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d", ""),
    ("~/.local/libexec", "selkies"),
    ("~/.local/libexec", "dri-"),
    ("~/.local/libexec", "muelsyse-"),
    ("~/.local/libexec", "sunshine"),
    ("~/.local/bin", "sunshine"),
    ("~/.local/bin", "selkies"),
]


class UsageError(Exception):
    pass


class RenderError(Exception):
    pass


# ---------- 占位符 ----------
def env_file_path(home):
    return os.environ.get("MUELSYSE_ENV_FILE") or os.path.join(home, ".config/muelsyse/env")


def load_env_file(path):
    """读 KEY=VALUE 文件；不存在返回空 dict。只认最简单的写法，好让 bash source 出同样的值。"""
    values = {}
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return values
    except OSError as e:
        raise RenderError(f"读不了 {path}: {e.strerror}")
    for lineno, line in enumerate(lines, 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, sep, value = line.partition("=")
        if not sep or not ENV_KEY_RE.match(key):
            raise RenderError(f"{path} 第 {lineno} 行不是 KEY=VALUE: {line}")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key] = value
    return values


def render_values(home):
    uid = os.getuid()
    pw = pwd.getpwuid(uid)
    values = dict(RENDER_DEFAULTS)
    values.update({k: v for k, v in load_env_file(env_file_path(home)).items() if k.startswith("MUELSYSE_")})
    values.update({
        "HOME": home,
        "USER": pw.pw_name,
        "GROUP": grp.getgrgid(pw.pw_gid).gr_name,
        "UID": str(uid),
    })
    return values


def render_text(text, values):
    missing = sorted({m.group(1) for m in PLACEHOLDER_RE.finditer(text) if m.group(1) not in values})
    if missing:
        raise RenderError("占位符没有值: " + ", ".join(missing) + "（在 ~/.config/muelsyse/env 里设）")
    return PLACEHOLDER_RE.sub(lambda m: values[m.group(1)], text)


def render_file(path, values):
    # newline="" 保留原换行，展开结果除占位符外与源文件逐字节相同
    with open(path, encoding="utf-8", newline="") as f:
        return render_text(f.read(), values).encode("utf-8")


class Checker:
    def __init__(self, home, repo, show_all):
        self.home = home
        self.repo = repo
        self.show_all = show_all
        self.counts = {}
        self.unit_start_cache = {}
        self._render_values = None

    def render_values(self):
        if self._render_values is None:
            self._render_values = render_values(self.home)
        return self._render_values

    # ---------- 输出 ----------
    def emit(self, status, target, note=""):
        self.counts[status] = self.counts.get(status, 0) + 1
        if self.show_all or status not in OK_STATUSES:
            print(f"{status} {target} {note}".rstrip(), flush=True)

    def summary(self):
        parts = [f"{s}={self.counts[s]}" for s in STATUS_ORDER if self.counts.get(s)]
        failed = any(self.counts.get(s) for s in FAIL_STATUSES)
        result = "FAIL" if failed else "OK"
        print(f"SUMMARY result={result} total={sum(self.counts.values())} {' '.join(parts)}".rstrip())
        return 1 if failed else 0

    # ---------- 路径 ----------
    def expand(self, path):
        if path == "~":
            return self.home
        if path.startswith("~/"):
            return os.path.join(self.home, path[2:])
        return path

    def shorten(self, path):
        if path.startswith(self.home + "/"):
            return "~/" + path[len(self.home) + 1:]
        return path

    # ---------- manifest ----------
    def load_manifest(self, path):
        rows = []
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError as e:
            raise UsageError(f"读不了 manifest {path}: {e.strerror}")
        for lineno, line in enumerate(lines, 1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = [c.strip() for c in line.rstrip().split("\t")]
            if len(cols) != 6:
                raise UsageError(f"manifest 第 {lineno} 行应有 6 列，实际 {len(cols)} 列")
            repo_path, target, mode, owner, kind, restart = cols
            if kind not in KINDS:
                raise UsageError(f"manifest 第 {lineno} 行 kind 未知: {kind}")
            if owner not in ("user", "root"):
                raise UsageError(f"manifest 第 {lineno} 行 owner 未知: {owner}")
            try:
                mode_int = int(mode, 8)
            except ValueError:
                raise UsageError(f"manifest 第 {lineno} 行 mode 不是八进制: {mode}")
            if not (target.startswith("~/") or target.startswith("/")):
                raise UsageError(f"manifest 第 {lineno} 行 target 必须是 ~/ 或绝对路径: {target}")
            rows.append({
                "repo_path": repo_path, "target": target, "abs": os.path.normpath(self.expand(target)),
                "mode": mode_int, "owner": owner, "kind": kind, "restart": restart,
            })
        return rows

    def load_retired(self, path):
        rows = []
        try:
            with open(path, encoding="utf-8") as f:
                lines = f.read().splitlines()
        except FileNotFoundError:
            return rows
        except OSError as e:
            raise UsageError(f"读不了 retired 清单 {path}: {e.strerror}")
        for line in lines:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.rstrip().split("\t")
            old = cols[0].strip()
            replaced = cols[1].strip() if len(cols) > 1 else ""
            note = cols[2].strip() if len(cols) > 2 else ""
            rows.append({"target": old, "abs": os.path.normpath(self.expand(old)),
                         "replaced_by": replaced, "note": note})
        return rows

    # ---------- 单项检查 ----------
    def check_row(self, row):
        target, path = row["target"], row["abs"]
        src = os.path.join(self.repo, row["repo_path"])
        try:
            st = os.stat(path)
        except FileNotFoundError:
            self.emit("MISSING", target, f"生产上不存在（{row['kind']}，来源 {row['repo_path']}）")
            return
        except PermissionError:
            self.emit("SKIP", target, "无权限 stat，未检查")
            return
        kind = row["kind"]
        if kind in ("copy", "render"):
            self.check_copy(row, src, path)
        elif kind == "template":
            self.emit("TEMPLATE_OK", target, "模板生成物存在")
        elif kind == "build":
            self.check_build(row, src, st)
        elif kind == "check":
            self.check_fragment(row, src, path)
        if kind in ("copy", "render", "template"):
            self.check_mode(row, st)

    def check_mode(self, row, st):
        want_uid = 0 if row["owner"] == "root" else os.getuid()
        problems = []
        actual = stat.S_IMODE(st.st_mode)
        if actual != row["mode"]:
            problems.append(f"权限 {actual:04o}，应为 {row['mode']:04o}")
        if st.st_uid != want_uid:
            problems.append(f"属主 uid={st.st_uid}，应为 {row['owner']}")
        if problems:
            self.emit("MODE", row["target"], "；".join(problems))

    def check_copy(self, row, src, path):
        target = row["target"]
        if os.path.isdir(src):
            if not os.path.isdir(path):
                self.emit("DRIFT", target, "仓库里是目录，生产上不是")
                return
            diff = compare_trees(src, path)
            if diff is None:
                self.emit("SKIP", target, "目录内有文件读不了，未检查")
            elif diff:
                self.emit("DRIFT", target, "目录内容不同: " + ", ".join(diff[:5]) + (" …" if len(diff) > 5 else ""))
            else:
                self.emit("SAME", target)
            return
        if not os.path.isfile(src):
            self.emit("WARN", target, f"manifest 的 repo_path 在仓库里不存在: {row['repo_path']}")
            return
        if row["kind"] == "render":
            try:
                want = hashlib.sha256(render_file(src, self.render_values())).digest()
            except (RenderError, OSError, UnicodeDecodeError) as e:
                self.emit("RENDER_FAIL", target, f"{row['repo_path']} 展开失败: {e}")
                return
        else:
            want = file_digest(src)
        try:
            same = want == file_digest(path)
        except PermissionError:
            self.emit("SKIP", target, "读不了（root 文件？），未比较内容")
            return
        except IsADirectoryError:
            self.emit("DRIFT", target, "生产上是目录，仓库里是文件")
            return
        if same:
            self.emit("SAME", target)
        else:
            self.emit("DRIFT", target, f"内容和仓库 {row['repo_path']} 不同")

    def check_build(self, row, src, st):
        target = row["target"]
        if not os.path.isdir(src):
            self.emit("WARN", target, f"build 的源码目录在仓库里不存在: {row['repo_path']}")
            return
        newest, newest_path = newest_mtime(src)
        if newest is None:
            self.emit("WARN", target, f"源码目录 {row['repo_path']} 里没有文件")
        elif st.st_mtime < newest:
            rel = os.path.relpath(newest_path, self.repo)
            self.emit("BUILD_STALE", target, f"构建产物早于源码（最新改动 {rel}）")
        else:
            self.emit("SAME", target, "构建产物不早于源码")

    def check_fragment(self, row, src, path):
        target = row["target"]
        try:
            with open(src, encoding="utf-8", errors="replace") as f:
                text = render_text(f.read(), self.render_values())
        except OSError:
            self.emit("WARN", target, f"读不了片段 {row['repo_path']}")
            return
        except RenderError as e:
            self.emit("RENDER_FAIL", target, f"{row['repo_path']} 展开失败: {e}")
            return
        want = rule_text_lines(text.splitlines())
        try:
            have = set(rule_lines(path))
        except PermissionError:
            self.emit("SKIP", target, "读不了（root 文件？），未检查片段")
            return
        missing = [line for line in want if line not in have]
        if missing:
            self.emit("CHECK_FAIL", target, f"缺 {len(missing)} 条规则，如: {missing[0]}")
        else:
            self.emit("CHECK_OK", target, f"片段 {row['repo_path']} 的 {len(want)} 条规则都在")

    # ---------- 改了没重启 ----------
    def unit_start(self, restart):
        """返回 (unit 名, 启动 unix 时间)；unit 不在跑或不需要比较时返回 None。"""
        if restart in RESTART_UNITS:
            scope, unit = "--user", RESTART_UNITS[restart]
        elif restart.startswith("unit:"):
            scope, unit = "--user", restart[5:]
        elif restart.startswith("system-unit:"):
            scope, unit = "--system", restart[12:]
        else:
            return None
        key = (scope, unit)
        if key not in self.unit_start_cache:
            props = systemctl_show(scope, unit, ["ActiveState", "ActiveEnterTimestamp"], unix=True)
            ts = props.get("ActiveEnterTimestamp", "")
            start = None
            if props.get("ActiveState") == "active" and ts.startswith("@"):
                try:
                    start = int(ts[1:])
                except ValueError:
                    start = None
            self.unit_start_cache[key] = start
        start = self.unit_start_cache[key]
        return None if start is None else (unit, start)

    def check_stale(self, row):
        info = self.unit_start(row["restart"])
        if info is None:
            return
        unit, start = info
        try:
            mtime = os.stat(row["abs"]).st_mtime
        except OSError:
            return
        # ActiveEnterTimestamp 是秒级截断，留 1 秒余量
        if mtime > start + 1:
            self.emit("STALE", row["target"], f"文件改动晚于 {unit} 启动，需要重启（{row['restart']}）")

    # ---------- 未登记文件 ----------
    def scan_unmanaged(self, rows, retired):
        managed = {r["abs"] for r in rows}
        retired_paths = {r["abs"] for r in retired}
        whitelist = {os.path.normpath(self.expand(p)) for p in UNMANAGED_WHITELIST}
        seen = set()
        for base, prefix in UNMANAGED_SCAN:
            base = self.expand(base)
            try:
                names = sorted(os.listdir(base))
            except FileNotFoundError:
                continue
            except PermissionError:
                self.emit("SKIP", self.shorten(base), "无权限列目录")
                continue
            for name in names:
                if not name.startswith(prefix):
                    continue
                path = os.path.join(base, name)
                for p in expand_entry(path):
                    if p in seen:
                        continue
                    seen.add(p)
                    self.classify_scanned(p, managed, retired_paths, whitelist)

    def classify_scanned(self, path, managed, retired_paths, whitelist):
        if path in whitelist or path in retired_paths:
            return
        # 本身登记过、在登记目录之下、或其下有登记项都算已管理
        for m in managed:
            if path == m or path.startswith(m + "/") or m.startswith(path + "/"):
                return
        name = os.path.basename(path)
        if ".bak" in name or ".disabled" in name:
            self.emit("JUNK", self.shorten(path), "备份/停用残留，可清理")
        else:
            self.emit("UNMANAGED", self.shorten(path), "生产上有但 manifest 里没有")

    # ---------- 运行态 ----------
    def git(self, *args):
        env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
        r = subprocess.run(["git", "-C", self.repo, *args], capture_output=True, text=True, env=env)
        return r.stdout if r.returncode == 0 else None

    def check_repo_dirty(self, rows):
        if self.git("rev-parse", "--git-dir") is None:
            self.emit("SKIP", self.repo, "不是 git 仓库，未检查未提交改动")
            return
        paths = sorted({r["repo_path"] for r in rows})
        out = self.git("status", "--porcelain", "--", *paths) if paths else ""
        if out is None:
            self.emit("WARN", self.repo, "git status 失败")
            return
        for line in out.splitlines():
            self.emit("WARN", line[3:], f"仓库有未提交改动（{line[:2].strip()}），生产可能装的是未提交版本")

    def check_build_info(self, label, directory, head, source_dirs):
        info_path = os.path.join(directory, "BUILD-INFO")
        try:
            with open(info_path, encoding="utf-8") as f:
                info = dict(l.split("=", 1) for l in f.read().splitlines() if "=" in l)
        except FileNotFoundError:
            self.emit("WARN", self.shorten(directory), f"{label} 未记录 Muelsyse 提交号（没有 BUILD-INFO）")
            return
        except OSError:
            self.emit("SKIP", self.shorten(info_path), "读不了 BUILD-INFO")
            return
        commit = info.get("muelsyse_commit", "").strip()
        if not commit:
            self.emit("WARN", self.shorten(info_path), f"{label} 的 BUILD-INFO 没有 muelsyse_commit")
        elif head is None:
            self.emit("SKIP", self.shorten(info_path), "取不到仓库 HEAD，未比较提交号")
        else:
            # 只关心构建所用的源码目录自那次提交以来有没有再变，HEAD 前进到别处不算过期
            changed = self.git("diff", "--name-only", commit, head, "--", *source_dirs)
            if changed is None:
                self.emit("WARN", self.shorten(directory), f"{label} 的提交 {commit[:12]} 在仓库里找不到")
            elif changed.strip():
                n = len(changed.splitlines())
                self.emit("WARN", self.shorten(directory),
                          f"{label} 构建于 {commit[:12]}，之后 {'/'.join(source_dirs)} 又改了 {n} 个文件，需要重新构建")
        if info.get("dirty", "").strip() not in ("", "0", "false", "no"):
            self.emit("WARN", self.shorten(directory), f"{label} 是从有未提交改动的工作区构建的（dirty={info['dirty'].strip()}）")

    def check_runtime(self):
        head = (self.git("rev-parse", "HEAD") or "").strip() or None
        # 1. selkies 前端 release
        site = os.path.join(self.home, ".local/share/remote-desktop/selkies-kwin/site")
        if os.path.islink(site) or os.path.exists(site):
            release = os.path.realpath(site)
            # site 软链可能指向 release/site，也可能直接指向 release 目录
            candidates = [release, os.path.dirname(release)]
            found = next((d for d in candidates if os.path.exists(os.path.join(d, "BUILD-INFO"))), release)
            self.check_build_info("selkies release", found, head, ("selkies", "pixelflux"))
        else:
            self.emit("WARN", self.shorten(site), "selkies site 软链不存在")
        # 2. KWin
        env = systemctl_show("--user", "remote-desktop-wayland.service", ["Environment"]).get("Environment", "")
        prefix = next((kv.split("=", 1)[1] for kv in env.split() if kv.startswith("SELKIES_KWIN_PREFIX=")), "")
        if not prefix:
            self.emit("WARN", "remote-desktop-wayland.service", "Environment 里没有 SELKIES_KWIN_PREFIX")
            return
        real_prefix = os.path.realpath(prefix)
        r = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "kwin_wayland"], capture_output=True, text=True)
        pids = r.stdout.split()
        if not pids:
            self.emit("WARN", "kwin_wayland", "没有运行中的 kwin_wayland，未检查 exe 位置")
        for pid in pids:
            try:
                exe = os.path.realpath(os.readlink(f"/proc/{pid}/exe"))
            except OSError:
                self.emit("SKIP", f"/proc/{pid}/exe", "读不了")
                continue
            if exe.endswith(" (deleted)"):
                self.emit("WARN", exe, f"kwin_wayland pid={pid} 的可执行文件已被替换，需要重启 session")
            elif not exe.startswith(real_prefix + "/"):
                self.emit("WARN", exe, f"kwin_wayland pid={pid} 不在 SELKIES_KWIN_PREFIX={prefix} 之下")
        self.check_build_info("KWin", real_prefix, head, ("kwin", "kwin-adapter"))


# ---------- 工具函数 ----------
def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.digest()


def list_files(root):
    out = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".git"]
        for name in files:
            p = os.path.join(d, name)
            out[os.path.relpath(p, root)] = p
    return out


def compare_trees(a, b):
    """返回差异文件名列表；有文件读不了返回 None。"""
    fa, fb = list_files(a), list_files(b)
    diff = sorted(set(fa) ^ set(fb))
    try:
        diff += [k for k in sorted(set(fa) & set(fb)) if file_digest(fa[k]) != file_digest(fb[k])]
    except PermissionError:
        return None
    return diff


def newest_mtime(root):
    """源码目录里最新的 mtime；test/ 下的脚本和测试程序不进产物，不算。"""
    newest, newest_path = None, None
    for rel, p in list_files(root).items():
        if rel.split(os.sep, 1)[0] in ("test", "tests"):
            continue
        try:
            m = os.lstat(p).st_mtime
        except OSError:
            continue
        if newest is None or m > newest:
            newest, newest_path = m, p
    return newest, newest_path


def rule_lines(path):
    """片段里的规则行：去掉空行和注释，空白归一。"""
    with open(path, encoding="utf-8", errors="replace") as f:
        return rule_text_lines(f)


def rule_text_lines(lines):
    lines = [" ".join(l.split()) for l in lines]
    return [l for l in lines if l and not l.startswith("#")]


def expand_entry(path):
    """扫描到的条目：普通文件原样返回；目录（如 .d/）展开成里面的文件。"""
    if os.path.isdir(path) and not os.path.islink(path):
        files = list(list_files(path).values())
        return sorted(os.path.normpath(p) for p in files) or [os.path.normpath(path)]
    return [os.path.normpath(path)]


def systemctl_show(scope, unit, props, unix=False):
    cmd = ["systemctl", scope, "show", unit, *(f"-p{p}" for p in props)]
    if unix:
        cmd.append("--timestamp=unix")
    r = subprocess.run(cmd, capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def default_manifest():
    here = os.path.dirname(os.path.realpath(__file__))
    in_repo = os.path.join(here, "..", "deploy", "manifest.tsv")
    # 部署出去的副本不在仓库里，没有默认可推导，须显式传 --manifest（drift-check unit 总是传）
    return os.path.normpath(in_repo)


def main(argv):
    parser = argparse.ArgumentParser(description="Muelsyse 只读漂移检查")
    parser.add_argument("--all", action="store_true", help="连 SAME/TEMPLATE_OK/CHECK_OK 也打印")
    parser.add_argument("--no-runtime", action="store_true",
                        help="跳过 systemd/进程/BUILD-INFO/git 检查（测试用）")
    parser.add_argument("--manifest", help="manifest.tsv 路径（默认仓库里的 deploy/manifest.tsv）")
    parser.add_argument("--render", metavar="FILE", help="只把 FILE 的占位符展开后写到 stdout，然后退出")
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:
        return 0 if e.code == 0 else 2

    home = os.path.normpath(os.environ.get("MUELSYSE_DRIFT_HOME") or os.path.expanduser("~"))
    if args.render:
        try:
            data = render_file(args.render, render_values(home))
        except (RenderError, OSError, UnicodeDecodeError) as e:
            print(f"check-drift: {args.render} 展开失败: {e}", file=sys.stderr)
            return 2
        sys.stdout.buffer.write(data)
        return 0

    manifest = os.path.abspath(args.manifest or default_manifest())
    deploy_dir = os.path.dirname(manifest)
    repo = os.path.dirname(deploy_dir)
    checker = Checker(home, repo, args.all)
    try:
        rows = checker.load_manifest(manifest)
        retired = checker.load_retired(os.path.join(deploy_dir, "retired.tsv"))
    except UsageError as e:
        print(f"check-drift: {e}", file=sys.stderr)
        return 2

    for row in rows:
        checker.check_row(row)
    for r in retired:
        if os.path.lexists(r["abs"]):
            note = f"已退役，应由 {r['replaced_by']} 取代" if r["replaced_by"] else "已退役"
            checker.emit("RETIRED_PRESENT", r["target"], note + (f"（{r['note']}）" if r["note"] else ""))
    checker.scan_unmanaged(rows, retired)
    if not args.no_runtime:
        for row in rows:
            checker.check_stale(row)
        checker.check_repo_dirty(rows)
        checker.check_runtime()
    return checker.summary()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
