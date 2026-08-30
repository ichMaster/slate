# Roadmap — Slate

Seven versions, built in order: **v0** proof (the walking skeleton and every proof-of-concept) → **v1** platform foundation (cache, live channel, component system) → **v2** interaction and the first applications (console, events/navigation, terminal, two browsers) → **v3** the shell (many applications at once) → **v4** the signature applications (notes, the Claude Code companion) → **v5** the authoring loop (validator, generation) → **v6** *(optional)* ports and voice (Srotas, Telegram, the audio seam, RoboFace, Lumi). Phases inside a version are numbered `vA.B`; each lists a **Goal**, a short description, a **Tasks** list, a **Definition of Done (DoD)**, and **Tests** (see [ARCHITECTURE.md](ARCHITECTURE.md) §Testing and CI). Every phase keeps its original step id (M0–M17) from [slate-vision.md](slate-vision.md) as a cross-reference.

Two rules shape the order. **Risk first:** v0.1 is the cheapest possible collision with the one question that can change everything — does LVGL's XML module run on the ESP32-P4. **Additions only:** after v0, every phase adds functionality the platform did not have; no phase formalises or re-records what an earlier one proved. Platform phases and application phases interleave — each application is its own phase, landing at the earliest point the platform can carry it, and formalising the components it forces into `components/` as part of its own phase. Until the shell (v3.1) the device is a single-application terminal: start page from firmware config, and from v2.2 the server's index; one session at a time.

**Versioning (`A.B.C`).** Roadmap phase `vA.B` → release `A.B.0`, tagged `vA.B.0`; `C` is a post-release fix on that phase. Releases are cut per phase. Never bump a version without explicit user confirmation.

---

## v0 — Proof: the walking skeleton (M0)

The concept on the desk, and every proof with it. One very simple application alive end to end; everything inessential sacrificed; the code allowed to be throwaway. The deliverables are the demo, the recorded verdicts, and the test scaffolding every later phase inherits. Depends on: nothing — and everything depends on it.

### v0.1 — Walking skeleton (M0)

**Goal:** the whole concept demonstrated on one screen, and the P4 question answered.

Minimal bring-up (Tab5 BSP, LVGL, `LV_USE_XML`), a single-file Python server (~150 lines) speaking a trimmed wire (`subscribe`/`data`/`event` only), one page fetched over HTTP at boot (no cache, hard-coded server address), and the app: a **counter** whose number lives on the server (a raw value label + an `increment` button), a server-clock label ticking at 1 Hz (unsolicited push), and **`doc-view` v0** — one hard-coded `.md` parsed server-side into typed blocks, pushed as a single `items` update, rendered as a scrollable label column. Raw LVGL widgets, default theme, no components, no tokens; three firmware-drawn states (`connecting…`, unreachable, the page). The trimmed wire thus exercises both update shapes — scalar and structured. UI details: [ui-m0-brief.md](ui-m0-brief.md) and the M0 canvas.

**Tasks:**
- ESP-IDF project with the Tab5 BSP; boot to a blank LVGL screen with display + touch alive; probe and record the panel revision (ILI9881C vs ST7123/ST7121).
- Enable `LV_USE_XML`; confirm vendored expat compiles; render one hand-written page via `lv_xml_component_register_from_file` + `lv_xml_create`.
- The trimmed wire on both ends; a hard-coded mini-applicator (find `count`/`clock`/`doc` by name, set text / rebuild the label column).
- One registered event callback wired to the button; the counter handler and clock ticker server-side.
- `doc-view` v0: server-side Markdown → block list; device-side scrollable column (headings larger, `•` bullets, code on a shaded strip).
- **The PoC ledger**, written at exit: the `lv_xml` go/no-go verdict (fallback if no: a vendored ~6 KB SAX parser, vocabulary hand-mapped to `lv_*`), page parse time, widget-tree heap cost, render time and scroll feel for a ~50-block document, the panel revision.
- **Test scaffolding**, seeded here and only extended later: pytest for the server; the fake-device script under `tools/` driving the trimmed wire from the host.

**DoD:** power on → the page appears from the server → the clock ticks → the button increments the count → the document renders and scrolls under a finger — and rebooting the device does not reset the counter, because the count never lived on the device. The ledger is written; the scaffolding is green on the host.

