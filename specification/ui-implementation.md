# Slate — UI implementation guide

**Audience:** Claude Code, implementing the renderer, the token layer, the
component library, and the page store.
**Source of truth for visuals:** the three design canvases in this project —
`Slate Product UI - Light.html` (primary), `Slate Product UI - Dark.html`
(dark variant), `Slate M0 Prototype.html`. Board ids (`F1`, `S1`, `A1`…) are
referenced throughout; when this document and a board disagree, the board wins
for *appearance* and this document wins for *structure*.

**Non-goal:** this is not a restatement of `specification/slate-vision.md`. It
describes only how the designed screens become tokens, components, and page
XML. Protocol, sessions, and caching are the vision spec's business.

---

## 1. What the design decided, in one paragraph

Light theme is primary; dark is a token flip, not a second design. Every screen
is a 40 px status bar over a content column padded `lg` (24 px). There are no
coordinates, no overlapping elements, and no shadows — the layout is rows,
columns, and gaps. Colour appears only where it carries meaning; the other 95 %
of every screen is `text` on `surface`. Five type roles and three spacing
tokens cover all fifteen boards. If a screen needs a sixth role or a pixel
value, that is a design bug, not a firmware feature.

---

## 2. Token layer (M3 / phase v1.3, `firmware/src/tokens.c`)

### 2.1 Colour

Two tables, one enum, one active pointer. Flipping theme swaps the pointer and
invalidates the display — no widget is rebuilt, no server is told.

```c
typedef enum {
  TK_SURFACE, TK_SURFACE_2, TK_TEXT, TK_MUTED,
  TK_ACCENT, TK_OK, TK_WARN, TK_ERROR,
  TK__COUNT
} slate_color_t;

static const uint32_t tk_light[TK__COUNT] = {
  0xf5f2ea, 0xffffff, 0x242220, 0x7a756a,
  0xc07f1a, 0x4a7a3a, 0xb3721a, 0xb03a2e,
};
static const uint32_t tk_dark[TK__COUNT] = {
  0x161513, 0x211f1c, 0xe8e4da, 0x8a857a,
  0xe8a33d, 0x7fb069, 0xe8a33d, 0xd95d4e,
};
```

Names on the wire are the lowercase enum tails: `"color": "warn"`. Unknown
names are dropped with a debug log, never a crash — same rule as unknown ids.

Two derived values the boards need and the table does not carry:

| Derived | Light | Dark | Used by |
|---|---|---|---|
| hairline (card border) | `#00000014` | *none* | card/input outline — **light only**, see 2.4 |
| pressed tint | `accent` @ 8 % | `accent` @ 8 % | list row press (`A3`) |
| inset ground | `#eeeae0` | `#100f0e` | terminal panel, code blocks |
| scrim | `#000000` @ 60 % | same | switcher overlay (`S2`) |

Note `accent` and `warn` are the same hex in dark and differ in light. Keep
both enum entries anyway — a page says what it *means*, and the light table is
what proves the distinction matters.

### 2.2 Type

One UI face and one mono face, both Latin + Cyrillic + LVGL symbols, compiled
at exactly these sizes. No other size may be compiled in: the ladder is the
contract that lets a page land on a second screen size later.

| Role | Face | Size | Weight | Notes |
|---|---|---|---|---|
| `title` | Noto Sans | 28 | SemiBold | page titles, `h1`/`h2` doc blocks |
| `body` | Noto Sans | 22 | Regular | paragraphs, list rows, button labels |
| `caption` | Noto Sans | 17 | Regular | labels, metadata, status bar |
| `stat-value` | Noto Sans | 44 | SemiBold | **tabular figures required** |
| `mono` | JetBrains Mono | 19 | Regular | terminal, code blocks |

`stat-value` without `LV_FONT_FMT_TXT_...` tabular digits will visibly jitter
on the console at 1 Hz — that is the single most noticeable rendering defect
available to this project. Verify against `A1` before closing M3.

