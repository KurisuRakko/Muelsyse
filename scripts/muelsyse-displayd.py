#!/usr/bin/env python3
"""虚拟屏 mode/scale 的唯一决策点：串行化所有改分辨率、改缩放的请求。

KWin 无头虚拟屏（默认 `Virtual-0`）的 mode 与 scale 以前有几处各改各的（pixelflux、
Sunshine session-prep、桌面 app）。本进程把「改不改、改成什么」收到一处：按策略
（follow / pinned / 租约）裁决，在一把锁里执行，执行完用 `kscreen-doctor -j` 回读校验。

执行（阶段 1，本进程自己写输出）：
    1. `kscreen-doctor -j` 读现状；目标与现值相同 → unchanged。
    2. 判断 Selkies 是否在抓屏，拿不准就拒绝（selkies_active）。
    3. 目标尺寸不在 modes 里 → 经 KWin adapter `prepare` 一个动态 mode。
    4. `kscreen-doctor output.<OUT>.mode.<id> output.<OUT>.scale.<S>` 一条命令切换。
    5. 再读 `-j` 校验；不符就写回旧值，回 verify_failed。
adapter 只保留一个「预备但未使用」的动态 mode，所以 3→4→5 必须在锁里连续做完，
不能批量 prepare，也不能缓存 mode 列表。kscreen-doctor 失败时退出码也是 0，只认回读。

socket 协议：Unix stream，只收同 UID；每行一个 JSON 请求，回一行 JSON：
    {"op":"status"}
    {"op":"request","w":W,"h":H,"scale":S,"source":"app|cli|selkies|sunshine","force":false}
    {"op":"pin","w":W,"h":H,"scale":S}      参数可省，省了就锁定当前值
    {"op":"follow"}
    {"op":"lease","name":N,"ttl_s":T}  /  {"op":"release","name":N}
被拒时回 {"ok":false,"reason":"invalid|pinned|leased:<name>|selkies_active|verify_failed|busy|backend_error","detail":"…"}。

配置全走环境变量（见 Config），测试时指向临时 KWin 或假命令。
"""

import asyncio
import json
import logging
import math
import os
import re
import shlex
import signal
import socket
import stat
import struct
import sys
import time

# scale 只开 5 档，对应 Selkies scaling_dpi 96/120/144/168/192。
ALLOWED_SCALES = (1.0, 1.25, 1.5, 1.75, 2.0)
# 与 Selkies 浏览器端上限一致，也避开 h264_nvenc 4096 的宽度上限。
MIN_SIDE = 320
MAX_SIDE = 4080
SOURCES = ("app", "cli", "selkies", "sunshine")
REFRESH_MHZ = 60000
SCALE_TOLERANCE = 0.01

MAX_LINE = 4096
IDLE_TIMEOUT_S = 30.0
KSCREEN_TIMEOUT_S = 10.0
COMMAND_TIMEOUT_S = 5.0
ADAPTER_TIMEOUT_S = 5.0
LEASE_DEFAULT_TTL_S = 12 * 3600
LEASE_MAX_TTL_S = 7 * 24 * 3600
LEASE_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
STARTUP_BACKOFF_MAX_S = 60.0
PORT_RECHECK_S = 0.4

# Selkies 日志里的客户端事件标记（selkies/src/selkies/selkies.py）：
# - 连上：ws_handler 在通过限速检查、把连接加进 self.clients 之前打
#   「Data WebSocket connected from …」（:3942）。每条数据 websocket 都会打，不分 primary/viewer、
#   不分音频开没开。没选「Initial setup: Primary client connected…」（:4493）：它只在音频没在跑时
#   才打，宽限期内重连、音频被策略关掉、第二个客户端加入都不会出现，会漏判成「没客户端」。
# - 走光：断开后的宽限期任务里，self.clients 为空时打「Last client gone after the grace period.」（:4944）。
#   self.clients 和上面那条是同一个集合，所以「最后一次连上晚于最后一次走光」= 还有连接。
# 已知偏保守的情况：没占 display 的连接（viewer）最后离开时不走宽限期任务、不打走光标记，
# 之后会一直判成「有客户端」而拒绝，直到下一个 primary 客户端走光；措辞改了也只会多拒绝。
SELKIES_CONNECT_MARK = "Data WebSocket connected from"
SELKIES_GONE_MARK = "Last client gone after the grace period."

