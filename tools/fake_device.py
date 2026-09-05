"""The fake device — a host-side script speaking the device's wire.

Seeded at v0.1 and **only ever extended** (ARCHITECTURE.md §Components). No later
phase introduces its own harness: v1.2 adds sessions and reconnection here, v2.2
adds `navigate`, v3.1 adds `notice`. That is why frame handling dispatches on
`type` through a registry rather than hard-coding v0.1's three messages — adding
a type later must not mean rewriting this file.

Two ways in, deliberately:

* as a **pytest fixture** — ``async with FakeDevice(url) as device: ...``, which is
  how every integration test drives the server;
* as a **CLI** — ``python tools/fake_device.py`` — for hand-driving a server with
  no hardware in reach, printing every frame it sees.

It holds no truth of its own. Like the real device, it renders what it is told
and reports what the user did.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import secrets
from collections.abc import Callable
from types import TracebackType
from typing import Any, Self

from websockets.asyncio.client import ClientConnection, connect

#: Default address of the M0 server. The real device's peer is 192.168.1.197;
#: the tests point this at an ephemeral local port instead.
DEFAULT_URL = "ws://127.0.0.1:8000/ws"

#: How long a test waits for a frame before deciding the server is not coming.
DEFAULT_TIMEOUT_S = 5.0

Frame = dict[str, Any]
FrameHandler = Callable[[Frame], None]


def mint_session_id() -> str:
    """A device-minted session id: ``s-`` plus enough hex to ignore collisions.

    The device mints it, never the server — first use *is* creation, and there is
    no handshake to get wrong (ARCHITECTURE.md §Protocol).
    """
    return f"s-{secrets.token_hex(2)}"


class FakeDevice:
    """One connection to one server, speaking the device's half of the wire."""

    def __init__(
        self,
        url: str = DEFAULT_URL,
        session_id: str | None = None,
        timeout_s: float = DEFAULT_TIMEOUT_S,
    ) -> None:
        self.url = url
        self.session_id = session_id if session_id is not None else mint_session_id()
        self.timeout_s = timeout_s
        self._connection: ClientConnection | None = None
        self._req_id = 0
        #: Every frame this device has received, in arrival order.
        self.received: list[Frame] = []
        #: Per-type observers, so a caller can watch a kind without draining.
        self._handlers: dict[str, list[FrameHandler]] = {}

    # -- connection lifecycle ---------------------------------------------

    async def __aenter__(self) -> Self:
        self._connection = await connect(self.url, open_timeout=self.timeout_s)
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        await self.close()

    async def close(self) -> None:
        if self._connection is not None:
            await self._connection.close()
            self._connection = None

    @property
    def connection(self) -> ClientConnection:
        if self._connection is None:
            raise RuntimeError("FakeDevice is not connected; use it as an async context manager")
        return self._connection

    # -- extension point ---------------------------------------------------

    def on(self, frame_type: str, handler: FrameHandler) -> None:
        """Observe every frame of one type as it arrives.

        The seam later phases grow through: `navigate`, `error` and `notice` need
        no change to this class, only a handler registered here.
        """
        self._handlers.setdefault(frame_type, []).append(handler)

    def _dispatch(self, frame: Frame) -> None:
        self.received.append(frame)
        for handler in self._handlers.get(str(frame.get("type", "")), ()):
            handler(frame)

    # -- device → server ---------------------------------------------------

    def next_req_id(self) -> int:
        self._req_id += 1
        return self._req_id

    async def send(self, frame: Frame) -> None:
        await self.connection.send(json.dumps(frame))

    async def subscribe(self, page: str, widgets: list[str]) -> int:
        """A page became active. Returns the ``req_id`` the response will echo."""
        req_id = self.next_req_id()
        await self.send(
            {
                "type": "subscribe",
                "session_id": self.session_id,
                "req_id": req_id,
                "page": page,
                "widgets": widgets,
            }
        )
        return req_id

    async def event(
        self, action: str, source: str = "", values: dict[str, str] | None = None
    ) -> None:
        """A user interaction. Fire-and-forget — the device does not wait.

        ``values`` carries every input field on the page, not a keystroke: submit
        the form, don't stream it.
        """
        await self.send(
            {
                "type": "event",
                "session_id": self.session_id,
                "action": action,
                "source": source,
                "values": values if values is not None else {},
            }
        )

    # -- server → device ---------------------------------------------------

    async def recv(self, timeout_s: float | None = None) -> Frame:
        """The next frame, whatever type it is."""
        raw = await asyncio.wait_for(
            self.connection.recv(), timeout_s if timeout_s is not None else self.timeout_s
        )
        frame: Frame = json.loads(raw)
        self._dispatch(frame)
        return frame

    async def recv_data(self, req_id: int | None = None, timeout_s: float | None = None) -> Frame:
        """The next ``data`` frame, optionally the one answering ``req_id``.

        Frames of other types are consumed and recorded on the way past, which is
        what lets a test ask for its answer without racing the clock ticker.
        """
        deadline = asyncio.get_running_loop().time() + (
            timeout_s if timeout_s is not None else self.timeout_s
        )
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError(f"no matching data frame (req_id={req_id})")
            frame = await self.recv(timeout_s=remaining)
            if frame.get("type") != "data":
                continue
            if req_id is None or frame.get("req_id") == req_id:
                return frame

    async def recv_push(self, widget_id: str, timeout_s: float | None = None) -> Frame:
        """The next **unsolicited** ``data`` frame touching ``widget_id``.

        Unsolicited means ``req_id`` is absent — the distinction the clock exists
        to prove, so the fake device checks it rather than trusting the caller.
        """
        deadline = asyncio.get_running_loop().time() + (
            timeout_s if timeout_s is not None else self.timeout_s
        )
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError(f"no unsolicited push for {widget_id!r}")
            frame = await self.recv(timeout_s=remaining)
            if frame.get("type") != "data" or "req_id" in frame:
                continue
            if any(u.get("id") == widget_id for u in frame.get("updates", ())):
                return frame

    def updates_for(self, widget_id: str) -> list[dict[str, Any]]:
        """Every update seen so far naming ``widget_id``, in arrival order."""
        return [
            update
            for frame in self.received
            if frame.get("type") == "data"
            for update in frame.get("updates", ())
            if update.get("id") == widget_id
        ]