Line heights: `body` paragraphs 1.5 (33 px), `mono` 1.45 (28 px), everything
else 1.2. Set them once in the component base, never per page.

### 2.3 Spacing, shape, geometry

```
sm = 8   md = 16   lg = 24        radius_card  = 12
                                  radius_btn   = 10
screen padding      = lg          radius_panel = 16   (switcher only)
status bar height   = 40
button height       = 52          min touch target = 48
input height        = 56          list row height  = 56  (64 with a subtitle)
error banner height = 56
```

`radius_panel` exists for exactly one element. Do not generalise it.

### 2.4 The light/dark asymmetry — read this before styling a card

In dark, `surface-2` separates itself from `surface` by luminance alone: cards
have **no border**. In light, white on warm paper does not separate, so every
`surface-2` fill carries a 1 px `#00000014` hairline, and the status bar
carries a bottom hairline instead of a fill difference.

This is the only structural difference between the themes, and it must live in
the component base as a themed property, not in page XML:

```c
static void card_apply_theme(lv_obj_t *o) {
  lv_obj_set_style_bg_color(o, tk(TK_SURFACE_2), 0);
  lv_obj_set_style_radius(o, 12, 0);
  lv_obj_set_style_border_width(o, theme_is_light() ? 1 : 0, 0);
  lv_obj_set_style_border_color(o, lv_color_hex(0x000000), 0);
  lv_obj_set_style_border_opa(o, LV_OPA_10, 0);
  lv_obj_set_style_shadow_width(o, 0, 0);   /* flat, always */
}
```

If a page ever needs to know which theme is active, the abstraction has
failed.

---

## 3. Component library (`components/`)

Each component is one `<component>` definition plus one C applicator entry.
Props below are **static** (fixed in XML at author time); dynamic properties
are the closed protocol set and nothing else.

The three states — empty / loading / ready — are implemented **once**, in the
component base, and driven by the firmware:

```
render            -> empty     value renders "—" in `muted`
subscribe(id)     -> loading   value at 40 % opa, 1.6 s ease-in-out pulse
first data(id)    -> ready     full colour, pulse cleared
error(id)         -> error     value renders "—" in `error`
```

The board legend at the bottom of `A1` (and `V1`) is the reference rendering of
that trio. Ship it as a fixture in the validator's golden PNGs.

### 3.1 `page-header`
Static `title`, `back` (default true). Dynamic `text`, `visible`.
Row, height 56, gap `md`: back chevron `‹` in `muted` at `title` size (48 px
hit box) · optional path eyebrow in `caption`/`muted` above the title · title
in `title` · optional right-aligned meta slot in `caption`/`muted`.
The chevron fires the **local** `back` action. It never reaches the server.
Boards: `A3`, `A4`, `A6`.

### 3.2 `stat-card`
Static `label`, `unit`. Dynamic `text`, `color`, `visible`, optional `action`.
Card, padding 20, column, `space-between`: label in `caption`/`muted` on top,
value in `stat-value` at the bottom with the unit trailing it in `body`/`muted`.
Value and unit share a baseline; the unit never scales with the value.
Boards: `A1` (2×2 grid, left half), `A8` (row of 4).

### 3.3 `text-block`
Static `font` (role, default `body`), `align`. Dynamic `text`, `color`,
`visible`. Width-constrained by its parent; `text-wrap: pretty` equivalent is
LVGL's `LV_LABEL_LONG_WRAP`. No inline markup, ever.

### 3.4 `list-view`
Static `rows` (fixed count), `empty-text`, optional `action`. Dynamic `items`,
`visible`.
Rows are 56 px (single line) or 64 px (title + subtitle), separated by a 1 px
divider — hairline in light, `#2d2a26` in dark — with **no divider after the
last row**. Row press paints the pressed tint at `radius_card`; press feedback
is local and immediate, and the event carries `row` as an additive key.
Fewer items than rows hides the remainder. More are truncated: put the true
count in the section's right-hand `caption` slot (`6 of 6 rows` on `A5`, `A7`)
so truncation is never silent.
Boards: `A3` (folder/file rows), `A5` (title + snippet), `A7` (note + date).

