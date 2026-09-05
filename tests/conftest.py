"""Shared fixtures for the Slate product suite.

v0.1's server is quarry under ``m0/`` rather than a package in ``server/`` (see
ARCHITECTURE.md §Stack), so the suite puts it on the path explicitly. When the
kept tree arrives at v1.1 this shim goes away and the import becomes ordinary.
"""

from __future__ import annotations

import sys
from datetime import datetime
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "m0" / "server"))

from server import M0Server  # noqa: E402


@pytest.fixture
def frozen_clock() -> datetime:
    """A fixed instant, so no test ever reads the wall clock."""
    return datetime(2026, 9, 5, 19, 4, 33)


@pytest.fixture
def m0(frozen_clock: datetime) -> M0Server:
    """A server whose clock is injected and whose counter starts at zero."""
    return M0Server(clock=lambda: frozen_clock)