log = logging.getLogger("muelsyse-displayd")


class Rejected(Exception):
    """请求被拒；reason 是协议里的固定词，detail 给人看。"""

    def __init__(self, reason, detail=""):
        super().__init__(f"{reason}: {detail}")
        self.reason = reason
        self.detail = detail


class BackendError(Rejected):
    def __init__(self, detail):
        super().__init__("backend_error", detail)


class Config:
    def __init__(self, env=os.environ):
        runtime = env.get("XDG_RUNTIME_DIR", "")

        def runtime_path(name):
            if not runtime:
                raise SystemExit("XDG_RUNTIME_DIR 未设置，无法确定 socket 路径")
            return os.path.join(runtime, name)

        self.socket = env.get("MUELSYSE_DISPLAY_SOCKET") or runtime_path("muelsyse-display.sock")
        self.wayland = env.get("MUELSYSE_DISPLAY_WAYLAND") or "wayland-remote-desktop"
        self.output = env.get("MUELSYSE_DISPLAY_OUTPUT") or "Virtual-0"
        self.adapter = env.get("MUELSYSE_DISPLAY_ADAPTER") or runtime_path("selkies-kwin-adapter.sock")
        self.state = env.get("MUELSYSE_DISPLAY_STATE") or os.path.join(
            os.path.expanduser("~"), ".config", "muelsyse", "display.json")
        self.selkies_unit = env.get("MUELSYSE_DISPLAY_SELKIES_UNIT") or "remote-desktop-selkies.service"
        self.kscreen_doctor = env.get("MUELSYSE_DISPLAY_KSCREEN_DOCTOR") or "kscreen-doctor"
        self.journalctl = env.get("MUELSYSE_DISPLAY_JOURNALCTL") or "journalctl"
        self.ss = env.get("MUELSYSE_DISPLAY_SS") or "ss"
        self.systemctl = env.get("MUELSYSE_DISPLAY_SYSTEMCTL") or "systemctl"
        self.pw_dump = env.get("MUELSYSE_DISPLAY_PW_DUMP") or "pw-dump"
        # 下面三个只给测试缩短等待用。
        self.queue_timeout = float(env.get("MUELSYSE_DISPLAY_QUEUE_S") or 15.0)
        self.pin_retry = float(env.get("MUELSYSE_DISPLAY_PIN_RETRY_S") or 60.0)
        self.backoff_max = float(env.get("MUELSYSE_DISPLAY_BACKOFF_MAX_S") or STARTUP_BACKOFF_MAX_S)
        # kscreen-doctor 要连目标 KWin；session bus 原样继承。KSCREEN_BACKEND_INPROCESS 让它在本进程里
        # 直接连 WAYLAND_DISPLAY，不经 session bus 上的 KScreen 后端服务（那个服务可能是按别的
        # WAYLAND_DISPLAY 起来的，会读写错屏）。
        self.kscreen_env = dict(env, WAYLAND_DISPLAY=self.wayland, QT_QPA_PLATFORM="wayland",
                                KSCREEN_BACKEND_INPROCESS="1")


async def run(argv, timeout, env=None):
    """跑一个子进程，返回 (退出码, stdout, stderr)；起不来或超时一律 BackendError。"""
    try:
        proc = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, env=env)
    except OSError as e:
        raise BackendError(f"{argv[0]} 起不来: {e}") from e
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise BackendError(f"{argv[0]} 超时（{timeout:g}s）") from None
    return proc.returncode, out.decode(errors="replace"), err.decode(errors="replace")


def fmt_scale(scale):
    return f"{scale:g}"


