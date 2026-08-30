# Slate — UI Design Brief for Claude Design

**What is being designed:** the screens of Slate, a thin-client "mainframe
terminal" for the M5Stack Tab5 — a 5-inch **1280×720 landscape** touch device
with an attachable 70-key keyboard. The device renders pages sent by a server;
all logic lives server-side. The UI must feel calm, instrument-like, and
legible at arm's length: a desk terminal, not a phone.

**Canvas setup:** every artboard is **1280×720 landscape**. The **light
theme is primary**; as built, both themes exist as full canvases, so the token
flip is proven end to end rather than by a single variant board.
All values below are the proposed defaults — they map 1:1 onto the platform's
token system, so changing them later is a palette swap, not a redesign.

---

## Part 1 — Design language

### Colour tokens

| Token | Dark | Light (primary) | Used for |
|---|---|---|---|
| `surface` | `#161513` | `#f5f2ea` | screen background |
| `surface-2` | `#211f1c` | `#ffffff` | cards, bars, input fields |
| `text` | `#e8e4da` | `#242220` | primary text |
| `muted` | `#8a857a` | `#7a756a` | labels, captions, secondary text |
| `accent` | `#e8a33d` | `#c07f1a` | interactive highlights, links, focus |
| `ok` | `#7fb069` | `#4a7a3a` | healthy values, success |
| `warn` | `#e8a33d` | `#b3721a` | warnings, elevated values |
| `error` | `#d95d4e` | `#b03a2e` | errors, critical values, danger buttons |

Warm, low-saturation, slightly amber-tinted — instrument panel, not neon
dashboard. Colour is used sparingly: most of the screen is `text` on
`surface`; `accent`/`ok`/`warn`/`error` appear only where they carry meaning.

### Type

Two faces only, both with full **Latin + Cyrillic** coverage:

| Role | Face | Size | Use |
|---|---|---|---|
| `title` | Noto Sans SemiBold | 28 px | page titles, headers |
| `body` | Noto Sans Regular | 22 px | paragraphs, list rows, buttons |
| `caption` | Noto Sans Regular | 17 px | labels, metadata, status bar |
| `stat-value` | Noto Sans SemiBold, **tabular figures** | 44 px | big live numbers |
| `mono` | JetBrains Mono Regular | 19 px | terminal, code blocks |

### Spacing, shape, touch

- Spacing tokens: `sm` 8 px · `md` 16 px · `lg` 24 px. Screen edge padding `lg`.
- Cards and inputs: 12 px corner radius, `surface-2` fill, no borders in dark
  (1 px `#00000014` border in light). No drop shadows — flat, crisp.
- Touch targets ≥ 48 px tall. Buttons: 52 px tall, radius 10 px; primary =
  `accent` fill with dark text, default = `surface-2`, danger = `error` fill.
- Layout is rows and columns only — no free-floating elements, nothing
  overlapping except the switcher overlay and error banner.

### Widget states (design each once, reuse everywhere)

Every live element has three states: **empty** (value shows `—`, muted),
**loading** (value at 40 % opacity with a subtle pulse), **ready** (full
colour). Show the state trio once on the console board as a small legend.

---

## Part 2 — The shell (system chrome)

### Status bar — on every screen except M0

40 px tall strip across the top, `surface-2`:

- Left: current server + app, `caption` muted — `mac-mini · Console`
- Right, in order: **notice badge** (accent dot + count, e.g. `● 2` — only
  when backgrounded apps have notices), **queue warning** (`⚠ 3 queued`, warn
  colour — only when events are queued offline), one **connection dot per
  connected server** (ok = green, reconnecting = warn, dead = error),
  **battery %**, **clock** `19:04`.

### Error banner

Slides down over the status bar: `error`-tinted strip, 56 px, white text,
`caption` code + `body` message, dismiss `✕` on the right. One consistent
banner for every application — apps never draw their own errors.

### Artboard S1 — Server picker

The first screen at boot. Centered column, max-width ~640 px:

- Wordmark `Slate` (`title`, muted) at top.
- Card list of saved servers: name (`body`), address (`caption` muted),
  connection dot; the last-used server row carries an `auto` tag.
  Rows: `mac-mini — 192.168.1.20:8443 ● ` / `home-pi — 192.168.1.31:8443 ○`.
- `+ Add server` row (accent text).
- Bottom hint (`caption`, muted): `⌥ hold — switcher · esc — back`.

### Artboard S2 — Application switcher (overlay)

Dimmed scrim (60 % black) over the current screen; centered panel ~800×520,
`surface-2`, radius 16. Contents grouped **by server**:

```
mac-mini ●
   ▸ Index          Console          Terminal
home-pi ●
   ▸ Index          Telegram ● 2
```

Each app is a tile: name (`body`), small live-state line (`caption` muted,
e.g. `CPU 43 %` or `2 new`), close `✕` in the corner. Active app tile has an
accent outline. Index tiles are always first per server and have no close.

---

## Part 3 — The first applications

All boards include the status bar. Realistic content only — no lorem ipsum.
Cyrillic must appear somewhere on most boards (the platform is bilingual).

### Artboard A1 — Status console

Read-only dashboard, one screen, no scrolling:

