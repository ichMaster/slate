# Slate

A mainframe terminal model rendered with LVGL. An ESP32-P4 device (M5Stack Tab5)
is a dumb renderer; a server holds all logic, data, and state. Between them:
WebSocket JSON for the live channel, HTTP GET for page XML and assets.

The unit of software is a **page** — a declarative XML file. A page plus its
server-side handler is an **application**. Pages are data, never instructions:
no executable code reaches the device beyond the firmware itself.

**Current release: `v0.1.0`** — the walking skeleton, demonstrated on hardware.

> Power on → the page arrives from the server → the clock ticks → the button
> increments a count that lives on the server → the document renders and scrolls
> — and a power cycle does not reset the counter, because the count never lived
> on the device.

That last clause is the whole milestone. Everything else v0.1 built exists to
make it demonstrable.

## Topology

Three machines, fixed for the project
([ARCHITECTURE.md](specification/ARCHITECTURE.md) §Deployment and test topology):

| Role | Host | What runs there |
|---|---|---|
| **Server** | `ich@ich-picobox` · `192.168.1.197:8010` | the reference server |
| **Device** | M5Stack Tab5 (ESP32-P4) | the firmware; joins WiFi, dials the server |
| **Workstation** | the Mac | the repo, ESP-IDF, the Tab5 on USB |

The workstation **cannot** host the server. Its endpoint filtering accepts an
inbound LAN connection and destroys the socket before the application's first
read — the handshake completes, so the port looks open and only the first
`read()` fails. Port 8010 rather than 8000 because `roboface_server` owns 8000
on that host.

## Commands

```bash
./tools/versions          # which of repo / server / device is behind
./tools/deploy            # sync → remote pytest → restart on green
./tools/deploy --check    # is the server up, and is it this build
./tools/m0-auto.sh        # everything machine-checkable, unattended
./tools/m0-hands-on.sh    # only what a person must confirm by eye and finger
```

**Run `./tools/versions` first.** Three places can disagree and nothing else
tells them apart:

```
РЕПОЗИТОРІЙ   реліз 0.1.0 · збірка 5e3d475 · відбиток 624a4f80eecc
СЕРВЕР        реліз 0.1.0 · відбиток 624a4f80eecc   ✓ збігається
ПРИСТРІЙ      реліз 0.1.0 · збірка 5e3d475          ✓ збігається
```

**Deploy after every server change**, before asking anyone to test — deploy is
part of the dev loop, not a release event.

### Firmware

From `m0/firmware/`, after `. ~/esp/esp-idf/export.sh`:

```bash
idf.py build
idf.py -p /dev/cu.usbmodem1101 flash
idf.py -p /dev/cu.usbmodem1101 monitor --no-reset
```

`--no-reset` matters: attaching the monitor reboots the device, which looks like
a crash and destroys whatever you were about to measure.

WiFi credentials and the server address live in
`m0/firmware/sdkconfig.defaults.local`, which is gitignored — this repository is
public. Copy `sdkconfig.defaults.local.example` and fill it in.

### Tests

```bash
pytest                                              # product suite (94)
cd codegen && ../.venv/bin/python -m pytest tests   # tracking suite (546)
```

## Versioning

Two halves, and only one is manual.

- **`VERSION`** holds the release (`0.1.0`) and moves only at a release.
- **Build identity is derived** — git short SHA, a `-dirty` suffix when the tree
  has uncommitted changes, and a UTC timestamp. Never hand-edited.

Deliberately not a hand-incremented fourth component. "Did the update land" is a
question of *identity*, not order, and a counter lies about identity the moment
someone forgets to bump it — which is exactly when it matters. The firmware logs
its identity every 15 s, and the server reports `version` plus a content
fingerprint at `/health`.

Roadmap phase `vA.B` → release `A.B.0`, tagged `vA.B.0`. Never bump without
explicit confirmation.

## Layout

```
specification/   MISSION · ARCHITECTURE · ROADMAP, the vision spec, UI briefs
m0/              v0.1's walking skeleton — quarry, thrown away at v1.1
  firmware/      ESP-IDF project for the Tab5
  server/        single-file asyncio server
  apps/          the M0 page
tools/           fake device, deploy, version check, test harnesses
tests/           pytest: unit, contract, fake-device integration
codegen/         the SDLC tracking machinery (its own suite, port 8420)
```

`firmware/`, `server/`, `components/`, `apps/` and `validator/` are the kept
trees and begin at v1.1 onward. `m0/` is not seeded into them.

## Where to read next

- [specification/MISSION.md](specification/MISSION.md) — what this is for.
- [specification/ARCHITECTURE.md](specification/ARCHITECTURE.md) — the
  build-facing map: components, protocol, contracts, topology.
- [specification/ROADMAP.md](specification/ROADMAP.md) — phases v0 … v6, each
  with Goal, Tasks, DoD, Tests.
- [specification/slate-vision.md](specification/slate-vision.md) — the founding
  concept and the reasoning behind every decision above.
- [v0.1 PoC ledger](specification/roadmap/implementation/v0.1-poc-ledger.md) —
  every verdict and measurement v0.1 produced, including the `lv_xml` go/no-go
  and the hardware facts v1.1 should inherit rather than rediscover.

## Licence

See [LICENSE](LICENSE).
