"""Unit tests for v0.1's two scalar widgets: the counter and the clock.

Both are pure logic with the clock injected, so nothing here sleeps, reads the
wall clock, or opens a socket.
"""

from __future__ import annotations

from datetime import datetime

import pytest
from server import Counter, M0Server, format_clock


class TestCounter:
    def test_starts_at_zero_by_default(self) -> None:
        assert Counter().value == 0

    @pytest.mark.parametrize("start", [0, 1, 41, 999, -3])
    def test_increments_by_one_from_an_arbitrary_start(self, start: int) -> None:
        counter = Counter(start)
        assert counter.increment() == start + 1
        assert counter.value == start + 1

    def test_increments_accumulate(self) -> None:
        counter = Counter(41)
        for _ in range(4):
            counter.increment()
        assert counter.value == 45


class TestFormatClock:
    def test_formats_as_zero_padded_24_hour(self) -> None:
        assert format_clock(datetime(2026, 9, 5, 19, 4, 33)) == "19:04:33"

    def test_pads_single_digit_fields(self) -> None:
        assert format_clock(datetime(2026, 1, 2, 3, 4, 5)) == "03:04:05"

    def test_midnight_is_not_24(self) -> None:
        assert format_clock(datetime(2026, 1, 1, 0, 0, 0)) == "00:00:00"


class TestWidgetValues:
    def test_count_reports_the_servers_number_as_text(self, m0: M0Server) -> None:
        m0.counter.increment()
        assert m0.widget_update("count") == {"id": "count", "text": "1"}

    def test_clock_reports_the_injected_instant(self, m0: M0Server) -> None:
        assert m0.widget_update("clock") == {"id": "clock", "text": "19:04:33"}

    def test_an_unknown_widget_has_no_value(self, m0: M0Server) -> None:
        assert m0.widget_update("nonesuch") is None