- Header row: `Console` (`title`) + `Updated 19:04:31` (`caption` muted).
- Grid of 4 stat-cards (2×2, left half): CPU `43 %` (ok), Memory `11.2 GB`
  (ok), Disk `82 %` (warn), Uptime `14 d` (muted). Card = label (`caption`
  muted) above value (`stat-value`) with unit.
- Right half: CPU history line chart, last 60 s, accent line on `surface-2`
  card, y-axis 0–100, no legend, no gridlines beyond two faint horizontals.
- Include the small state-trio legend (empty / loading / ready) at the bottom
  of this board only, as a designer's reference.

### Artboard A2 — Server terminal

- Output area fills the screen: `mono` on `surface` (slightly darker inset
  panel), last ~24 lines of a real `ls -la` plus a `git status` output.
  Auto-follows the tail; a thin scrollbar hints scrollback.
- Bottom bar: prompt `$` + input field (`mono`, `surface-2`, 52 px) +
  `Run` primary button. Input shows a half-typed command with cursor.
- No tabs, no fonts menu, no PTY affordances — this is command → output.

### Artboard A3 — Markdown browser · listing

- Header: `page-header` with back chevron + current path `notes/projects/`
  (`title`, path tail; `caption` muted full path above).
- File list, full-width rows 56 px: folder rows (`▸ name`, count `caption`),
  file rows (`name.md`, modified date `caption` muted right-aligned).
  8–10 rows, one row pressed state shown (accent tint 8 %).

### Artboard A4 — Markdown browser · reader

- `page-header`: back chevron + `slate-vision.md`.
- Document column, max-width ~880 px, centered: `h1` (title role), paragraph
  (`body`, 1.5 line height), a bulleted list, a fenced code block (`mono` on
  inset panel), a `quote` block (accent left rule, muted text), one **link
  block** (accent text, chevron) → this is how links look; they are
  block-level, never inline.
- Content suggestion: the opening of this very spec, mixed EN/UK.

### Artboard A5 — Wikipedia · search

- Centered column: `Вікіпедія` (`title`), search field (56 px, placeholder
  `Пошук…`) with keyboard focus ring (accent), `Search` primary button.
- Below: results list-view rows — article title (`body`) + first-line snippet
  (`caption` muted). Query shown: `Львів`, 6 results, Cyrillic titles.

### Artboard A6 — Wikipedia · article

Same skeleton as A4 (this is the point — one reading experience):
`page-header` back + `Львів`, doc-view blocks with an `h1`, paragraphs in
Ukrainian, an `h2` `Історія`, and 3 link blocks (`Галичина ›`,
`Площа Ринок ›`, `УНР ›`).

### Artboard A7 — Notes · capture and list

- Top: capture card — multi-line text-field (~120 px, `surface-2`) holding a
  **half-typed sentence with a visible cursor** (`Ідея для Slate: статус-бар
  повинен пок▌`) + `Save` primary button to its right. This half-typed state
  is the platform's signature — make it deliberate, not accidental.
- Below: `Recent` (`caption` muted) + list-view of notes: first line
  (`body`), date (`caption` muted, right). 6 rows, EN/UK mixed.

### Artboard A8 — Companion · dashboard

The flagship. Claude Code session monitoring, push-fed:

- Header: `Claude Code` (`title`) + session id + `● running` (ok).
- Stat row (4 cards): Tasks `7 / 12`, Tests `128 ✓ 3 ✗` (the 3 in error
  colour), Findings `2` (warn), ETA `~40 min` (muted).
- Left-bottom: burn-down chart (accent line, muted ideal line) on a card.
- Right-bottom: activity feed card — last 5 events (`caption`, timestamped):
  `19:02 ✓ tests passed (unit)`, `18:57 ⚠ review finding: unused import`, …
- One `progress` bar across the bottom: current task name + determinate bar.

### Artboard A9 — Companion · question

A full-screen interrupt pushed by the server when Claude asks something:

- `caption` muted eyebrow: `Claude Code · awaiting your answer`.
- The full question (`body`, up to ~6 lines — the point of the 5-inch screen
  is showing the *whole* question): use a real-looking one, e.g. a choice
  between two migration strategies.
- `button-row`: up to 3 choice buttons (first = primary) + a free-form
  text-field beneath (`Or answer in your own words…`) + `Send`.

### Artboard A10 — Companion · chat

- chat-view: role-aligned bubbles — user right (`surface-2`),
  assistant left (accent-tinted 10 % fill). 4–5 messages of a plausible
  exchange about the running task; the last assistant bubble is **streaming**:
  partial text + subtle pulsing `▌` and a muted `…typing` indicator.
- Bottom bar: text-field + `Send` primary (same pattern as terminal input).

### Artboard V1 — Light theme variant

The status console (A1) rebuilt with the light column of the token table —
identical layout, values, and geometry. This board exists to prove the
palette is a swap, not a redesign.

---

## Board inventory (15)

S1 picker · S2 switcher · A1 console · A2 terminal · A3 md listing ·
A4 md reader · A5 wiki search · A6 wiki article · A7 notes ·
A8 companion dashboard · A9 companion question · A10 companion chat ·
V1 light variant · plus a small board for the **error banner** and one for
the **status-bar states** (all badge/warning permutations) if space allows.

The M0 walking-skeleton prototype is deliberately *not* on this canvas — it
predates the design system and is described separately in
[ui-m0-brief.md](ui-m0-brief.md).
