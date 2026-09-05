"""Slate M0 — the walking skeleton's server.

Quarry, not foundation. This is v0.1's throwaway half: one page over HTTP, a
trimmed wire over WebSocket (``subscribe``/``data``/``event`` and nothing else),
a counter whose value lives here rather than on the device, and a clock that
pushes unprompted. The kept ``server/`` tree begins at v1.1 and is not seeded
from this file (ARCHITECTURE.md §Stack and repository layout).

Deliberately absent, because they belong to later phases:

* no ``ETag`` and no conditional GET — v1.1 owns cache honesty;
* no ``proto``/``screen`` connect params, no session registry, no reconnection
  — v1.2 owns the connect URL and session binding;
* no ``navigate``, ``error`` or ``notice`` — v0.1 speaks a strict *subset* of
  the protocol, never a variant of it.

The library choice (stdlib + ``websockets``) is this file's own business and is
**not** the aiohttp-vs-FastAPI decision, which ARCHITECTURE.md reserves for v1.1.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable, Iterable
from datetime import datetime
from pathlib import Path
from typing import Any, Final

from websockets.asyncio.server import ServerConnection, serve
from websockets.datastructures import Headers
from websockets.http11 import Request, Response

log = logging.getLogger("slate.m0")

#: Where the page XML lives, next to this file's parent.
PAGE_PATH: Final = "/apps/m0.xml"
APPS_DIR: Final = Path(__file__).resolve().parent.parent / "apps"

#: The interval of the unsolicited clock push. One second, per ROADMAP §v0.1.
CLOCK_INTERVAL_S: Final = 1.0

#: A clock source, injected so tests never sleep and never read the wall clock.
Clock = Callable[[], datetime]


class Counter:
    """The number the whole milestone exists to prove.

    It lives here and only here. The device is told what it is and never
    computes it, which is why rebooting the device does not reset it.
    """

    def __init__(self, start: int = 0) -> None:
        self._value = start

    @property
    def value(self) -> int:
        return self._value

    def increment(self) -> int:
        """Bump by one and return the new value."""
        self._value += 1
        return self._value


def format_clock(now: datetime) -> str:
    """The clock label's text: ``HH:MM:SS``, zero-padded, 24-hour."""
    return now.strftime("%H:%M:%S")


def make_update(widget_id: str, **props: Any) -> dict[str, Any]:
    """One element of a ``data`` frame: an ``id`` plus properties to apply.

    Properties must come from the closed dynamic set. v0.1 exercises exactly two
    of the eight — ``text`` (scalar) and ``items`` (structured).
    """
    return {"id": widget_id, **props}


def make_data(
    session_id: str,
    updates: Iterable[dict[str, Any]],
    req_id: int | None = None,
) -> dict[str, Any]:
    """A ``data`` frame. ``req_id`` is omitted entirely on unsolicited push."""
    frame: dict[str, Any] = {
        "type": "data",
        "session_id": session_id,
        "updates": list(updates),
    }
    if req_id is not None:
        frame["req_id"] = req_id
    return frame


