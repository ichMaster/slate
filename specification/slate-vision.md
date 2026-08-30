# Slate — Thin-Client Application Platform

**Name:** Slate
**Audience:** Claude Code, implementing this from scratch.
**Status:** Vision / architecture spec. No code exists yet.

---

## 1. Concept

A **mainframe terminal model, rendered with LVGL.**

The device is a dumb-but-pretty renderer. The server holds all logic, all data, all
state. Between them travels a narrow, well-defined protocol: the server sends
*content*, the device sends *events*.

The unit of software is a **page**. A page is an XML file describing a screen
layout in LVGL's declarative XML format. A page plus its server-side handler is
what we call an **application**. There is no executable code on the device beyond
the firmware itself — a page cannot introduce new behaviour, only arrange
existing widgets and reference named actions the firmware already implements.

Three consequences follow, and they are the point of the whole design:

1. **Firmware stabilises early.** Once the renderer works, new applications appear
   by adding files on the server. No reflashing, no compile cycle, no USB cable.
2. **Applications are generatable.** A page is declarative text with a constrained
   vocabulary. Claude Code can write one from a Markdown description in seconds,
   and validate it without hardware.
3. **The platform is portable.** Any LVGL device can host the same shell. Tab5
   first; Cardputer, StickC, and future hardware later, differing only in layout.

### What this is not

- Not a web browser. No HTML, no JavaScript, no DOM.
- Not a code-download system. Pages are data, never instructions.
- Not a UI builder. Pages are authored as text (by hand or by an agent), not dragged.

---