**Tests:** unit — counter/clock/doc handlers, Markdown → blocks; integration — fake device: subscribe → initial data, event `increment` → pushed value, unsolicited clock push, the `items` document update. On-device demonstrations are the DoD, not CI.

---

## v1 — Platform foundation: cache, live channel, component system (M1–M3)

The same loop rebuilt honestly, as kept code. v0.1's code is quarry, not foundation. By the end of v1 the platform has honest caching with offline behaviour, the real protocol with sessions and reconnection, and the component system with tokens, both fonts, and the manifest — so every application after it is built on real components and nothing is ever migrated later. Depends on: v0's verdict.

### v1.1 — Static fetch (M1)

**Goal:** cache honesty — and the first kept code.

The kept `firmware/` and `server/` trees start here, versions pinned. The server (asyncio; the aiohttp-vs-FastAPI choice is made now and recorded in ARCHITECTURE) serves page XML from `apps/` with a content-hash `ETag`; the device gains WiFi, an HTTP client, a conditional GET, and an SD cache keyed by base path storing body + `ETag` together.

**Tasks:**
- Pin ESP-IDF/LVGL/BSP versions; scaffold the kept trees; `.env`-style config for the server.
- The deploy pipeline to `192.168.1.197` (ARCHITECTURE §Deployment and test topology): sync
  `server/`+`apps/`+`components/` → run the server pytest suite remotely → restart on green.
  Executed on every server-code change from here on; the server suite never runs on the
  workstation again.
- Server: static page serving with content-hash `ETag`; `304` on match.
- Device: WiFi bring-up; conditional GET with `If-None-Match`; SD cache write/read; render from cache.
- The three paths, each rendering something sensible: `200` (fetch, cache, render), `304` (render cache), offline (render cache; a plain error screen only when there is no cache either).

**DoD:** a cold fetch renders; a warm activation revalidates with a `304`; an edited page on the server replaces the cache on next activation; WiFi off renders from cache.

**Tests:** unit — `ETag` stability and change-on-edit; integration — fake device/HTTP client: 200 → 304 → edit → 200 sequencing; contract — cache keyed by base path (query string excluded).

### v1.2 — Live channel (M2)

**Goal:** v0.1's trimmed wire grown into the real protocol — sessions, push, reconnection.

The WS endpoint honours `?proto=&screen=` (a `proto_mismatch` close renders as the plain mismatch screen, never a hang). The device gains a frame codec and dispatcher (JSON in text frames; unknown types and keys ignored; **binary frames left reserved** so v6.3 is not precluded), device-minted `session_id` with lazy server-side creation, `subscribe` on page activation driving the loading state, and the real applicator: an id → widget map built at render time, the eight-property switch, unknown ids dropped with a debug log. Server-side, handler API v0 (`async` handler, `session.update(...)`) with a minimal push demo — one ticking value; v1.3 rebuilds it on real components, v2.1 replaces it with a real application.

**Tasks:**
- WS endpoint + version negotiation; the mismatch screen.
- Frame codec/dispatcher; forward-compatibility rules (unknown ignored; binary reserved).
- Session minting + lazy registry; `subscribe` on activation; loading-state plumbing.
- The applicator over the closed property set; unknown-id drop.
- Handler API v0 + the ticking demo; reconnect with backoff; active-page re-subscribe.

**DoD:** a pushed value renders live; killing and restarting the server mid-run reconnects, re-subscribes, and resumes values with no user action; a version-mismatched server produces the mismatch screen.

**Tests:** contract — the six message schemas (four in use now), connect-URL params, the closed property set; integration — fake device: lazy session creation, re-subscribe after reconnect, unsolicited push, `proto_mismatch` close, unknown message type ignored.

### v1.3 — Component system (M3)

**Goal:** the design system's machinery, early — so nothing is ever built ad-hoc to be migrated.

`<component>` definitions load from `components/` (declared props only; the empty/loading/ready trio built into the base once). The token layer lands in firmware: colour tokens with light and dark tables, five type roles, spacing tokens, the per-device role → size map; both faces compiled (UI + `mono`, Latin + Cyrillic + symbols, tabular figures for `stat-value`). The machine-readable manifest is seeded and grows with every component added after. The seed components — `page-header`, `text-block`, `stat-card` — are proven by rebuilding v0.1's counter page on them. `toggle` and `image-view` wait for the first application that demands them: the growth discipline applies to build order too. Values and geometry: [ui-implementation.md](ui-implementation.md) §2–3.

