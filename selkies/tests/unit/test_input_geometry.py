#!/usr/bin/env python3
"""One CSS-to-remote mapping for every pointer path, with one DPR in it.

Absolute mouse, touch, drag, relative motion and pointer lock all resolve a
client point (or delta) against the same sink box: remote pixels per CSS pixel
are `framebuffer / CSS box`, measured off the node that is actually drawing.
The local `devicePixelRatio` belongs to whoever sized that framebuffer and must
not be applied a second time on the way in -- doing so doubles every coordinate
on a HiDPI screen, which is what this suite is here to catch. The rule is
JavaScript, so the checks live in tests/tools/input_geometry_audit.mjs.

Usage: python3 tests/unit/test_input_geometry.py
"""
import os
import shutil
import subprocess
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIT = os.path.join(TESTS, "tools", "input_geometry_audit.mjs")

node = shutil.which("node")
if not node:
    # Reported as a skip, never as a pass: the audit is the whole suite, so
    # exiting 0 here would announce the rule as checked.
    print("SKIP node not found, so the input geometry audit cannot run", flush=True)
    # helpers.SKIP_EXIT, without importing the e2e helper module
    sys.exit(77)

r = subprocess.run([node, AUDIT], capture_output=True, text=True, timeout=120)
lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
for line in lines:
    print(line, flush=True)
if not lines:
    print(f"FAIL  [input-geometry] audit ran  {r.stderr.strip()[:400]}", flush=True)
    sys.exit(1)

passed = sum(1 for ln in lines if ln.startswith("PASS"))
print(f"[input-geometry] {passed}/{len(lines)} passed")
sys.exit(r.returncode)
