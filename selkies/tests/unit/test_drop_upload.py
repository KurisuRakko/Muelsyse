#!/usr/bin/env python3
"""Drag-drop placement: staged uploads and the /api/drop hand-off.

With a drop helper configured, an upload carrying X-Upload-Drop lands in that
drop's staging directory under the cache dir rather than the file-manager
directory, and /api/drop runs the helper on the staged top-level entries at
the drop point. A helper that accepts leaves the staging directory for the
desktop's copy, marked placed, and removes it a day later; one that refuses
has the entries moved into the file-manager directory without overwriting
anything already there, and so has a drop never placed once it sits idle.
A helper that overruns its timeout is sent SIGTERM before SIGKILL, and a
placement keeps running when its client goes away. Without a helper the
header is ignored and uploads behave as before.

The helpers here are stand-in scripts that record their argv and exit with
the status their X coordinate names, sleep, or ignore SIGTERM, so no desktop
is needed.
"""
import asyncio
import json
import os
import pathlib
import sys
import tempfile
import time

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))

for _key in [k for k in os.environ if k.startswith("SELKIES_")]:
    del os.environ[_key]
_SCRATCH = os.path.realpath(tempfile.mkdtemp(prefix="selkies-drop-upload-"))
_DESKTOP = os.path.join(_SCRATCH, "Desktop")
_CACHE = os.path.join(_SCRATCH, "cache")
_ARGV_LOG = os.path.join(_SCRATCH, "helper-argv.json")
os.makedirs(_DESKTOP)
os.environ["XDG_CACHE_HOME"] = _CACHE

from aiohttp import web  # noqa: E402
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402

from selkies import stream_server  # noqa: E402
from selkies.stream_server import (  # noqa: E402
    DROP_PLACED_MARKER, DROP_PLACED_TTL_SECONDS, DROP_STAGING_TTL_SECONDS,
    CentralizedStreamServer, TransferPacer, _drop_staging_root, _run_drop_helper,
)

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
    print(("PASS" if ok else "FAIL") + "  [drop-upload] {}  {}".format(name, detail),
          flush=True)


# Exit status = int(X): 0 accepts, 2 refuses, anything else is an error.
FAKE_HELPER = """#!/usr/bin/env python3
import json, sys
with open({log!r}, "w") as fh:
    json.dump(sys.argv[1:], fh)
sys.stderr.write("fake helper ran\\n")
sys.exit(int(float(sys.argv[1])))
""".format(log=_ARGV_LOG)

# Accepts after a pause long enough to cancel the request in.
SLOW_HELPER = """#!/usr/bin/env python3
import sys, time
time.sleep(1.0)
sys.exit(0)
"""

# Overruns any timeout; records a SIGTERM and exits on it, or ignores it.
STUCK_HELPER = """#!/usr/bin/env python3
import signal, sys, time
log = {log!r}
def on_term(sig, frame):
    with open(log, "w") as fh:
        fh.write("term")
    sys.exit(1)
signal.signal(signal.SIGTERM, signal.SIG_IGN if sys.argv[0].endswith("-deaf") else on_term)
time.sleep(60)
"""


class _Settings:
    file_transfers = ["upload", "download"]
    file_transfer_limit_mbps = 0.0
    file_manager_path = _DESKTOP
    drop_helper = ""


def _server(helper=""):
    settings = _Settings()
    settings.drop_helper = helper
    server = CentralizedStreamServer.__new__(CentralizedStreamServer)
    server.settings = settings
    server.upload_dir = pathlib.Path(_DESKTOP)
    server._chunked_uploads = {}
    server._drops_in_flight = {}
    server._drop_sweep = None
    return server


def _app(helper):
    server = _server(helper)
    settings = server.settings
    server.transfer_cap = TransferPacer(static_bps=0)
    server.upload_pacer = TransferPacer(adaptive=True)
    app = web.Application()
    app["settings"] = settings
    app.router.add_post("/api/upload", server.handle_upload)
    app.router.add_post("/api/drop", server.handle_drop)
    return TestClient(TestServer(app))


async def _upload(client, path, data, drop_id=None):
    headers = {"X-Upload-Path": path}
    if drop_id is not None:
        headers["X-Upload-Drop"] = drop_id
    return await client.post("/api/upload", data=data, headers=headers)


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _write_script(name, text):
    path = os.path.join(_SCRATCH, name)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o755)
    return path


