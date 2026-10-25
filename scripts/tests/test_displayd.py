#!/usr/bin/env python3
"""muelsyse-displayd 单测：假 kscreen-doctor / adapter / systemctl / journalctl / ss / pw-dump，
在临时 XDG_RUNTIME_DIR 里起真的守护进程，经 CLI 和裸 socket 打。

    python3 -I scripts/tests/test_displayd.py

假 kscreen-doctor 和假 adapter 共用一个 JSON 状态文件（输出、modes、各假命令的回答），
调用记录追加到 calls.log。adapter 跑在本进程的线程里，模拟「只保留一个未使用的动态 mode」。
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DAEMON = os.path.join(ROOT, "scripts", "muelsyse-displayd.py")
CLI = os.path.join(ROOT, "scripts", "muelsyse-display")

CONNECT = "INFO:data_websocket:Data WebSocket connected from ('127.0.0.1', 50000)"
GONE = "INFO:data_websocket:Last client gone after the grace period. Tearing down singleton collectors and pipelines."

# 假命令共用的读写状态工具，内嵌进每个假脚本。
FAKE_COMMON = r'''
import json, os, sys, time
STATE = os.environ["FAKE_DISPLAY_STATE"]
def load():
    with open(STATE) as f:
        return json.load(f)
def save(st):
    tmp = STATE + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE)
def record(*words):
    with open(os.path.join(os.path.dirname(STATE), "calls.log"), "a") as f:
        f.write(" ".join(str(w) for w in words) + "\n")
'''

FAKE_KSCREEN = FAKE_COMMON + r'''
st = load()
args = sys.argv[1:]
if args == ["-j"]:
    if st.get("kscreen_down"):
        sys.exit(1)
    record("kscreen", "-j", os.environ.get("WAYLAND_DISPLAY"), os.environ.get("QT_QPA_PLATFORM"))
    out = {"name": "Virtual-0", "currentModeId": st["current"], "scale": st["scale"],
           "modes": [{"id": m["id"], "name": "%dx%d@60" % (m["w"], m["h"]), "refreshRate": 60.0,
                      "size": {"width": m["w"], "height": m["h"]}} for m in st["modes"]]}
    print(json.dumps({"outputs": [{"name": "Other-1", "currentModeId": "1", "scale": 1,
                                    "modes": [{"id": "1", "refreshRate": 60, "size": {"width": 640, "height": 480}}]}, out]}))
    sys.exit(0)
start = time.time()
time.sleep(st.get("set_delay", 0))
st = load()  # 睡眠期间测试可能改了别的键，重新读
record("kscreen-set", "%.3f" % start, *args)
if st.get("partial_set_once"):
    # 只切了 mode、没改 scale，之后的调用按 fail_set 处理
    st.pop("partial_set_once")
    args = [a for a in args if ".mode." in a]
elif st.get("fail_set_once") or st.get("fail_set"):
    st.pop("fail_set_once", None)
    save(st)
    print("Output mode 1234x567@60 not found.")
    sys.exit(0)
for a in args:
    parts = a.split(".")
    if parts[2] == "mode":
        if not any(m["id"] == parts[3] for m in st["modes"]):
            print("not found"); sys.exit(0)
        st["current"] = parts[3]
    elif parts[2] == "scale":
        st["scale"] = float(".".join(parts[3:]))
save(st)
record("kscreen-set-end", "%.3f" % time.time())
'''

FAKE_SYSTEMCTL = FAKE_COMMON + r'''
st = load()["selkies"]
args = sys.argv[1:]
assert args[0] == "--user", args
if st.get("systemctl_fail"):
    sys.exit(1)
if args[1] == "is-active":
    print(st["active"]); sys.exit(0 if st["active"] == "active" else 3)
if args[1:5] == ["show", "-p", "MainPID", "--value"]:
    print(st.get("mainpid", 4242)); sys.exit(0)
if args[1:5] == ["show", "-p", "Environment", "--value"]:
    print(st.get("environment", 'SELKIES_PORT=8090 "SELKIES_X=a b"')); sys.exit(0)
sys.exit(2)
'''

FAKE_JOURNALCTL = FAKE_COMMON + r'''
st = load()["selkies"]
record("journalctl", *sys.argv[1:])
if st.get("journal_rc"):
    sys.exit(st["journal_rc"])
print("\n".join(st.get("journal", [])))
'''

FAKE_SS = FAKE_COMMON + r'''
st = load()["selkies"]
record("ss", *sys.argv[1:])
if st.get("ss_rc"):
    sys.exit(st["ss_rc"])
# ss_once：只在第一次被调用时有连接（模拟监控面板的 HTTP 探活）。
once = st.get("ss_once")
flag = STATE + ".ss_once"
if once and not os.path.exists(flag):
    open(flag, "w").close()
    print(once, end="")
    sys.exit(0)
print(st.get("ss", ""), end="")
'''

FAKE_PW_DUMP = FAKE_COMMON + r'''
st = load()
if st.get("pw_fail"):
    sys.exit(1)
nodes = [{"id": 64, "info": {"state": "running", "props": {"node.name": "selkies-kwin", "media.class": "Stream/Input/Video"}}}]
if st.get("uu"):
    nodes.append({"id": 94, "info": {"state": st["uu"], "props": {"node.name": "uuremote-server", "media.class": "Stream/Input/Video"}}})
print(json.dumps(nodes))
'''


def initial_state():
    return {
        "current": "1",
        "scale": 1.0,
        "modes": [{"id": "1", "w": 3840, "h": 2160}, {"id": "2", "w": 1920, "h": 1080}],
        "next_id": 3,
        "selkies": {"active": "inactive"},
    }


class FakeAdapter:
    """单行 JSON 的假 KWin adapter；prepare 时丢掉旧的未使用动态 mode，同尺寸幂等。"""

    def __init__(self, path, state_path):
        self.path = path
        self.state_path = state_path
        self.requests = []
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(8)
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            with conn:
                line = conn.makefile("rb").readline()
                req = json.loads(line)
                self.requests.append(req)
                conn.sendall((json.dumps(self._reply(req)) + "\n").encode())

    def _reply(self, req):
        with open(self.state_path) as f:
            st = json.load(f)
        if req["op"] == "status":
            return {"ok": True, "backend": "virtual", "outputs": [
                {"index": 7, "name": "Virtual-0", "modes": [{"width": m["w"], "height": m["h"], "refresh_mhz": 60000} for m in st["modes"]]}]}
        if req["op"] == "prepare":
            if st.get("prepare_fail"):
                return {"ok": False, "error": "目标 mode 超出安全范围"}
            w, h = req["width"], req["height"]
            if not any(m["w"] == w and m["h"] == h for m in st["modes"]):
                st["modes"] = [m for m in st["modes"] if not m.get("dyn") or m["id"] == st["current"]]
                st["modes"].append({"id": str(st["next_id"]), "w": w, "h": h, "dyn": True})
                st["next_id"] += 1
                tmp = self.state_path + ".adapter"
                with open(tmp, "w") as f:
                    json.dump(st, f)
                os.replace(tmp, self.state_path)
            return {"ok": True}
        return {"ok": False, "error": "unknown op"}

    def close(self):
        self.srv.close()


class DisplaydTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="displayd-test.")
        d = self.tmp.name
        self.state_path = os.path.join(d, "fake.json")
        self.write_state(initial_state())
        self.bins = {}
        for name, body in (("kscreen-doctor", FAKE_KSCREEN), ("systemctl", FAKE_SYSTEMCTL),
                           ("journalctl", FAKE_JOURNALCTL), ("ss", FAKE_SS), ("pw-dump", FAKE_PW_DUMP)):
            path = os.path.join(d, "fake-" + name)
            with open(path, "w") as f:
                f.write(f"#!{sys.executable} -I\n{body}")
            os.chmod(path, 0o755)
            self.bins[name] = path
        self.adapter = FakeAdapter(os.path.join(d, "adapter.sock"), self.state_path)
        self.sock = os.path.join(d, "display.sock")
        self.env = dict(os.environ)
        self.env.update({
            "XDG_RUNTIME_DIR": d,
            "MUELSYSE_DISPLAY_SOCKET": self.sock,
            "MUELSYSE_DISPLAY_ADAPTER": self.adapter.path,
            "MUELSYSE_DISPLAY_STATE": os.path.join(d, "config", "display.json"),
            "MUELSYSE_DISPLAY_WAYLAND": "wayland-test",
            "MUELSYSE_DISPLAY_KSCREEN_DOCTOR": self.bins["kscreen-doctor"],
            "MUELSYSE_DISPLAY_SYSTEMCTL": self.bins["systemctl"],
            "MUELSYSE_DISPLAY_JOURNALCTL": self.bins["journalctl"],
            "MUELSYSE_DISPLAY_SS": self.bins["ss"],
            "MUELSYSE_DISPLAY_PW_DUMP": self.bins["pw-dump"],
            "MUELSYSE_DISPLAY_PIN_RETRY_S": "0.3",
            "MUELSYSE_DISPLAY_BACKOFF_MAX_S": "0.5",
            "FAKE_DISPLAY_STATE": self.state_path,
        })
        self.proc = None
        self.start_daemon()

    def tearDown(self):
        self.stop_daemon()
        self.adapter.close()
        self.tmp.cleanup()

    # ---- 工具 ----

    def write_state(self, st):
        tmp = self.state_path + ".w"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, self.state_path)

    def read_state(self):
        with open(self.state_path) as f:
            return json.load(f)

    def patch(self, **kw):
        st = self.read_state()
        sel = kw.pop("selkies", None)
        if sel is not None:
            st["selkies"] = sel
        st.update(kw)
        self.write_state(st)

    def current(self):
        st = self.read_state()
        m = next(m for m in st["modes"] if m["id"] == st["current"])
        return m["w"], m["h"], st["scale"]

    def calls(self, prefix):
        try:
            with open(os.path.join(self.tmp.name, "calls.log")) as f:
                return [l.split() for l in f if l.startswith(prefix + " ")]
        except FileNotFoundError:
            return []

    def start_daemon(self, extra_env=None):
        env = dict(self.env, **(extra_env or {}))
        self.log_path = os.path.join(self.tmp.name, "daemon.log")
        self.log_file = open(self.log_path, "a")
        self.proc = subprocess.Popen([sys.executable, "-I", DAEMON], env=env,
                                     stdout=self.log_file, stderr=subprocess.STDOUT)
        for _ in range(100):
            if self.proc.poll() is not None:
                break
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.connect(self.sock)
                return
            except OSError:
                time.sleep(0.05)
        self.fail("displayd 没起来:\n" + open(self.log_path).read())

    def stop_daemon(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(5)
        self.proc = None
        self.log_file.close()

    def daemon_log(self):
        with open(self.log_path) as f:
            return f.read()

    def raw(self, payload):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(30)
            s.connect(self.sock)
            data = payload if isinstance(payload, bytes) else (json.dumps(payload) + "\n").encode()
            s.sendall(data)
            return json.loads(s.makefile("rb").readline())

    def req(self, **kw):
        kw.setdefault("source", "app")
        return self.raw({"op": "request", **kw})

    def cli(self, *args, env=None):
        p = subprocess.run([sys.executable, "-I", CLI, *args], env=env or self.env,
                           capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout.strip(), p.stderr.strip()

    def assertRejected(self, reply, reason):
        self.assertFalse(reply["ok"], reply)
        self.assertEqual(reply["reason"], reason, reply)

    # ---- 状态与基本流程 ----

    def test_status(self):
        st = self.raw({"op": "status"})
        self.assertTrue(st["ok"])
        self.assertEqual(st["mode"], {"w": 3840, "h": 2160, "refresh_mhz": 60000})
        self.assertEqual(st["scale"], 1.0)
        self.assertEqual(st["policy"], "follow")
        self.assertIsNone(st["pin"])
        self.assertEqual(st["leases"], [])
        self.assertEqual(st["selkies"], {"service_active": False, "clients": "no"})
        self.assertFalse(st["uu_watching"])
        self.assertIsNone(st["last_change"])
        # kscreen-doctor 用的是目标 KWin 的 wayland socket
        self.assertEqual(self.calls("kscreen")[0][2:], ["wayland-test", "wayland"])
        rc, out, _ = self.cli("status", "--json")
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads(out)["mode"]["w"], 3840)
        rc, out, _ = self.cli("status")
        self.assertEqual(rc, 0)
        self.assertIn("mode 3840x2160@60 scale 1", out)
        self.assertIn("policy follow", out)

    def test_uu_watching(self):
        self.patch(uu="running")
        self.assertTrue(self.raw({"op": "status"})["uu_watching"])
        self.patch(uu="suspended")
        self.assertFalse(self.raw({"op": "status"})["uu_watching"])
        self.patch(uu="running", pw_fail=True)
        self.assertFalse(self.raw({"op": "status"})["uu_watching"])

    def test_new_size_prepares_then_switches(self):
        rc, out, err = self.cli("set", "1600x900", "--scale", "1.5")
        self.assertEqual((rc, out), (0, "applied 1600x900 scale 1.5"), err)
        self.assertEqual(self.current(), (1600, 900, 1.5))
        prep = [r for r in self.adapter.requests if r["op"] == "prepare"]
        self.assertEqual(prep, [{"op": "prepare", "output_index": 7, "width": 1600, "height": 900, "refresh_mhz": 60000}])
        sets = self.calls("kscreen-set")
        self.assertEqual(sets[-1][2:], ["output.Virtual-0.mode.3", "output.Virtual-0.scale.1.5"])
        lc = self.raw({"op": "status"})["last_change"]
        self.assertEqual((lc["source"], lc["result"], lc["to"]["w"]), ("cli", "applied", 1600))
        self.assertIn("cli 3840x2160@1 → 1600x900@1.5 applied", self.daemon_log())
        # 再换一个新尺寸：旧的动态 mode 1600x900 现在是当前 mode，不能被丢掉
        self.assertTrue(self.req(w=1280, h=720)["ok"])
        self.assertEqual(self.current(), (1280, 720, 1.5))

    def test_existing_size_skips_prepare(self):
        reply = self.req(w=1920, h=1080)
        self.assertEqual(reply["result"], "applied")
        self.assertEqual([r for r in self.adapter.requests if r["op"] == "prepare"], [])
        self.assertEqual(self.current(), (1920, 1080, 1.0))

    def test_scale_only_and_unchanged(self):
        rc, out, _ = self.cli("set", "--scale", "1.75")
        self.assertEqual((rc, out), (0, "applied 3840x2160 scale 1.75"))
        n = len(self.calls("kscreen-set"))
        rc, out, _ = self.cli("set", "3840x2160", "--scale", "1.75")
        self.assertEqual((rc, out), (0, "unchanged 3840x2160 scale 1.75"))
        self.assertEqual(len(self.calls("kscreen-set")), n)

    def test_invalid(self):
        for kw in ({"w": 1601, "h": 900}, {"w": 4096, "h": 2160}, {"w": 300, "h": 900},
                   {"scale": 1.3}, {"w": 1920}, {}, {"w": "1920", "h": 1080}, {"w": True, "h": 1080}):
            self.assertRejected(self.req(**kw), "invalid")
        self.assertRejected(self.req(w=1920, h=1080, source="evil"), "invalid")
        self.assertRejected(self.raw({"op": "nope"}), "invalid")
        self.assertRejected(self.raw(b"not json\n"), "invalid")
        self.assertRejected(self.raw(b'{"op":"status","pad":"' + b"x" * 5000 + b'"}\n'), "invalid")
        rc, _, err = self.cli("set", "1601x900")
        self.assertEqual(rc, 1)
        self.assertTrue(err.startswith("rejected: invalid"), err)
        rc, _, _ = self.cli("set", "--scale", "1.3")
        self.assertEqual(rc, 1)
        self.assertEqual(self.cli("set")[0], 2)
        self.assertEqual(self.cli("set", "abc")[0], 2)
        self.assertEqual(self.current(), (3840, 2160, 1.0))
        self.assertEqual(self.calls("kscreen-set"), [])
        # 守护进程还活着
        self.assertTrue(self.raw({"op": "status"})["ok"])

    def test_fake_success_rolls_back(self):
        self.patch(fail_set_once=True)
        reply = self.req(w=1600, h=900, scale=1.25)
        self.assertRejected(reply, "verify_failed")
        self.assertIn("已写回旧值", reply["detail"])
        self.assertEqual(self.current(), (3840, 2160, 1.0))
        sets = self.calls("kscreen-set")
        self.assertEqual(len(sets), 2)
        self.assertEqual(sets[1][2:], ["output.Virtual-0.mode.1", "output.Virtual-0.scale.1"])
        self.assertEqual(self.raw({"op": "status"})["last_change"]["result"], "verify_failed")

    def test_rollback_also_fails(self):
        self.patch(partial_set_once=True, fail_set=True)
        reply = self.req(w=1920, h=1080, scale=1.5)
        self.assertRejected(reply, "verify_failed")
        self.assertIn("写回旧值也没成功", reply["detail"])

    def test_backend_errors(self):
        self.patch(prepare_fail=True)
        self.assertRejected(self.req(w=1600, h=900), "backend_error")
        self.patch(prepare_fail=False, kscreen_down=True)
        self.assertRejected(self.req(w=1600, h=900), "backend_error")
        self.assertRejected(self.raw({"op": "status"}), "backend_error")
        self.patch(kscreen_down=False)
        self.adapter.close()
        self.assertRejected(self.req(w=1600, h=900), "backend_error")
        self.assertTrue(self.req(w=1920, h=1080)["ok"])  # 现有 mode 不需要 adapter

    # ---- pin / follow ----

    def test_pin_policy_and_restart(self):
        rc, out, _ = self.cli("pin", "1920x1080", "--scale", "1.5")
        self.assertEqual((rc, out), (0, "applied 1920x1080 scale 1.5"))
        st = self.raw({"op": "status"})
        self.assertEqual((st["policy"], st["pin"]), ("pinned", {"w": 1920, "h": 1080, "scale": 1.5}))
        for src in ("selkies", "sunshine"):
            self.assertRejected(self.req(w=1280, h=720, source=src), "pinned")
            self.assertRejected(self.req(w=1280, h=720, source=src, force=True), "pinned")
        # app/cli 的请求更新 pin（只给 scale，尺寸保持）
        self.assertTrue(self.req(scale=1.25)["ok"])
        self.assertEqual(self.raw({"op": "status"})["pin"], {"w": 1920, "h": 1080, "scale": 1.25})
        with open(self.env["MUELSYSE_DISPLAY_STATE"]) as f:
            self.assertEqual(json.load(f), {"policy": "pinned", "pin": {"w": 1920, "h": 1080, "scale": 1.25}})

        # 重启：守护进程停着时输出被别人改了，起来后自动把 pin 写回去
        self.stop_daemon()
        self.patch(current="1", scale=2.0)
        self.start_daemon()
        self.wait_for(lambda: self.current() == (1920, 1080, 1.25))
        self.assertEqual(self.raw({"op": "status"})["policy"], "pinned")

        rc, out, _ = self.cli("follow")
        self.assertEqual((rc, out), (0, "follow"))
        self.assertTrue(self.req(w=1280, h=720, source="selkies")["ok"])
        with open(self.env["MUELSYSE_DISPLAY_STATE"]) as f:
            self.assertEqual(json.load(f), {"policy": "follow", "pin": None})

    def test_pin_current_and_rejected_pin(self):
        self.assertTrue(self.req(w=1920, h=1080, scale=1.5)["ok"])
        rc, out, _ = self.cli("pin")
        self.assertEqual((rc, out), (0, "unchanged 1920x1080 scale 1.5"))
        self.assertEqual(self.raw({"op": "status"})["pin"], {"w": 1920, "h": 1080, "scale": 1.5})
        # 应用被拒时 pin 不变
        self.patch(selkies={"active": "active", "journal": [CONNECT]})
        rc, _, err = self.cli("pin", "1280x720")
        self.assertEqual(rc, 1)
        self.assertTrue(err.startswith("rejected: selkies_active"), err)
        self.assertEqual(self.raw({"op": "status"})["pin"], {"w": 1920, "h": 1080, "scale": 1.5})

    def test_restart_pin_waits_for_selkies(self):
        self.assertTrue(self.raw({"op": "pin", "w": 1920, "h": 1080, "scale": 1.5})["ok"])
        self.stop_daemon()
        self.patch(current="1", scale=1.0, kscreen_down=True,
                   selkies={"active": "active", "journal": [CONNECT]})
        self.start_daemon()
        time.sleep(1.0)
        self.patch(kscreen_down=False)
        time.sleep(1.0)
        self.assertEqual(self.current(), (3840, 2160, 1.0))  # Selkies 有客户端，不写
        self.assertIn("selkies_active", self.daemon_log())
        self.patch(selkies={"active": "active", "journal": [CONNECT, GONE]})
        self.wait_for(lambda: self.current() == (1920, 1080, 1.5))

    # ---- 租约 ----

    def test_lease(self):
        rc, _, _ = self.cli("lease", "sunshine", "--ttl", "60")
        self.assertEqual(rc, 0)
        self.assertEqual([l["name"] for l in self.raw({"op": "status"})["leases"]], ["sunshine"])
        self.assertRejected(self.req(w=1920, h=1080), "leased:sunshine")
        rc, _, err = self.cli("set", "1920x1080")
        self.assertEqual(rc, 1)
        self.assertTrue(err.startswith("rejected: leased:sunshine"), err)
        self.assertTrue(self.req(w=1920, h=1080, source="sunshine")["ok"])
        rc, out, _ = self.cli("set", "1280x720", "--force")
        self.assertEqual((rc, out), (0, "applied 1280x720 scale 1"))
        rc, out, _ = self.cli("release", "sunshine")
        self.assertEqual((rc, out), (0, "released sunshine"))
        self.assertTrue(self.req(w=1920, h=1080)["ok"])
        # TTL 到期自动失效
        self.assertTrue(self.raw({"op": "lease", "name": "sunshine", "ttl_s": 0.5})["ok"])
        self.assertRejected(self.req(w=1280, h=720), "leased:sunshine")
        time.sleep(0.7)
        self.assertTrue(self.req(w=1280, h=720)["ok"])
        self.assertEqual(self.raw({"op": "status"})["leases"], [])
        self.assertRejected(self.raw({"op": "lease", "name": "a b", "ttl_s": 5}), "invalid")
        self.assertRejected(self.raw({"op": "lease", "name": "x", "ttl_s": -1}), "invalid")

    # ---- Selkies 判断 ----

    def test_selkies_judgement(self):
        cases = [
            ({"active": "inactive"}, True),
            ({"active": "failed", "systemctl_fail": False}, True),
            ({"active": "active"}, True),  # 刚启动，日志里没有客户端事件
            ({"active": "active", "journal": [CONNECT, GONE]}, True),
            ({"active": "active", "journal": [CONNECT, GONE, CONNECT]}, False),
            ({"active": "active", "journal": [CONNECT, CONNECT]}, False),
            ({"active": "active", "journal": [CONNECT, GONE], "ss": "0 0 127.0.0.1:8090 127.0.0.1:50000\n"}, False),
            # 只连一瞬间的探活不算客户端（隔一会儿再看一次就没了）。
            ({"active": "active", "journal": [CONNECT, GONE], "ss_once": "0 0 127.0.0.1:8090 127.0.0.1:50001\n"}, True),
            ({"active": "active", "journal_rc": 1}, False),
            ({"active": "active", "ss_rc": 1}, False),
            ({"active": "active", "environment": "FOO=1"}, False),
            ({"active": "active", "mainpid": 0}, False),
            ({"active": "activating", "journal": [CONNECT]}, False),
            ({"active": "inactive", "systemctl_fail": True}, False),
        ]
        for sel, allowed in cases:
            with self.subTest(sel=sel):
                self.patch(selkies=sel)
                before = self.current()
                if allowed:
                    w, h = (3840, 2160) if before[:2] == (1920, 1080) else (1920, 1080)
                    reply = self.req(w=w, h=h)
                    self.assertTrue(reply["ok"], reply)
                    self.assertEqual(self.current()[:2], (w, h))
                else:
                    self.assertRejected(self.req(w=1280, h=720), "selkies_active")
                    self.assertEqual(self.current(), before)
                    self.assertTrue(self.req(w=1280, h=720, force=True)["ok"])
                    self.assertTrue(self.req(w=1920, h=1080, force=True)["ok"])
        # 日志查的是本次 MainPID、最近 24h
        self.patch(selkies={"active": "active", "mainpid": 777})
        self.raw({"op": "status"})
        j = self.calls("journalctl")[-1]
        self.assertIn("_PID=777", j)
        self.assertIn("-24h", j)
        self.assertIn("-Htn state established ( sport = :8090 )", " ".join(self.calls("ss")[-1]))
        st = self.raw({"op": "status"})["selkies"]
        self.assertEqual(st, {"service_active": True, "clients": "no"})

    def test_warn_when_client_joins_during_write(self):
        # 写的过程中（kscreen-doctor 慢）浏览器连上：照样 applied，日志记 warning
        self.patch(set_delay=0.8, selkies={"active": "active", "journal": [CONNECT, GONE]})
        t = threading.Thread(target=lambda: setattr(self, "_r", self.req(w=1920, h=1080)))
        t.start()
        time.sleep(0.5)
        self.patch(selkies={"active": "active", "journal": [CONNECT, GONE, CONNECT]})
        t.join()
        self.assertEqual(self._r["result"], "applied")
        self.assertIn("写完后发现 Selkies 客户端=yes", self.daemon_log())

    # ---- 锁 ----

    def test_concurrent_requests_serialize(self):
        self.patch(set_delay=0.5)
        results = {}

        def run(key, **kw):
            results[key] = self.req(**kw)

        a = threading.Thread(target=run, args=("a",), kwargs={"w": 1600, "h": 900})
        b = threading.Thread(target=run, args=("b",), kwargs={"scale": 1.5})
        a.start()
        time.sleep(0.15)
        b.start()
        a.join()
        b.join()
        self.assertTrue(results["a"]["ok"] and results["b"]["ok"], results)
        # b 只改 scale，尺寸沿用 a 的结果
        self.assertEqual(results["b"]["mode"]["w"], 1600)
        self.assertEqual(self.current(), (1600, 900, 1.5))
        starts = [float(c[1]) for c in self.calls("kscreen-set")]
        ends = [float(c[1]) for c in self.calls("kscreen-set-end")]
        self.assertEqual(len(starts), 2)
        self.assertLessEqual(ends[0], starts[1] + 0.01)

    def test_busy(self):
        self.stop_daemon()
        self.start_daemon({"MUELSYSE_DISPLAY_QUEUE_S": "0.3"})
        self.patch(set_delay=1.0)
        t = threading.Thread(target=lambda: self.req(w=1920, h=1080))
        t.start()
        time.sleep(0.2)
        self.assertRejected(self.req(w=1280, h=720), "busy")
        t.join()
        # status 不排队
        self.assertTrue(self.raw({"op": "status"})["ok"])

    # ---- socket 与进程 ----

    def test_socket_mode_and_multiple_requests(self):
        self.assertEqual(os.stat(self.sock).st_mode & 0o777, 0o600)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(self.sock)
            s.sendall(b'{"op":"status"}\n\n{"op":"follow"}\n')
            f = s.makefile("rb")
            self.assertTrue(json.loads(f.readline())["ok"])
            self.assertEqual(json.loads(f.readline()), {"ok": True, "policy": "follow"})

    def test_cli_unreachable_and_sigterm(self):
        self.stop_daemon()
        self.assertFalse(os.path.exists(self.sock))
        rc, _, err = self.cli("status")
        self.assertEqual(rc, 3)
        self.assertIn("muelsyse-displayd 没在运行", err)
        # 留下死 socket 也能起来
        dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        dead.bind(self.sock)
        dead.close()
        self.start_daemon()
        self.assertEqual(self.cli("status")[0], 0)

    def wait_for(self, cond, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if cond():
                return
            time.sleep(0.1)
        self.fail("等待超时；守护进程日志:\n" + self.daemon_log())


if __name__ == "__main__":
    unittest.main()
