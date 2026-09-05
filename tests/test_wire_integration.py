"""Integration tests: the fake device against a live server.

These are the four flows ROADMAP §v0.1 names under **Tests** — subscribe →
initial data, `event` `increment` → pushed value, the unsolicited clock push,
and the `items` document update — plus the HTTP fetch that precedes all of them.

Nothing here sleeps to observe a tick and nothing binds a fixed port. The clock
is injected and the server binds port 0, so the suite is deterministic and
parallel-safe.
"""

from __future__ import annotations

import asyncio
import urllib.error
import urllib.request

import pytest
from fake_device import FakeDevice, mint_session_id
from server import M0Server

pytestmark = pytest.mark.asyncio

PAGE = "/apps/m0"
WIDGETS = ["count", "clock", "doc"]


def _http_get(url: str) -> tuple[int, bytes, str | None]:
    """Blocking GET, always called through ``asyncio.to_thread``.

    Calling it directly on the loop deadlocks against the in-process server —
    which is exactly the bug this helper exists to make impossible.
    """
    try:
        response = urllib.request.urlopen(url, timeout=5)
        return response.status, response.read(), response.headers.get("Content-Type")
    except urllib.error.HTTPError as error:
        return error.code, b"", None


class TestPageFetch:
    async def test_the_page_is_served_over_plain_http(
        self, live_server: tuple[M0Server, int]
    ) -> None:
        _, port = live_server
        status, body, ctype = await asyncio.to_thread(
            _http_get, f"http://127.0.0.1:{port}/apps/m0.xml"
        )
        assert status == 200
        assert b"<component>" in body
        assert ctype is not None and "xml" in ctype

    async def test_the_page_names_the_three_dynamic_ids(
        self, live_server: tuple[M0Server, int]
    ) -> None:
        _, port = live_server
        _, body, _ = await asyncio.to_thread(_http_get, f"http://127.0.0.1:{port}/apps/m0.xml")
        page = body.decode("utf-8")
        for widget_id in WIDGETS:
            assert f'name="{widget_id}"' in page

    async def test_an_unknown_path_is_a_404_not_a_hang(
        self, live_server: tuple[M0Server, int]
    ) -> None:
        _, port = live_server
        status, _, _ = await asyncio.to_thread(_http_get, f"http://127.0.0.1:{port}/nope")
        assert status == 404


class TestSubscribeFlow:
    """subscribe → initial data."""

    async def test_subscribe_returns_the_current_value_of_every_widget(
        self, device: FakeDevice
    ) -> None:
        req_id = await device.subscribe(PAGE, ["count", "clock"])
        frame = await device.recv_data(req_id)
        assert [u["id"] for u in frame["updates"]] == ["count", "clock"]
        assert frame["updates"][0]["text"] == "0"
        assert frame["updates"][1]["text"] == "19:04:33"

    async def test_the_response_echoes_the_req_id(self, device: FakeDevice) -> None:
        req_id = await device.subscribe(PAGE, ["count"])
        frame = await device.recv_data(req_id)
        assert frame["req_id"] == req_id

    async def test_the_response_carries_the_devices_session_id(
        self, device: FakeDevice
    ) -> None:
        req_id = await device.subscribe(PAGE, ["count"])
        frame = await device.recv_data(req_id)
        assert frame["session_id"] == device.session_id


class TestIncrementFlow:
    """event increment → pushed value."""

    async def test_increment_returns_the_new_count(self, device: FakeDevice) -> None:
        await device.event("increment", source="increment_btn")
        frame = await device.recv_data()
        assert frame["updates"] == [{"id": "count", "text": "1"}]

    async def test_repeated_increments_accumulate_on_the_server(
        self, device: FakeDevice
    ) -> None:
        for expected in ("1", "2", "3"):
            await device.event("increment", source="increment_btn")
            frame = await device.recv_data()
            assert frame["updates"][0]["text"] == expected

    async def test_the_count_survives_a_reconnect_because_it_never_lived_on_the_device(
        self, live_server: tuple[M0Server, int]
    ) -> None:
        # The milestone's whole philosophical point, in one test: a *new*
        # connection with a *new* session id still sees the old count.
        _, port = live_server
        url = f"ws://127.0.0.1:{port}/ws"
        async with FakeDevice(url) as first:
            for _ in range(4):
                await first.event("increment")
                await first.recv_data()
        async with FakeDevice(url) as second:
            assert second.session_id != first.session_id
            req_id = await second.subscribe(PAGE, ["count"])
            frame = await second.recv_data(req_id)
            assert frame["updates"][0]["text"] == "4"

    async def test_an_unknown_action_produces_no_frame_and_no_disconnect(
        self, device: FakeDevice
    ) -> None:
        await device.event("detonate")
        with pytest.raises(TimeoutError):
            await device.recv_data(timeout_s=0.2)
        # Still alive: a normal event still round-trips.
        await device.event("increment")
        assert (await device.recv_data())["updates"][0]["text"] == "1"


