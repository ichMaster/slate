# Slate M0 — Prototype UI Brief for Claude Design

**What this is:** the screen of Slate's M0 walking skeleton — the throwaway
prototype that proves the concept before any design system exists. It is
**deliberately crude**: raw LVGL widgets, default theme, no tokens, no fonts
beyond the default, no chrome. Its job is to demonstrate the architecture,
not to look good — and the design artefact should communicate exactly that.

Keep this canvas separate from the main Slate UI canvas
([ui-design-brief.md](ui-design-brief.md)): the visual gap between the two
*is the message* — everything the design system adds becomes visible by
contrast.

**Canvas setup:** one artboard, **1280×720 landscape** (M5Stack Tab5,
5-inch touch). Optionally a second board annotating the runtime states.

---

## Artboard 1 — The M0 screen

Plain and grey, like an unstyled toolkit demo. Background `#e0e0e0`, default
sans-serif, black text, stock-looking button. Single column, centred,
generous but unconsidered spacing.

```
┌────────────────────────────────┐
│           Slate  M0            │   plain title label
│                                │
│              42        [ +1 ]  │   counter value + default button
│           19:04:33             │   server clock label
│                                │
│  ┌──────────────────────────┐  │
│  │ # Heading                │  │   doc-view v0: plain scrollable
│  │ Paragraph text…          │  │   label column — heading merely
│  │ • bullet                 │  │   larger, bullets prefixed,
│  │ ▒ code line ▒            │  │   code on a grey ground
│  │          ⋮  (scrolls)    │  │
│  └──────────────────────────┘  │
└────────────────────────────────┘
```

Element by element:

1. **Title** — `Slate M0`, a plain label, slightly larger than body. Static.
2. **Counter value** — `42`, large plain text. This number is owned by the
   server; the device only displays what it is told.
3. **Increment button** — `[ +1 ]`, a stock button with a visible pressed
   state. Pressing it sends an event to the server; the number changes only
   when the server's update returns.
4. **Clock** — `19:04:33`, plain label, updated once a second by unsolicited
   server push.
5. **Document region** — a scrollable panel (~55 % of screen height, inset,
   white ground) rendering a server-parsed Markdown file as a column of
   plain labels: headings simply larger, bullets prefixed with `•`, code
   lines on a light-grey strip. No links, no images, no styling beyond that.
   Show a thin scrollbar and content clearly cut off at the bottom edge to
   signal scrollability.

Content for the document region: use the opening of a real README — a
heading, two short paragraphs, a 3-item bullet list, two code lines. Mix in
one Ukrainian sentence to show the caveat below.

## Annotations to place on the board

- *"Raw LVGL widgets, default theme — the design system does not exist yet."*
- On the button: *"press feedback is instant and local"*.
- On the counter: *"the value lives on the server; reboot the device and 42
  is still 42"*.
- On the clock: *"unsolicited push, 1 Hz"*.
- On the document: *"doc-view v0 — the platform's heaviest renderer, proven
  first; ~50 blocks must scroll smoothly"*.
- Caveat note: *"default LVGL font is Latin-only — Cyrillic renders as
  tofu in M0; real fonts arrive with the design system (M3)"*.

## Optional artboard 2 — the three boot states

Three small frames side by side, same grey aesthetic:

1. `connecting…` — a single centred label on the grey ground.
2. `server unreachable` — a single centred error line, plain text.
3. The rendered page (a miniature of artboard 1).

Caption: *"Everything the firmware can draw before a page arrives."*