class M0Server:
    """The trimmed wire, both halves of it.

    One counter and one clock shared by every connection — v0.1 has no session
    registry, so "the session" is whatever ``session_id`` the device last sent.
    Plural sessions arrive at v1.2.
    """

    def __init__(
        self,
        clock: Clock | None = None,
        counter_start: int = 0,
        clock_interval_s: float = CLOCK_INTERVAL_S,
    ) -> None:
        self.counter = Counter(counter_start)
        self.clock: Clock = clock if clock is not None else datetime.now
        self.clock_interval_s = clock_interval_s
        #: Live connections, each mapped to the session_id it last identified as.
        self._connections: dict[ServerConnection, str] = {}
        self._clock_task: asyncio.Task[None] | None = None
        #: Set after each clock tick, so tests can await a push instead of sleeping.
        self.ticked = asyncio.Event()

    # -- the widgets the page names ---------------------------------------

    def widget_update(self, widget_id: str) -> dict[str, Any] | None:
        """The current value of one widget, or ``None`` if this page has no such id.

        SLATE-004 extends this with ``doc``; v0.1 knows nothing else.
        """
        if widget_id == "count":
            return make_update("count", text=str(self.counter.value))
        if widget_id == "clock":
            return make_update("clock", text=format_clock(self.clock()))
        return None

    # -- the three message types ------------------------------------------

    def on_subscribe(self, message: dict[str, Any]) -> dict[str, Any] | None:
        """A page became active: answer with the current value of each named widget.

        ``req_id`` is echoed so the device can match the response to its request.
        """
        session_id = str(message.get("session_id", ""))
        widgets = message.get("widgets") or []
        updates = [u for u in (self.widget_update(str(w)) for w in widgets) if u is not None]
        if not updates:
            return None
        req_id = message.get("req_id")
        return make_data(session_id, updates, req_id if isinstance(req_id, int) else None)

    def on_event(self, message: dict[str, Any]) -> dict[str, Any] | None:
        """A user interaction. Fire-and-forget: we answer only if we have something to say."""
        session_id = str(message.get("session_id", ""))
        if message.get("action") == "increment":
            value = self.counter.increment()
            return make_data(session_id, [make_update("count", text=str(value))])
        # An unknown action is ignored, exactly like an unknown message type.
        log.debug("ignoring unknown action %r", message.get("action"))
        return None

    def handle(self, message: dict[str, Any]) -> dict[str, Any] | None:
        """Dispatch one inbound frame.

        Unknown message types are **ignored, not errors** — forward compatibility
        is a protocol guarantee (ARCHITECTURE.md §Protocol) and it starts here.
        Unknown JSON keys are ignored for free, because nothing reads them.
        """
        kind = message.get("type")
        if kind == "subscribe":
            return self.on_subscribe(message)
        if kind == "event":
            return self.on_event(message)
        log.debug("ignoring unknown message type %r", kind)
        return None

    # -- the connection ----------------------------------------------------

    async def ws_handler(self, connection: ServerConnection) -> None:
        self._connections[connection] = ""
        try:
            async for raw in connection:
                try:
                    message = json.loads(raw)
                except (json.JSONDecodeError, TypeError):
                    log.debug("ignoring unparseable frame")
                    continue
                if not isinstance(message, dict):
                    continue
                session_id = message.get("session_id")
                if isinstance(session_id, str) and session_id:
                    self._connections[connection] = session_id
                reply = self.handle(message)
                if reply is not None:
                    await connection.send(json.dumps(reply))
        finally:
            self._connections.pop(connection, None)

    async def push_clock(self) -> None:
        """One unsolicited clock frame to every open connection. No ``req_id``."""
        text = format_clock(self.clock())
        for connection, session_id in list(self._connections.items()):
            frame = make_data(session_id, [make_update("clock", text=text)])
            try:
                await connection.send(json.dumps(frame))
            except Exception:  # a closing connection must not kill the ticker
                log.debug("clock push dropped for a closing connection")
        self.ticked.set()

    async def _clock_loop(self) -> None:
        while True:
            await asyncio.sleep(self.clock_interval_s)
            await self.push_clock()

    def start_clock(self) -> None:
        if self._clock_task is None:
            self._clock_task = asyncio.create_task(self._clock_loop())

    async def stop_clock(self) -> None:
        if self._clock_task is not None:
            self._clock_task.cancel()
            try:
                await self._clock_task
            except asyncio.CancelledError:
                pass
            self._clock_task = None

    # -- HTTP --------------------------------------------------------------

    def process_request(
        self, connection: ServerConnection, request: Request
    ) -> Response | None:
        """Serve the page over plain HTTP; let ``/ws`` through to the upgrade.

        No ``ETag`` and no ``If-None-Match``: the device re-fetches every boot and
        caches nothing. Honest caching is v1.1's whole phase.
        """
        path = request.path.split("?", 1)[0]
        if path == "/ws":
            return None
        if path == PAGE_PATH:
            try:
                body = (APPS_DIR / "m0.xml").read_bytes()
            except OSError:
                return connection.respond(500, "page unreadable\n")
            headers = Headers(
                {
                    "Content-Type": "application/xml; charset=utf-8",
                    "Content-Length": str(len(body)),
                }
            )
            return Response(200, "OK", headers, body)
        return connection.respond(404, "not found\n")


async def run(
    host: str = "0.0.0.0",
    port: int = 8000,
    server: M0Server | None = None,
) -> None:
    """Serve until cancelled."""
    m0 = server if server is not None else M0Server()
    async with serve(m0.ws_handler, host, port, process_request=m0.process_request):
        m0.start_clock()
        try:
            await asyncio.get_running_loop().create_future()
        finally:
            await m0.stop_clock()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    log.info("Slate M0 server on :8000 — page %s, wire /ws", PAGE_PATH)
    asyncio.run(run())


if __name__ == "__main__":
    main()