**Tasks:**
- Component loading + the state trio in the base; the themed card asymmetry (hairline in light only).
- Token tables + theme flip (pointer swap + display invalidate); role → size map.
- Font build: both faces, five roles, Cyrillic ranges, tabular digits.
- Manifest seed (components, props, dynamic properties, actions) + a consistency check against `components/`.
- Rebuild the counter page on the seed components.

**DoD:** the counter page is reborn with zero raw widgets; the dark/light flip is global and instant; a component instantiates from XML by declared props alone; the manifest describes everything that exists.

**Tests:** contract — manifest ↔ `components/` consistency, token/role name lists; unit — manifest generation; on-device — the flip and the state trio against the `F1` board (DoD).

---

## v2 — Interaction and the first applications (M4–M8)

The platform earns its keep: the first real application on pure push, then the full user-acts/server-decides loop, then three applications that each land at the earliest phase able to carry them — and each formalises the components it forces. By the end of v2 the library holds everything except `status-bar`, `chat-view`, and `progress`. Depends on: v1.

### v2.1 — Application: status console (M4)

**Goal:** the live channel's first real consumer — read-only, pure push. Brings `chart`.

One page (6.5): a `stat-card` grid (CPU, memory, disk, uptime) and a CPU-history `chart` (fixed axes, single series, 31-point window); psutil behind the handler, pushing once a second with threshold colours (`ok` < 70, `warn` 70–90, `error` > 90). No input, no navigation — the pressure lands on update volume and render cost. 6.5's restart actions arrive free once v2.2's events exist — an enhancement, not a phase.

**Tasks:**
- The `chart` component (wraps `lv_chart`; `kind`/`y-min`/`y-max`/`points` static, `items` dynamic) into `components/` + manifest.
- `apps/console/` page + handler (psutil, 1 Hz push, threshold colours, `updated` stamp).

**DoD:** the console runs untouched for an hour with a stable heap; a server restart resumes the cards unprompted; the chart scrolls its history.

**Tests:** unit — handler thresholds and window slide (psutil mocked); integration — fake device: 1 Hz updates carry all card ids + the full `items` window; contract — `chart` manifest entry.

### v2.2 — Events and navigation (M5)

**Goal:** the full loop — user acts, server decides, screen changes.

