"""Contract tests for v0.1's trimmed wire.

These pin a seam. ARCHITECTURE.md §Contracts lists the wire messages as a stable
seam, which means this file changes only when the protocol deliberately changes —
never to accommodate an implementation that drifted.

v0.1 speaks a strict *subset*: `subscribe`, `data`, `event`. The other three
types, the connect-URL params, and session plurality arrive in later phases and
must not appear here.
"""

from __future__ import annotations

from server import M0Server, make_data, make_update

#: The full closed dynamic-property set (ARCHITECTURE.md §Contracts).
DYNAMIC_PROPERTIES = {
    "text",
    "value",
    "visible",
    "enabled",
    "color",
    "progress",
    "items",
    "image",
}

#: The subset v0.1 is allowed to exercise. Growing this is a phase decision.
V0_1_PROPERTIES = {"text", "items"}


class TestSubscribeShape:
    def test_subscribe_is_answered_with_a_data_frame(self, m0: M0Server) -> None:
        reply = m0.handle(
            {
                "type": "subscribe",
                "session_id": "s-7f3a",
                "req_id": 12,
                "page": "/apps/m0",
                "widgets": ["count", "clock"],
            }
        )
        assert reply is not None
        assert reply["type"] == "data"
        assert reply["session_id"] == "s-7f3a"

    def test_req_id_is_echoed_so_the_device_can_match_the_response(self, m0: M0Server) -> None:
        reply = m0.handle(
            {
                "type": "subscribe",
                "session_id": "s-7f3a",
                "req_id": 12,
                "widgets": ["count"],
            }
        )
        assert reply is not None
        assert reply["req_id"] == 12

    def test_every_named_widget_gets_exactly_one_update(self, m0: M0Server) -> None:
        reply = m0.handle(
            {
                "type": "subscribe",
                "session_id": "s-7f3a",
                "req_id": 1,
                "widgets": ["count", "clock"],
            }
        )
        assert reply is not None
        assert [u["id"] for u in reply["updates"]] == ["count", "clock"]

    def test_an_unknown_widget_is_skipped_not_errored(self, m0: M0Server) -> None:
        reply = m0.handle(
            {
                "type": "subscribe",
                "session_id": "s-7f3a",
                "req_id": 1,
                "widgets": ["count", "nonesuch"],
            }
        )
        assert reply is not None
        assert [u["id"] for u in reply["updates"]] == ["count"]


class TestDataShape:
    def test_a_data_frame_carries_type_session_and_updates(self) -> None:
        frame = make_data("s-7f3a", [make_update("count", text="42")], req_id=3)
        assert frame == {
            "type": "data",
            "session_id": "s-7f3a",
            "updates": [{"id": "count", "text": "42"}],
            "req_id": 3,
        }

    def test_unsolicited_push_omits_req_id_entirely(self) -> None:
        frame = make_data("s-7f3a", [make_update("clock", text="19:04:33")])
        assert "req_id" not in frame

    def test_every_update_names_an_id(self, m0: M0Server) -> None:
        reply = m0.handle(
            {"type": "subscribe", "session_id": "s", "req_id": 1, "widgets": ["count", "clock"]}
        )
        assert reply is not None
        assert all("id" in update for update in reply["updates"])

    def test_v0_1_uses_only_text_and_items_from_the_closed_property_set(
        self, m0: M0Server
    ) -> None:
        reply = m0.handle(
            {"type": "subscribe", "session_id": "s", "req_id": 1, "widgets": ["count", "clock"]}
        )
        assert reply is not None
        used = {key for update in reply["updates"] for key in update if key != "id"}
        assert used <= V0_1_PROPERTIES
        assert V0_1_PROPERTIES <= DYNAMIC_PROPERTIES


class TestEventShape:
    def test_increment_bumps_the_server_side_count_and_pushes_it_back(
        self, m0: M0Server
    ) -> None:
        reply = m0.handle(
            {
                "type": "event",
                "session_id": "s-7f3a",
                "action": "increment",
                "source": "increment_btn",
                "values": {},
            }
        )
        assert reply is not None
        assert reply["updates"] == [{"id": "count", "text": "1"}]

    def test_the_count_lives_on_the_server_not_in_the_message(self, m0: M0Server) -> None:
        for expected in ("1", "2", "3"):
            reply = m0.handle(
                {"type": "event", "session_id": "s", "action": "increment", "values": {}}
            )
            assert reply is not None
            assert reply["updates"][0]["text"] == expected

    def test_an_event_response_is_unsolicited_and_carries_no_req_id(self, m0: M0Server) -> None:
        reply = m0.handle(
            {"type": "event", "session_id": "s", "action": "increment", "values": {}}
        )
        assert reply is not None
        assert "req_id" not in reply

    def test_an_unknown_action_is_ignored(self, m0: M0Server) -> None:
        assert m0.handle({"type": "event", "session_id": "s", "action": "detonate"}) is None
        assert m0.counter.value == 0


class TestForwardCompatibility:
    """Unknown types and keys are ignored, never errors (ARCHITECTURE.md §Protocol).

    This is what lets a later protocol version add messages without bumping the
    integer version, so it is a contract in its own right.
    """

    def test_an_unknown_message_type_is_ignored(self, m0: M0Server) -> None:
        assert m0.handle({"type": "navigate", "session_id": "s", "mode": "back"}) is None

    def test_a_message_with_no_type_is_ignored(self, m0: M0Server) -> None:
        assert m0.handle({"session_id": "s"}) is None

    def test_an_unknown_key_on_a_known_type_is_ignored(self, m0: M0Server) -> None:
        reply = m0.handle(
            {
                "type": "subscribe",
                "session_id": "s-7f3a",
                "req_id": 7,
                "widgets": ["count"],
                "screen": "1280x720",
                "future_field": {"nested": True},
            }
        )
        assert reply is not None
        assert reply["updates"] == [{"id": "count", "text": "0"}]

    def test_an_unknown_key_does_not_leak_into_the_response(self, m0: M0Server) -> None:
        reply = m0.handle(
            {
                "type": "event",
                "session_id": "s",
                "action": "increment",
                "values": {},
                "unknown": 1,
            }
        )
        assert reply is not None
        assert set(reply) == {"type", "session_id", "updates"}


class TestSubsetDiscipline:
    """v0.1 speaks a subset of the protocol, never a variant of it."""

    def test_the_later_message_types_are_not_implemented_here(self, m0: M0Server) -> None:
        for kind in ("navigate", "error", "notice"):
            assert m0.handle({"type": kind, "session_id": "s"}) is None
