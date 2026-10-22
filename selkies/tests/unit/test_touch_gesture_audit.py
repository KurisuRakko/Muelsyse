#!/usr/bin/env python3
"""Direct touch behaves like a touch screen: a swipe scrolls by distance and
holds no button, taps of any length short of the long press click, a double
tap held down or a full long-press ring drags, two fingers scroll, tap and
pinch. The gestures are JavaScript, so the checks live in
tests/tools/touch_gesture_audit.mjs.

Usage: python3 tests/unit/test_touch_gesture_audit.py
"""
import os
import shutil
import subprocess
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIT = os.path.join(TESTS, "tools", "touch_gesture_audit.mjs")

node = shutil.which("node")
if not node:
    # Reported as a skip, never as a pass: the audit is the whole suite, so
    # exiting 0 here would announce the rule as checked.
    print("SKIP node not found, so the touch gesture audit cannot run", flush=True)
    # helpers.SKIP_EXIT, without importing the e2e helper module
    sys.exit(77)

r = subprocess.run([node, AUDIT], capture_output=True, text=True, timeout=120)
lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
for line in lines:
    print(line, flush=True)
if not lines:
    print(f"FAIL  [touch] audit ran  {r.stderr.strip()[:400]}", flush=True)
    sys.exit(1)

passed = sum(1 for ln in lines if ln.startswith("PASS"))
print(f"[touch] {passed}/{len(lines)} passed")
sys.exit(r.returncode)
