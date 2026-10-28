#!/usr/bin/env python3
"""The direct session-socket endpoints: what the server hands a client and
what it lets that client do with them.

A page loaded through one front door can open its session socket on another
the operator lists in ``direct_ws_urls``. The server's side is three things,
run here through the real handlers behind the real auth middleware: the list
itself (`api/direct-endpoints`, https entries only, normalized to a base URL),
the round-trip probe (`api/ping`, uncached, granting CORS and Private Network
Access to exactly the Origins the WebSocket guard admits), and that guard
admitting a cross-host upgrade from a listed Origin while a same-host one
still passes and an unlisted one is still refused.
"""
import asyncio
import logging
import os
import sys
import tempfile

TESTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(REPO, "src"))

# The server module reads its settings at import; keep the shell's out of it
# and point the upload directory it creates at a scratch one.
for _key in [k for k in os.environ if k.startswith("SELKIES_")]:
    del os.environ[_key]
os.environ["SELKIES_FILE_MANAGER_PATH"] = tempfile.mkdtemp(prefix="selkies-direct-ws-")

from aiohttp import web  # noqa: E402
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402

from selkies.stream_server import CentralizedStreamServer, direct_ws_urls  # noqa: E402

FRONT = "https://desktop.example"
TAILNET = "https://host.example.ts.net:8444/"

passed = failed = 0


def check(label: str, ok, detail="") -> None:
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"{'PASS' if ok else 'FAIL'}  [direct-ws] {label}  {detail}", flush=True)


class _Settings:
    """The settings fields the middleware and the handlers read."""

    def __init__(self, **over) -> None:
        self.enable_basic_auth = (False,)
        self.basic_auth_user = "user"
        self.basic_auth_password = "secret"
        self.basic_auth_viewonly_password = ""
        self.master_token = ""
        self.subfolder = ""
        self.allowed_origins = ""
        self.direct_ws_urls = ""
        for key, value in over.items():
            setattr(self, key, value)


class _App:
    """The real ping and endpoint-list handlers, and a stub session socket
    route, behind the real auth middleware."""

    def __init__(self, settings: _Settings) -> None:
        server = CentralizedStreamServer.__new__(CentralizedStreamServer)
        server.settings = settings
        app = web.Application(middlewares=[server._auth_middleware])
        app["settings"] = settings
        app.router.add_get("/api/ping", server.handle_ping)
        app.router.add_route("OPTIONS", "/api/ping", server.handle_ping)
        app.router.add_get("/api/direct-endpoints", server.handle_direct_endpoints)
        app.router.add_get("/api/websockets", self._ok)
        self.client = TestClient(TestServer(app))

    async def _ok(self, _: web.Request) -> web.Response:
        return web.Response(text="ok")

    async def __aenter__(self) -> "_App":
        await self.client.start_server()
        return self

    async def __aexit__(self, *exc) -> None:
        await self.client.close()

    @property
    def own_origin(self) -> str:
        return f"http://{self.client.host}:{self.client.port}"

    async def call(self, method: str, path: str, headers=None):
        response = await self.client.request(method, path, headers=headers or {})
        await response.read()
        return response


def parsing() -> None:
    urls = direct_ws_urls(_Settings(direct_ws_urls=""))
    check("unset: no endpoints", urls == [], urls)
    urls = direct_ws_urls(_Settings(
        direct_ws_urls=f" {TAILNET} , https://other.example:9443 ,https://other.example:9443/,"
                       "http://plain.example/,wss://sock.example/,not a url,https:///nohost"))
    check("https entries kept in order, normalized to a trailing slash and deduplicated",
          urls == [TAILNET, "https://other.example:9443/"], urls)
    urls = direct_ws_urls(_Settings(direct_ws_urls="https://host.example/desk"))
    check("a subfolder base keeps its path", urls == ["https://host.example/desk/"], urls)


async def endpoint_list() -> None:
    async with _App(_Settings(direct_ws_urls=f"{TAILNET},http://plain.example/")) as app:
        response = await app.call("GET", "/api/direct-endpoints")
        body = await response.json()
        check("the list is served as JSON", response.status == 200 and body == {"urls": [TAILNET]},
              f"{response.status} {body}")
        check("the list is never cached",
              response.headers.get("Cache-Control") == "no-store", response.headers.get("Cache-Control"))
    async with _App(_Settings()) as app:
        response = await app.call("GET", "/api/direct-endpoints")
        body = await response.json()
        check("unset: the list is empty", body == {"urls": []}, body)
    async with _App(_Settings(master_token="m", direct_ws_urls=TAILNET)) as app:
        response = await app.call("GET", "/api/direct-endpoints")
        check("secure mode: the list wants a credential", response.status == 401, response.status)
        response = await app.call("GET", "/api/direct-endpoints", headers={"Authorization": "Bearer m"})
        check("secure mode: the list is served with one", response.status == 200, response.status)