### 3.5 `button-row`
One to four buttons; each has its own `id`, `label`, `action`, `variant`.
Height 52, radius 10, label in `body`, **horizontal padding 20–24**.

| Variant | Fill | Label |
|---|---|---|
| `primary` | `accent` | `text` (dark ink on amber, both themes) |
| `default` | `surface-2` (+ hairline in light) | `text` |
| `danger` | `error` | `#ffffff` |

Buttons stretch equally when the row fills its parent (`A9`); a trailing
action button beside an input keeps its intrinsic width (`A2`, `A5`, `A7`).
Pressed = one accent ramp step past base, applied locally on `LV_EVENT_PRESSED`
before any frame is sent. **Do not centre the label if you later widen a button
past its text** — but note the boards centre `Run`/`Send`/`Save` because those
buttons are sized to their labels; keep them centred and they read identically.

### 3.6 `text-field`
Static `label`, `type`, `required`, `readonly`, `maxlen`, `placeholder`.
Dynamic `value`, `enabled`, `visible`, `color`.
Height 56 (multi-line: min 120, `A7`), radius 12, `surface-2` fill, padding
`md`. Focused fields carry a **2 px `accent` ring** (`A5`, `A7`, and the
terminal input on `A2`). Placeholder in `muted`.
The caret is drawn by LVGL; the boards show it as `▌` at 1 Hz step-end so the
half-typed state is legible in a static image. Emits nothing itself — contents
ride in `values` on every event from the page.

### 3.7 `progress`
Static `label`. Dynamic `progress` (0–100, −1 indeterminate), `color`,
`visible`. Track 10 px, radius 5, `#00000012` in light / `surface-2` in dark;
bar in `accent`. Label row above it: name left in `caption`/`muted`, percentage
right in `caption`/`muted` with tabular figures. Board: `A8` bottom.

### 3.8 `log-view`
Dynamic `text` (tail re-send, set semantics), `visible`.
Inset ground, radius 12, padding `md` `lg`, `mono` at 1.45. **Bottom-anchored:**
the newest line sits flush to the panel floor and old lines clip at the top.
Anything else is not a follow-tail log. A 4–8 px `muted` scrollbar hints
scrollback; follow-tail releases when the user scrolls up and re-arms at the
bottom. The server strips ANSI; there is no device-side buffer beyond what is
shown. Board: `A2`.

### 3.9 `doc-view`
Dynamic `items` — `[{kind, text, link?}]`, `kind` ∈ `h1 h2 h3 p bullet code
quote divider`. Variable length, capped at 200 blocks.
Column, max width **880 px, centred**, gap `md`. Per-kind rendering:

| kind | Role | Treatment |
|---|---|---|
| `h1`, `h2`, `h3` | `title` | `h2`/`h3` get `sm` extra top margin |
| `p` | `body` | line height 1.5 |
| `bullet` | `body` | `•` in `muted`, gap 14, hanging indent |
| `code` | `mono` | inset ground, radius 12, padding `md` `lg`, no wrap |
| `quote` | `body`/`muted` | 3 px `accent` left rule, padding-left `md` |
| `divider` | — | 1 px hairline, `md` above and below |
| any + `link` | `body`/`accent` | full-width row, 14 px vertical padding, top hairline, trailing `›` |

Link blocks are **block-level only**. Inline links and inline images are
refused — span hit-testing inside flowing text is where this renderer would
die. A tap emits the page action with `link` as an additive key.
Boards: `A4` (markdown reader), `A6` (article, same skeleton — that identity is
the design decision, do not let the two drift).

