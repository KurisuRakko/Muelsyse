#!/usr/bin/env python3
"""What density a page streams at, and what scale it publishes for its neighbours.

A page's framebuffer is its window's CSS size times `render_scale`, so 100%
streams the window at its own size and 200% supersamples it; the browser's own
`devicePixelRatio` takes no part, and a manual resolution is the operator's
framebuffer, streamed at density 1 whatever the render scale says. A page
publishes the scale of its box with the layout, for the cross-display drag, by
measuring the box it draws the stream in, which only answers the question while
the box is showing the stream the server realized: one still holding the stream
from before a resize measures that stream's ratio. The remote desktop's own DPI
(`scaling_dpi`) is not an input to any of it. The rules are JavaScript, so the
checks live in tests/tools/stream_density_audit.mjs.
"""
import os
import shutil
import subprocess
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIT = os.path.join(TESTS, "tools", "stream_density_audit.mjs")

node = shutil.which("node")
if not node:
    # Reported as a skip, never as a pass: the audit is the whole suite, so
    # exiting 0 here would announce the rule as checked.
    print("SKIP node not found, so the stream density audit cannot run", flush=True)
    # helpers.SKIP_EXIT, without importing the e2e helper module
    sys.exit(77)

r = subprocess.run([node, AUDIT], capture_output=True, text=True, timeout=120)
lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
for line in lines:
    print(line, flush=True)
if not lines:
    print(f"FAIL  [stream-density] audit ran  {r.stderr.strip()[:400]}", flush=True)
    sys.exit(1)

passed = sum(1 for ln in lines if ln.startswith("PASS"))
print(f"[stream-density] {passed}/{len(lines)} passed")
sys.exit(r.returncode)
