"""Markdown → typed blocks, for `doc-view` v0.

The device never parses Markdown. That is the invariant this module exists to
establish: the server turns a `.md` file into a flat list of `{kind, text}`
blocks, ships them as one `items` update, and the renderer on the other end
only ever switches on `kind`. Every later document surface — the Markdown
browser at v2.4, Wikipedia at v2.5 — reaches the device through this same
shape.

The kind set is a **seam** (ARCHITECTURE.md §Contracts) and is closed:

    h1 h2 h3 p bullet code quote divider

Out of scope at v0.1, deliberately:

* the ``link`` key — block-level links arrive with the Markdown browser (v2.4);
* inline formatting of any sort. Inline links and inline images are a refused
  design line, not a deferral: span hit-testing inside flowing text is where
  this renderer would die.

The parser is line-oriented and forgiving. It is quarry code, and its job is to
produce well-formed blocks from a document we control, not to be a conformant
CommonMark implementation.
"""

from __future__ import annotations

import re
from typing import Final, TypedDict


class Block(TypedDict):
    """One element of a `doc-view` `items` array."""

    kind: str
    text: str


#: The closed set. Adding a member is a contract change, and its test says so.
BLOCK_KINDS: Final[frozenset[str]] = frozenset(
    {"h1", "h2", "h3", "p", "bullet", "code", "quote", "divider"}
)

#: `doc-view` caps items at 200 blocks (ui-implementation.md §3.9).
MAX_BLOCKS: Final = 200

_HEADING = re.compile(r"^(#{1,3})\s+(.*)$")
_BULLET = re.compile(r"^\s*[-*+]\s+(.*)$")
_QUOTE = re.compile(r"^\s*>\s?(.*)$")
_DIVIDER = re.compile(r"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$")
_FENCE = re.compile(r"^\s*```")


def parse_markdown(source: str, max_blocks: int = MAX_BLOCKS) -> list[Block]:
    """Turn Markdown into a flat list of typed blocks.

    Paragraphs accumulate across consecutive non-blank lines and are flushed on a
    blank line or any block-level construct. Fenced code becomes **one** `code`
    block per fence, newlines preserved, so the renderer can lay it on a single
    shaded strip rather than one strip per line.
    """
    blocks: list[Block] = []
    paragraph: list[str] = []
    code: list[str] | None = None

    def flush_paragraph() -> None:
        if paragraph:
            blocks.append({"kind": "p", "text": " ".join(paragraph).strip()})
            paragraph.clear()

    for line in source.splitlines():
        # Inside a fence, everything is code until the closing fence.
        if code is not None:
            if _FENCE.match(line):
                blocks.append({"kind": "code", "text": "\n".join(code)})
                code = None
            else:
                code.append(line)
            continue

        if _FENCE.match(line):
            flush_paragraph()
            code = []
            continue

        if not line.strip():
            flush_paragraph()
            continue

        # A divider must be tested before a bullet: `---` matches both.
        if _DIVIDER.match(line):
            flush_paragraph()
            blocks.append({"kind": "divider", "text": ""})
            continue

        heading = _HEADING.match(line)
        if heading:
            flush_paragraph()
            blocks.append({"kind": f"h{len(heading.group(1))}", "text": heading.group(2).strip()})
            continue

        bullet = _BULLET.match(line)
        if bullet:
            flush_paragraph()
            blocks.append({"kind": "bullet", "text": bullet.group(1).strip()})
            continue

        quote = _QUOTE.match(line)
        if quote:
            flush_paragraph()
            blocks.append({"kind": "quote", "text": quote.group(1).strip()})
            continue

        paragraph.append(line.strip())

    flush_paragraph()
    # An unterminated fence still yields its content rather than swallowing it.
    if code:
        blocks.append({"kind": "code", "text": "\n".join(code)})

    return blocks[:max_blocks]