### 3.10 `chat-view`
Dynamic `items` — `[{role, text, pending?}]`, last 100. Bottom-anchored column,
gap `md`.
User bubbles right-aligned, `surface-2` fill (+ hairline in light). Assistant
bubbles left-aligned, `accent` @ 10 % fill. Both radius 12, padding 14/18,
`body`, **max width 76 %** of the column. `pending` renders a caret at the end
of the text plus a `…typing` line in `caption`/`muted` **beneath** the bubble —
not beside it; a baseline-floated indicator clips the moment the bubble wraps.
Input is an ordinary `text-field` + `button-row` below the transcript, not part
of this component. Board: `A10`.

### 3.11 `status-bar` — shell-owned
40 px, `surface-2`, padding 0 `lg`, `caption`. Pages never instantiate it.
Left: `server · App`, in `muted`. Right, in this order, each hidden when empty:

1. notice badge — `accent` dot + count (`● 2`), only for backgrounded sessions
2. queue warning — `⚠ 3 queued` in `warn`; at the queue limit, `⚠ 12 queued ·
   oldest dropped` in `error`
3. one connection dot per connected server — `ok` / `warn` reconnecting /
   `error` dead
4. battery %, `muted` — `error` under 15 %
5. clock, `text`

All numerals tabular. Every permutation is drawn on board `X2`; treat that
board as the acceptance list.

### 3.12 Error banner — shell-owned
56 px, `error` fill, white text, slides **over** the status bar. Code in
`mono`/17 at 80 % white, message in `body`/white, `✕` right. One banner for the
whole system: applications never draw error UI. Board `X1`.

---

## 4. Shell screens

### 4.1 Server picker (`S1`)
Boot screen, must render before any network exists. Centred column, max width
640, top margin 56: wordmark `Slate` in `title`/`muted` · saved-server cards
(name `body`, address `caption`/`muted` with tabular figures, `auto` tag as a
10 px-radius `accent` outline chip, connection dot) · `+ Add server` row in
`accent` · bottom hint in `caption`/`muted`, pinned with `margin-top:auto`.
Status bar shows only battery and clock — there is nothing else true yet.

### 4.2 Switcher (`S2`)
Scrim at 60 % black over the live screen, which stays rendered beneath. Panel
800 wide, `surface-2`, `radius_panel`, padding `lg`, centred. Header row:
`Open applications` in `title`, `5 of 8 · oldest evicts` in `caption`/`muted`.
Then per server: a `muted` name + connection dot, then a row of equal tiles.
Tile = `surface` fill, radius 12, padding `md`, min height 96: name in `body`,
live-state line in `caption` (`CPU 43 %`, `Олена · 2 нових`), `✕` top-right
(48 px hit box). Active tile carries a 2 px `accent` border. Index tiles come
first per server and have no `✕`.
Footer line, `caption`/`muted`: *Only the active application receives pushed
data.* Keep it — it is the one place the background rule is visible.

---

## 5. Page specs

Each application is a directory in `apps/`. Structure is XML; every dynamic
element carries a page-unique `id`; nothing here contains a pixel coordinate.

### 5.1 Status console — `apps/console/index.xml` (M4 / v2.1, boards `A1`/`V1`)

```xml
<column pad="lg" gap="lg">
  <row align="baseline" gap="md">
    <text-block id="hdr" font="title" text="Console"/>
    <text-block id="updated" font="caption" color="muted" grow="1" align="right"/>
  </row>
  <row gap="lg" grow="1">
    <column gap="md" grow="1">
      <row gap="md" grow="1">
        <stat-card id="cpu"  label="CPU"    unit="%"  grow="1"/>
        <stat-card id="mem"  label="Memory" unit="GB" grow="1"/>
      </row>
      <row gap="md" grow="1">
        <stat-card id="disk" label="Disk"   unit="%"  grow="1"/>
        <stat-card id="up"   label="Uptime" unit="d"  grow="1"/>
      </row>
    </column>
    <chart id="cpu_hist" kind="line" y-min="0" y-max="100" points="31" grow="1"/>
  </row>
</column>
```

