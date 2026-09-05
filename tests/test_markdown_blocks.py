"""Unit tests for Markdown → typed blocks.

The fixture covers all eight contracted kinds, because a parser that silently
stops emitting one is the failure this suite exists to catch.
"""

from __future__ import annotations

import pytest
from markdown import BLOCK_KINDS, Block, parse_markdown

FIXTURE = """\
# Title

## Section

### Subsection

A paragraph that runs
across two source lines.

- first
- second
* third with a star

> a quotation
> continued

---

```python
def f() -> int:
    return 1
```

Це речення українською.
"""


@pytest.fixture
def blocks() -> list[Block]:
    return parse_markdown(FIXTURE)


class TestKindCoverage:
    def test_the_fixture_exercises_every_contracted_kind(
        self, blocks: list[Block]
    ) -> None:
        assert {b["kind"] for b in blocks} == set(BLOCK_KINDS)

    def test_no_block_escapes_the_closed_kind_set(self, blocks: list[Block]) -> None:
        assert all(b["kind"] in BLOCK_KINDS for b in blocks)

    def test_every_block_has_exactly_kind_and_text(self, blocks: list[Block]) -> None:
        assert all(set(b) == {"kind", "text"} for b in blocks)


class TestHeadings:
    @pytest.mark.parametrize(
        ("line", "kind", "text"),
        [
            ("# One", "h1", "One"),
            ("## Two", "h2", "Two"),
            ("### Three", "h3", "Three"),
        ],
    )
    def test_heading_levels_map_to_h1_h2_h3(self, line: str, kind: str, text: str) -> None:
        assert parse_markdown(line) == [{"kind": kind, "text": text}]

    def test_a_fourth_level_heading_is_not_promoted_to_a_kind(self) -> None:
        # There is no h4 in the contract; it must degrade, not invent a kind.
        blocks = parse_markdown("#### Four")
        assert [b["kind"] for b in blocks] == ["p"]


class TestParagraphs:
    def test_consecutive_lines_join_into_one_paragraph(self) -> None:
        assert parse_markdown("one\ntwo\nthree") == [{"kind": "p", "text": "one two three"}]

    def test_a_blank_line_separates_paragraphs(self) -> None:
        assert parse_markdown("one\n\ntwo") == [
            {"kind": "p", "text": "one"},
            {"kind": "p", "text": "two"},
        ]

    def test_a_paragraph_is_flushed_before_a_heading(self) -> None:
        assert parse_markdown("text\n# Head") == [
            {"kind": "p", "text": "text"},
            {"kind": "h1", "text": "Head"},
        ]


class TestBullets:
    @pytest.mark.parametrize("marker", ["-", "*", "+"])
    def test_every_bullet_marker_is_recognised(self, marker: str) -> None:
        assert parse_markdown(f"{marker} item") == [{"kind": "bullet", "text": "item"}]

    def test_the_marker_is_stripped_from_the_text(self, blocks: list[Block]) -> None:
        bullets = [b["text"] for b in blocks if b["kind"] == "bullet"]
        assert bullets == ["first", "second", "third with a star"]


class TestCode:
    def test_a_fence_becomes_one_block_with_newlines_preserved(self) -> None:
        blocks = parse_markdown("```\na\nb\n```")
        assert blocks == [{"kind": "code", "text": "a\nb"}]

    def test_the_fence_markers_are_not_part_of_the_text(
        self, blocks: list[Block]
    ) -> None:
        code = [b["text"] for b in blocks if b["kind"] == "code"]
        assert code == ["def f() -> int:\n    return 1"]

    def test_markdown_inside_a_fence_is_not_interpreted(self) -> None:
        blocks = parse_markdown("```\n# not a heading\n- not a bullet\n```")
        assert [b["kind"] for b in blocks] == ["code"]

    def test_an_unterminated_fence_still_yields_its_content(self) -> None:
        assert parse_markdown("```\norphan") == [{"kind": "code", "text": "orphan"}]


class TestQuotesAndDividers:
    def test_a_quote_loses_its_marker(self) -> None:
        assert parse_markdown("> quoted") == [{"kind": "quote", "text": "quoted"}]

    @pytest.mark.parametrize("rule", ["---", "***", "___", "-----"])
    def test_every_rule_form_becomes_a_divider(self, rule: str) -> None:
        assert parse_markdown(rule) == [{"kind": "divider", "text": ""}]

    def test_a_divider_is_not_mistaken_for_a_bullet(self) -> None:
        # `---` matches the bullet pattern too; order of testing decides this.
        assert parse_markdown("---")[0]["kind"] == "divider"


class TestCyrillic:
    def test_the_ukrainian_line_survives_byte_for_byte(
        self, blocks: list[Block]
    ) -> None:
        texts = [b["text"] for b in blocks]
        assert "Це речення українською." in texts

    def test_cyrillic_is_not_escaped_or_transliterated(self) -> None:
        block = parse_markdown("Привіт, світе")[0]
        assert block["text"] == "Привіт, світе"


class TestCap:
    def test_blocks_are_capped(self) -> None:
        source = "\n\n".join(f"para {i}" for i in range(50))
        assert len(parse_markdown(source, max_blocks=10)) == 10

    def test_the_default_cap_matches_the_doc_view_contract(self) -> None:
        from markdown import MAX_BLOCKS

        assert MAX_BLOCKS == 200


class TestEmptyInput:
    def test_an_empty_document_yields_no_blocks(self) -> None:
        assert parse_markdown("") == []

    def test_whitespace_only_yields_no_blocks(self) -> None:
        assert parse_markdown("\n\n   \n") == []
