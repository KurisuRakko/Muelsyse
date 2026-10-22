"""Relay of the remote text caret to the browser, so its IME window follows it.

The browser places its input-method candidate window at the caret of the
focused DOM element. That element is the stream overlay, so without help the
window lands at an arbitrary spot rather than under the remote text field.
`muelsyse-imecaret` (Muelsyse/scripts) learns the caret rectangle of the focused
Qt app over the fcitx portal and streams it as JSON lines on a unix socket;
this module follows that socket and turns each line into an
`ime_caret,<json>` control message, whose rectangle the client maps from frame
pixels onto the overlay. `ime_caret,null` means no caret is known, and the
client falls back to its own estimate.

The sensor is optional: while its socket is absent the relay retries quietly
and the clients receive `null`.
"""

import asyncio
import json
import logging
import os
from typing import Awaitable, Callable, Optional

logger = logging.getLogger("ime_caret")

RECONNECT_DELAY_S = 2.0
# One JSON line is well under 200 bytes; anything longer is not the sensor.
MAX_LINE_BYTES = 4096
# Generous bound on a frame coordinate; rejects garbage, never a real screen.
MAX_COORD = 1 << 15

NULL_MESSAGE = "ime_caret,null"


def default_socket_path() -> Optional[str]:
    """The sensor's socket: MUELSYSE_IMECARET_SOCKET, else under XDG_RUNTIME_DIR."""
    override = os.environ.get("MUELSYSE_IMECARET_SOCKET")
    if override:
        return override
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    return os.path.join(runtime, "muelsyse-imecaret.sock") if runtime else None


def message_from_line(line: bytes) -> Optional[str]:
    """Translates one sensor line into an `ime_caret,` message, or None if malformed."""
    try:
        data = json.loads(line)
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None
    if not isinstance(data, dict):
        return None
    caret = data.get("caret")
    if caret is None:
        return NULL_MESSAGE
    if not isinstance(caret, dict):
        return None
    rect = {}
    for key in ("x", "y", "w", "h"):
        value = caret.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or abs(value) > MAX_COORD:
            return None
        rect[key] = value
    if rect["w"] < 0 or rect["h"] <= 0:
        return None
    payload = dict(rect, src=str(data.get("src", ""))[:32])
    return "ime_caret," + json.dumps(payload, separators=(",", ":"))


class ImeCaretRelay:
    """Follows the sensor socket and hands every caret change to `publish`.

    `latest` is the last message published, so a client that connects later
    can be brought up to date.
    """

    def __init__(self, publish: Callable[[str], Awaitable[None]],
                 socket_path: Optional[str] = None):
        self._publish = publish
        self._path = socket_path if socket_path is not None else default_socket_path()
        self.latest = NULL_MESSAGE

    async def _emit(self, message: str) -> None:
        if message == self.latest:
            return
        self.latest = message
        try:
            await self._publish(message)
        except Exception as e:  # a broadcast failure must not end the relay
            logger.warning(f"ime_caret broadcast failed: {e}")

    async def run(self) -> None:
        """Runs until cancelled, reconnecting whenever the sensor goes away."""
        if not self._path:
            logger.info("ime_caret: no socket path (XDG_RUNTIME_DIR unset); relay disabled")
            return
        warned = False
        while True:
            try:
                reader, writer = await asyncio.open_unix_connection(
                    self._path, limit=MAX_LINE_BYTES)
            except OSError as e:
                if not warned:
                    logger.info(f"ime_caret: sensor not available at {self._path} ({e}); retrying")
                    warned = True
                await asyncio.sleep(RECONNECT_DELAY_S)
                continue
            warned = False
            logger.info(f"ime_caret: connected to {self._path}")
            try:
                while True:
                    try:
                        line = await reader.readline()
                    except (ValueError, asyncio.LimitOverrunError):
                        logger.warning("ime_caret: oversized line from sensor; reconnecting")
                        break
                    if not line:
                        break
                    message = message_from_line(line)
                    if message is not None:
                        await self._emit(message)
            except (ConnectionResetError, OSError) as e:
                logger.info(f"ime_caret: sensor connection lost: {e}")
            finally:
                writer.close()
            await self._emit(NULL_MESSAGE)
            await asyncio.sleep(RECONNECT_DELAY_S)