def same_scale(a, b):
    return abs(a - b) <= SCALE_TOLERANCE


class Backend:
    """kscreen-doctor + KWin adapter：读现状、prepare、切换。"""

    def __init__(self, cfg):
        self.cfg = cfg

    async def read(self):
        """返回 {"w","h","refresh_mhz","scale","modes":[{"id","w","h","refresh_mhz"}]}。"""
        rc, out, err = await run([self.cfg.kscreen_doctor, "-j"], KSCREEN_TIMEOUT_S, self.cfg.kscreen_env)
        if rc != 0:
            raise BackendError(f"kscreen-doctor -j 退出码 {rc}: {err.strip()[:200]}")
        try:
            doc = json.loads(out)
            output = next(o for o in doc["outputs"] if o.get("name") == self.cfg.output)
            modes = [{
                "id": str(m["id"]),
                "w": int(m["size"]["width"]),
                "h": int(m["size"]["height"]),
                "refresh_mhz": int(round(float(m.get("refreshRate", 0)) * 1000)),
            } for m in output["modes"]]
            current = next(m for m in modes if m["id"] == str(output["currentModeId"]))
            scale = float(output["scale"])
        except StopIteration:
            raise BackendError(f"kscreen-doctor -j 里没有 {self.cfg.output} 或它的当前 mode") from None
        except (ValueError, KeyError, TypeError) as e:
            raise BackendError(f"kscreen-doctor -j 输出解析失败: {e}") from e
        return {"w": current["w"], "h": current["h"], "refresh_mhz": current["refresh_mhz"],
                "scale": scale, "modes": modes}

    async def adapter(self, payload):
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_unix_connection(self.cfg.adapter, limit=1 << 20), ADAPTER_TIMEOUT_S)
        except (OSError, asyncio.TimeoutError) as e:
            raise BackendError(f"连不上 KWin adapter: {e!r}") from e
        try:
            writer.write((json.dumps(payload) + "\n").encode())
            await writer.drain()
            line = await asyncio.wait_for(reader.readline(), ADAPTER_TIMEOUT_S)
            reply = json.loads(line)
        except (OSError, ValueError, asyncio.TimeoutError) as e:
            raise BackendError(f"KWin adapter 无应答: {e!r}") from e
        finally:
            writer.close()
        if not isinstance(reply, dict):
            raise BackendError(f"KWin adapter 回复格式不对: {line[:200]!r}")
        return reply

    async def output_index(self):
        reply = await self.adapter({"op": "status"})
        if not reply.get("ok"):
            raise BackendError(f"adapter status 失败: {reply.get('error')}")
        for o in reply.get("outputs") or []:
            if o.get("name") == self.cfg.output:
                return int(o["index"])
        raise BackendError(f"adapter status 里没有 {self.cfg.output}")

    @staticmethod
    def find_mode(state, w, h):
        for m in state["modes"]:
            if m["w"] == w and m["h"] == h and abs(m["refresh_mhz"] - REFRESH_MHZ) <= 1000:
                return m
        return None

    async def switch(self, w, h, scale):
        """prepare（需要时）→ 切换 → 回读。返回回读到的状态，校验由调用方做。"""
        state = await self.read()
        mode = self.find_mode(state, w, h)
        if mode is None:
            index = await self.output_index()
            reply = await self.adapter({"op": "prepare", "output_index": index, "width": w,
                                        "height": h, "refresh_mhz": REFRESH_MHZ})
            if not reply.get("ok"):
                raise BackendError(f"adapter prepare {w}x{h} 失败: {reply.get('error')}")
            state = await self.read()
            mode = self.find_mode(state, w, h)
            if mode is None:
                raise BackendError(f"prepare 后 kscreen-doctor 仍没有 {w}x{h}@60")
        out = self.cfg.output
        # 退出码不可信（选不存在的 mode 也是 0），这里只看它有没有跑完。
        await run([self.cfg.kscreen_doctor, f"output.{out}.mode.{mode['id']}",
                   f"output.{out}.scale.{fmt_scale(scale)}"], KSCREEN_TIMEOUT_S, self.cfg.kscreen_env)
        return await self.read()


