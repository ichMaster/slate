# Slate test suite

Seeded at v0.1 and **only ever extended**. No later phase introduces its own
harness — the fake device in [`tools/fake_device.py`](../tools/fake_device.py)
drives the wire for every phase that follows, growing by registering frame
handlers rather than by being rewritten.

## Running it

```bash
pytest                    # the product suite (this directory only)
pytest tests/test_wire_contract.py -v
```

`testpaths = ["tests"]` in the root `pyproject.toml` is load-bearing: without it
a bare `pytest` collects recursively from the working directory and sweeps
`codegen/`'s suite into the product run. The two are separate and stay
separately runnable:

```bash
cd codegen && ../.venv/bin/python -m pytest tests    # the tracking suite
```

## Where it runs

**v0.1 runs locally.** That is the documented pre-v1.1 bootstrap exception, not
the steady state. From v1.1 the server suite runs **only on `192.168.1.197`**
via `tools/deploy` — sync → remote pytest → restart on green — so tests always
exercise the exact environment the device talks to
([ARCHITECTURE.md](../specification/ARCHITECTURE.md) §Deployment and test
topology). On-device checks run from Claude Code over the USB-attached Tab5 and
are never part of CI.

## Layers

| File | Layer | Pins |
|---|---|---|
| `test_m0_counter_clock.py` | unit | counter arithmetic, clock formatting |
| `test_markdown_blocks.py` | unit | Markdown → typed blocks, all eight kinds |
| `test_wire_contract.py` | **contract** | message shapes, the closed property set, `doc-view` block kinds, forward compatibility |
| `test_wire_integration.py` | integration | the four ROADMAP §v0.1 flows, over a live server |

Contract tests pin seams. They change only when the protocol deliberately
changes — never to accommodate an implementation that drifted.

## Rules the fixtures enforce

- **No wall clock.** The server's clock is injected (`frozen_clock`,
  `ticking_clock`), so no test sleeps to observe a tick and the clock's value is
  asserted exactly.
- **No fixed port.** `live_server` binds port 0 and reports what the OS gave it,
  so the suite is parallel-safe and leaves nothing listening.
- **No live network, no paid APIs.** Nothing here reaches outside the process.
- **The ticker is opt-in.** `live_server` leaves the clock stopped so tests that
  do not want pushes are never raced by one; `fast_ticking_server` starts it at
  10 ms for the tests that do.
