"""Unit tests for :mod:`trace_tools.mapping` (allowlist + jq-compat helpers)."""

from __future__ import annotations

from trace_tools.mapping import (
    ALLOWLIST,
    jq_alt,
    jq_tostring,
    parse_spans,
    shippable_key,
    split_input_lines,
)


def test_allowlist_membership() -> None:
    """Allowlist members and the usage prefix are shippable; others are not."""
    assert shippable_key("harness.issue")
    assert shippable_key("gen_ai.usage.input_tokens")
    assert not shippable_key("harness.summary")
    assert not shippable_key("harness.worktree")


def test_allowlist_has_no_duplicates() -> None:
    """The single-source allowlist carries each key once."""
    assert len(ALLOWLIST) == len(set(ALLOWLIST))


def test_jq_tostring_matches_jq_semantics() -> None:
    """Strings pass through; bools/None/ints render like jq ``tostring``."""
    assert jq_tostring("git") == "git"
    assert jq_tostring(1234) == "1234"
    assert jq_tostring(0) == "0"
    assert jq_tostring(True) == "true"
    assert jq_tostring(False) == "false"
    assert jq_tostring(None) == "null"


def test_jq_alt_replaces_only_null_and_false() -> None:
    """``//`` keeps empty strings/zero; only null/false fall to the default."""
    assert jq_alt(None, "unknown") == "unknown"
    assert jq_alt(False, "unknown") == "unknown"
    assert jq_alt("", "unknown") == ""
    assert jq_alt(0, "unknown") == 0
    assert jq_alt("git", "unknown") == "git"


def test_split_input_lines_matches_jq_line_reading() -> None:
    """One trailing newline terminates; interior blanks are preserved."""
    assert split_input_lines("") == []
    assert split_input_lines("a\nb\n") == ["a", "b"]
    assert split_input_lines("a\nb") == ["a", "b"]
    assert split_input_lines("a\n\nb\n") == ["a", "", "b"]


def test_parse_spans_skips_non_objects() -> None:
    """Non-JSON and non-object JSON lines are dropped and counted."""
    text = '{"a":1}\nnot json\n[1,2]\n42\n{"b":2}\n'
    skipped, spans = parse_spans(text)
    assert skipped == 3
    assert spans == [{"a": 1}, {"b": 2}]
