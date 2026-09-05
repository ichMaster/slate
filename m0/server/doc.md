# Slate

Slate is a mainframe terminal for the modern desk. An ESP32-P4 device renders;
a server holds all logic, data, and state. Between them sits a narrow protocol:
WebSocket JSON for the live channel, HTTP GET for page XML and assets.

The unit of software is a page — a declarative XML file. A page plus its
server-side handler is an application. Pages are data, never instructions.

## Why a terminal

Every device on the desk wants to be a computer. Slate wants to be a window.
The distinction matters because it decides where complexity lives, and
complexity on a battery-powered renderer is complexity you pay for twice.

The device owns feel: touch feedback, scrolling, text entry, the application
stack. The server owns meaning: what a page contains and when it changes.

- The device has no truth of its own except in-progress input.
- A page is fetched once and never regenerated to change a value.
- No executable code reaches the device beyond the firmware itself.

## Structure is static, content is dynamic

Page XML is fetched once, cached, and left alone. To change a value the server
sends a targeted update naming an element id. Re-sending a page to change a
number destroys scroll position, input focus, and animation continuity.

Це речення українською — і в M0 воно навмисно рендериться як порожні квадрати.

The dynamic property set is closed. Eight properties cover every application
the roadmap names, and keeping the list short is what keeps the renderer small
enough to reason about.

```
text  value  visible  enabled
color progress items  image
```

Anything outside that set requires a page replacement, and a page replacement
is an explicit navigation — never a silent redraw.

### The applicator

On the device, an id maps to a widget. A data frame arrives, each update is
looked up by id, and the named property is applied. An update naming an id the
page does not have is dropped and debug-logged.

> Never a crash. A server that has drifted ahead of a cached page is a normal
> condition on a device that caches pages, not an exceptional one.

---

## The component vocabulary

Pages are assembled from a small fixed set of components and arranged with row
and column containers using spacing tokens. There are no pixel coordinates
anywhere in a page, and no raw hex outside data-driven colour.

- Structural: page-header, stat-card, text-block, status-bar.
- Interactive: button-row, text-field, toggle, list-view.
- Heavy: chart, log-view, doc-view, chat-view.

The vocabulary grows only when a named application demands it. That is how
chart, log-view, and doc-view earned their places, and it is the reason the
list has stayed short enough to implement well.

### doc-view

This document is being rendered by doc-view. The server parsed the Markdown
into typed blocks and pushed them as a single items update; the device knows
nothing about Markdown and never will.

Block kinds are a contract:

- Headings at three levels, paragraphs, and bullets.
- Fenced code, laid on an inset ground.
- Block quotes and horizontal dividers.

```python
def parse(source: str) -> list[Block]:
    """The device never runs this. That is the point."""
    return [block for block in blocks(source)]
```

Inline links are refused by design. Span hit-testing inside flowing text is
where a renderer this small would die, so links are block-level or absent.

## Sessions

A session id binds the two halves of an open application: a live screen on the
device, a logic session on the server. Switching away and back rebuilds
neither half, and that is the entire reason state survives.

The device mints the id. The server creates sessions lazily on first sight of
an unknown one, so first use is creation and there is no handshake to get
wrong. A server restart is the same path as an idle expiry.

> Only the active application receives pushed data. Backgrounded sessions stay
> alive but unfed, and re-subscribe when the user returns.

---

## Trust

Trusted network only, as a decision rather than an oversight. The device never
touches the internet; servers proxy everything. Secrets live server-side, and
the action registry is the enforcement point: a page may reference declared
actions only, and may never invent one.

A page therefore cannot do anything the firmware was not already built to do,
which is what makes generated pages safe to run without review.

### The authoring loop

A description becomes a page: the model writes XML, a validator checks it
against the schema and the component library, and the server serves it. No
reflash, no compile cycle.

The validator is what makes agent authoring viable at all. It confirms every
referenced action exists, every dynamic id is unique, and the page renders at
the target resolution — then exits non-zero with errors a model can act on.

- Unknown component, bad action, duplicate id: each fails readably.
- Raw hex is warned; raw pixel coordinates are an error.
- Golden renders diff against the design boards.

Without it, generation produces plausible XML that fails on hardware and every
page needs a human. With it, the agent corrects itself.

## Build order

Milestones are ordered by risk, not size. The walking skeleton comes first and
carries every proof, because the cheapest possible collision with the hardest
question is worth more than a month of design.

> Rebooting the device must not reset the count, because the count never lived
> there. That is the whole milestone, stated as one sentence.

Everything after it adds functionality the platform did not have before.