class SelkiesProbe:
    """阶段 1：从外面判断 Selkies 有没有客户端。拿不准一律当「有」。"""

    def __init__(self, cfg):
        self.cfg = cfg

    async def _systemctl(self, *args):
        rc, out, _err = await run([self.cfg.systemctl, "--user", *args], COMMAND_TIMEOUT_S)
        return rc, out.strip()

    async def service_active(self):
        """True / False；systemctl 自己出问题时 None。"""
        try:
            _rc, out = await self._systemctl("is-active", self.cfg.selkies_unit)
        except BackendError:
            return None
        if out in ("inactive", "failed"):
            return False
        # active / activating / deactivating / reloading 都按在跑处理。
        return True if out else None

    async def _journal_says(self):
        """"yes" / "no" / "unknown"：本次 MainPID 下最后一条客户端事件是连上还是走光。"""
        try:
            _rc, pid = await self._systemctl("show", "-p", "MainPID", "--value", self.cfg.selkies_unit)
            if not pid.isdigit() or int(pid) <= 0:
                return "unknown"
            rc, out, _err = await run([self.cfg.journalctl, "--user", "-u", self.cfg.selkies_unit,
                                       f"_PID={pid}", "--since", "-24h", "-o", "cat", "-q", "--no-pager"],
                                      COMMAND_TIMEOUT_S)
        except BackendError:
            return "unknown"
        if rc != 0:
            return "unknown"
        last_connect = last_gone = -1
        for i, line in enumerate(out.splitlines()):
            if SELKIES_CONNECT_MARK in line:
                last_connect = i
            elif SELKIES_GONE_MARK in line:
                last_gone = i
        # 刚启动、两条都没有 → 没客户端。
        return "yes" if last_connect > last_gone else "no"

    async def _port_says(self):
        try:
            _rc, env = await self._systemctl("show", "-p", "Environment", "--value", self.cfg.selkies_unit)
            port = None
            for item in shlex.split(env):
                if item.startswith("SELKIES_PORT="):
                    port = item.split("=", 1)[1]
            if port is None or not port.isdigit() or not 0 < int(port) < 65536:
                return "unknown"
            argv = [self.cfg.ss, "-Htn", "state", "established", f"( sport = :{int(port)} )"]
            # 浏览器的 WebSocket 是长连接；监控面板之类的 HTTP 探活只连几毫秒。隔一小会儿再看一次，
            # 两次都有连接才算有客户端，免得探活撞上检查时误拒。
            for attempt in range(2):
                if attempt:
                    await asyncio.sleep(PORT_RECHECK_S)
                rc, out, _err = await run(argv, COMMAND_TIMEOUT_S)
                if rc != 0:
                    return "unknown"
                if not out.strip():
                    return "no"
        except (BackendError, ValueError):
            return "unknown"
        return "yes"

    async def check(self):
        """返回 (service_active, clients)；clients ∈ yes/no/unknown，只有 no 才可以自己写。"""
        active = await self.service_active()
        if active is None:
            return False, "unknown"
        if not active:
            return False, "no"
        journal, port = await asyncio.gather(self._journal_says(), self._port_says())
        if "yes" in (journal, port):
            return True, "yes"
        if "unknown" in (journal, port):
            return True, "unknown"
        return True, "no"


async def uu_watching(cfg):
    """pw-dump 里有 running 的 uuremote-server 视频输入流 → UU 正在看。失败一律 False。"""
    try:
        rc, out, _err = await run([cfg.pw_dump], COMMAND_TIMEOUT_S)
        if rc != 0:
            return False
        for obj in json.loads(out):
            info = obj.get("info") or {}
            props = info.get("props") or {}
            if (props.get("node.name") == "uuremote-server"
                    and props.get("media.class") == "Stream/Input/Video"
                    and info.get("state") == "running"):
                return True
    except (BackendError, ValueError, AttributeError, TypeError):
        pass
    return False


