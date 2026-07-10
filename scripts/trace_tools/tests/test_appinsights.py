"""Unit tests for :mod:`trace_tools.appinsights` envelope projection."""

from __future__ import annotations

from typing import cast

from trace_tools.appinsights import build_envelope, project


def _base_data(envelope: dict[str, object]) -> dict[str, object]:
    """Extract ``data.baseData`` as a typed dict for assertions."""
    data = cast(dict[str, object], envelope["data"])
    return cast(dict[str, object], data["baseData"])


_TOOL_SPAN: dict[str, object] = {
    "schema_version": 1,
    "timestamp": "2026-07-04T10:00:09Z",
    "span": "tool",
    "harness.issue": 220,
    "harness.version": "abc1234",
    "span_id": "spantl07",
    "parent_span_id": "spanlc07",
    "gen_ai.tool.name": "ruff",
    "harness.outcome": "pass",
    "harness.duration_ms": 250,
}

_MODEL_SPAN: dict[str, object] = {
    "schema_version": 1,
    "timestamp": "2026-07-04T10:00:11Z",
    "span": "model",
    "harness.issue": 220,
    "harness.version": "abc1234",
    "span_id": "spanmd07",
    "gen_ai.request.model": "example-model",
    "gen_ai.usage.input_tokens": 10,
    "gen_ai.usage.output_tokens": 20,
}


def test_tool_envelope_shape_and_key_order() -> None:
    """A tool span → RemoteDependency with jq key order and resultCode."""
    env = build_envelope(_TOOL_SPAN)
    assert list(env) == ["ver", "name", "time", "sampleRate", "tags", "data"]
    assert env["name"] == "Microsoft.ApplicationInsights.RemoteDependency"
    assert cast(dict[str, object], env["tags"])["ai.operation.id"] == "issue-220"
    base = _base_data(env)
    assert list(base) == [
        "ver",
        "name",
        "id",
        "type",
        "duration",
        "success",
        "properties",
        "resultCode",
    ]
    assert base["name"] == "ruff"
    assert base["type"] == "harness.tool"
    assert base["duration"] == "00:00:00.250"
    assert base["success"] is True
    assert base["resultCode"] == "pass"
    assert cast(dict[str, object], base["properties"])["harness.duration_ms"] == "250"


def test_duration_day_segment_and_clamp() -> None:
    """>= 24h gains a day segment; negatives clamp to the floor."""
    over_day = build_envelope({**_TOOL_SPAN, "harness.duration_ms": 90061234})
    assert _base_data(over_day)["duration"] == "1.01:01:01.234"
    negative = build_envelope({**_TOOL_SPAN, "harness.duration_ms": -5})
    assert _base_data(negative)["duration"] == "00:00:00.000"
    absent = build_envelope({k: v for k, v in _TOOL_SPAN.items() if k != "harness.duration_ms"})
    assert _base_data(absent)["duration"] == "00:00:00.000"


def test_model_envelope_measurements_are_numbers() -> None:
    """Model usage lands in measurements as JSON numbers (not strings)."""
    env = build_envelope(_MODEL_SPAN)
    assert env["name"] == "Microsoft.ApplicationInsights.Event"
    base = _base_data(env)
    assert base["name"] == "harness.model/example-model"
    assert base["measurements"] == {
        "gen_ai.usage.input_tokens": 10,
        "gen_ai.usage.output_tokens": 20,
    }
    # Usage keys are ALSO stringified into properties (allowlist prefix rule).
    assert cast(dict[str, object], base["properties"])["gen_ai.usage.input_tokens"] == "10"


def test_lifecycle_success_defaults_true_without_outcome() -> None:
    """A span without harness.outcome defaults success to true, no resultCode."""
    span = {
        "timestamp": "2026-07-04T10:00:02Z",
        "span": "lifecycle",
        "harness.issue": 220,
        "harness.version": "abc1234",
        "span_id": "spanlc02",
        "harness.lifecycle_step": "worktree_create",
    }
    base = _base_data(build_envelope(span))
    assert base["success"] is True
    assert "resultCode" not in base


def test_project_counts_skipped_and_noversion() -> None:
    """project reports skipped non-objects and version-less spans."""
    text = (
        '{"span":"tool","harness.issue":220,"harness.version":"v","span_id":"a"}\n'
        "garbage\n"
        '{"span":"tool","harness.issue":220,"span_id":"b"}\n'
    )
    skipped, noversion, envelopes = project(text)
    assert skipped == 1
    assert noversion == 1
    assert len(envelopes) == 2
