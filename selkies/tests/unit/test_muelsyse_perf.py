#!/usr/bin/env python3
"""MUELSYSE_PERF metering: the per-second RD_PERF_SRV line and RD_PERF_CLIENT relay.

With the switch on, the server counts what the pixelflux callback hands the
loop, what the ACK gate holds back, what each relay drops and sends, the
pointer messages the input handler dispatches and how late the loop wakes, and
prints one fixed-format line per display per active second. A client report
(`RD_PERF_CLIENT <json>`) is logged as-is, ahead of the viewer gate and the
input handler; with the switch off it is dropped without a word and the
server_settings payloads carry no `muelsyse_perf` key.

Usage: python3 tests/unit/test_muelsyse_perf.py
"""
import asyncio
import gzip
import os
import re
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))
# Read once at import, so it has to be set before the modules load.
os.environ["MUELSYSE_PERF"] = "1"

passed = failed = 0


def check(label: str, ok, detail="") -> None:
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"{'PASS' if ok else 'FAIL'}  [muelsyse-perf] {label}  {detail}", flush=True)


try:
    from selkies import input_handler
    from selkies import selkies as srv
    from selkies.settings import inflate_gz_bounded
except ModuleNotFoundError as exc:
    print(f"SKIP {exc.name} not installed, so the server cannot be imported",
          flush=True)
    sys.exit(77)  # helpers.SKIP_EXIT, without importing the e2e helper module
except Exception as exc:  # pragma: no cover - reported, never silently passed
    print(f"FAIL  [muelsyse-perf] the modules import  {exc}", flush=True)
    print("[muelsyse-perf] 0/1 passed")
    sys.exit(1)

SOURCE = open(os.path.join(REPO, "src", "selkies", "selkies.py"), encoding="utf-8").read()
LINE_RE = re.compile(
    r"^RD_PERF_SRV t=\d+ disp=\S+ rx=\d+ rx_kb=\d+ hop_ms_max=(-|\d+\.\d) gated=\d+ "
    r"sent=\d+ sent_kb=\d+ relay_drop=\d+ send_ms_max=(-|\d+\.\d) in_m=\d+ "
    r"in_iv=(-|\d+\.\d/\d+\.\d/\d+\.\d) loop_lag_ms_max=(-|\d+\.\d)$")

check("the switch reads on from MUELSYSE_PERF=1", srv.MUELSYSE_PERF is True)

# --- percentile helper ------------------------------------------------------
check("no samples is a dash", srv._perf_triplet([]) == "-")
check("one sample fills all three", srv._perf_triplet([16.66]) == "16.7/16.7/16.7",
      srv._perf_triplet([16.66]))
check("nearest-rank p50/p95/max over 1..100",
      srv._perf_triplet([float(v) for v in range(100, 0, -1)]) == "50.0/95.0/100.0",
      srv._perf_triplet([float(v) for v in range(1, 101)]))
check("ms fields keep one decimal, dash when empty",
      srv._perf_ms(None) == "-" and srv._perf_ms(3.14159) == "3.1")

# --- pointer window ---------------------------------------------------------
win = input_handler.PerfInputWindow()
for at in (10.0, 10.016, 10.033, 12.5, 12.508):
    win.note(at)
count, gaps = win.take()
check("every m/m2 counts, a gap past the ceiling is left out of the intervals",
      count == 5 and [round(g) for g in gaps] == [16, 17, 8], (count, gaps))
win.note(12.524)
count, gaps = win.take()
check("the interval spanning a window boundary lands in the later one",
      count == 1 and [round(g) for g in gaps] == [16], (count, gaps))

# --- the per-second line ----------------------------------------------------
srv._PERF_DISPLAYS.clear()
input_handler.PERF_INPUT.take()
srv._perf_loop_lag_ms_max = 0.4
check("an idle second prints nothing", srv._perf_report_lines(1) == [])

w = srv._perf_display("primary")
w.note_rx(7, 2048, 1.25)
w.note_rx(7, 1024, 3.5)   # second stripe of frame 7
w.note_rx(8, 1024, 0.5)
w.note_gated(8)
w.note_gated(8)
w.note_send(True, 3072, 2.0)
w.note_send(False, 1024, 9.04)
srv._perf_display("display2").note_rx(1, 512, None)
input_handler.PERF_INPUT.note(20.0)
input_handler.PERF_INPUT.note(20.008)
srv._perf_loop_lag_ms_max = 12.34
lines = srv._perf_report_lines(1700000000123)
check("one line per active display, primary first", len(lines) == 2
      and " disp=primary " in lines[0] and " disp=display2 " in lines[1], lines)
check("every line matches the fixed field order", all(LINE_RE.match(l) for l in lines), lines)
check("stripes count as one logical frame, bytes add up",
      " rx=2 rx_kb=4 hop_ms_max=3.5 gated=1 sent=1 sent_kb=4 " in lines[0], lines[0])
check("input and loop lag ride the primary line",
      lines[0].endswith(" send_ms_max=9.0 in_m=2 in_iv=8.0/8.0/8.0 loop_lag_ms_max=12.3"),
      lines[0])
check("a secondary line carries no input",
      " in_m=0 in_iv=- " in lines[1] and " hop_ms_max=- " in lines[1], lines[1])