def _stage(name, files, age):
    """Stage ``files`` (relative path -> text) as drop ``name``, every path
    in it last modified ``age`` seconds ago."""
    stage = os.path.join(_drop_staging_root(), name)
    os.makedirs(stage, exist_ok=True)
    for rel, text in files.items():
        path = os.path.join(stage, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    stamp = time.time() - age
    for dirpath, dirnames, filenames in os.walk(stage):
        for entry in dirnames + filenames:
            os.utime(os.path.join(dirpath, entry), (stamp, stamp))
    os.utime(stage, (stamp, stamp))
    return stage


class _FakeRequest(dict):
    """The slice of a request handle_drop reads, so the handler can be
    called (and cancelled) as a plain coroutine."""

    def __init__(self, app, body):
        super().__init__()
        self.app = app
        self._body = body

    async def json(self):
        return self._body


async def main():
    helper = os.path.join(_SCRATCH, "fake-helper")
    with open(helper, "w", encoding="utf-8") as fh:
        fh.write(FAKE_HELPER)
    os.chmod(helper, 0o755)
    stage_root = _drop_staging_root()
    check("staging root sits under XDG_CACHE_HOME",
          stage_root == os.path.join(_CACHE, "muelsyse-drop"), stage_root)

    # No helper: the header is ignored and /api/drop is refused.
    client = _app("")
    await client.start_server()
    try:
        resp = await _upload(client, "plain.txt", b"plain", drop_id="ignored-1")
        check("helper off: upload with a drop header answers 200", resp.status == 200, resp.status)
        check("helper off: the file lands in the file-manager directory",
              _read(os.path.join(_DESKTOP, "plain.txt")) == "plain")
        check("helper off: nothing is staged", not os.path.exists(os.path.join(stage_root, "ignored-1")))
        resp = await client.post("/api/drop", json={"id": "ignored-1", "x": 0, "y": 0, "entries": ["plain.txt"]})
        check("helper off: /api/drop refused", resp.status == 403, resp.status)
    finally:
        await client.close()

    client = _app(helper)
    await client.start_server()
    try:
        # Staging and id validation.
        resp = await _upload(client, "dir/sub/a.txt", b"A", drop_id="drop-ok")
        check("drop upload answers 200", resp.status == 200, resp.status)
        check("drop upload lands in the staging directory",
              _read(os.path.join(stage_root, "drop-ok", "dir", "sub", "a.txt")) == "A")
        check("drop upload does not touch the file-manager directory",
              not os.path.exists(os.path.join(_DESKTOP, "dir")))
        for bad in ("../x", "a/b", "a.b", "x" * 65, "", "with space"):
            resp = await _upload(client, "f.txt", b"x", drop_id=bad)
            check(f"invalid drop id {bad!r} refused", resp.status == 400, resp.status)
        resp = await _upload(client, "../escape.txt", b"x", drop_id="drop-ok")
        check("traversal inside a drop stays refused", resp.status == 400, resp.status)
        check("traversal wrote nothing beside the staging directory",
              not os.path.exists(os.path.join(stage_root, "escape.txt")))

        # Request validation.
        bad_bodies = [
            ({"id": "drop-ok", "x": 0, "y": 0, "entries": ["../drop-ok"]}, "entry with a slash"),
            ({"id": "drop-ok", "x": 0, "y": 0, "entries": [".."]}, "entry '..'"),
            ({"id": "drop-ok", "x": 0, "y": 0, "entries": ["."]}, "entry '.'"),
            ({"id": "drop-ok", "x": 0, "y": 0, "entries": ["dir\\..\\x"]}, "entry with a backslash"),
            ({"id": "drop-ok", "x": 0, "y": 0, "entries": ["missing"]}, "entry not staged"),
            ({"id": "drop-ok", "x": 0, "y": 0, "entries": []}, "empty entries"),
            ({"id": "drop-ok", "x": 0, "y": 0, "entries": [1]}, "non-string entry"),
            ({"id": "drop-ok", "x": -1, "y": 0, "entries": ["dir"]}, "negative x"),
            ({"id": "drop-ok", "x": 0, "y": "5", "entries": ["dir"]}, "string y"),
            ({"id": "drop-ok", "x": True, "y": 0, "entries": ["dir"]}, "boolean x"),
            ({"id": "../drop-ok", "x": 0, "y": 0, "entries": ["dir"]}, "invalid id"),
        ]
        for body, label in bad_bodies:
            resp = await client.post("/api/drop", json=body)
            check(f"/api/drop refuses {label}", resp.status == 400, resp.status)
        resp = await client.post("/api/drop", data=b"{not json",
                                 headers={"Content-Type": "application/json"})
        check("/api/drop refuses malformed JSON", resp.status == 400, resp.status)
        os.symlink(_DESKTOP, os.path.join(stage_root, "drop-ok", "link"))
        resp = await client.post("/api/drop", json={"id": "drop-ok", "x": 0, "y": 0, "entries": ["link"]})
        check("/api/drop refuses an entry resolving outside the staging directory",
              resp.status == 400, resp.status)
        os.remove(os.path.join(stage_root, "drop-ok", "link"))
        check("no helper ran for a refused request", not os.path.exists(_ARGV_LOG))

        # Accepted: placed, staging kept for the desktop's copy.
        resp = await client.post("/api/drop", json={"id": "drop-ok", "x": 0, "y": 12.5, "entries": ["dir"]})
        body = await resp.json()
        check("accepted drop answers placed", resp.status == 200 and body.get("placed") is True,
              f"{resp.status} {body}")
        argv = json.loads(_read(_ARGV_LOG)) if os.path.exists(_ARGV_LOG) else None
        check("helper got X, Y and the staged absolute path",
              argv == ["0.00", "12.50", os.path.join(os.path.realpath(stage_root), "drop-ok", "dir")],
              argv)
        check("accepted drop keeps its staging directory",
              os.path.isdir(os.path.join(stage_root, "drop-ok", "dir")))
        check("accepted drop leaves the file-manager directory alone",
              not os.path.exists(os.path.join(_DESKTOP, "dir")))
        check("accepted drop is marked placed",
              os.path.isfile(os.path.join(stage_root, "drop-ok", DROP_PLACED_MARKER)))
        resp = await client.post("/api/drop", json={"id": "drop-ok", "x": 0, "y": 0, "entries": ["dir"]})
        check("a placed drop is not placed again", resp.status == 409, resp.status)
        resp = await client.post("/api/drop", json={
            "id": "drop-ok", "x": 0, "y": 0, "entries": [DROP_PLACED_MARKER]})
        check("/api/drop refuses the placed marker as an entry", resp.status == 400, resp.status)
        resp = await _upload(client, DROP_PLACED_MARKER, b"", drop_id="drop-mark")
        check("an upload cannot plant the placed marker", resp.status == 400
              and not os.path.exists(os.path.join(stage_root, "drop-mark", DROP_PLACED_MARKER)), resp.status)
        resp = await _upload(client, f"sub/{DROP_PLACED_MARKER}", b"m", drop_id="drop-mark")
        check("the marker name is only reserved at the top", resp.status == 200, resp.status)
        resp = await client.post("/api/drop", json={
            "id": "drop-mark", "x": 0, "y": 0, "entries": [DROP_PLACED_MARKER]})
        check("/api/drop refuses the marker name before looking for it", resp.status == 400, resp.status)

        # Refused: moved to the file-manager directory, never overwriting.
        with open(os.path.join(_DESKTOP, "note.txt"), "w", encoding="utf-8") as fh:
            fh.write("original")
        with open(os.path.join(_DESKTOP, "note (1).txt"), "w", encoding="utf-8") as fh:
            fh.write("first copy")
        os.makedirs(os.path.join(_DESKTOP, "folder"))
        await _upload(client, "note.txt", b"dropped", drop_id="drop-no")
        await _upload(client, "folder/inner.txt", b"inner", drop_id="drop-no")
        await _upload(client, "fresh.txt", b"fresh", drop_id="drop-no")
        resp = await client.post("/api/drop", json={
            "id": "drop-no", "x": 2, "y": 3, "entries": ["note.txt", "folder", "fresh.txt"]})
        body = await resp.json()
        check("refused drop answers placed: false with a reason",
              resp.status == 200 and body.get("placed") is False and "2" in body.get("reason", ""),
              f"{resp.status} {body}")
        check("refused drop reports where the entries landed",
              body.get("entries") == ["note (2).txt", "folder (1)", "fresh.txt"], body.get("entries"))
        check("existing file not overwritten", _read(os.path.join(_DESKTOP, "note.txt")) == "original")
        check("existing numbered copy not overwritten",
              _read(os.path.join(_DESKTOP, "note (1).txt")) == "first copy")
        check("dropped file renamed beside them", _read(os.path.join(_DESKTOP, "note (2).txt")) == "dropped")
        check("dropped directory renamed whole",
              _read(os.path.join(_DESKTOP, "folder (1)", "inner.txt")) == "inner")
        check("existing directory left empty", os.listdir(os.path.join(_DESKTOP, "folder")) == [])
        check("unclashing entry keeps its name", _read(os.path.join(_DESKTOP, "fresh.txt")) == "fresh")
        check("refused drop removes its staging directory",
              not os.path.exists(os.path.join(stage_root, "drop-no")))

        # A helper error (not just a refusal) and a helper that cannot run
        # fall back the same way.
        await _upload(client, "err.txt", b"e", drop_id="drop-err")
        resp = await client.post("/api/drop", json={"id": "drop-err", "x": 1, "y": 0, "entries": ["err.txt"]})
        body = await resp.json()
        check("helper error falls back", body.get("placed") is False
              and _read(os.path.join(_DESKTOP, "err.txt")) == "e", body)
    finally:
        await client.close()

    client = _app(os.path.join(_SCRATCH, "no-such-helper"))
    await client.start_server()
    try:
        await _upload(client, "gone.txt", b"g", drop_id="drop-gone")
        resp = await client.post("/api/drop", json={"id": "drop-gone", "x": 0, "y": 0, "entries": ["gone.txt"]})
        body = await resp.json()
        check("missing helper falls back", resp.status == 200 and body.get("placed") is False
              and _read(os.path.join(_DESKTOP, "gone.txt")) == "g", body)
    finally:
        await client.close()

    # The sweep: a placed drop is kept for a day and then deleted; one never
    # placed is handed to the file-manager directory after an idle hour.
    old = DROP_STAGING_TTL_SECONDS + 60
    stale = _stage("stale-1", {}, old)
    unplaced = _stage("unplaced-1", {
        "note.txt": "unplaced note",
        "tree/deep/leaf.txt": "leaf",
        ".selkies-upload-0123.part": "half",
        "tree/.selkies-upload-4567.part": "half",
    }, old)
    fresh = _stage("unplaced-fresh", {"fresh-only.txt": "f"}, 10)
    deep_write = _stage("unplaced-deep", {"top/inner.txt": "i"}, old)
    os.utime(os.path.join(deep_write, "top", "inner.txt"))
    busy = _stage("unplaced-busy", {"busy.txt": "b"}, old)
    placed = _stage("placed-1", {"kept.txt": "k", DROP_PLACED_MARKER: ""}, DROP_PLACED_TTL_SECONDS + 60)
    os.utime(os.path.join(placed, DROP_PLACED_MARKER))
    server = _server()
    server._drops_in_flight = {"unplaced-busy": None}
    before = set(os.listdir(_DESKTOP))
    await server._expire_stale_drops()
    check("empty stale staging directory swept", not os.path.exists(stale))
    check("unplaced idle drop removed from staging", not os.path.exists(unplaced))
    check("unplaced idle drop's file moved without overwriting",
          _read(os.path.join(_DESKTOP, "note (3).txt")) == "unplaced note"
          and _read(os.path.join(_DESKTOP, "note.txt")) == "original",
          sorted(set(os.listdir(_DESKTOP)) - before))
    check("unplaced idle drop's folder moved whole",
          _read(os.path.join(_DESKTOP, "tree", "deep", "leaf.txt")) == "leaf")
    check("unfinished upload leftovers are not handed over",
          not any(n.startswith(".selkies-upload-") for n in os.listdir(_DESKTOP))
          and os.listdir(os.path.join(_DESKTOP, "tree")) == ["deep"])
    check("fresh unplaced drop kept", os.path.isfile(os.path.join(fresh, "fresh-only.txt")))
    check("a recent write deep inside keeps an unplaced drop",
          os.path.isfile(os.path.join(deep_write, "top", "inner.txt")))
    check("a drop being placed is kept", os.path.isfile(os.path.join(busy, "busy.txt")))
    check("placed drop kept before its day is up", os.path.isfile(os.path.join(placed, "kept.txt")))
    check("placed drop's entries never handed to the file-manager directory",
          not os.path.exists(os.path.join(_DESKTOP, "kept.txt")))
    check("accepted drop from the HTTP run kept", os.path.isdir(os.path.join(stage_root, "drop-ok")))
    stamp = time.time() - DROP_PLACED_TTL_SECONDS - 60
    os.utime(os.path.join(placed, DROP_PLACED_MARKER), (stamp, stamp))
    await server._expire_stale_drops()
    check("placed drop deleted after its day", not os.path.exists(placed))
    check("deleted placed drop left the file-manager directory alone",
          not os.path.exists(os.path.join(_DESKTOP, "kept.txt")))

    # A helper that overruns is sent SIGTERM, then SIGKILL if it ignores that.
    term_log = os.path.join(_SCRATCH, "term.log")
    stuck = _write_script("stuck-helper", STUCK_HELPER.format(log=term_log))
    deaf = _write_script("stuck-helper-deaf", STUCK_HELPER.format(log=term_log))
    saved = (stream_server.DROP_HELPER_TIMEOUT_SECONDS, stream_server.DROP_HELPER_TERM_GRACE_SECONDS)
    stream_server.DROP_HELPER_TIMEOUT_SECONDS, stream_server.DROP_HELPER_TERM_GRACE_SECONDS = 1.0, 1.0
    try:
        start = time.monotonic()
        code, text = await _run_drop_helper([stuck, "0", "0"])
        check("a helper answering SIGTERM is terminated, not killed",
              code is None and text.endswith("terminated") and os.path.exists(term_log)
              and _read(term_log) == "term", f"{code} {text!r}")
        check("termination waited for the timeout only", time.monotonic() - start < 1.9,
              f"{time.monotonic() - start:.2f}s")
        os.remove(term_log)
        start = time.monotonic()
        code, text = await _run_drop_helper([deaf, "0", "0"])
        elapsed = time.monotonic() - start
        check("a helper ignoring SIGTERM is killed after the grace period",
              code is None and text.endswith("killed") and not os.path.exists(term_log), f"{code} {text!r}")
        check("the kill came after the grace period", 1.9 < elapsed < 4.0, f"{elapsed:.2f}s")

        client = _app(stuck)
        await client.start_server()
        try:
            await _upload(client, "slowpoke.txt", b"s", drop_id="drop-stuck")
            resp = await client.post("/api/drop", json={
                "id": "drop-stuck", "x": 0, "y": 0, "entries": ["slowpoke.txt"]})
            body = await resp.json()
            check("a timed-out helper falls back", body.get("placed") is False
                  and "timed out" in body.get("reason", "")
                  and _read(os.path.join(_DESKTOP, "slowpoke.txt")) == "s", body)
        finally:
            await client.close()
    finally:
        stream_server.DROP_HELPER_TIMEOUT_SECONDS, stream_server.DROP_HELPER_TERM_GRACE_SECONDS = saved

    # A client leaving mid-drop does not abandon the placement.
    slow = _write_script("slow-helper", SLOW_HELPER)
    server = _server(slow)
    app = web.Application()
    app["settings"] = server.settings
    _stage("drop-left", {"left.txt": "l"}, 0)
    handler = asyncio.ensure_future(server.handle_drop(
        _FakeRequest(app, {"id": "drop-left", "x": 0, "y": 0, "entries": ["left.txt"]})))
    await asyncio.sleep(0.3)
    handler.cancel()
    try:
        await handler
    except asyncio.CancelledError:
        pass
    check("the drop stays in flight after its client left", "drop-left" in server._drops_in_flight)
    placement = server._drops_in_flight.get("drop-left")
    if placement is not None:
        await placement
    check("the placement finished and was recorded",
          "drop-left" not in server._drops_in_flight
          and os.path.isfile(os.path.join(stage_root, "drop-left", DROP_PLACED_MARKER)))
    check("a finished placement is not also moved to the file-manager directory",
          not os.path.exists(os.path.join(_DESKTOP, "left.txt"))
          and os.path.isfile(os.path.join(stage_root, "drop-left", "left.txt")))

    print(f"[drop-upload] {passed}/{passed + failed} passed", flush=True)
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if asyncio.run(main()) else 1)
