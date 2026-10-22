#!/usr/bin/env python3
"""IME caret relay: sensor lines become `ime_caret` messages, and losing the
sensor says `null` rather than leaving the last caret standing.

The relay follows a unix socket; a stand-in sensor here serves lines, one of
them malformed, then goes away and comes back.
"""
import asyncio
import os
import sys
import tempfile

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))

from selkies import ime_caret  # noqa: E402
from selkies.ime_caret import ImeCaretRelay, message_from_line  # noqa: E402

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f": {detail}" if detail and not ok else ""))


def test_parse():
    check("a caret line maps to its rectangle",
          message_from_line(b'{"caret":{"x":10,"y":20,"w":2,"h":30},"app":"wechat","src":"fcitx"}\n')
          == 'ime_caret,{"x":10,"y":20,"w":2,"h":30,"src":"fcitx"}')
    check("a null caret maps to null", message_from_line(b'{"caret":null}') == "ime_caret,null")
    for bad in (b"not json", b"[1]", b'{"caret":{"x":1,"y":2,"w":3}}',
                b'{"caret":{"x":1.5,"y":2,"w":3,"h":4}}', b'{"caret":{"x":true,"y":2,"w":3,"h":4}}',
                b'{"caret":{"x":1,"y":2,"w":3,"h":0}}', b"[" * 4000, b'{"caret":{"x":99999999,"y":2,"w":3,"h":4}}'):
        check(f"malformed line is ignored: {bad!r}", message_from_line(bad) is None)


async def test_relay():
    ime_caret.RECONNECT_DELAY_S = 0.05
    path = os.path.join(tempfile.mkdtemp(), "caret.sock")
    sent = []

    async def publish(msg):
        sent.append(msg)

    relay = ImeCaretRelay(publish, socket_path=path)
    task = asyncio.create_task(relay.run())
    await asyncio.sleep(0.15)
    os.makedirs(path)  # not a socket: the relay must keep retrying, not die
    await asyncio.sleep(0.15)
    check("a non-socket at the path does not end the relay", not task.done())
    os.rmdir(path)
    check("an absent sensor publishes nothing", sent == [] and relay.latest == "ime_caret,null", str(sent))

    async def serve(writer_lines):
        """A sensor that serves one connection until `server.done` is set."""
        done = asyncio.Event()

        async def handler(reader, writer):
            server.close()
            for line in writer_lines:
                writer.write(line)
            await writer.drain()
            await done.wait()
            writer.close()
        server = await asyncio.start_unix_server(handler, path)
        server.done = done
        return server

    server = await serve([b'{"caret":{"x":1,"y":2,"w":0,"h":9},"src":"fcitx"}\n', b"garbage\n",
                          b'{"caret":{"x":1,"y":2,"w":0,"h":9},"src":"fcitx"}\n',
                          b'{"caret":{"x":5,"y":6,"w":0,"h":9},"src":"fcitx"}\n'])
    await asyncio.sleep(0.3)
    server.done.set()
    await asyncio.sleep(0.1)
    check("changes are published once each, then null when the sensor closes",
          sent == ['ime_caret,{"x":1,"y":2,"w":0,"h":9,"src":"fcitx"}',
                   'ime_caret,{"x":5,"y":6,"w":0,"h":9,"src":"fcitx"}',
                   "ime_caret,null"], str(sent))
    if os.path.exists(path):
        os.unlink(path)
    sent.clear()
    server = await serve([b'{"caret":{"x":7,"y":8,"w":0,"h":9},"src":"fcitx"}\n'])
    await asyncio.sleep(0.3)
    check("the relay reconnects to a restarted sensor",
          sent == ['ime_caret,{"x":7,"y":8,"w":0,"h":9,"src":"fcitx"}'], str(sent))
    server.done.set()
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


test_parse()
asyncio.run(test_relay())
failed = [r for r in results if not r[1]]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