async def _run_cli(
    url: str, page: str, widgets: list[str], increments: int, watch_s: float
) -> None:
    async with FakeDevice(url) as device:
        print(f"connected to {url} as {device.session_id}")
        req_id = await device.subscribe(page, widgets)
        frame = await device.recv_data(req_id)
        for update in frame["updates"]:
            if "items" in update:
                print(f"  {update['id']}: {len(update['items'])} blocks")
            else:
                print(f"  {update['id']}: {update}")
        for _ in range(increments):
            await device.event("increment", source="increment_btn")
            print(f"  increment -> {await device.recv_data()}")
        if watch_s > 0:
            print(f"watching pushes for {watch_s}s (Ctrl-C to stop)")
            try:
                async with asyncio.timeout(watch_s):
                    while True:
                        print(f"  push {await device.recv(timeout_s=watch_s)}")
            except (TimeoutError, asyncio.TimeoutError):
                pass
        print("done")


def main() -> None:
    parser = argparse.ArgumentParser(description="Drive a Slate server without hardware.")
    parser.add_argument("--url", default=DEFAULT_URL, help=f"server WS url (default {DEFAULT_URL})")
    parser.add_argument("--page", default="/apps/m0", help="page path to subscribe to")
    parser.add_argument(
        "--widgets", default="count,clock,doc", help="comma-separated widget ids to subscribe"
    )
    parser.add_argument("--increments", type=int, default=1, help="how many increment events")
    parser.add_argument("--watch", type=float, default=3.0, help="seconds to watch pushes")
    args = parser.parse_args()
    asyncio.run(
        _run_cli(
            args.url,
            args.page,
            [w.strip() for w in args.widgets.split(",") if w.strip()],
            args.increments,
            args.watch,
        )
    )


if __name__ == "__main__":
    main()