`event` with `action`/`source`/`values` (input collection walks the page's fields; fire-and-forget); the bounded outbound queue with drop-oldest and a provisional user-visible warning; `navigate` both ways with all four modes, the history stack, and parameterised paths; `error` rendering in a first-pass overlay; and **action registry v0** — a declared file in `components/`, each name marked local or server. Two throwaway pages joined by a button exercise push/back and a server-sent `navigate`; v2.3 and v2.4 replace them with real applications. From here the server's index is the natural start page.

**Tasks:**
- `event` assembly + input walking; the queue with its limit + warning.
- `navigate` four modes + history; parameterised path handling (cache by base, full path in history/`subscribe`).
- `error` overlay v1; the action registry file, loaded by firmware.
- The two throwaway pages + demo handler.

**DoD:** button navigation and back work across two pages; `values` arrives complete on submit; a WiFi drop mid-typing queues events and shows the warning, and reconnection flushes the queue in order; a server-pushed `navigate` lands unprompted.

**Tests:** contract — `event`/`navigate`/`error` schemas, registry shape; integration — fake device: values completeness, queue-flush ordering after reconnect, server-driven navigate, history semantics of the four modes.

### v2.3 — Application: server terminal (M6)

**Goal:** the event loop's first real consumer — command → output, never a PTY. Brings `text-field`, `button-row`, `log-view`; puts `mono` to work.

One page (6.6): a command `text-field` (Enter fires `run` when the keyboard is attached) and a `log-view` scrollback. Submit runs the command on the server; output arrives as tail re-sends (set semantics, ANSI stripped server-side); follow-tail is bottom-anchored and releases when the user scrolls up. The handler runs with the server's privileges — the trusted-LAN assumption made vivid.

**Tasks:**
- `text-field`, `button-row`, `log-view` into `components/` + manifest (focus ring, variants, bottom-anchored tail per [ui-implementation.md](ui-implementation.md)).
- `apps/terminal/` page + handler (subprocess, output buffering, tail re-send, ANSI strip).

**DoD:** a long directory listing streams into the scrollback; follow-tail holds unless the user scrolls up; a command fired during a WiFi drop queues, warns, and executes on reconnect.

**Tests:** unit — command runner (subprocess mocked), tail-window logic, ANSI stripping; integration — fake device: submit → orderly tail re-sends; queued command executes after reconnect.

### v2.4 — Application: Markdown browser (M7)

**Goal:** hierarchy and reading — `doc-view` becomes a real component. Brings `list-view` and `doc-view` (link blocks included).

Two pages (6.12): a parameterised listing (`?path=`) — a `list-view` of folders and files, a tap descending or opening — and a reader rendering server-parsed Markdown into `doc-view` blocks (`h1 h2 h3 p bullet code quote divider`, 200-block cap, block-level links only). Links between files arrive as link blocks and navigate with `push`, so back retraces every hop. v0.1's throwaway renderer proved the block model; here it becomes the component.

**Tasks:**
- `list-view` (fixed rows, row template, additive `row` key) and `doc-view` (block kinds, `link` key, `accent` link rows) into `components/` + manifest.
- `apps/md/` listing + reader pages; handler: directory walk, Markdown → blocks, link resolution.

**DoD:** descend two folders, open a file, follow a link to another file, and back retraces every step; headings, bullets, and code render as typed blocks; a directory of real notes (an Obsidian vault will do) browses comfortably.

**Tests:** unit — Markdown → block list (fixtures: headings, code, quotes, links, the 200 cap), directory walk; contract — block-kind enum; integration — fake device: list rows, `row` tap → navigate push, reader `items`, link tap → parameterised navigate.

### v2.5 — Application: Wikipedia browser (M8)

**Goal:** the v2.4 shape plus search and an external source; history at real depth. Brings nothing — the first application the library already carries whole.

A search page (6.7: `text-field` + results `list-view`, Cyrillic in anger) and one parameterised article page structurally identical to the Markdown reader — that identity is the design decision. The server proxies and converts articles to blocks; the device never touches the internet.

**Tasks:**
- `apps/wiki/` search + article pages; handler: search API, article fetch, wikitext/HTML → blocks, link extraction into link blocks.

**DoD:** search → article → link → link → back → back retraces exactly; Cyrillic articles render; the device never touches the internet — the server proxies everything.

**Tests:** unit — article → blocks conversion (fixtures incl. Ukrainian), search result mapping (API mocked); integration — fake device: search round-trip, parameterised article subscribe, deep back-stack walk.

---

## v3 — The shell (M9)

The device becomes a terminal for many applications at once — assembled from the component library it inherits. Depends on: v2 (four applications exist to switch between).

### v3.1 — Shell (M9)

**Goal:** many worlds, many applications, state that survives switching. Brings `status-bar`.

Server picker (saved servers, add/edit, auto-connect); sessions in plural (one `lv_screen` per open application, an open-limit with oldest-first eviction, explicit close); the switcher grouped by server (one WS per connected world; each world's index always present); the background rule enforced (only the active session subscribed; `notice` badges surface backgrounded sessions, tap switches); the status bar complete (per-server connection, battery, clock, queue warning, notice badges) and the error overlay in final form; the keyboard (Macintosh-port I2C driver `0x6D` adopted as-is; the shell key map — back, switcher, submit, address entry — defined against real screens); local actions complete (brightness, volume, sleep, back, switch, close). Boards `S1`/`S2`/`X1`/`X2` gate the visuals.

**Tasks:**
- `status-bar` into `components/`; picker + switcher screens on the library.
- Multi-session firmware: screens, eviction, close; per-world WS connections.
- `notice` end to end (badge, alert persistence, tap-to-switch); the queue warning in its final home.
- Keyboard driver port + key map + field editing; local actions.

**DoD:** three applications across two servers switch instantly with scroll and half-typed text intact; killing one server marks only its own applications disconnected; a `notice` from a backgrounded session badges the status bar and a tap lands in that application; the whole shell is drivable from the keyboard alone.

**Tests:** integration — fake devices ×2 sessions: active-only push asserted, `notice` routed to the backgrounded session's connection, eviction order; contract — `notice` schema, saved-server record; unit — server multi-connection registry.

---

## v4 — Signature applications: notes, the companion (M10–M11)

The platform's promise made personal: the input-preservation proof, then the application the whole project was started for. Depends on: v3.

### v4.1 — Application: notes with Markdown (M10)

**Goal:** the shell's first real consumer — and the platform's signature, proven. Brings nothing; its contribution is the proof.

One capture page (6.4: a multi-line `text-field` + Save, a recent-notes `list-view`) and a parameterised reader on `doc-view`. The half-typed draft surviving a switch away and back is this page's only acceptance criterion that matters: the field's contents live in the LVGL widget, are never sent until `save`, and are never overwritten by a `value` update while the field has focus.

**Tasks:**
- `apps/notes/` pages + handler (note store, list, Markdown → blocks reuse).
- The focus-guard rule in `text-field` (no `value` overwrite while focused) if not already pinned.

**DoD:** leave mid-sentence, switch to another application, come back — the draft is intact; a note with headings, bullets, and code renders as typed blocks; capture → list → reader → back flows without a page re-send.

**Tests:** unit — note store, ordering, dates; integration — fake device: save → list update, reader blocks; contract — the focus-guard rule; the switch-away draft proof is an on-device DoD gate.

### v4.2 — Application: Claude Code companion (M11)

**Goal:** the original motivation, whole — dashboard, question page, chat. Brings `chat-view` and `progress`.

Claude Code hooks write events; the daemon serves them (6.1). The dashboard: four `stat-card`s (tasks, tests, findings, ETA), a burn-down `chart` beside an activity feed, a `progress` bar. The question page arrives as a server-pushed `navigate`: the whole question, never truncated — the entire argument for a 5-inch screen — a `button-row` of choices and a free-form `text-field`. The chat page on `chat-view`: messages injected into the session via the Agent SDK, replies streamed back by tail re-send with the `pending` typing indicator. `notice` fires when a question or completion lands while backgrounded.

**Tasks:**
- `chat-view` and `progress` into `components/` + manifest (bubbles, 76 % max width, `pending` beneath the bubble; track/bar geometry).
- The hooks → event-file → daemon pipeline; dashboard/question/chat pages in `apps/claude/`.
- Agent SDK injection for chat; question round-trip (choices + free text); `notice` on question/completion.

**DoD:** a real Claude Code run drives the dashboard; a mid-run question lands as a `navigate`, is answered from the keyboard, and generation resumes; chat round-trips with streamed replies — all while other applications stay open and intact.

**Tests:** unit — hook-event parsing, burn-down/ETA computation, question lifecycle (SDK mocked); integration — fake device: pushed navigate to the question page, answer event → resume, chat tail re-sends with `pending`, notice while backgrounded; contract — `chat-view` item shape.

---

## v5 — The authoring loop (M12)

The platform starts writing its own applications. The platform is **complete at the end of v5** — shell, component library, flagship, and the authoring loop; everything after is optional. Depends on: v4 (the library is complete; the manifest describes it all).

### v5.1 — Validator and authoring loop (M12)

**Goal:** a page is proven without hardware; the agent self-corrects.

The host build of LVGL shares the firmware's renderer layer — same `lv_xml`, same components, same applicator (SDL or a headless framebuffer). `slate-validate page.xml`: manifest and schema checks, unknown components/props, action names against the registry, id uniqueness, token/role whitelists, the raw-hex warning and the raw-pixel error; renders PNG at target resolution; exits non-zero with errors both a human and an agent can read. The authoring workflow (a prompt/skill reading the manifest + registry, writing page + handler stub, iterating to clean) and CI (validator over every page in `apps/`, golden PNGs in both themes) land together.

**Tasks:**
- `validator/`: host renderer build; the CLI with every check; PNG output.
- Golden-PNG suite for all pages in `apps/`, both themes.
- The authoring skill/prompt; a canned Markdown description exercised end to end.
- CI wiring: ruff + pytest + validate + golden diffs.

**DoD:** seeded errors (unknown component, bad action, duplicate id, raw hex, raw pixels) each fail with a readable message; a sample page written by the agent from a Markdown description passes clean and runs on hardware unmodified; CI is green over `apps/`. The first real generated application is v6.1 — the first optional phase.

**Tests:** the validator's own suite (seeded fixtures per error class); golden-PNG determinism; contract — validator exit codes and message format (agent-parseable).

---

## v6 — Ports and voice *(optional)* (M13–M17)

Everything below is optional: the platform is complete at v5.1. These are ports of the author's existing projects, undertaken when wanted — v6.1/v6.2 in any order once v5.1 exists; v6.4/v6.5 only after v6.3. All are chat-shaped and ride the `chat-view` the companion paid for; v6.1 and v6.2 are **generated** applications — the authoring loop's proof at scale.

### v6.1 — Application: Srotas feed (M13, generated)

**Goal:** the first generated application — it forces nothing, which is why it goes first.

Generated from a Markdown description (6.9): the feed `list-view` of scored cards, a parameterised detail page (`doc-view` summary, like/dislike `button-row`, free-text feedback `text-field`). The handler fronts the existing Srotas process; its collect → score → feedback loop is untouched.

**Tasks:** the Markdown description; run the loop; a thin handler over Srotas' store/API.

**DoD:** the generated page passes the validator untouched by hand and runs on hardware; feedback from the device shifts weights end to end.

**Tests:** unit — handler over a mocked Srotas store; integration — fake device: feed, detail, feedback event; CI — the generated pages under the standard validate + golden gates.

### v6.2 — Application: Telegram client (M14, generated)

**Goal:** one conversation, just chat — the second generated application.

A single page (6.11): `chat-view` + a send `text-field`; Telethon behind the handler; the peer chosen in server configuration. No chat list, no media, no stickers. Incoming messages while backgrounded arrive as `notice` badges.

**Tasks:** the Markdown description; run the loop; the Telethon handler (send, receive, history tail).

**DoD:** messages flow both ways; an incoming message while the chat is backgrounded badges the status bar via `notice`, and a tap lands in the conversation.

**Tests:** unit — handler over a mocked Telethon client; integration — fake device: send event → transcript update, incoming → tail re-send when active / `notice` when backgrounded.

### v6.3 — Audio seam (M15)

**Goal:** voice for the final ports, designed when its consumers arrive.

The contract first, as a design doc: binary WS frames tagged with session and stream, PCM16 format and rate, start/stop control in JSON, backpressure — RoboFace's wire (JSON control + binary PCM16 over WSS) is the reference. Firmware capture/playback on Tab5's mic and speaker; push-to-talk as a local action (no wake word); the server-side audio router proven with an echo handler; `chat-view` gains mic-state and speaking affordances.

**Tasks:** the seam design doc; firmware capture/playback + push-to-talk; the router + echo handler; `chat-view` affordances; fake-device binary-frame support.

**DoD:** a held key streams mic PCM to the server and a server-sent clip plays back — the echo round-trip on hardware; text-only chat is byte-identical when audio is absent.

**Tests:** contract — the binary frame header + control messages; integration — fake device speaks binary frames through the echo handler; regression — text-only paths byte-identical with audio absent.

### v6.4 — Application: RoboFace agent (M16)

**Goal:** the conversation, typed and spoken — the audio seam's first real consumer.

`chat-view` against the existing RoboFace orchestrator (6.8): typed chat is the interface RoboFace never had; voice rides the v6.3 seam, push-to-talk. No face — the transcript, not the character; the animated face stays RoboFace's own.

**Tasks:** the handler bridging Slate's wire to the RoboFace server (text turns; audio via the seam); a generated chat page.

**DoD:** a held key speaks and the reply returns as streamed text and audio together; typed chat works identically with audio absent.

**Tests:** unit — bridge mapping (RoboFace protocol mocked); integration — fake device: typed round-trip with streaming; audio path against a mocked orchestrator.

### v6.5 — Application: Lumi (M17)

**Goal:** the private persona on the device — the roadmap's last phase.

A generated chat page over her existing `Core.reply()` (6.10) — memory, emotion, and intent machinery untouched; Slate is exactly the "growing interface" her architecture planned for. Mood and closeness land as status colour; voice through her own chain — Deepgram → core → ElevenLabs — on the v6.3 seam.

**Tasks:** the handler over `Core.reply()` (emotion → colour token mapping); the generated page; voice wiring on the seam.

**DoD:** a text conversation with Лілі survives switching away mid-thought and returning; voice mode round-trips on the seam; the emotion channel visibly colours the page.

**Tests:** unit — handler over a mocked `Core` (emotion mapping, colour tokens); integration — fake device: chat round-trip, emotion-driven `color` updates; voice against mocked ASR/TTS.
