# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

Slate is **spec-only**. There is no source code, no build system, and no tests yet — the
repository holds [specification/slate-vision.md](specification/slate-vision.md) (the authority),
two UI design briefs for Claude Design —
[specification/ui-design-brief.md](specification/ui-design-brief.md) (design language, shell,
first applications; concrete token values proposed there) and
[specification/ui-m0-brief.md](specification/ui-m0-brief.md) (the deliberately crude M0
walking-skeleton screen, kept on its own canvas) — a LICENSE, and a Python-flavoured `.gitignore`
(partially apt: the server side **is Python** by decision; the ESP-IDF/C firmware entries will
need adding once real code lands).

The layout is decided: a **monorepo** — `specification/`, `components/` (component definitions +
action registry, the contract shared by all three consumers), `firmware/` (ESP-IDF, Tab5),
`server/` (Python asyncio reference server + Claude Code companion daemon), `validator/`, `apps/`
(page store). Create directories to match as milestones land.

Read the vision spec before writing anything. It is the authority on architecture, protocol, and
build order; this file only summarises the parts that are easy to violate by accident.

**When build, flash, validate, or test commands come into existence, record them here** — that is
what future sessions will look for first.

## What Slate is

A mainframe terminal model rendered with LVGL. An ESP32-P4 device (M5Stack Tab5 first) is a dumb
renderer; a server holds all logic, data, and state. Between them: WebSocket JSON for the live
channel, HTTP GET for page XML and assets.

The unit of software is a **page** — an LVGL declarative XML file. A page plus its server-side
handler is an **application**. Pages are data, never instructions: no executable code reaches the
device beyond the firmware itself.

## Invariants

These are the rules that make the design work. Breaking any of them silently degrades the platform
into something else.

- **Structure is static, content is dynamic.** Page XML is fetched once, cached on SD, and never
  regenerated at runtime. To change a value, send a targeted `data` update naming the element `id`.
  Re-sending a page to change a number destroys scroll position, input focus, and animation
  continuity. A page is replaced only when its *form* differs, and that is an explicit `navigate`.
- **The dynamic property set is closed:** `text`, `value`, `visible`, `enabled`, `color`,
  `progress`, `items`, `image`. Anything else requires a page replacement. Keeping this list short
  is what keeps the renderer simple — grow it only under real pressure.
- **The component vocabulary is deliberately small** (`page-header`, `stat-card`, `text-block`,
  `list-view`, `button-row`, `text-field`, `toggle`, `progress`, `image-view`, `status-bar`,
  `chart`, `log-view`, `doc-view`, `chat-view`). Pages are assembled only from these, never from raw LVGL
  widgets, and arranged only with `row`/`column` flex containers using spacing tokens — no pixel
  coordinates. Each component's full contract (static attrs, dynamic props, events, states) is in
  the spec's **Component contracts** section — implement against that, and grow the vocabulary
  only when a named application demands it (that's how `chart`, `log-view`, and `doc-view` got
  in). `doc-view` means the device never parses Markdown — servers convert to typed blocks.
- **Pages name roles and tokens, never pixels and hex.** Two font faces exactly (a UI face and
  `mono`, both Latin + Cyrillic) at a small size ladder; pages reference size roles (`body`,
  `title`, `caption`, `stat-value`, `mono`) and colour tokens (`surface`, `text`, `muted`,
  `accent`, `ok`, `warn`, `error`) that firmware maps per device — this indirection is the
  layout-portability and dark-mode mechanism. Spacing uses `sm`/`md`/`lg` tokens the same way.
  Raw hex in `color` is legal only for data-driven colour and is validator-flagged.
