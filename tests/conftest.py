"""Shared fixtures for the Slate product suite.

v0.1's server is quarry under ``m0/`` rather than a package in ``server/`` (see
ARCHITECTURE.md §Stack), so the suite puts it and ``tools/`` on the path
explicitly. When the kept tree arrives at v1.1 this shim goes away and the
imports become ordinary.

Two rules this file enforces for every test that inherits it:

* **no wall clock** — the server's clock is injected, so nothing sleeps to
  observe a tick;
* **no fixed port** — the server binds port 0 and the fixture reports what the
  OS gave it, so suites run in parallel and leave nothing listening.
"""

from __future__ import annotations

import sys
from collections.abc import AsyncIterator, Iterator
from datetime import datetime, timedelta
from pathlib import Path

import pytest
import pytest_asyncio

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "m0" / "server"))
sys.path.insert(0, str(REPO_ROOT / "tools"))

from fake_device import FakeDevice  # noqa: E402
from server import M0Server  # noqa: E402
from websockets.asyncio.server import Server, serve  # noqa: E402


@pytest.fixture
def frozen_clock() -> datetime:
    """A fixed instant, so no test ever reads the wall clock."""
    return datetime(2026, 9, 5, 19, 4, 33)


@pytest.fixture
def m0(frozen_clock: datetime) -> M0Server:
    """A server whose clock is injected and whose counter starts at zero."""
    return M0Server(clock=lambda: frozen_clock)


@pytest.fixture
def ticking_clock(frozen_clock: datetime) -> Iterator[M0Server]:
    """A server whose clock advances one second per read.

    Lets a test watch the clock actually change across pushes without waiting a
    real second for each one.
    """
    ticks = {"n": 0}

    def clock() -> datetime:
        ticks["n"] += 1
        return frozen_clock + timedelta(seconds=ticks["n"] - 1)

    yield M0Server(clock=clock, clock_interval_s=0.01)


@pytest_asyncio.fixture
async def live_server(m0: M0Server) -> AsyncIterator[tuple[M0Server, int]]:
    """The M0 server running in-process on an ephemeral port.

    Yields the server and its port. The clock ticker is left stopped: a test that
    wants pushes starts it, so tests that don't are never raced by it.
    """
    async with serve(m0.ws_handler, "127.0.0.1", 0, process_request=m0.process_request) as server:
        yield m0, _port_of(server)
        await m0.stop_clock()


@pytest_asyncio.fixture
async def fast_ticking_server(
    ticking_clock: M0Server,
) -> AsyncIterator[tuple[M0Server, int]]:
    """A live server whose clock ticker is running at 10 ms, for push tests."""
    m0 = ticking_clock
    async with serve(m0.ws_handler, "127.0.0.1", 0, process_request=m0.process_request) as server:
        m0.start_clock()
        yield m0, _port_of(server)
        await m0.stop_clock()


@pytest_asyncio.fixture
async def device(live_server: tuple[M0Server, int]) -> AsyncIterator[FakeDevice]:
    """A fake device already connected to the live server."""
    _, port = live_server
    async with FakeDevice(f"ws://127.0.0.1:{port}/ws") as fake:
        yield fake


def _port_of(server: Server) -> int:
    """The port the OS actually assigned to a ``port=0`` bind."""
    sockets = server.sockets
    assert sockets, "server bound no sockets"
    port: int = sockets[0].getsockname()[1]
    return port