class TestUnsolicitedPush:
    """The clock push — driven by the fixture's fast ticker, never by a sleep."""

    async def test_the_clock_arrives_unprompted(
        self, fast_ticking_server: tuple[M0Server, int]
    ) -> None:
        _, port = fast_ticking_server
        async with FakeDevice(f"ws://127.0.0.1:{port}/ws") as fake:
            frame = await fake.recv_push("clock")
            assert frame["updates"][0]["id"] == "clock"

    async def test_an_unsolicited_push_omits_req_id(
        self, fast_ticking_server: tuple[M0Server, int]
    ) -> None:
        _, port = fast_ticking_server
        async with FakeDevice(f"ws://127.0.0.1:{port}/ws") as fake:
            frame = await fake.recv_push("clock")
            assert "req_id" not in frame

    async def test_the_clock_actually_advances_between_pushes(
        self, fast_ticking_server: tuple[M0Server, int]
    ) -> None:
        _, port = fast_ticking_server
        async with FakeDevice(f"ws://127.0.0.1:{port}/ws") as fake:
            first = await fake.recv_push("clock")
            second = await fake.recv_push("clock")
            assert first["updates"][0]["text"] != second["updates"][0]["text"]

    async def test_a_disconnected_device_does_not_kill_the_ticker(
        self, fast_ticking_server: tuple[M0Server, int]
    ) -> None:
        m0, port = fast_ticking_server
        url = f"ws://127.0.0.1:{port}/ws"
        async with FakeDevice(url) as first:
            await first.recv_push("clock")
        # First device gone; a second still receives pushes.
        async with FakeDevice(url) as second:
            assert await second.recv_push("clock") is not None
        assert m0.counter.value == 0


class TestDocumentUpdate:
    """The items document update — the structured half of the wire."""

    async def test_the_whole_document_arrives_in_one_frame(
        self, device: FakeDevice
    ) -> None:
        req_id = await device.subscribe(PAGE, ["doc"])
        frame = await device.recv_data(req_id)
        assert len(frame["updates"]) == 1
        assert len(frame["updates"][0]["items"]) >= 50

    async def test_the_blocks_are_typed_and_carry_no_markdown(
        self, device: FakeDevice
    ) -> None:
        req_id = await device.subscribe(PAGE, ["doc"])
        items = (await device.recv_data(req_id))["updates"][0]["items"]
        assert all(set(block) == {"kind", "text"} for block in items)
        assert not any(block["text"].startswith("#") for block in items)

    async def test_the_cyrillic_line_crosses_the_wire_intact(
        self, device: FakeDevice
    ) -> None:
        req_id = await device.subscribe(PAGE, ["doc"])
        items = (await device.recv_data(req_id))["updates"][0]["items"]
        assert any("українською" in block["text"] for block in items)

    async def test_both_update_shapes_ride_one_subscribe(self, device: FakeDevice) -> None:
        req_id = await device.subscribe(PAGE, WIDGETS)
        frame = await device.recv_data(req_id)
        shapes = [set(u) - {"id"} for u in frame["updates"]]
        assert shapes == [{"text"}, {"text"}, {"items"}]


class TestFakeDeviceItself:
    """The harness is inherited by every later phase, so it gets its own tests."""

    async def test_it_mints_a_distinct_session_id_per_device(self) -> None:
        assert mint_session_id() != mint_session_id()

    async def test_session_ids_look_like_the_specified_shape(self) -> None:
        session_id = mint_session_id()
        assert session_id.startswith("s-")
        assert len(session_id) > 3

    async def test_req_ids_increase_so_responses_can_be_matched(
        self, device: FakeDevice
    ) -> None:
        first = await device.subscribe(PAGE, ["count"])
        await device.recv_data(first)
        second = await device.subscribe(PAGE, ["count"])
        assert second > first

    async def test_it_records_every_frame_it_saw(self, device: FakeDevice) -> None:
        req_id = await device.subscribe(PAGE, ["count"])
        await device.recv_data(req_id)
        await device.event("increment")
        await device.recv_data()
        assert len(device.received) == 2
        assert [u["text"] for u in device.updates_for("count")] == ["0", "1"]

    async def test_handlers_registered_with_on_see_their_type(
        self, device: FakeDevice
    ) -> None:
        # The extension point v1.2/v2.2/v3.1 grow through.
        seen: list[dict[str, object]] = []
        device.on("data", seen.append)
        req_id = await device.subscribe(PAGE, ["count"])
        await device.recv_data(req_id)
        assert len(seen) == 1

    async def test_using_it_unconnected_is_a_clear_error(self) -> None:
        with pytest.raises(RuntimeError, match="not connected"):
            _ = FakeDevice().connection
