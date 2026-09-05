# Architecture — Slate

## Overview

Two halves bound by a narrow protocol. The **device** (ESP32-P4, ESP-IDF, LVGL) owns *feel*: rendering XML into widget trees, instant touch/keyboard feedback, the application stack, page caching, offline behaviour, and the local hardware actions that must never wait on a network. The **server** (Python, asyncio) owns *meaning*: what every page contains, all business logic and data, session state, and the decision to push. An open application exists in both places at once — a live LVGL screen retaining scroll, focus, and entered text; a server session holding logic state — bound by a `session_id`; switching away and back rebuilds neither half, which is the whole reason state survives. The founding concept and rationale live in [slate-vision.md](slate-vision.md); the visual system lives in [ui-implementation.md](ui-implementation.md) and the design canvases. This document is the build-facing map.

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  Tab5 (ESP32-P4, ESP-IDF)   │         │  Server (Python, asyncio)    │
│                             │         │                              │
│  ┌───────────────────────┐  │         │  ┌────────────────────────┐  │
│  │ Shell                 │  │  WS     │  │ Session manager        │  │
│  │  - server picker      │◄─┼─────────┼─►│  - one session per     │  │
│  │  - app switcher       │  │  JSON   │  │    open application    │  │
│  │  - history stack      │  │         │  └────────────────────────┘  │
│  └───────────────────────┘  │         │  ┌────────────────────────┐  │
│  ┌───────────────────────┐  │  HTTP   │  │ Page store (XML files) │  │
│  │ XML renderer (LVGL)   │◄─┼─────────┼──│  + index page          │  │
│  └───────────────────────┘  │         │  └────────────────────────┘  │
│  ┌───────────────────────┐  │         │  ┌────────────────────────┐  │
│  │ Page cache (SD card)  │  │         │  │ Application handlers   │  │
│  └───────────────────────┘  │         │  └────────────────────────┘  │
│  ┌───────────────────────┐  │         └──────────────────────────────┘
│  │ Local actions         │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

## Components