async def ping() -> None:
    async with _App(_Settings(allowed_origins=FRONT)) as app:
        response = await app.call("GET", "/api/ping")
        check("ping: empty and uncached",
              response.status == 204 and response.headers.get("Cache-Control") == "no-store",
              f"{response.status} {response.headers.get('Cache-Control')}")
        check("ping without an Origin: no CORS grant",
              "Access-Control-Allow-Origin" not in response.headers, dict(response.headers))

        response = await app.call("GET", "/api/ping", headers={"Origin": FRONT})
        check("ping from a listed Origin: echoed back",
              response.headers.get("Access-Control-Allow-Origin") == FRONT
              and response.headers.get("Vary") == "Origin", dict(response.headers))
        check("a plain GET carries no preflight grants",
              "Access-Control-Allow-Private-Network" not in response.headers, dict(response.headers))

        response = await app.call("GET", "/api/ping", headers={"Origin": "https://evil.example"})
        check("ping from an unlisted Origin: answered, but no CORS grant",
              response.status == 204 and "Access-Control-Allow-Origin" not in response.headers,
              dict(response.headers))

        response = await app.call("GET", "/api/ping", headers={"Origin": app.own_origin})
        check("ping from the same host: echoed back",
              response.headers.get("Access-Control-Allow-Origin") == app.own_origin,
              dict(response.headers))

        preflight = {"Origin": FRONT, "Access-Control-Request-Method": "GET",
                     "Access-Control-Request-Private-Network": "true"}
        response = await app.call("OPTIONS", "/api/ping", headers=preflight)
        h = response.headers
        check("preflight from a listed Origin: CORS and Private Network Access granted",
              response.status == 204 and h.get("Access-Control-Allow-Origin") == FRONT
              and h.get("Access-Control-Allow-Private-Network") == "true"
              and h.get("Access-Control-Allow-Methods") == "GET", dict(h))
        response = await app.call("OPTIONS", "/api/ping",
                                  headers=dict(preflight, Origin="https://evil.example"))
        check("preflight from an unlisted Origin: nothing granted",
              "Access-Control-Allow-Origin" not in response.headers
              and "Access-Control-Allow-Private-Network" not in response.headers,
              dict(response.headers))

    async with _App(_Settings(master_token="m", enable_basic_auth=(True,), allowed_origins=FRONT)) as app:
        response = await app.call("GET", "/api/ping", headers={"Origin": FRONT})
        check("secure mode and Basic: the cross-origin ping needs no credential",
              response.status == 204 and response.headers.get("Access-Control-Allow-Origin") == FRONT,
              f"{response.status} {dict(response.headers)}")


async def upgrade_origins() -> None:
    upgrade = {"Upgrade": "websocket", "Connection": "Upgrade"}
    async with _App(_Settings()) as app:
        response = await app.call("GET", "/api/websockets", headers=dict(upgrade, Origin=FRONT))
        check("unset allowed_origins: a cross-host upgrade is refused", response.status == 403,
              response.status)
    async with _App(_Settings(allowed_origins=FRONT)) as app:
        response = await app.call("GET", "/api/websockets", headers=dict(upgrade, Origin=FRONT))
        check("a cross-host upgrade from the listed page origin passes", response.status == 200,
              response.status)
        response = await app.call("GET", "/api/websockets",
                                  headers=dict(upgrade, Origin=app.own_origin))
        check("a same-host upgrade still passes with allowed_origins set", response.status == 200,
              response.status)
        response = await app.call("GET", "/api/websockets",
                                  headers=dict(upgrade, Origin="https://evil.example"))
        check("an unlisted cross-host upgrade is still refused", response.status == 403,
              response.status)


def main() -> bool:
    logging.getLogger("aiohttp.access").setLevel(logging.ERROR)
    logging.getLogger("stream_server").setLevel(logging.ERROR)
    parsing()
    asyncio.run(endpoint_list())
    asyncio.run(ping())
    asyncio.run(upgrade_origins())
    print(f"[direct-ws] {passed}/{passed + failed} passed", flush=True)
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
