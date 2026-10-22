#!/usr/bin/env python3
"""The IME window follows the remote caret: the composition host's insertion
point is moved onto it, mapped from frame pixels through the same geometry the
pointer uses, and held still while a composition is open. The placement is
JavaScript, so the checks live in tests/tools/ime_caret_audit.mjs.

Usage: python3 tests/unit/test_ime_caret_audit.py
"""
import os
import shutil
import subprocess
import sys

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIT = os.path.join(TESTS, "tools", "ime_caret_audit.mjs")

node = shutil.which("node")
if not node:
    # Reported as a skip, never as a pass: the audit is the whole suite, so
    # exiting 0 here would announce the rule as checked.
    print("SKIP node not found, so the IME caret audit cannot run", flush=True)
    # helpers.SKIP_EXIT, without importing the e2e helper module
    sys.exit(77)

r = subprocess.run([node, AUDIT], capture_output=True, text=True, timeout=120)
lines = [ln for ln in r.stdout.splitlines() if ln.startswith(("PASS", "FAIL"))]
for line in lines:
    print(line, flush=True)
if not lines:
    print(f"FAIL  [ime-caret] audit ran  {r.stderr.strip()[:400]}", flush=True)
    sys.exit(1)

passed = sum(1 for ln in lines if ln.startswith("PASS"))
print(f"[ime-caret] {passed}/{len(lines)} passed")
sys.exit(r.returncode)