Handler pushes once a second: `cpu.text`+`color` (`ok` <70, `warn` 70–90,
`error` >90 — the same thresholds drive `disk`), `updated.text`, and
`cpu_hist.items` as the full 31-value window. `uptime` stays `muted`: it is
information, not a condition. Two faint horizontals at 25 % and 75 %, axis
labels in `caption`/`muted` inside the plot, no legend, no autoscale.

### 5.2 Server terminal — `apps/terminal/index.xml` (M6 / v2.3, board `A2`)

```xml
<column pad="lg" gap="md">
  <log-view id="out" grow="1"/>
  <row gap="md" align="center">
    <text-block font="mono" color="muted" text="$"/>
    <text-field id="cmd" type="text" maxlen="512" grow="1"
                placeholder="" submit="run"/>
    <button-row>
      <button id="run_btn" label="Run" action="run" variant="primary"/>
    </button-row>
  </row>
</column>
```

Enter with the keyboard attached fires `run`; so does the button. `values`
carries `cmd`. Output arrives as repeated `out.text` tail re-sends — never an
append. A command fired during a WiFi drop queues, the status bar warns, and it
executes on reconnect: that path is board `X2` strip 3, not a hypothetical.

### 5.3 Markdown browser — `apps/md/` (M7 / v2.4, boards `A3`, `A4`)

`listing.xml?path=` — `page-header` (path tail as title, full path as eyebrow,
item count right) + `list-view rows="9"` with a two-cell row template
(`name`, `meta`); folders prefix `▸` in `accent`, files do not. Row tap emits
`open` with `row`; the handler decides descend-vs-read and replies with
`navigate` push.

`reader.xml?f=` — `page-header` (filename, block count right) + `doc-view`.
The server parses the Markdown; the device never sees source. Links between
files arrive as link blocks and navigate with `push`, so `back` retraces every
hop.

### 5.4 Wikipedia — `apps/wiki/` (M8 / v2.5, boards `A5`, `A6`)

`search.xml` — centred 880 column: `Вікіпедія` in `title` · `text-field`
(placeholder `Пошук…`, focus ring) + `Search` primary · `Результати` /
`6 of 6 rows` caption row · `list-view rows="6"` with `title` + `snippet`.

`article.xml?t=` — **structurally identical to the markdown reader.** Cache the
XML by base path; `subscribe` and history carry the full path. One cached
structure, many history entries. Cyrillic titles in the header prove the font
build.

### 5.5 Notes — `apps/notes/index.xml` (M10 / v4.1, board `A7`)

```xml
<column pad="lg" gap="lg">
  <row gap="md" align="stretch">
    <text-field id="draft" type="text" maxlen="2000" grow="1"
                placeholder="Нова нотатка…"/>
    <button-row>
      <button id="save_btn" label="Save" action="save" variant="primary"/>
    </button-row>
  </row>
  <row align="baseline">
    <text-block font="caption" color="muted" text="Recent"/>
    <text-block id="count" font="caption" color="muted" grow="1" align="right"/>
  </row>
  <list-view id="recent" rows="6" action="open" grow="1"/>
</column>
```

The half-typed draft surviving a switch away and back is the platform's
signature and this page's *only* acceptance criterion that matters. The field's
contents live in the LVGL widget, are never sent until `save`, and are never
overwritten by a `value` update while the field has focus.

### 5.6 Companion — `apps/claude/` (M11 / v4.2, boards `A8`, `A9`, `A10`)

`dashboard.xml` — header row (`Claude Code` title, session + branch in
`caption`/`muted`, `● running` in `ok` right) · four `stat-card`s · a row of
two cards, burn-down `chart` left (actual in `accent`, ideal as a dashed
`muted` line) and a 5-row activity `list-view` right (`caption`, tabular
timestamps, status glyph in `ok`/`warn`/`error`) · `progress` across the
bottom.
`question.xml` — pushed by the server as `navigate`. Eyebrow in
`caption`/`muted` · the **whole** question in `body` at max width 960, never
truncated (this is the entire argument for a 5-inch screen) · `button-row` of
up to 3 choices, first `primary`, stretched equally · a free-form `text-field`
+ `Send`, pinned to the bottom with `margin-top:auto`.
`chat.xml` — `chat-view` + input row.