check("the windows reset after the report", srv._perf_report_lines(2) == [])
input_handler.PERF_INPUT.note(20.016)
lines = srv._perf_report_lines(3)
check("a second with only input still prints the primary line",
      len(lines) == 1 and " disp=primary rx=0 " in lines[0] and " in_m=1 " in lines[0], lines)


# --- relay drop and send counting -------------------------------------------
def h264(frame_id: int, row: int, idr: bool) -> dict:
    data = bytearray(16)
    data[0] = 0x04
    data[1] = 0x01 if idr else 0x02
    data[4] = (row >> 8) & 0xFF
    data[5] = row & 0xFF
    return {'data': memoryview(bytes(data)), 'owner': None, 'frame_id': frame_id}


class FakeServer:
    def __init__(self):
        self.display_clients = {}
        self.video_relay_groups = {}
        self.clients = set()
        self._bytes_sent_in_interval = 0


class FakeWS:
    def __init__(self):
        self.sent = []

    async def send_bytes(self, data):
        self.sent.append(bytes(data))


async def relay_cases() -> None:
    srv._PERF_DISPLAYS.clear()
    server = FakeServer()
    ws = FakeWS()
    relay = srv._VideoRelay(server, "primary", ws, 4 * 1024 * 1024)
    server.video_relay_groups["primary"] = {ws: relay}
    relay.offer(h264(1, 0, False))   # fresh relay: delta on an ungated row
    relay.offer(h264(1, 16, False))  # same frame, another row
    w = srv._perf_display("primary")
    check("a gated delta frame drops once however many stripes it has",
          w.relay_drop == 1, w.relay_drop)
    relay.offer(h264(2, 0, True))
    relay.offer(h264(2, 16, True))
    relay.offer(h264(3, 0, False))
    relay.start()
    for _ in range(50):
        await asyncio.sleep(0)
        if not relay.backlog:
            break
    relay.stop()
    await asyncio.sleep(0)
    check("sent counts logical frames that reached send_bytes",
          len(ws.sent) == 3 and w.sent == 2 and w.sent_bytes == 48
          and w.send_ms_max is not None, (len(ws.sent), w.sent, w.sent_bytes))
    relay.budget = 20
    relay.offer(h264(4, 0, False))
    relay.offer(h264(5, 0, False))   # over budget: frame 4 is cleared, then 5 is gated
    check("a budget overflow counts the frames it threw away, and the delta it then gates",
          w.relay_drop == 3, w.relay_drop)

    srv._perf_loop_lag_ms_max = None
    probe = asyncio.ensure_future(srv._perf_loop_probe())
    await asyncio.sleep(0.03)
    probe.cancel()
    check("the loop probe records a lag sample",
          srv._perf_loop_lag_ms_max is not None and srv._perf_loop_lag_ms_max >= 0.0,
          srv._perf_loop_lag_ms_max)


asyncio.run(relay_cases())

# --- RD_PERF_CLIENT ---------------------------------------------------------
report = '{"fps":58.2,"decode_ms":[1.2,3.4,9.9],"note":"x' + "y" * 600 + '"}'
line = srv._perf_client_line("RD_PERF_CLIENT " + report, ("198.51.100.7", 51234), 42)
check("the client report is logged with peer and its JSON untouched",
      line == f"RD_PERF_CLIENT t=42 peer=198.51.100.7:51234 {report}", line[:80])
big = srv._perf_client_line("RD_PERF_CLIENT " + "z" * 9000, ("::1", 1), 1)
check("the JSON is cut at 4KB", big.endswith(" " + "z" * 4096), len(big))
check("a newline cannot split the journal line",
      "\n" not in srv._perf_client_line('RD_PERF_CLIENT {"a":"b\nc"}', ("h", 2), 1))
wire = b"\x05" + gzip.compress(("RD_PERF_CLIENT " + report).encode())
check("a gzip-wrapped report past 512 bytes inflates back to the same text",
      inflate_gz_bounded(wire[1:]) == "RD_PERF_CLIENT " + report)

handler = SOURCE[SOURCE.index("async for msg in websocket:"):]
gz_at = handler.index("msg.data[0] == 0x05")
text_at = handler.index("elif msg.type == WSMsgType.TEXT:")
branch_at = handler.index('message.startswith("RD_PERF_CLIENT")')
viewer_at = handler.index("DENIED unauthorized message from viewer")
input_at = handler.index("self.input_handler.on_message(message")
check("the gzip unwrap runs before the text dispatch that holds the branch",
      gz_at < text_at < branch_at)
check("the branch sits ahead of the viewer gate and the input handler",
      branch_at < viewer_at < input_at)
branch = handler[branch_at:handler.index("perms = client_permissions.get(websocket)", branch_at)]
check("off, the branch drops the report without logging",
      re.search(r"if MUELSYSE_PERF:\s+data_logger\.info\(_perf_client_line\(", branch)
      is not None and branch.rstrip().endswith("continue")
      and "warning" not in branch)

# --- server_settings flag ---------------------------------------------------
flags = re.findall(r'if MUELSYSE_PERF:\s+(?:#[^\n]*\s+)?\S+\["muelsyse_perf"\] = True', SOURCE)
check("both server_settings payloads gain muelsyse_perf only behind the switch",
      len(flags) == 2 and SOURCE.count('"muelsyse_perf"') == 2, flags)

print(f"[muelsyse-perf] {passed}/{passed + failed} passed")
sys.exit(1 if failed else 0)
