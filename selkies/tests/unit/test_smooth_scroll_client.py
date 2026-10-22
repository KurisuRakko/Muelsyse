#!/usr/bin/env python3
"""What the client puts on the wire for wheel input under smooth scrolling.

A `ws` delta has to add up to the distance the `m2` click path sends for the
same input, signed the way the server's scroll clicks are, at most one message
a frame within the server's bound, and with nothing left scheduled once it is
sent or dropped; with the setting off the click path is untouched. The checks
live in tests/tools/smooth_scroll_audit.mjs, because the paths under test are
JavaScript.
"""
import os
import shutil
import subprocess
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIT = os.path.join(TESTS, "tools", "smooth_scroll_audit.mjs")

node = shutil.which("node")
if not node:
    # Reported as a skip, never as a pass: the audit is the whole suite.
    print("SKIP node not found, so the smooth scroll audit cannot run", flush=True)
    # helpers.SKIP_EXIT, without importing the e2e helper module
    sys.exit(77)

r = subprocess.run([node, AUDIT], capture_output=True, text=True, timeout=120)
lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
for line in lines:
    print(line, flush=True)
if not lines:
    print(f"FAIL  [smooth-scroll] audit ran  {r.stderr.strip()[:400]}", flush=True)
    sys.exit(1)

passed = sum(1 for ln in lines if ln.startswith("PASS"))
print(f"[smooth-scroll] {passed}/{len(lines)} passed")
sys.exit(r.returncode)