## 2. Architecture

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  Tab5 (ESP32-P4, ESP-IDF)   │         │  Server (any language)       │
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
│  │  (brightness, volume, │  │
│  │   nav, sleep)         │  │
│  └───────────────────────┘  │
└─────────────────────────────┘
```

The protocol is language-neutral, but the reference server, the Claude Code
companion daemon, and every example handler are **Python** (asyncio; the thin
web layer — aiohttp or FastAPI — is chosen when M1 begins).

### Division of responsibility

**Device owns *feel*:**
- Rendering XML into an LVGL widget tree
- Immediate touch/keyboard feedback (button press states, text entry, scrolling)
- The application stack and switching between open applications
- Page caching and offline behaviour
- Local hardware actions that must never wait on the network

**Server owns *meaning*:**
- What each page contains
- All business logic and data access
- Session state per open application
- Deciding when content changes and pushing it

The device never has its own truth except the user's in-progress input.

### Two halves of an application

An open application exists in two places at once:

- **On the device:** a live LVGL screen object with real widgets, retaining scroll
  position, focus, entered text, and animation state.
- **On the server:** a session holding logic state and any subscriptions.

A `session_id` binds them. When the user switches away and back, neither half is
rebuilt — that is the whole reason state survives.

---

## 3. Page model

### Structure vs content

This split is the core rule of the platform.

**Structure is static.** A page's XML is downloaded once, cached on SD, and never
regenerated at runtime. It defines the widget tree, layout, styles, and which
elements are dynamic.

Cached copies stay honest through ordinary HTTP validation: when a page becomes
active the device revalidates with `If-None-Match`; a `304` costs a few bytes
and confirms the cache, a `200` replaces it. Offline, the cache renders as-is.
The server keeps no per-device state. One renderer rule closes the remaining
window: a `data` update naming an `id` not present on the page is dropped (and
logged in debug builds) — never a crash.

### Parameterised pages

A page path may carry a query string: `/apps/wiki/article?t=Lviv`. The query
selects **content, never structure**: the XML is fetched and cached by the base
path alone, while `subscribe` and `navigate` carry the full path — so the
server knows which content to serve, and the history stack distinguishes one
article from another. One cached structure, many history entries; the stack
walks back through them without a single re-fetch.

**Content is dynamic.** Every element that can change carries an `id`. The server
sends targeted updates naming that `id` and the property to change.

Never re-send a page to change a number. Re-sending a page loses scroll position,
input focus, and animation continuity, and it flickers. A page is replaced only
when the *form* genuinely differs, and then it is an explicit navigation.

### Assets

Images travel the page machinery: HTTP GET beside the pages, cached on SD with
the same `If-None-Match` revalidation — one cache implementation, two content
kinds. The server pre-scales every image to the requesting device's resolution,
which it learns from the `screen` parameter on the connect URL. Formats are
PNG and JPEG — LVGL's own decoders, nothing exotic.

### Layout

Pages arrange components with two containers and no coordinates:

- `column` — vertical flex; the implicit root of every page
- `row` — horizontal flex

Both take `gap` and `pad` as spacing tokens (`none`, `sm`, `md`, `lg`), an
`align`, and children may set `grow` to claim remaining space. There are no
pixel positions in pages — the same indirection as fonts and colour, and the
reason a page can land on another screen size at all. Components own their
internal padding; pages only arrange.

Portability beyond Tab5 is deferred until second hardware exists: roles,
tokens, and coordinate-free layout are the prepared mechanism, pages are
authored Tab5-first, and the breakpoints-versus-page-variants choice waits for
a real 240×135 screen to test against.

### Component vocabulary

Claude Code must not be handed the entire LVGL widget set. The platform defines a
small library of `<component>` definitions — the application's design system — and
pages are assembled only from those. Predictable generation matters more than
expressive range.

Start with roughly these, and resist growing the list until real applications
demand it:

| Component | Purpose |
|---|---|
| `page-header` | Title bar with optional back affordance |
| `stat-card` | Labelled value, optional unit and trend colour |
| `text-block` | Static or dynamic paragraph text |
| `list-view` | Repeating rows from a row template |
| `button-row` | One to four actions side by side |
| `text-field` | Single-line input with label and validation state |
| `toggle` | Boolean setting |
| `progress` | Determinate or indeterminate progress |
| `image-view` | Cached or streamed image |
| `status-bar` | Connection, battery, active-session indicator |
| `chart` | Line or bar trend (wraps `lv_chart`) |
| `log-view` | Bounded monospace scrollback with follow-tail |
| `doc-view` | Server-rendered document as typed text blocks |
| `chat-view` | Conversation transcript with streaming replies |

`chart` earns its place only under discipline: `kind`, axis ranges, and series
count are fixed in the XML; the sole dynamic property is `items` carrying the
values. Single series to start. Legends, ticks, autoscaling, and second axes are
refused until a real application cannot live without them — chart APIs are where
small vocabularies go to die.

### Component contracts

The contract each component offers to pages, servers, and the validator. Static
attributes are fixed in XML; dynamic properties come only from the closed set
below; every dynamic component instance carries a page-unique `id`. Visual
geometry, states rendering, and the design boards that gate each component
live in [ui-implementation.md](ui-implementation.md).

#### `page-header`
Title bar. Static: `title`, `back` (default `true`) — the back affordance fires
the **local** `back` action, never the server. Dynamic: `text` (title),
`visible`.

#### `stat-card`
Labelled value. Static: `label`, `unit` (optional). Dynamic: `text` (the
value), `color` (status token), `visible`. Optional `action` emits on tap.
Empty renders `—`; loading pulses the value.

#### `text-block`
Paragraph. Static: `font` (role, default `body`), `align`. Dynamic: `text`,
`color`, `visible`.

#### `list-view`
A fixed number of rows (`rows`) stamped from an inline row template; template
children carry template-local ids, and `items` rows are objects keyed by those
ids. Fewer items than rows hides the remainder; more are truncated — fixed count is
the decision, and variable length lives where it landed: `doc-view` and
`chat-view`. Static: `rows`, `empty-text`, optional `action`. Dynamic:
`items`, `visible`. A row tap emits the action with the row index as an
additive `row` key on the event.

#### `button-row`
One to four buttons, each with its own `id`, `label`, `action`, and `variant`
(`default`, `primary`, `danger`). Dynamic per button: `text`, `enabled`,
`visible`, `color`. The registry decides whether an action is local or
server-bound.

#### `text-field`
Static: `label`, `type` (`text`, `number`, `password`), `required`, `readonly`,
`maxlen`, `placeholder`. Dynamic: `value`, `enabled`, `visible`, `color`
(validation highlight). Emits nothing of its own — contents ride in `values`
on every event from the page. Enter, with the keyboard attached, fires an
optional `submit` action.

#### `toggle`
Static: `label`, `action`. Dynamic: `value` (`on`/`off`), `enabled`,
`visible`. Flips immediately on tap — device owns feel — and emits its action
with the new state in `values`; the server may correct it with a `value`
update — server owns truth.

#### `progress`
Static: `label` (optional). Dynamic: `progress` (0–100, `-1` for
indeterminate), `color`, `visible`.

#### `image-view`
Static: `src` (initial, optional), `fit` (`contain`, `cover`). Dynamic:
`image` (asset path), `visible`. Assets fetch over HTTP and cache like pages.

#### `status-bar`
Shell-owned; pages never instantiate it. Listed because it is built from the
same primitives and renders on every screen.

#### `chart`
Static: `kind` (`line`, `bar`), `y-min`, `y-max`, `points`. Dynamic: `items`
(numeric array), `color`, `visible`. Single series; the discipline note above
stands.

#### `log-view`
Bounded monospace scrollback. Dynamic: `text` (the server re-sends the visible
tail of its own buffer — set semantics, so the property set stays closed),
`visible`. The device follows the tail unless the user has scrolled up — feel
stays local. The server strips ANSI escapes; they never cross the wire. There
is no append operation and no device-side buffer beyond what is shown.

#### `doc-view`
A document rendered as typed blocks. Dynamic: `items` — an array of
`{ "kind": ..., "text": ... }` where `kind` is one of `h1`, `h2`, `h3`, `p`,
`bullet`, `code`, `quote`, `divider`; each kind styles itself from the font
roles and colour tokens (`code` uses `mono`). `visible`. The device never
parses markup — the server converts Markdown (or anything else) to blocks.
Variable length, capped at 200 blocks; unlike `list-view`, a document is not a
fixed grid, and this component is where that revisit landed.

Static: optional `action`. A block may carry a `link` key; such blocks render
in `accent`, and a tap emits the action with the link value as an additive
`link` key on the event — the server decides what it means. **Inline**
(within-paragraph) links and images remain refused: span hit-testing inside
flowing text is where renderer complexity explodes. Navigation is by search
and link blocks — a drawn design line, not a gap.

#### `chat-view`
A conversation transcript. Dynamic: `items` — an array of
`{ "role": "user" | "assistant", "text": ... }`, role-aligned bubbles styled
from the tokens, capped at the last 100 messages (the server owns full
history); `visible`. Streaming replies use the `log-view` pattern: the server
re-sends the growing last item — set semantics, no append operation — and a
`pending` flag on it renders a typing indicator. Follows the tail unless the
user has scrolled up. Renders history only: input is an ordinary `text-field`
and `button-row` below it.

Each component declares its `id`-addressable properties. That declaration is the
contract shared by firmware, server, and agent.

### Text and fonts

Fonts are compiled into firmware; no page can introduce one. The platform
compiles **two faces and no more**. The first is the UI face, at a small
ladder of sizes, covering Latin, Cyrillic, and the LVGL symbol glyphs.

Pages never name pixel sizes. They name **roles** — `body`, `title`, `caption`,
`stat-value` — and each device's firmware maps roles to sizes. This indirection
is deliberate: it is the mechanism that will let the same page XML land on a
Cardputer's 240×135 later. `stat-value` uses tabular figures so live-updating
numbers do not jitter.

A monospace face (role: `mono`) is compiled in as the second face — the
terminal's scrollback and markdown code blocks both demand it. It is also the
last: a third face is refused until a real application cannot live without it.

### Colour

The same indirection as fonts. Firmware defines a small token palette —
`surface`, `text`, `muted`, `accent`, `ok`, `warn`, `error` — with light and
dark values. Pages and `color` updates name tokens (`"color": "warn"`), so
every application shares one colour language and dark mode is a firmware flip
the servers never learn about.

Raw hex remains legal for genuinely data-driven colour (a bulb's actual hue in
the home dashboard); the validator flags it, so generated pages reach for
tokens first.

### Dynamic properties

The set of properties the protocol may update is deliberately small:

`text`, `value`, `visible`, `enabled`, `color`, `progress`, `items`, `image`

Anything not in this list requires a page replacement. Keeping this list short is
what keeps the renderer simple.

### Widget states

Every dynamic component must render sensibly in three states, and the component
library handles this once so applications never have to:

1. **Empty** — before the first server response
2. **Loading** — request outstanding
3. **Ready** — data present

A fourth, **error**, is desirable for anything that can fail.

The firmware drives the transitions, so applications get states for free: a
component renders empty until a `subscribe` names its `id`, enters loading
when one does, and becomes ready on the first `data` update that names it.

### Input fields

Fields carry attributes so the server can validate and the device can highlight
without any local logic: `required`, `readonly`, `type` (text, number, password),
`maxlen`.

---

## 4. Protocol

Transport: **WebSocket** for the live channel, **HTTP GET** for fetching page XML
and assets. JSON messages, one object per frame.

The protocol carries a **single integer version**, stated once when the channel
opens (`GET /ws?proto=1&screen=1280x720` — the connect URL also declares the
device profile, which is how the server knows what to pre-scale assets to).
The server accepts, or closes with `proto_mismatch` and the minimum version it
requires, which the shell renders as a plain firmware/server mismatch screen.
Two rules keep bumps rare: unknown JSON keys and unknown message types are
always ignored, so additive changes never bump the version; only breaking
changes do.

The design is asynchronous in both directions. No message assumes an ordering
relative to any other. Requests carry a `req_id` so a response can be matched to
its asker; every message carries a `session_id` because several applications are
open at once.

### Message types

Six types cover everything.

#### `subscribe` — device → server

Sent when a page becomes active, or when a widget needs data.

```json
{
  "type": "subscribe",
  "session_id": "s-7f3a",
  "req_id": 12,
  "page": "/apps/weather",
  "widgets": ["temp", "forecast_list"]
}
```

#### `data` — server → device

Targeted content updates. Sent in response to `subscribe`, or pushed
unprompted whenever the server decides something changed.

```json
{
  "type": "data",
  "session_id": "s-7f3a",
  "req_id": 12,
  "updates": [
    { "id": "temp",   "text": "24.5", "color": "warn" },
    { "id": "status", "text": "Updated 19:04" },
    { "id": "refresh_btn", "enabled": true }
  ]
}
```

`req_id` is omitted for unsolicited pushes.

For `list-view`, `items` carries an array of row objects whose keys match the row
template's ids:

```json
{ "id": "forecast_list", "items": [
    { "day": "Mon", "hi": "26", "lo": "14" },
    { "day": "Tue", "hi": "23", "lo": "12" }
]}
```

#### `event` — device → server

User interaction. Fire-and-forget by default: the device does not block waiting
for a reply. If a response is warranted, the server sends `data` or `navigate` of
its own accord.

```json
{
  "type": "event",
  "session_id": "s-7f3a",
  "action": "refresh",
  "source": "refresh_btn",
  "values": { "city_field": "Lviv" }
}
```

`values` carries the current contents of every input field on the page — the
mainframe pattern of submitting the form, not streaming keystrokes. This gives
predictable behaviour on poor connections and keeps message volume low.

#### `navigate` — both directions

Device → server when the user follows a link; server → device when logic dictates
a screen change.

```json
{
  "type": "navigate",
  "session_id": "s-7f3a",
  "page": "/apps/weather/settings",
  "mode": "push"
}
```

`mode`: `push` (add to history), `replace` (swap current), `back` (pop), `root`
(return to index).

#### `error` — server → device

```json
{
  "type": "error",
  "session_id": "s-7f3a",
  "req_id": 12,
  "code": "not_found",
  "message": "Unknown widget: forecst_list"
}
```

The shell renders errors in a consistent overlay so applications need no error UI
of their own.

#### `notice` — server → device

A nudge from a **backgrounded** session — the one message that crosses the
background rule without breaking it. The shell shows a status-bar badge and the
text; tapping it switches to that application, which re-subscribes normally.
The session itself is never woken and no content travels — a notice is an
invitation, not an update.

```json
{
  "type": "notice",
  "session_id": "s-7f3a",
  "text": "Message from Olena",
  "level": "info"
}
```

`level` is `info` or `alert`; an `alert` badge does not fade until seen.

### Event queue

The device holds a bounded outbound queue. If the connection drops, events wait
for reconnection up to the queue limit, then the oldest are dropped and the user
is told plainly. Events must never fail silently — that is the single most
confusing failure mode in this kind of system.

### Background sessions

Only the **active** application receives pushed `data`. Backgrounded sessions stay
alive on the server but are not updated until the user returns, at which point the
device re-subscribes and receives current values. This bounds both network traffic
and device memory.

### Session lifecycle

- Created on first navigation into an application. The **device mints** the
  `session_id` (random, `s-` plus enough hex to make collisions ignorable) and
  sends it in that first `navigate`; the server creates the session lazily on
  first sight of an unknown id. First use *is* creation — there is no handshake
  and no extra round-trip before rendering.
- Kept alive while the application is open in the switcher
- Closed when the user closes it, or evicted when the open-application limit
  is reached (oldest first)
- On reconnection after a dropped link, the device re-subscribes only the
  **active** application; backgrounded sessions re-subscribe when the user
  returns to them, exactly per the background rule above
- Server restart is the same path, not a special case: an unknown `session_id`
  creates a fresh session (lazy creation, above), and the `subscribe` already
  tells the server which page the device is showing. A handler that cannot
  rebuild lost state pushes a `navigate` to a sane page. There is no
  `session_expired` message — idle expiry on the server is indistinguishable
  from a restart as seen from the device, and both are handled by the one
  mechanism

### Trust model

Trusted network only — as a decision, not an omission. v1 assumes LAN or
Tailscale, the protocol carries no authentication, and secrets live
server-side. The named-but-unbuilt hardening is an optional per-server bearer
token in the picker, sent as an HTTP header and a WS connect parameter —
additive when wanted. Untrusted page servers remain a non-goal; if that ever
changes, the action registry is the enforcement point.

---

## 5. The shell

The only screens compiled into firmware.

### Server picker

The first screen at boot, because it must work before any network exists. Lists
saved servers, allows adding a new address, remembers the last used one and can
auto-connect.

Multiple servers is a first-class idea: one for Claude Code monitoring, one for
home automation, one for experiments. They are independent worlds — and they can
be open **simultaneously**. The device holds one WebSocket per server with open
applications, the switcher spans all of them, and the picker adds a world rather
than replacing the current one. The background rule already bounds traffic
regardless of server count: only the active application receives data, whichever
server it belongs to. A `session_id` lives inside its own connection, so
uniqueness across servers is a non-question.

### Index page

Fetched from the server root. It is an ordinary page with no special powers — by
convention it lists the applications available on that server. Because it is just
a page, the server author controls what it looks like.

### Application switcher

A list of open applications, invoked by a gesture or a dedicated key, grouped by
server when more than one world is connected. Each connected server's index is
always present. Switching is instantaneous because nothing is rebuilt.

### Navigation

Back and forward across a history stack, refresh of the current page, and a jump
to the index. With the 70-key keyboard attached, an address entry for going
directly to a page by path.

### Chrome and visual language

Every screen is the status bar over a content column. The status bar shows
connection state per connected server, battery, the clock, `notice` badges
from backgrounded applications, and the event-queue warning when deliveries
are at risk — it is the one place the system talks over an application.

Errors render in a shell-owned banner in the `error` token; applications never
build error UI (§4's promise, restated as chrome).

Spacing has tokens exactly as type and colour do — `sm`, `md`, `lg`, mapped per
device.

The server picker and the application switcher are themselves built from the
component library — the same vocabulary the applications use, which five
applications have already proven by the time the shell is built (§8). Nothing
in the shell is ad-hoc.

### Local actions

Handled entirely on-device, never round-tripped: brightness, volume, sleep, back,
switch application, close application.

---

## 6. Use cases

These are the applications that motivate the design. They are deliberately
different in shape, to keep the protocol honest.

### 6.1 Claude Code companion

The original motivation. Claude Code hooks write events to a file; a local daemon
serves them as an application.

- **Dashboard page:** tasks closed, tests passed and failed, review findings, a
  burn-down chart, projected completion time. Pure server-push into `stat-card`
  and `progress` components.
- **Question page:** when generation pauses awaiting an answer, the server pushes
  a `navigate` to a question page carrying the full prompt text and a
  `button-row` of choices, plus a `text-field` for free-form replies. The 5-inch
  screen shows the entire question rather than a truncated line, and the keyboard
  answers it.
- **Chat page:** a `chat-view` conversation with the session itself — send a
  message to Claude mid-run (the daemon injects it via the Agent SDK), watch the
  streamed reply arrive. The device becomes a two-way companion, not a read-only
  dashboard.
- Exercises: unsolicited push, navigation driven by the server, form submission,
  streaming replies into `chat-view`.

### 6.2 Home and sensor dashboard

Grid of `stat-card` components fed by MQTT or Home Assistant on the server side,
with `toggle` components for switching devices.

- Exercises: high-frequency updates, many subscribed widgets, toggle round-trips.

### 6.3 Robot telemetry and control

Live values from a UGV or arm, with a `button-row` for commands and a text field
for scripted instructions.

- Exercises: low-latency events, the need for immediate local button feedback,
  graceful degradation when the link drops.

### 6.4 Notes with Markdown

A `text-field` capturing into a note store, a `list-view` of recent entries,
and a `doc-view` reading page: tap a note, the server parses its Markdown and
pushes the block list. The device never sees Markdown source.

- Exercises: input state preservation across application switching — leave
  mid-sentence, switch away, come back, the text is still there — plus
  `doc-view` rendering and list → detail navigation.

### 6.5 Server-side status console

Disk, CPU, running services, with actions to restart them and a CPU-history
`chart`.

- Exercises: confirmation dialogs (`navigate` with `replace`), destructive
  actions requiring explicit acknowledgement, high-frequency push into
  `stat-card` and `chart`.

### 6.6 Server terminal

A `text-field` for the command, a `log-view` for the scrollback. Submit runs
the command on the server; output is pushed into the tail as it arrives.
**Command → output, not a PTY**: no cursor addressing, no keystroke streaming,
no vim — drawn as a design line, not a limitation to fix. The handler runs with
the server's privileges; the action registry bounds what a *page* can invoke,
never what a handler chooses to do, and this application makes that vivid —
trusted-LAN assumption applies in full.

- Exercises: the form-submit model at its purest, streaming output as repeated
  tail re-sends, the `mono` face, follow-tail scroll feel.

### 6.7 Wikipedia browser

A search page (`text-field` plus a `list-view` of results) and a single
parameterised article page (`/apps/wiki/article?t=...`) whose `doc-view`
content the server builds from the article source. Link blocks navigate
article to article, and the shell's history stack walks back through them.
The device never touches the internet — the server is the proxy, so the
trusted-LAN model is undisturbed.

- Exercises: parameterised pages, deep history stacks, `doc-view` link blocks,
  an external data source behind the server, and Cyrillic text in anger.

### 6.8 RoboFace agent

A port of the RoboFace project's conversation, typed instead of spoken. The
RoboFace server already speaks thin-client — JSON control frames plus binary
PCM over WSS to an M5Stack Core S3 — so the Slate handler fronts the same
orchestrator with a `chat-view`, adding the text interface RoboFace never had.
**No face**: the animated face stays RoboFace's own; Slate renders the
transcript, not the character. Voice waits on the audio seam (M15), whose
reference implementation is RoboFace's own wire.

- Exercises: streaming assistant replies, a live AI backend behind a handler.

### 6.9 Srotas feed

The personal news feed, re-hosted: a feed page (`list-view` of scored cards
with their interest-node tags) and a parameterised detail page — `doc-view`
summary, like/dislike `button-row`, and a `text-field` for the free-text
feedback that drives the weight-shift loop. The Slate handler sits in front of
the existing Srotas process; its collect → score → feedback loop is untouched.

- Exercises: nothing new — the first port to land entirely on the existing
  vocabulary, which is itself the test passing.

### 6.10 Lumi

The private persona, reachable from the device: a `chat-view` conversation
through her existing interface-independent core (the handler calls
`Core.reply()`; memory, emotion, and intent machinery untouched — Slate is
exactly the "growing interface" her architecture planned for). Mood and
closeness from the emotion channel land as status colour. Voice — her
Deepgram → core → ElevenLabs chain — waits on the same audio seam as 6.8.

- Exercises: a stateful persona behind `chat-view`; leave mid-conversation,
  switch away, return — the input-preservation promise applied to a
  relationship.

### 6.11 Telegram client

Deliberately minimal: **one conversation, just chat**. A single page with a
`chat-view` and a `text-field`; which peer it talks to is server configuration
(Telethon; the Lumi telegram bridges are prior art). No chat list, no media,
no stickers — text in, text out. Incoming messages while the application is
backgrounded arrive as `notice` badges — even a one-chat messenger makes
that message type earn its keep.

- Exercises: high unsolicited push volume, and the background-notification gap
  in anger.

### 6.12 Markdown browser

A read-only browser over a directory of `.md` files on the server — a docs
folder, an Obsidian vault, a repository's documentation. A `list-view` of
folders and files (parameterised by `?path=`), a `doc-view` reader page; the
server walks the tree and parses the Markdown. Links between files become
`doc-view` link blocks.

- Exercises: `doc-view`'s first outing, hierarchical navigation on
  parameterised pages, list → detail at depth. Forces nothing beyond the
  vocabulary — and Wikipedia (6.7) is exactly this shape plus search and an
  external source.

### The first five applications

Each application is its own roadmap step (§8), placed at the earliest point
the platform can carry it — and each formalises the components it forces into
the library as part of its own step. (M0's counter precedes them all — a
throwaway proof of the concept, not a member of this list.)

1. **Status console** (step M4 — the live channel's first consumer) — pure
   `subscribe`/`data` push, no input. Brings `chart`.
2. **Server terminal** (step M6 — the event loop's first consumer) — the
   first app with events and form values. Brings `text-field`, `button-row`,
   `log-view`, and puts the `mono` face to work.
3. **Markdown browser** (step M7 — hierarchy and reading) — folders, files,
   reader, links between files. Brings `list-view` and `doc-view`.
4. **Wikipedia browser** (step M8 — the M7 shape plus search and an external
   source) — article-to-article navigation, history at real depth. Brings
   nothing: the first application the library already carries whole.
5. **Notes with Markdown** (step M10 — right after the shell its signature
   proof needs) — capture, list → detail, input preservation. Brings nothing;
   its contribution is the proof.

That each component is traceable to a named application demanding it is the
vocabulary discipline working as intended — in the spec and in the build
order alike. The companion (6.1) is step M11, whole — dashboard, question
page, and chat — bringing `chat-view` and `progress`; by then every other
mechanism it needs has been proven by the five above.

A **second wave** of ports follows the flagship, all chat-shaped and all
riding the `chat-view` the companion paid for: the RoboFace agent (6.8), the
Srotas feed (6.9), Lumi (6.10), and the Telegram client (6.11). All of them
are **optional steps beyond the complete platform**: Srotas and Telegram as
M13–M14, generated by the authoring loop; RoboFace and Lumi as M16–M17 on the
M15 audio seam — one design serving all of them, made when it is next, not
before.

---

## 7. Authoring workflow

The workflow this platform exists to enable.

```
Markdown description  →  Claude Code  →  page XML  →  validator  →  server
```

1. A human writes a Markdown description of the application: what it shows, what
   data it needs, what the user can do.
2. Claude Code reads the component library and the action registry, then writes
   the page XML and a server-side handler stub.
3. A validator script renders the XML headlessly and reports errors.
4. Claude Code fixes and re-runs until clean, without human involvement.
5. The page is dropped into the server's page store. It is live immediately.

### Validator

A command-line tool built from LVGL compiled for the host (macOS or WebAssembly).
It takes an XML file and:

- validates against the schema and the component library
- confirms every referenced action exists in the registry
- confirms every dynamic `id` is unique within the page
- renders to PNG at target resolution for visual inspection
- exits non-zero with readable errors

This closes the agent's feedback loop. Without it, generation produces plausible
XML that fails on hardware, and every page needs human eyes. With it, the agent
self-corrects.

### Action registry

A declared list of action names the firmware implements, and the server-side
handlers that respond to them. The agent may reference actions; it may never
invent them. This is the security boundary: a generated page cannot do anything
the firmware was not already built to do.

---

### Repository layout

One repository. The component definitions and the action registry are a
contract with three consumers — firmware, server, validator — and in one repo
they cannot drift apart. The authoring agent sees the entire platform in a
single checkout.

```
slate/
  specification/   this document, the UI briefs + implementation guide,
                   and the design canvas exports
  components/      component definitions + action registry (the contract)
  firmware/        ESP-IDF project, Tab5 first
  server/          Python reference server + Claude Code companion daemon
  validator/       host LVGL build and CLI
  apps/            page store the reference server serves