def parse_scale(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise Rejected("invalid", f"scale 必须是数字: {value!r}")
    for s in ALLOWED_SCALES:
        if abs(value - s) < 1e-6:
            return s
    raise Rejected("invalid", f"scale 只能是 {', '.join(fmt_scale(s) for s in ALLOWED_SCALES)}")


def parse_size(req):
    """返回 (w, h) 或 None；只给一个或值不合法 → invalid。"""
    w, h = req.get("w"), req.get("h")
    if w is None and h is None:
        return None
    for v in (w, h):
        if isinstance(v, bool) or not isinstance(v, int):
            raise Rejected("invalid", "w、h 必须同时给出且为整数")
    if w % 2 or h % 2:
        raise Rejected("invalid", f"{w}x{h} 宽高必须是偶数")
    if not (MIN_SIDE <= w <= MAX_SIDE and MIN_SIDE <= h <= MAX_SIDE):
        raise Rejected("invalid", f"{w}x{h} 超出 {MIN_SIDE}..{MAX_SIDE}")
    return w, h


def parse_target(req, require=True):
    size = parse_size(req)
    scale = parse_scale(req["scale"]) if req.get("scale") is not None else None
    if require and size is None and scale is None:
        raise Rejected("invalid", "至少给出 w/h 或 scale")
    return size, scale


def mode_view(state):
    return {"w": state["w"], "h": state["h"], "refresh_mhz": state["refresh_mhz"]}


class Daemon:
    def __init__(self, cfg):
        self.cfg = cfg
        self.backend = Backend(cfg)
        self.selkies = SelkiesProbe(cfg)
        self.lock = asyncio.Lock()
        self.policy = "follow"
        self.pin = None
        self.leases = {}
        self.last_change = None
        self.server = None
        self.tasks = set()
        # 请求分发表；阶段 2 的 subscribe / capture_begin 等往这里加。
        self.ops = {
            "status": self.op_status,
            "request": self.op_request,
            "pin": self.op_pin,
            "follow": self.op_follow,
            "lease": self.op_lease,
            "release": self.op_release,
        }

    # ---- 持久状态 ----

    def load_state(self):
        try:
            with open(self.cfg.state, encoding="utf-8") as f:
                doc = json.load(f)
        except FileNotFoundError:
            return
        except (OSError, ValueError) as e:
            log.warning("状态文件 %s 读不了，按 follow 启动: %s", self.cfg.state, e)
            return
        if not isinstance(doc, dict):
            log.warning("状态文件 %s 不是 JSON 对象，按 follow 启动", self.cfg.state)
            return
        pin = doc.get("pin")
        try:
            if doc.get("policy") == "pinned" and isinstance(pin, dict):
                w, h = parse_size(pin)
                self.pin = {"w": w, "h": h, "scale": parse_scale(pin.get("scale"))}
                self.policy = "pinned"
        except (Rejected, TypeError, AttributeError) as e:
            log.warning("状态文件里的 pin 无效，忽略: %s", e)

    def save_state(self):
        path = self.cfg.state
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"policy": self.policy, "pin": self.pin}, f)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)

    def set_pin(self, pin):
        self.pin = pin
        self.policy = "follow" if pin is None else "pinned"
        self.save_state()

    # ---- 租约 ----

    def live_leases(self):
        now = time.time()
        for name in [n for n, exp in self.leases.items() if exp <= now]:
            log.info("租约 %s 已过期", name)
            del self.leases[name]
        return self.leases

    # ---- 请求处理 ----

    async def op_status(self, req):
        state = await self.backend.read()
        active, clients = await self.selkies.check()
        return {
            "ok": True,
            "mode": mode_view(state),
            "scale": state["scale"],
            "policy": self.policy,
            "pin": self.pin,
            "leases": [{"name": n, "expires_at": round(exp, 3)} for n, exp in sorted(self.live_leases().items())],
            "selkies": {"service_active": active, "clients": clients},
            "uu_watching": await uu_watching(self.cfg),
            "last_change": self.last_change,
        }

    async def op_request(self, req):
        source = req.get("source")
        if source not in SOURCES:
            raise Rejected("invalid", f"source 必须是 {'/'.join(SOURCES)}")
        size, scale = parse_target(req)
        return await self.apply(size, scale, source, bool(req.get("force")))

    async def op_pin(self, req):
        size, scale = parse_target(req, require=False)
        if size is None and scale is None:
            # 不给参数：锁定当前值，不改输出。
            state = await self.backend.read()
            self.set_pin({"w": state["w"], "h": state["h"], "scale": state["scale"]})
            log.info("锁定当前 %sx%s scale %s", state["w"], state["h"], fmt_scale(state["scale"]))
            return {"ok": True, "result": "unchanged", "mode": mode_view(state), "scale": state["scale"]}
        return await self.apply(size, scale, "app", bool(req.get("force")), update_pin=True)

    async def op_follow(self, req):
        self.set_pin(None)
        log.info("切回 follow")
        return {"ok": True, "policy": "follow"}

    async def op_lease(self, req):
        name = req.get("name")
        ttl = req.get("ttl_s", LEASE_DEFAULT_TTL_S)
        if not isinstance(name, str) or not LEASE_NAME_RE.match(name):
            raise Rejected("invalid", "租约名只能是 1–64 个字母、数字、._-")
        if isinstance(ttl, bool) or not isinstance(ttl, (int, float)) or not 0 < ttl <= LEASE_MAX_TTL_S:
            raise Rejected("invalid", f"ttl_s 必须在 (0, {LEASE_MAX_TTL_S}]")
        self.leases[name] = time.time() + ttl
        log.info("租约 %s，%gs", name, ttl)
        return {"ok": True, "lease": {"name": name, "expires_at": round(self.leases[name], 3)}}

    async def op_release(self, req):
        name = req.get("name")
        if not isinstance(name, str):
            raise Rejected("invalid", "缺租约名")
        released = self.live_leases().pop(name, None) is not None
        if released:
            log.info("释放租约 %s", name)
        return {"ok": True, "released": released}

    async def apply(self, size, scale, source, force, update_pin=False):
        """策略判断 → 拿锁 → 执行。app/cli 在 pinned 下（以及 pin op）成功后更新 pin。"""
        if self.policy == "pinned" and source in ("selkies", "sunshine"):
            raise Rejected("pinned", f"已锁定 {self.pin['w']}x{self.pin['h']} scale {fmt_scale(self.pin['scale'])}")
        if not force:
            for name in self.live_leases():
                if name != source:
                    raise Rejected(f"leased:{name}", "租约持有中，--force 可越过")
        try:
            await asyncio.wait_for(self.lock.acquire(), self.cfg.queue_timeout)
        except asyncio.TimeoutError:
            raise Rejected("busy", f"排队超过 {self.cfg.queue_timeout:g}s") from None
        try:
            reply = await self._apply_locked(size, scale, source, force)
        finally:
            self.lock.release()
        if update_pin or (self.policy == "pinned" and source in ("app", "cli")):
            self.set_pin({"w": reply["mode"]["w"], "h": reply["mode"]["h"], "scale": reply["scale"]})
        return reply

    async def _apply_locked(self, size, scale, source, force):
        started = time.monotonic()
        before = await self.backend.read()
        w, h = size if size is not None else (before["w"], before["h"])
        target_scale = scale if scale is not None else before["scale"]
        if w == before["w"] and h == before["h"] and same_scale(target_scale, before["scale"]):
            return {"ok": True, "result": "unchanged", "mode": mode_view(before), "scale": before["scale"]}

        if not force:
            active, clients = await self.selkies.check()
            if clients != "no":
                raise Rejected("selkies_active", f"Selkies 在跑，客户端={clients}；--force 可越过")

        old = (before["w"], before["h"], before["scale"])
        desc = f"{source} {old[0]}x{old[1]}@{fmt_scale(old[2])} → {w}x{h}@{fmt_scale(target_scale)}"
        try:
            after = await self.backend.switch(w, h, target_scale)
        except BackendError as e:
            # 切换中途出错（kscreen-doctor 超时被杀、回读失败……）时输出可能已经改了一半，尽力写回旧值。
            rollback = await self._rollback(old)
            self._record(source, old, (w, h, target_scale), "backend_error", started)
            log.warning("变更 %s 失败 backend_error（%dms）: %s；%s", desc, self._ms(started), e.detail, rollback)
            raise BackendError(f"{e.detail}；{rollback}") from e
        if after["w"] == w and after["h"] == h and same_scale(after["scale"], target_scale):
            self._record(source, old, (w, h, target_scale), "applied", started)
            log.info("变更 %s applied（%dms）", desc, self._ms(started))
            await self._warn_if_selkies_joined(force)
            return {"ok": True, "result": "applied", "mode": mode_view(after), "scale": after["scale"]}

        got = f"{after['w']}x{after['h']}@{fmt_scale(after['scale'])}"
        rollback = await self._rollback(old)
        self._record(source, old, (w, h, target_scale), "verify_failed", started)
        log.warning("变更 %s verify_failed（%dms）: 回读 %s，%s", desc, self._ms(started), got, rollback)
        raise Rejected("verify_failed", f"回读是 {got}，{rollback}")

    async def _rollback(self, old):
        """写回旧 mode/scale，返回给人看的结果说明。"""
        try:
            back = await self.backend.switch(*old)
        except BackendError as e:
            return f"写回旧值失败: {e.detail}"
        if back["w"] == old[0] and back["h"] == old[1] and same_scale(back["scale"], old[2]):
            return "已写回旧值"
        return f"写回旧值也没成功，现在是 {back['w']}x{back['h']}@{fmt_scale(back['scale'])}"

    async def _warn_if_selkies_joined(self, force):
        # 检查之后、写完之前恰好有浏览器连上：网页端可能冻在旧尺寸，刷新恢复。只记录，不回滚。
        _active, clients = await self.selkies.check()
        if clients != "no" and not force:
            log.warning("写完后发现 Selkies 客户端=%s：网页端可能卡住，刷新页面可恢复", clients)

    @staticmethod
    def _ms(started):
        return int((time.monotonic() - started) * 1000)

    def _record(self, source, old, new, result, started):
        self.last_change = {
            "at": round(time.time(), 3),
            "source": source,
            "from": {"w": old[0], "h": old[1], "scale": old[2]},
            "to": {"w": new[0], "h": new[1], "scale": new[2]},
            "result": result,
            "ms": self._ms(started),
        }

    async def dispatch(self, req):
        if not isinstance(req, dict) or not isinstance(req.get("op"), str) or req["op"] not in self.ops:
            return {"ok": False, "reason": "invalid", "detail": "未知 op"}
        try:
            return await self.ops[req["op"]](req)
        except Rejected as e:
            return {"ok": False, "reason": e.reason, "detail": e.detail}
        except Exception as e:  # 单个请求出什么错都不能带崩守护进程。
            log.exception("处理 %s 出错", req.get("op"))
            return {"ok": False, "reason": "backend_error", "detail": repr(e)[:300]}

    # ---- socket ----

    async def handle(self, reader, writer):
        sock = writer.get_extra_info("socket")
        try:
            _pid, uid, _gid = struct.unpack(
                "3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        except OSError:
            uid = -1
        if uid != os.getuid():
            writer.close()
            return
        try:
            while True:
                try:
                    line = await asyncio.wait_for(reader.readline(), IDLE_TIMEOUT_S)
                except asyncio.TimeoutError:
                    break
                except (ValueError, asyncio.LimitOverrunError):
                    # 超长行：回一句就断开，缓冲区里剩下的半行没法再对齐。
                    await self._send(writer, {"ok": False, "reason": "invalid", "detail": f"单行超过 {MAX_LINE} 字节"})
                    break
                if not line:
                    break
                if not line.strip():
                    continue
                try:
                    req = json.loads(line)
                except ValueError:
                    reply = {"ok": False, "reason": "invalid", "detail": "不是 JSON"}
                else:
                    reply = await self.dispatch(req)
                await self._send(writer, reply)
        except (ConnectionError, OSError):
            pass
        finally:
            writer.close()

    @staticmethod
    async def _send(writer, obj):
        writer.write((json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
        await writer.drain()

    async def open_socket(self):
        path = self.cfg.socket
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISSOCK(st.st_mode):
                raise SystemExit(f"{path} 已存在且不是 socket，拒绝覆盖")
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.connect(path)
            except OSError:
                os.unlink(path)  # 上次没清掉的死 socket
            else:
                raise SystemExit(f"{path} 上已有 displayd 在跑")
            finally:
                probe.close()
        old_umask = os.umask(0o177)
        try:
            self.server = await asyncio.start_unix_server(self.handle, path, limit=MAX_LINE)
        finally:
            os.umask(old_umask)
        os.chmod(path, 0o600)

    def close_socket(self):
        if self.server is not None:
            self.server.close()
            try:
                os.unlink(self.cfg.socket)
            except FileNotFoundError:
                pass

    # ---- 启动时恢复 pin ----

    async def restore_pin(self):
        delay = 1.0
        while self.pin is not None:
            try:
                await self.backend.read()
                await self.backend.output_index()
                break
            except BackendError as e:
                log.info("等 KWin 就绪（%gs 后重试）: %s", delay, e.detail)
                await asyncio.sleep(delay)
                delay = min(delay * 2, self.cfg.backoff_max)
        while self.pin is not None:
            try:
                result = await self._restore_pin_once()
            except Rejected as e:
                log.info("启动时恢复 pin 被拒 %s（%gs 后重试）: %s", e.reason, self.cfg.pin_retry, e.detail)
                await asyncio.sleep(self.cfg.pin_retry)
                continue
            except Exception:  # 和 dispatch 一样，出什么错都只记日志、稍后重试。
                log.exception("启动时恢复 pin 出错（%gs 后重试）", self.cfg.pin_retry)
                await asyncio.sleep(self.cfg.pin_retry)
                continue
            log.info("启动时恢复 pin: %s", result)
            return

    async def _restore_pin_once(self):
        """在锁里读 pin 再应用：排队期间用户改了 pin/follow 时，用的是最新值，也不会把旧 pin 写回状态。"""
        for name in self.live_leases():
            raise Rejected(f"leased:{name}", "租约持有中")
        try:
            await asyncio.wait_for(self.lock.acquire(), self.cfg.queue_timeout)
        except asyncio.TimeoutError:
            raise Rejected("busy", f"排队超过 {self.cfg.queue_timeout:g}s") from None
        try:
            pin = self.pin
            if pin is None:
                return "pin 已被清除，不再恢复"
            reply = await self._apply_locked((pin["w"], pin["h"]), pin["scale"], "app", False)
        finally:
            self.lock.release()
        return reply["result"]

    def spawn(self, coro):
        task = asyncio.create_task(coro)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def serve(self):
        self.load_state()
        await self.open_socket()
        log.info("socket %s，输出 %s@%s，policy %s", self.cfg.socket, self.cfg.output, self.cfg.wayland, self.policy)
        if self.pin is not None:
            self.spawn(self.restore_pin())
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set)
        try:
            await stop.wait()
        finally:
            self.close_socket()
            for task in list(self.tasks):
                task.cancel()
        log.info("退出")


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout, format="%(name)s: %(message)s")
    return asyncio.run(Daemon(Config()).serve()) or 0


if __name__ == "__main__":
    sys.exit(main())