- **Renderer (firmware).** LVGL with the XML module (`LV_USE_XML`): `lv_xml` registers `<component>` definitions from `components/` and instantiates pages into widget trees. The v0.1 walking skeleton answers whether it builds and runs on the P4; the fallback (a vendored ~6 KB SAX parser with the vocabulary hand-mapped to `lv_*` calls) preserves every design decision at the cost of XML-defined components.
- **Applicator (firmware).** The receiving end of `data`: an id → widget map built at render time and a switch over the closed eight-property set. Updates naming an unknown `id` are dropped with a debug log — never a crash.
- **Page cache (firmware).** SD-backed, keyed by base path, storing body + `ETag`. Revalidates with a conditional GET each time a page becomes active; offline renders the cache as-is. Assets (PNG/JPEG, pre-scaled by the server to the connect-time `screen`) ride the same machinery.
- **Shell (firmware).** The only compiled-in screens: server picker, application switcher (grouped by world), status bar, error banner, navigation chrome, keyboard handling (the Tab5 Macintosh port's I2C driver, `0x6D`, matrix-event), and the local actions (brightness, volume, sleep, back, switch, close). Built from the component library it inherits — nothing ad-hoc.
- **Component library (`components/`).** The design system as data: `<component>` definitions with declared props, the three states (empty/loading/ready) built into the base once, plus the **action registry** file and the **manifest**. One contract, three consumers — firmware, server, validator — in one repo so it cannot drift. The machinery lands early (v1.3); each application phase formalises the components it forces.
- **Token layer (firmware).** Colour tokens with light and dark tables, five type roles across exactly two faces (UI + `mono`, Latin + Cyrillic + symbols, tabular figures for `stat-value`), spacing tokens, and the per-device role → size map. Theme flip swaps a pointer and invalidates the display; no widget is rebuilt, no server is told. Values and per-component geometry: [ui-implementation.md](ui-implementation.md).
- **Server.** Asyncio process: HTTP for pages/assets (content-hash `ETag`), WS for the live channel, a lazy session registry, and the handler API (`async` handlers, `session.update(...)`, push at will). Serves `apps/` — the page store — and hosts each application's handler. Reference server, companion daemon, and every example handler are Python.
- **Validator (`validator/`, v5.1).** The host build of LVGL sharing the firmware's renderer layer — same `lv_xml`, same components, same applicator. `slate-validate page.xml` checks a page against the manifest and registry, renders a PNG at target resolution, and exits non-zero with errors both a human and an agent can read. Closes the authoring loop; runs in CI over every page in `apps/`. Its visual checks — no raw pixels, the font-role whitelist, the raw-hex warning, golden PNGs against the boards — come from [ui-implementation.md §8](ui-implementation.md).
- **Fake device (`tools/`, from v0.1).** A host-side script speaking the device's wire, so every server behaviour — sessions, push, reconnect, notices — is testable in pytest without hardware. Seeded in v0.1 and only ever extended; no later phase introduces its own harness.

## Page model

- **Structure is static.** XML fetched once per base path, cached, revalidated on activation. It defines the widget tree, layout, and which elements are dynamic.
- **Content is dynamic.** Every changeable element carries a page-unique `id`; the server sends targeted updates. Re-sending a page to change a value is forbidden — it destroys scroll, focus, and animation continuity. Replacement is an explicit `navigate`.
- **Parameterised pages.** `?query` selects content, never structure: cache by base path, full path in `subscribe`/`navigate` and the history stack. One cached structure, many history entries.
- **Layout.** Two containers (`column`, `row`), spacing tokens, `align`, `grow` — no coordinates anywhere in a page. Components own internal padding; pages only arrange. Portability beyond Tab5 is deferred until second hardware exists; the token indirection is the prepared mechanism.
- **Widget states.** Empty → loading → ready (error where it can fail), implemented once in the component base and driven by the firmware: empty until a `subscribe` names the `id`, loading while outstanding, ready on first `data`.

Full component vocabulary and per-component contracts: [slate-vision.md §3](slate-vision.md). Per-component geometry, states rendering, and board references: [ui-implementation.md §3](ui-implementation.md).

## Protocol

Transport: WS for the live channel (JSON, one object per frame), HTTP GET for pages and assets. Asynchronous both ways; no ordering assumptions; requests carry `req_id`, everything carries `session_id`.

- **Connect.** `GET /ws?proto=1&screen=1280x720` — one integer protocol version plus the device profile (asset pre-scaling). Mismatch → server closes with `proto_mismatch` + minimum version; the shell renders a plain mismatch screen. Unknown JSON keys **and unknown message types are always ignored**: additive changes never bump the version.
- **Six message types.** `subscribe` (device→server: page active / widgets need data), `data` (server→device: targeted `updates`; `req_id` omitted on unsolicited push), `event` (device→server, fire-and-forget; `values` carries every input field on the page — submit the form, don't stream keystrokes), `navigate` (both ways; `push`/`replace`/`back`/`root`), `error` (server→device, rendered by the shell), `notice` (server→device: a badge from a backgrounded session — never wakes it, no content travels; `info` fades, `alert` holds until seen).
- **Sessions.** The device mints `session_id`; the server creates sessions lazily on first sight — first use *is* creation, no handshake. Reconnect re-subscribes the active application only; a server restart is the same path (unknown id → fresh session; a handler that cannot rebuild state pushes a `navigate`). There is **no `session_expired` message**. Only the active application receives pushed `data`; backgrounded sessions stay alive but unfed until return.
- **Event queue.** Bounded outbound queue; on a dropped link events wait, past the limit the oldest are dropped and the user is told via the status bar. Events must never fail silently.
- **Streaming.** `log-view` and `chat-view` stream by tail re-send — the server re-sends the growing tail with set semantics. There is no append operation; the property set stays closed.
- **Audio (v6.3, direction pinned).** Binary PCM16 frames beside the JSON on the same WS, session- and stream-tagged, start/stop control in JSON; RoboFace's wire is the reference. v1.2's frame dispatcher reserves binary frames so this is never precluded.

- **The v0.1 subset.** The walking skeleton speaks a strict *subset* of the above, never a variant: `subscribe`, `data` and `event` only, over a plain `GET /ws` with **no `proto`/`screen` params**. There is no session registry (one implicit session), no `ETag` on the page, and no reconnection. Unknown message types and keys are already ignored, because forward compatibility is cheaper to build than to retrofit. The full connect URL and session binding arrive at v1.2, cache honesty at v1.1.

Message schemas with examples: [slate-vision.md §4](slate-vision.md).

## The shell

Server picker (boot screen — must work before any network), index page per world (an ordinary page with no special powers), the switcher (grouped by server; each world's index always present; switching instantaneous because nothing is rebuilt), history navigation (+ keyboard address entry), and the chrome: a 40 px status bar (per-server connection dots, battery, clock, notice badges, queue warning) and the shell-owned error banner — applications never draw error UI. Several worlds are open simultaneously: one WS per server with open applications; a `session_id` lives inside its own connection, so cross-server uniqueness is a non-question.

Before the shell exists (pre-v3.1) the device is a single-application terminal: server address and start page in firmware config, and from v2.2 the server's index is the natural start page — one session at a time, no picker, no switcher, no retained state across leaving an application. That is precisely what the shell adds.

## Security and trust

Trusted network only, as a decision: LAN or Tailscale, no protocol auth in v1, secrets server-side (`.env`-style, never in pages or firmware beyond WiFi credentials + server address). The named-but-unbuilt hardening is an optional per-server bearer token in the picker (HTTP header + WS connect param — additive). The action registry is the enforcement point: pages reference declared actions only; a handler's own privileges (the terminal runs commands!) are bounded by trust in one's own servers, not by the platform. The device never touches the internet — servers proxy everything. Untrusted page servers remain a non-goal.

## Error handling and resilience

- **Version mismatch** → plain shell screen, never a hang. **Unknown `id` in `data`** → dropped, debug-logged, never a crash. **Unknown message types/keys** → ignored (forward compatibility).
- **Offline**: cached pages render as-is; events queue with a visible warning; reconnect flushes in order and re-subscribes the active session.
- **Server restart**: indistinguishable from idle expiry; lazy re-creation + re-subscribe; handlers that cannot rebuild push a `navigate` to a sane page.
- **Widget error state** renders `—` in `error` colour; the shell's banner carries `code` + `message` for session-level errors.

## Contracts

The stable seams. Changing one must change its contract test (§Testing and CI).

- **Wire messages:** the six JSON schemas (`subscribe`/`data`/`event`/`navigate`/`error`/`notice`) + the connect URL (`proto`, `screen`).
- **Dynamic property set:** exactly `text`, `value`, `visible`, `enabled`, `color`, `progress`, `items`, `image`. Anything else is a page replacement.
- **Component contracts:** each component's declared static props, dynamic subset, emitted actions, and additive event keys (`row`, `link`) — pinned by the manifest.
- **Manifest:** machine-readable components/props/dynamic-properties/actions; the validator's and the agent's ground truth; grows with every component, never drifts from `components/`.
- **Action registry:** declared names, each marked `local` | `server`; pages may reference, never invent.
- **Token/role names:** the colour tokens, five type roles, three spacing tokens; the validator whitelists them; raw hex is warn-flagged, raw pixels are an error.
- **Session binding:** device-minted `session_id`, lazy server creation, active-only re-subscribe.
- **Cache honesty:** base-path caching + `If-None-Match` revalidation, for pages and assets alike.
- **`doc-view` block kinds:** `h1 h2 h3 p bullet code quote divider` (+ `link` key); `chat-view` items `{role, text, pending?}`.

## Data model

Server-side shapes (per world; the reference server keeps them in process or simple local storage — persistence is each handler's own business):

- `Session{ id, app, page_path, widgets[], connected }` — created lazily; holds handler state; dies on close/eviction/idle.
- `Page` — an XML file in `apps/<app>/`; served with a content-hash `ETag`; parameterised by query string.
- `Update{ id, <property>: value, ... }` — one element of a `data` frame.
- `ActionRegistryEntry{ name, scope: local|server }` — a row of the registry file in `components/`.
- `ManifestEntry{ component, props{}, dynamic[], actions[] }` — one row of the manifest.

Device-side: the page cache entry `{ base_path, etag, body }` on SD; the per-session screen (`lv_screen`) with its id → widget map; saved servers `{ name, address, auto }` in NVS; the bounded event queue.

## Stack and repository layout

```
slate/
  specification/   MISSION.md · ARCHITECTURE.md · ROADMAP.md (the working set)
                   slate-vision.md (+ .uk translation) — the founding concept
                   ui-design-brief.md · ui-m0-brief.md · ui-implementation.md
                   + the design canvas exports (visual source of truth)
  components/      component definitions + action registry + manifest (the contract)
  firmware/        ESP-IDF project, Tab5 first (from v1.1; v0.1's code is quarry)
  m0/              v0.1's walking skeleton — quarry, not foundation. Its firmware
                   and server are thrown away; firmware/ and server/ start at v1.1
  server/          Python asyncio reference server + application handlers + companion daemon
  validator/       host LVGL build + slate-validate CLI (v5.1)
  apps/            the page store the reference server serves
  tools/           fake device + measurement scripts (from v0.1) + the deploy
                   pipeline to 192.168.1.197 (from v1.1)
  tests/           pytest: unit, contract, integration over the fake device
```

Firmware: ESP-IDF + Tab5 BSP + LVGL (versions pinned from v1.1). Server: Python 3.12+, asyncio; the aiohttp-vs-FastAPI choice is made at v1.1 and recorded here. Fonts: one UI face + JetBrains-Mono-class `mono`, both Latin + Cyrillic, compiled at the five roles only. Create each directory as its phase begins; the component contract is born at v1.3 and every application phase feeds it.

## Deployment and test topology

Three machines, three roles — fixed for the whole project:

- **The deployment server is `192.168.1.197`** — the LAN host that runs the reference server (and later the companion daemon and every port's handler). It is the address the Tab5 talks to. Reachability verified (ping, SSH up); access is key-based SSH — install the workstation's key once (`ssh-copy-id`) before the pipeline exists.
- **Deploy on every server change.** A deployment pipeline (under `tools/`, created at v1.1 with the kept server tree) ships `server/`, `apps/`, and `components/` to `192.168.1.197` and is **executed every time the server's code changes** — deploy is part of the dev loop, not a release event. Order: sync → run the server test suite remotely → restart the service only on green.
- **Server tests run only on the deployment server.** The server-side pytest suite (unit, contract, fake-device integration) executes **on `192.168.1.197`**, never on the workstation — tests always exercise the exact environment the device talks to. A red suite aborts the restart and leaves the previous version running.
- **The Tab5 is on USB at the workstation.** Permanently connected to the development machine and available to Claude Code for updates and testing — flashing and monitoring (`idf.py flash` / `idf.py monitor`) during firmware work, and on-device checks during unit tests and validations. The device's network peer is always `192.168.1.197`; USB is the control and observation channel.

## Testing and CI

Tests ship with every phase and encode its DoD; `main` stays green. Where tests run is fixed by §Deployment and test topology: the server suite runs **only on `192.168.1.197`** (as the deploy gate), on-device checks run **from Claude Code over the USB-attached Tab5**, and repo-level CI (lint, validator, golden PNGs) stays hostless.

- **Unit tests (server):** handler logic per application (psutil, command runner, Markdown → blocks, wiki proxy, note store, hooks daemon — external effects mocked), ETag generation, session registry, notice routing.
- **Contract tests:** the six message schemas; the closed dynamic-property set; manifest ↔ `components/` consistency; action-registry shape; `doc-view` block kinds; the connect-URL params. Changing a seam changes its test.
- **Integration tests (fake device):** full wire flows against a running server — subscribe → data, unsolicited push, event → data round-trip, navigate both ways, reconnect + lazy session re-creation, version-mismatch close, active-only push with two sessions, notice for a backgrounded session, queue flush ordering.
- **Validator tests (v5.1):** seeded errors (unknown component, bad action, duplicate id, raw hex, raw pixels) each fail readably; golden PNGs render every page in `apps/` in both themes at 1280×720 and diff against the boards — a complete visual regression suite for one CI job.
- **On-device tests (USB).** Firmware checks that need real hardware — flash-and-verify after firmware changes, parse/heap measurements, scroll feel, the DoD demonstrations — run from Claude Code against the USB-attached Tab5 (`idf.py flash`/`monitor`), with the device pointed at `192.168.1.197`.
- **No paid APIs in any suite.** Wikipedia, Telegram (Telethon), the Agent SDK, ASR/TTS are mocked; the model-driven authoring loop is exercised with a canned description.
- **CI:** lint (ruff) on every push; from v5.1 also `slate-validate` over `apps/` + golden-PNG diffs. The server pytest suite is not a repo-CI job — it runs on `192.168.1.197` as the deploy pipeline's gate.