- **Every application is its own roadmap step**, interleaved with platform steps at the earliest
  point the platform can carry it — and each app step formalises the components it forces into
  `components/` (the component *machinery* lands early at M3; the library grows app by app;
  nothing is built ad-hoc to be migrated later). Spec §8: status console **M4** (pure push;
  brings `chart`), server terminal **M6** (form-submit — command→output by design, never a PTY;
  brings `text-field`/`button-row`/`log-view`), Markdown browser **M7** (folders/files/reader
  over server-side `.md`; brings `list-view`/`doc-view` with link blocks — block-level only,
  inline links are a refused design line), Wikipedia browser **M8** (history at depth; brings
  nothing — the library carries it whole), notes with Markdown **M10** (the input-preservation
  proof, right after the M9 shell), companion **M11** whole — dashboard, question page, chat
  (brings `chat-view` + `progress`; streaming via the log-view tail-re-send pattern). Srotas
  **M13** and Telegram **M14** (one conversation, just chat, no media) ship as *generated*
  applications after the M12 validator; RoboFace **M16** and Lumi **M17** close the roadmap on
  the M15 audio seam (RoboFace's JSON+binary-PCM wire is the reference). Telegram's background
  messages ride the `notice` message type. **M13–M17 are optional** — the required roadmap ends
  at M12 with the platform complete.
- **The action registry is the security boundary.** Generated pages may reference declared action
  names only; they may never invent them. A page cannot do anything the firmware was not already
  built to do.
- **Device owns feel, server owns meaning.** Immediate touch feedback, scrolling, text entry, the
  application stack, caching, and local hardware actions (brightness, volume, sleep, back, switch
  app, close app) never round-trip. Everything else is the server's. The device has no truth of its
  own except the user's in-progress input.
- **A `session_id` binds the two halves of an open application** — a live LVGL screen on the device,
  a logic session on the server. Switching away and back rebuilds neither half; that is the entire
  reason state survives.
- **Only the active application receives pushed `data`.** Backgrounded sessions stay alive but
  unfed; the device re-subscribes on return.
- **Events must never fail silently.** The outbound queue is bounded; when the connection drops
  events wait, and past the limit the oldest are dropped *and the user is told*.

## Protocol shape

Six message types, JSON, one object per frame, asynchronous in both directions with no ordering
assumptions. Every message carries `session_id`; requests carry `req_id` so responses can be
matched.

| Type | Direction | Purpose |
|---|---|---|
| `subscribe` | device → server | Page became active, or a widget needs data |
| `data` | server → device | Targeted `updates` by element `id`; `req_id` omitted on unsolicited push |
| `event` | device → server | User interaction, fire-and-forget |
| `navigate` | both | `mode`: `push` / `replace` / `back` / `root` |
| `error` | server → device | `code` + `message`, rendered by the shell in a shared overlay |
| `notice` | server → device | Badge from a *backgrounded* session — never wakes it; tap switches to the app |

`event.values` carries the contents of **every** input field on the page — submit the form, don't
stream keystrokes. This is what keeps behaviour predictable on poor links.

Decisions layered onto the protocol (all recorded in the spec — don't reinvent them):

- **Sessions**: the device mints `session_id`; the server creates sessions lazily on first sight
  of an unknown id. First use *is* creation — no handshake. Reconnect re-subscribes the active
  application only; server restart is the same path (unknown id → fresh session, handler pushes a
  `navigate` if it can't rebuild state). There is **no `session_expired` message**.
- **Versioning**: one integer protocol version stated at connect (`GET /ws?proto=1&screen=1280x720`
  — the connect URL also declares the device profile, used for asset pre-scaling); mismatch → the
  shell's plain mismatch screen. Unknown JSON keys **and unknown message types** are always
  ignored; only breaking changes bump the version.
- **Assets**: same machinery as pages — HTTP GET, SD cache, `If-None-Match`; server pre-scales to
  the connect-time `screen`; PNG/JPEG only.
- **Trust model**: trusted network only (LAN/Tailscale), no protocol auth, secrets server-side; an
  optional per-server bearer token is the named future hardening. Untrusted page servers are a
  non-goal.
- **Audio**: direction pinned (binary PCM16 beside JSON on the same WS, RoboFace wire as
  reference), full design deferred to milestone M15 — M2's connection code must not preclude a
  mixed text/binary socket.
- **Page cache**: conditional GET (`If-None-Match`) each time a page becomes active; offline
  renders the cache as-is; the server keeps no per-device state. A `data` update naming an `id`
  not on the page is dropped and debug-logged, never a crash.
- **Parameterised pages**: a path's query string (`/apps/wiki/article?t=Lviv`) selects content,
  never structure — XML cached by base path alone, full path in `subscribe`/`navigate` and the
  history stack.
- **Multiple servers**: simultaneous, one WebSocket per server with open applications; the
  switcher spans worlds; only the active application receives data regardless of server count.

Every dynamic component must render sensibly when **empty**, **loading**, and **ready** (plus
**error** where failure is possible). The component library handles this once so applications never
repeat it — and the shell owns error UI, so applications should not build their own.

## Build order

Milestones are ordered by risk, not size, and each is independently testable. Full detail in §8 of
the spec.

**M0 (walking skeleton) carries every proof.** One trivial app end to end — a counter whose value
lives on the server (a `stat-card`, an `increment` button, a server-clock tick as unsolicited
push), plus a throwaway **`doc-view` v0** — one hard-coded `.md` parsed server-side into typed
blocks, pushed as `items`, rendered as a scrollable label column: the platform's heaviest
renderer, proven first — over a trimmed wire (`subscribe`/`data`/`event` only), no cache, no
sessions in plural, no shell. The code is allowed to be throwaway; its DoD is philosophical: rebooting the device must
not reset the count, because the count never lived there. All PoC and test scaffolding
concentrate in M0: the `lv_xml`-on-P4 go/no-go verdict (fallback: a vendored SAX parser with the
vocabulary hand-mapped to `lv_*`), parse/heap measurements, the panel-revision probe, and the
pytest suite + fake-device script under `tools/` that every later milestone extends, never
reinvents.

After M0, every step adds functionality the platform did not have before — none exists to
formalise or re-record what an earlier one proved — and platform steps interleave with
application steps (each app is its own step, the live proof of the platform step before it):
M1 static fetch + SD cache (the kept `firmware/`/`server/` trees start here — M0's code is
quarry, not foundation) → M2 live channel (`subscribe`/`data`, sessions, reconnection) →
M3 component system (tokens, fonts, `<component>` machinery, manifest; the counter reborn on
real components with a global dark/light flip) → **M4 status console** → M5 `event`/`navigate`
+ history + action registry → **M6 server terminal** → **M7 Markdown browser** →
**M8 Wikipedia browser** → M9 shell (picker, switcher, multi-session, `notice`, keyboard,
`status-bar`) → **M10 notes** → **M11 companion (flagship)** → M12 validator and authoring
loop → *(optional from here on)* **M13 Srotas (generated)** → **M14 Telegram (generated)** →
M15 audio seam → **M16 RoboFace** → **M17 Lumi**. Each step in the spec carries a task list, a *Done when* exit
gate (demonstrable on hardware, not a code review), and — for platform steps — an *Out of
scope* fence; implement to the gate, and don't pull a later step's concern forward.

## Authoring loop

`Markdown description → Claude Code → page XML → validator → server`

The **validator** is the piece that makes agent authoring viable: a host build of LVGL (macOS or
WebAssembly) exposed as a CLI that checks XML against the schema and component library, confirms
every referenced action exists in the registry, confirms every dynamic `id` is unique within the
page, renders to PNG at target resolution, and exits non-zero with readable errors. Without it,
generation produces plausible XML that fails on hardware and every page needs human review; with
it, the agent self-corrects. When writing pages, run the validator to completion rather than
reasoning about correctness.

Pages are dropped into the server's page store and are live immediately — no reflash, no compile
cycle. The index page is an ordinary page with no special powers; by convention it lists the
server's applications.

## Open questions

Only one remains in the spec's §9, and only hardware answers it: **does LVGL's XML module build
and run on ESP32-P4** — M0 answers it, with the verdict, the parse/heap measurements, and the
display-revision probe (ILI9881C vs ST7123/ST7121) all landing in its exit ledger. Everything else once listed there is decided and recorded in the
spec: keyboard = the Tab5 Macintosh port's I2C driver (`0x6D`, matrix-event) adopted at M9 with
the key map defined then; `list-view` stays fixed-count (variable length lives in `doc-view` /
`chat-view`); portability beyond Tab5 waits for second hardware (roles/tokens are the prepared
mechanism); assets, trust model, `notice`, and the audio seam are summarised above.