```

---

## 8. Implementation plan

Ordered by risk, not by size. M0 carries the walking skeleton, every
proof-of-concept, and the test scaffolding; each step after it adds
functionality the platform did not have before — no rung exists to formalise
or re-record what an earlier one proved. Platform steps and **application
steps interleave**: every application is its own step, landing at the earliest
point the platform can carry it. And the component library is not a late
milestone: its machinery lands early (M3), and each application step
formalises the components it forces into `components/` as part of its own
step — the library grows app by app, and nothing is ever built ad-hoc to be
migrated later. Each step is independently testable and ends with something
running. *Done when* is the exit gate — demonstrable on hardware (or, for
M12, on the host), never a code review.

How applications run **before the shell exists** (M9): the device is a
single-application terminal. The server address and the start page live in
firmware config — M0's pattern, kept — so at M4 the console is simply the
page the device boots into. From M5, navigation makes the server's **index**
the natural start page: boot, land on the index, navigate into an
application, `back` or `root` out — still one session at a time, no picker,
no switcher, and no state retained across leaving an application. That is
precisely what M9 adds, and why the input-preservation proof (M10) waits
for it.

**M0 — Walking skeleton (the concept on the desk, and every proof with it).**
One very simple application alive end to end — and every proof-of-concept
the platform needs, concentrated in one milestone. Everything inessential is
sacrificed and the code is allowed to be throwaway; the demo, the recorded
verdicts, and the test scaffolding are the deliverables.

- Minimal bring-up: Tab5 BSP, LVGL, `LV_USE_XML` — the first informal answer
  to the P4 question falls out here, because nothing renders without it.
- A single-file Python server (~150 lines): one page over HTTP, a trimmed
  wire over WS — `subscribe`, `data`, `event`, nothing else.
- One page fetched from the server at boot; no cache, no revalidation; the
  server address hard-coded in firmware config.
- The app — a **counter**: a plain value label shows a number owned by the
  server, a button sends `increment`, the server pushes the new value back. A
  second label ticks with the server's clock — unsolicited push, proven on day
  one. (No components exist yet — these are raw widgets; `stat-card` arrives
  at M3.)
- **`doc-view` v0**, throwaway but proving the heaviest renderer early: the
  server parses one hard-coded `.md` file into typed blocks and pushes them
  as an `items` update; the device renders them as a scrollable column of
  labels — headings larger, bullets prefixed, code on a shaded ground. No
  component, no links, no tokens — just proof that a variable-length document
  renders and scrolls acceptably on the P4. With it, the trimmed wire
  exercises both update shapes: scalar (`text` on the counter) and structured
  (`items` on the document).
- No sessions in plural, no `navigate`, no error overlay, no shell, no
  components, no tokens. One screen, one app, one server.
- **The UI, in full:** three firmware-drawn states — a plain `connecting…`
  label at boot, a plain error text when the server is unreachable, the page
  once it arrives — plus the page itself: raw LVGL widgets, not components
  (a title label, the count, the clock, one button, and a scrollable document
  region below), LVGL's default theme and font, lv_xml's native flex
  attributes for centring. The philosophy must be
  visible on screen: the button's pressed state is instant and local, while
  the number changes only when the server's `data` frame returns. Full brief:
  [ui-m0-brief.md](ui-m0-brief.md); [ui-implementation.md §6](ui-implementation.md).

  ```
  ┌────────────────────────────────┐
  │           Slate  M0            │
  │              42        [ +1 ]  │   counter + button (event path)
  │           19:04:33             │   clock (unsolicited push)
  │  ┌──────────────────────────┐  │
  │  │ # Heading                │  │
  │  │ Paragraph text…          │  │   doc-view v0: scrollable label
  │  │ • bullet                 │  │   column from server-parsed .md,
  │  │ ▒ code line ▒            │  │   pushed as one items update
  │  │          ⋮  (scrolls)    │  │
  │  └──────────────────────────┘  │
  └────────────────────────────────┘
  ```
- **The PoC ledger**, written at exit: the `lv_xml` go/no-go verdict — the
  no-go fallback being a vendored ~6 KB SAX parser with the vocabulary
  hand-mapped to `lv_*` calls, every design decision surviving — plus page
  parse time, widget-tree heap cost, render time and scroll feel for a
  ~50-block document, and the panel revision (ILI9881C vs ST7123/ST7121) as
  probed by the BSP.
- **Test scaffolding**, seeded here and only ever extended later: a pytest
  suite for the server and a fake-device script under `tools/` driving the
  wire from the host. No later step introduces a harness; they all inherit
  this one.

*Done when:* power on → the page appears from the server → the clock ticks →
the button increments the count → the document renders and scrolls under a
finger — and rebooting the device does not reset the counter, because the
count never lived on the device. The whole concept,
demonstrated in one screen — with the ledger written and the scaffolding
green on the host.
*Out of scope:* everything else, deliberately — M1 onward builds the same
loop honestly.

**M1 — Static fetch.**
Replaces M0's naive fetch with cache honesty — and the first kept code.

- The kept `firmware/` and `server/` trees start here, versions pinned. M0's
  code is quarry, not foundation.
- `server/` skeleton: Python asyncio; the aiohttp-vs-FastAPI choice is made
  here and recorded in §2; serves page XML from `apps/` with a content-hash
  `ETag`.
- WiFi bring-up; HTTP client; conditional GET with `If-None-Match`; SD cache
  keyed by base path, storing body and `ETag` together.
- All three paths render something sensible: `200` (fetch, cache, render),
  `304` (render cache), offline (render cache; a plain error screen only when
  there is no cache either).

*Done when:* a cold fetch renders; a warm activation revalidates with a `304`;
an edited page on the server replaces the cache on next activation; WiFi off
renders from cache.
*Out of scope:* WebSocket, sessions, anything dynamic.

**M2 — Live channel.**
M0's trimmed wire grown into the real protocol: `subscribe` → `data`,
sessions, reconnection.

- WS endpoint honouring `?proto=&screen=`; a `proto_mismatch` close renders as
  the plain mismatch screen, never a hang.
- Frame codec and dispatcher on the device: JSON in text frames; unknown types
  and keys ignored; binary frames left reserved so M15 is not precluded.
- Device-minted `session_id`; lazy session creation in the server's registry.
- `subscribe` on page activation driving the loading state; the applicator:
  an id → widget map built at render time, the eight-property switch, unknown
  ids dropped with a debug log.
- Handler API v0 on the server (`async` handler, `session.update(...)`) and a
  minimal push demo — one raw-widget value fed by a ticking value; M3 rebuilds
  it on real components, M4 replaces it with a real application.
- Reconnect with backoff; the active page re-subscribes on reconnection.

*Done when:* a pushed value renders live; killing and restarting the server
mid-run reconnects, re-subscribes, and resumes values with no user action; a
version-mismatched server produces the mismatch screen.
*Out of scope:* events, navigation, a second session.

**M3 — Component system.**
The design system's machinery, early — so every application after it is built
on real components and nothing is ever migrated later.

- `<component>` definitions loading from `components/`: declared props only,
  the three states (empty / loading / ready) built into the base once.
- The token system in firmware: colour tokens with light and dark values,
  font roles, spacing tokens, the per-device role → size map.
- Fonts compiled once, both faces: the UI face and `mono`, Latin + Cyrillic +
  symbols, the size ladder, tabular figures for `stat-value`.
- The machine-readable manifest, seeded — components, props, dynamic
  properties, actions — and growing with every component added after; the
  validator (M12) and the agent read it as ground truth.
- The seed components, proven by rebuilding M0's counter page on them:
  `page-header`, `text-block`, `stat-card`.
- `toggle` and `image-view` wait for the first application that demands them
  (the home dashboard, most likely) — the growth discipline applies to build
  order too.

*Done when:* the counter page is reborn with zero raw widgets; the dark/light
flip is global and instant; a component instantiates from XML by declared
props alone; the manifest describes everything that exists.

**M4 — Application: status console.**
The live channel's first real consumer (6.5) — read-only, pure push.
Brings `chart` into the library.

- One page: a `stat-card` grid (CPU, memory, disk, uptime) and a CPU-history
  `chart`; psutil behind the handler, pushing once a second.
- No input, no navigation — the pressure lands on update volume and render
  cost instead. 6.5's restart actions and their confirmations arrive free once
  M5's events exist — an enhancement to this app, not a step.

*Done when:* the console runs untouched for an hour with a stable heap; a
server restart resumes the cards unprompted; the chart scrolls its history.

**M5 — Events and navigation.**
The full loop: user acts, server decides, screen changes.

- `event` with `action` / `source` / `values`; input collection walks the
  page's fields; fire-and-forget.
- The bounded outbound queue: drop-oldest past the limit, and the user told —
  a provisional indicator until M9's status bar exists.
- `navigate` in both directions, all four modes, the history stack, and
  parameterised paths (structure cached by base path; the full path lives in
  history and `subscribe`).
- `error` rendering in a first-pass overlay.
- Action registry v0: a declared file in `components/`, each name marked
  local or server — loaded by firmware, read later by the agent.
- Two throwaway pages joined by a button, exercising push/back and a
  server-sent `navigate` — M6 and M7 replace them with real applications.

*Done when:* button navigation and back work across two pages; `values`
arrives complete on submit; a WiFi drop mid-typing queues events and shows the
warning, and reconnection flushes the queue in order; a server-pushed
`navigate` lands unprompted.
*Out of scope:* the switcher, multiple sessions, the picker.

**M6 — Application: server terminal.**
The event loop's first real consumer (6.6): command → output, never a PTY.
Brings `text-field`, `button-row`, and `log-view` into the library, and puts
the `mono` face to work.

- A command `text-field` and a `log-view` scrollback; submit runs the command
  on the server, output arrives as tail re-sends.

*Done when:* a long directory listing streams into the scrollback; follow-tail
holds unless the user scrolls up; a command fired during a WiFi drop queues,
warns, and executes on reconnect.

**M7 — Application: Markdown browser.**
Hierarchy and reading (6.12): a directory of `.md` files on the server,
browsed and rendered. Brings `list-view` and `doc-view` — link blocks
included, ahead of the app that first demanded them. M0's throwaway renderer
already proved the block model; here it becomes a real component.

- A parameterised listing page (`?path=`): a `list-view` of folders and
  files; a tap descends into a folder or opens a file.
- A reader page rendering server-parsed Markdown into `doc-view` blocks;
  links between files arrive as link blocks.

*Done when:* descend two folders, open a file, follow a link to another file,
and back retraces every step; headings, bullets, and code render as typed
blocks; a directory of real notes (an Obsidian vault will do) browses
comfortably.

**M8 — Application: Wikipedia browser.**
The M7 shape plus search and an external source (6.7): history at real depth.
Brings nothing — the first application the library already carries whole.

- A search page (`text-field`, results `list-view`) and one parameterised
  article page; the server converts article source to `doc-view` blocks; link
  blocks navigate article to article.

*Done when:* search → article → link → link → back → back retraces exactly;
Cyrillic articles render; the device never touches the internet — the server
proxies everything.

**M9 — Shell.**
The device becomes a terminal for many applications at once — assembled from
the component library it inherits, nothing ad-hoc. Brings `status-bar`.

- Server picker: saved servers, add/edit, auto-connect to the last used.
- Sessions in plural: one `lv_screen` per open application, the open-limit
  with oldest-first eviction, explicit close.
- The switcher, grouped by server; one WS per connected server; each server's
  index always present.
- The background rule enforced: only the active session is subscribed;
  switching back re-subscribes; `notice` badges surface backgrounded sessions
  and a tap switches to them.
- The status bar complete: per-server connection, battery, clock, queue
  warning, notice badges. The error overlay in its final session-scoped form.
- Keyboard: the Macintosh port’s I2C driver (`0x6D`, matrix-event) adopted
  as-is; the shell key map — back, switcher, submit, address entry — defined
  against the screens it drives; text editing in fields.
- Local actions complete: brightness, volume, sleep, back, switch, close.

*Done when:* three applications (there are four to pick from now: console,
terminal, the two browsers) across two servers switch instantly with scroll
and half-typed text intact; killing one server marks only its own
applications disconnected; a `notice` from a backgrounded session badges the
status bar and a tap lands in that application; the whole shell is drivable
from the keyboard alone.

**M10 — Application: notes with Markdown.**
The shell's first real consumer (6.4) — and the platform's signature, proven.
Brings nothing; its contribution is the proof.

- A capture `text-field` and a recent-notes `list-view`; a parameterised
  reader page rendering server-parsed Markdown into `doc-view` blocks.

*Done when:* leave mid-sentence, switch to another application, come back —
the draft is intact; a note with headings, bullets, and code renders as typed
blocks; capture → list → reader → back flows without a page re-send.

**M11 — Application: Claude Code companion (the flagship).**
The original motivation (6.1), whole: dashboard, question page, chat.
Brings `chat-view` and `progress` into the library.

- Hooks write events; the daemon serves them: a dashboard of `stat-card`s,
  `progress`, and a burn-down `chart`.
- The question page: a mid-run question arrives as a server-pushed `navigate`
  — full prompt text, a `button-row` of choices, a `text-field` for free-form
  replies.
- The chat page on `chat-view`: messages injected into the session via the
  Agent SDK, replies streamed back by tail re-send.
- `notice` when a question or completion lands while the companion is
  backgrounded.

*Done when:* a real Claude Code run drives the dashboard; a mid-run question
lands as a `navigate`, is answered from the keyboard, and generation resumes;
chat round-trips with streamed replies — all while other applications stay
open and intact.

**M12 — Validator and authoring loop.**
Closes the agent’s feedback loop: a page is proven without hardware.

- Host build of LVGL sharing the firmware’s renderer layer — same `lv_xml`,
  same components, same applicator; SDL or a headless framebuffer.
- `slate-validate page.xml`: manifest and schema checks, unknown components
  and props, action names against the registry, id uniqueness, token and role
  names, the raw-hex warning; renders PNG at target resolution; non-zero exit
  with errors a human and an agent can both read.
- The authoring workflow: a prompt/skill that reads the manifest and registry,
  writes the page plus a handler stub, runs the validator, iterates to clean.
- CI runs the validator over every page in `apps/` on every commit.

*Done when:* seeded errors (unknown component, bad action, duplicate id, raw
hex) each fail with a readable message; a sample page written by the agent
from a Markdown description passes clean and runs on hardware unmodified; CI
is green over `apps/`. The first real generated application is M13 — the
first of the optional steps.

Everything below this line is **optional**. The platform is complete at M12
— shell, component library, flagship, and the authoring loop. M13–M17 are
ports, undertaken when wanted: M13 and M14 in any order once M12 exists; M16
and M17 only after M15.

**M13 (optional) — Application: Srotas feed (the first generated one).**
Written by the authoring loop, not by hand — it forces nothing, which is why
it goes first (6.9).

- Generated from a Markdown description: the feed `list-view` of scored cards,
  a parameterised detail page, like/dislike `button-row`, free-text feedback
  `text-field`. The handler fronts the existing Srotas process; its collect →
  score → feedback loop is untouched.

*Done when:* the generated page passes the validator untouched by hand and
runs on hardware; feedback from the device shifts weights end to end.

**M14 (optional) — Application: Telegram client (generated).**
One conversation, just chat (6.11) — the second generated application.

- A single page: `chat-view` plus a send `text-field`; Telethon behind the
  handler; the peer chosen in server configuration.

*Done when:* messages flow both ways; an incoming message while the chat is
backgrounded badges the status bar via `notice`, and a tap lands in the
conversation.

**M15 (optional) — Audio seam.**
Voice for the final ports, designed when its consumers arrive.

- The contract first, as a design doc: binary WS frames tagged with session
  and stream, PCM16 format and rate, start/stop control in JSON, backpressure.
  RoboFace’s wire (JSON control + binary PCM16 over WSS) is the reference.
- Firmware capture and playback on Tab5’s mic and speaker; push-to-talk as a
  local action — no wake word.
- The server-side audio router, proven with an echo handler — the real
  consumers are the next two steps.
- `chat-view` voice affordances: mic state, a speaking indicator.

*Done when:* a held key streams mic PCM to the server and a server-sent clip
plays back — the echo round-trip on hardware; text-only chat is byte-identical
when audio is absent.
*Out of scope:* wake word, barge-in (Lumi’s queue-not-discard pattern can
follow later), any codec beyond PCM16 until bandwidth demands one.

**M16 (optional) — Application: RoboFace agent.**
The conversation, typed and spoken (6.8) — the audio seam's first real
consumer.

- `chat-view` against the existing RoboFace orchestrator: typed chat is the
  interface RoboFace never had; voice rides the M15 seam, push-to-talk. No
  face — the transcript, not the character.

*Done when:* a held key speaks and the reply returns as streamed text and
audio together; typed chat works identically with audio absent.

**M17 (optional) — Application: Lumi.**
The private persona on the device (6.10) — the roadmap's last step.

- A generated chat page over her existing `Core.reply()` — memory, emotion,
  and intent machinery untouched; mood and closeness land as status colour.
- Voice through her own chain — Deepgram → core → ElevenLabs — on the M15
  seam.

*Done when:* a text conversation with Лілі survives switching away
mid-thought and returning; voice mode round-trips on the seam; the emotion
channel visibly colours the page.

Ship M0 before designing anything further — it is the cheapest possible
collision with the one question that can change everything. If the XML module
does not work on P4, M0 finds out in its first days and chooses the fallback
in its exit ledger; everything after inherits that verdict instead of
re-litigating it.

---

## 9. Open questions

One remains, and only hardware can answer it:

- **XML module on P4.** Unverified. M0 exists to answer it: the verdict, the
  measurements, and the panel-revision probe (ILI9881C vs ST7123/ST7121) all
  land in its exit ledger.

Everything else this section once held has been decided and folded into the
sections above: sessions, reconnection, versioning, caching, parameterised
pages, assets, fonts, colour, layout and its portability policy, the keyboard,
the trust model, the `notice` message, and the audio seam's direction (M15).