---

## 6. M0, and why it looks nothing like the above

Board set `Slate M0 Prototype.html`; the standalone brief is
[ui-m0-brief.md](ui-m0-brief.md). Raw LVGL widgets, stock theme, default
font, `#e0e0e0` ground, no tokens, no components, no status bar, no chrome.
Build it exactly that ugly:

- title label · `42` at ~80 px · a stock `+1` button with a visible pressed
  state · a 1 Hz clock label · a white inset panel, ~55 % of screen height,
  holding server-parsed blocks as a plain label column (headings merely larger,
  bullets prefixed `•`, code on a `#ebebeb` strip)
- the Ukrainian line renders as **tofu** — the default font is Latin-only, and
  the board draws the boxes on purpose. Do not fix this in M0; real fonts
  arrive with M3.
- content must be visibly cut at the panel's bottom edge, with a thin
  scrollbar, so scrollability reads without a gesture
- three firmware-drawn states and nothing else: `connecting…`, `server
  unreachable`, the page

If an M0 screen starts looking designed, the milestone has drifted. Its code is
quarry, not foundation — M1 starts the kept trees.

---

## 7. Build order and acceptance

| Step | Phase | Adds to the UI | Boards that gate it |
|---|---|---|---|
| M0 | v0.1 | raw widgets, doc-view v0 | M0-1, M0-2 |
| M3 | v1.3 | token layer, both fonts, states trio, `page-header`/`text-block`/`stat-card` | `F1` |
| M4 | v2.1 | `chart` | `A1`, plus `V1` for the theme flip |
| M5 | v2.2 | error banner v1, pressed states, queue warning (provisional) | `X1` |
| M6 | v2.3 | `text-field`, `button-row`, `log-view`, `mono` in anger | `A2` |
| M7 | v2.4 | `list-view`, `doc-view` incl. link blocks | `A3`, `A4` |
| M8 | v2.5 | nothing new — Cyrillic and deep history | `A5`, `A6` |
| M9 | v3.1 | `status-bar`, picker, switcher, final error overlay | `S1`, `S2`, `X2`, `X1` |
| M10 | v4.1 | nothing new — input preservation | `A7` |
| M11 | v4.2 | `chat-view`, `progress` | `A8`, `A9`, `A10` |

Phase ids are [ROADMAP.md](ROADMAP.md)'s `vA.B`; the M-ids are the original step
numbers from [slate-vision.md](slate-vision.md), kept as cross-references.

Per-board acceptance, in order of how easily each is got wrong:

1. `stat-value` digits do not jitter as the console updates (`A1`).
2. The theme flip is global, instant, and changes no geometry — screenshot
   `A1` and `V1` and diff the layout boxes, not the pixels.
3. The log tail is flush to the panel floor and old lines clip at the top
   (`A2`).
4. A streaming chat bubble wraps to two lines with the caret on the last, and
   `…typing` sits beneath it, uncut (`A10`).
5. The markdown reader and the Wikipedia article render through the *same*
   code path (`A4` ≡ `A6`).
6. Every status-bar permutation on `X2` is reachable, and none of them shifts
   the clock's position.
7. Half-typed text survives a switch away and back (`A7`).

## 8. Validator hooks (M12 / v5.1)

Beyond the vision spec's schema and registry checks, the design adds four the
validator can enforce cheaply, and should:

- **no pixel values in page XML** — spacing must be `sm`/`md`/`lg`, sizes must
  be roles. A raw number is an error, not a warning.
- **raw hex warning** — legal only for genuinely data-driven colour; every
  board here uses tokens exclusively.
- **font role whitelist** — the five roles in §2.2 and nothing else.
- **golden PNGs** — render each page in §5 at 1280×720 in both themes and diff
  against the board it came from. Fifteen images is a complete visual
  regression suite for this platform, and it costs one CI job.
