#!/usr/bin/env python3
"""Where the WebSocket core opens its session socket.

A page can reach its server through the origin it was loaded from and through
the direct endpoints the operator lists; the socket opens on the one with the
lowest measured round trip, or on the route the user picked, and stays on the
origin when nothing was measured. The rules are JavaScript, so the checks live
in tests/tools/ws_route_audit.mjs.
"""
import os
import shutil
import subprocess
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIT = os.path.join(TESTS, "tools", "ws_route_audit.mjs")

node = shutil.which("node")
if not node:
    # Reported as a skip, never as a pass: the audit is the whole suite, so
    # exiting 0 here would announce the rule as checked.
    print("SKIP node not found, so the ws route audit cannot run", flush=True)
    # helpers.SKIP_EXIT, without importing the e2e helper module
    sys.exit(77)

r = subprocess.run([node, AUDIT], capture_output=True, text=True, timeout=120)
lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
for line in lines:
    print(line, flush=True)
if not lines:
    print(f"FAIL  [ws-route] audit ran  {r.stderr.strip()[:400]}", flush=True)
    sys.exit(1)

passed = sum(1 for ln in lines if ln.startswith("PASS"))
print(f"[ws-route] {passed}/{len(lines)} passed")
sys.exit(r.returncode)
