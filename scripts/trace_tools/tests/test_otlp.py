"""Unit tests for :mod:`trace_tools.otlp` (OTLP resourceSpans projection)."""

from __future__ import annotations

from trace_tools.otlp import (
    end_nanos,
    otlp_attributes,
    otlp_span,
    project,
    span_name,
    start_nanos,
    trace_id,
)

_TS = "2026-07-04T10:00:00Z"
_EPOCH = 1783159200


def test_trace_id_issue_220_pads_to_32_hex() -> None:
    """Issue 220 → hex ``dc`` left-padded with zeros to 32 chars."""
    assert trace_id({"harness.issue": 220}) == "000000000000000000000000000000dc"


def test_trace_id_missing_or_zero_folds_to_32_zeros() -> None:
    """A missing or zero issue folds to 32 zeros (jq ``trace_id`` default)."""
    assert trace_id({}) == "0" * 32
    assert trace_id({"harness.issue": 0}) == "0" * 32


def test_trace_id_negative_clamps_to_zero() -> None:
    """A negative issue clamps to zero before hex rendering."""
    assert trace_id({"harness.issue": -5}) == "0" * 32


def test_start_nanos_is_epoch_string_plus_nine_zeros() -> None:
    """``startTimeUnixNano`` is ``"<epoch>000000000"`` (string concat, no float)."""
    result = start_nanos({"timestamp": _TS})
    assert result == f"{_EPOCH}000000000"
    assert isinstance(result, str)


def test_end_nanos_no_duration_equals_start() -> None:
    """No/absent duration → end equals start (single-point span)."""
    span: dict[str, object] = {"timestamp": _TS}
    assert end_nanos(span) == start_nanos(span)


def test_end_nanos_negative_duration_equals_start() -> None:
    """A negative duration clamps to zero → end equals start."""
    span = {"timestamp": _TS, "harness.duration_ms": -100}
    assert end_nanos(span) == start_nanos(span)


def test_end_nanos_sub_second_remainder_is_nine_digit_padded() -> None:
    """5 ms → 5_000_000 ns remainder, zero-padded to 9 digits; epoch unchanged."""
    span = {"timestamp": _TS, "harness.duration_ms": 5}
    assert end_nanos(span) == f"{_EPOCH}005000000"


def test_end_nanos_folds_whole_seconds_into_epoch() -> None:
    """1234 ms folds 1 whole second into the epoch, 234 ms → 234_000_000 ns."""
    span = {"timestamp": _TS, "harness.duration_ms": 1234}
    assert end_nanos(span) == f"{_EPOCH + 1}234000000"


def test_end_nanos_ge_24h_duration_folds_identically() -> None:
    """A >= 24h duration folds all whole seconds; the remainder stays 9 digits."""
    millis = 90_061_234  # 90061.234 s → +90061 s epoch, 234_000_000 ns
    span = {"timestamp": _TS, "harness.duration_ms": millis}
    assert end_nanos(span) == f"{_EPOCH + 90_061}234000000"


def test_span_name_falls_back_to_span_type() -> None:
    """Each span type uses its primary field, falling back to the span type."""
    assert span_name({"span": "tool", "gen_ai.tool.name": "git"}) == "git"
    assert span_name({"span": "tool"}) == "tool"
    assert span_name({"span": "lifecycle"}) == "lifecycle"
    assert span_name({"span": "model", "gen_ai.request.model": "m"}) == "m"


def test_otlp_attributes_projects_allowlist_only_as_string_values() -> None:
    """Only allowlisted keys survive; every value is a ``stringValue`` string."""
    span = {
        "harness.issue": 220,
        "gen_ai.usage.input_tokens": 10,
        "harness.summary": "secret free text",
    }
    attrs = otlp_attributes(span)
    keys = [a["key"] for a in attrs]
    assert "harness.issue" in keys
    assert "gen_ai.usage.input_tokens" in keys
    assert "harness.summary" not in keys
    for attr in attrs:
        value = attr["value"]
        assert isinstance(value, dict)
        assert isinstance(value["stringValue"], str)


def test_otlp_span_omits_parent_when_absent_or_empty() -> None:
    """``parentSpanId`` is absent unless a non-empty ``parent_span_id`` exists."""
    without = otlp_span({"span": "tool", "span_id": "s1", "timestamp": _TS})
    assert "parentSpanId" not in without
    empty = otlp_span({"span": "tool", "span_id": "s1", "timestamp": _TS, "parent_span_id": ""})
    assert "parentSpanId" not in empty
    with_parent = otlp_span(
        {"span": "tool", "span_id": "s1", "timestamp": _TS, "parent_span_id": "p1"}
    )
    assert with_parent["parentSpanId"] == "p1"


def test_otlp_span_key_order_matches_jq() -> None:
    """Span keys are emitted in the exact jq order; kind is an int literal 1."""
    span = {
        "span": "tool",
        "span_id": "s1",
        "timestamp": _TS,
        "parent_span_id": "p1",
        "harness.issue": 220,
    }
    result = otlp_span(span)
    assert list(result.keys()) == [
        "traceId",
        "spanId",
        "name",
        "kind",
        "startTimeUnixNano",
        "endTimeUnixNano",
        "attributes",
        "parentSpanId",
    ]
    assert result["kind"] == 1


def test_project_marker_counts_and_body_shape() -> None:
    """``project`` returns skip/noversion/count markers and the resourceSpans body."""
    text = "\n".join(
        [
            '{"span":"tool","span_id":"s1","timestamp":"' + _TS + '",'
            '"harness.issue":220,"harness.version":"abc"}',
            "not json at all",
            '{"span":"agent","span_id":"s2","timestamp":"' + _TS + '","harness.issue":220}',
        ]
    )
    skipped, noversion, count, body = project(text)
    assert skipped == 1
    assert noversion == 1
    assert count == 2
    spans = body["resourceSpans"][0]["scopeSpans"][0]["spans"]  # type: ignore[index]
    assert len(spans) == 2
    assert all(s["traceId"] == "000000000000000000000000000000dc" for s in spans)
