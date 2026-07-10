"""Unit tests for :mod:`trace_tools.logmap` (step-level log projection)."""

from __future__ import annotations

from typing import cast

from trace_tools.logmap import (
    log_record,
    message_envelope,
    project_appinsights,
    project_otlp,
    severity_level,
    severity_number,
    time_unix_nano,
)

_TS = "2026-07-10T10:00:00Z"
_EPOCH = 1783677600

_INFO_RECORD: dict[str, object] = {
    "log_schema_version": 1,
    "timestamp": _TS,
    "level": "info",
    "harness.issue": 220,
    "message": "tool invoked",
    "span_id": "aaaaaaaaaaaaaaaa",
    "parent_span_id": "cccccccccccccccc",
    "gen_ai.tool.name": "bash",
    "harness.args_summary": "ARGSLEAK free text ghp_FAKEtoken",
}

_ERROR_RECORD: dict[str, object] = {
    "log_schema_version": 1,
    "timestamp": "2026-07-10T10:00:02Z",
    "level": "error",
    "harness.issue": 220,
    "message": "step failed",
}


def _base_data(envelope: dict[str, object]) -> dict[str, object]:
    """Extract ``data.baseData`` as a typed dict for assertions."""
    data = cast(dict[str, object], envelope["data"])
    return cast(dict[str, object], data["baseData"])


def test_severity_number_maps_levels() -> None:
    """OTLP severityNumber: info→9, warn→13, error→17; unknown→0."""
    assert severity_number("info") == 9
    assert severity_number("warn") == 13
    assert severity_number("error") == 17
    assert severity_number("debug") == 0
    assert severity_number(None) == 0


def test_severity_level_maps_levels() -> None:
    """App-Insights severityLevel: info→1, warn→2, error→3; unknown→0."""
    assert severity_level("info") == 1
    assert severity_level("warn") == 2
    assert severity_level("error") == 3
    assert severity_level("trace") == 0


def test_time_unix_nano_is_epoch_string_plus_nine_zeros() -> None:
    """timeUnixNano reuses the otlp epoch derivation: ``"<epoch>000000000"``."""
    result = time_unix_nano({"timestamp": _TS})
    assert result == f"{_EPOCH}000000000"
    assert isinstance(result, str)


def test_log_record_reuses_span_trace_id() -> None:
    """traceId reuses otlp.trace_id — issue 220 → 32-hex ending ``dc``."""
    record = log_record(_INFO_RECORD)
    assert record["traceId"] == "000000000000000000000000000000dc"


def test_log_record_carries_span_id_when_present() -> None:
    """A record with span_id carries .spanId; key order appends it last."""
    record = log_record(_INFO_RECORD)
    assert record["spanId"] == "aaaaaaaaaaaaaaaa"
    assert list(record.keys()) == [
        "traceId",
        "timeUnixNano",
        "severityNumber",
        "severityText",
        "body",
        "attributes",
        "spanId",
    ]


def test_log_record_omits_span_id_when_absent() -> None:
    """A record with no span_id has NO .spanId — never fabricated."""
    record = log_record(_ERROR_RECORD)
    assert "spanId" not in record


def test_log_record_omits_span_id_when_empty() -> None:
    """An empty span_id is treated as absent — never a fabricated empty id key."""
    record = log_record({**_ERROR_RECORD, "span_id": ""})
    assert "spanId" not in record


def test_log_record_body_and_severity_text() -> None:
    """body.stringValue is the message; severityText is the level string."""
    record = log_record(_INFO_RECORD)
    body = cast(dict[str, object], record["body"])
    assert body["stringValue"] == "tool invoked"
    assert record["severityText"] == "info"
    assert record["severityNumber"] == 9


def test_log_record_attributes_allowlist_drop() -> None:
    """Allowlisted keys become attributes; free-text/secret keys are dropped."""
    record = log_record(_INFO_RECORD)
    attrs = cast(list[dict[str, object]], record["attributes"])
    keys = [a["key"] for a in attrs]
    assert "gen_ai.tool.name" in keys
    assert "harness.issue" in keys
    assert "harness.args_summary" not in keys
    assert "message" not in keys
    assert "level" not in keys
    for attr in attrs:
        value = cast(dict[str, object], attr["value"])
        assert isinstance(value["stringValue"], str)


def test_message_envelope_shape_and_correlation() -> None:
    """MessageData envelope: name/baseType/ver, operation id + parentId, no iKey."""
    envelope = message_envelope(_INFO_RECORD)
    assert envelope["ver"] == 1
    assert envelope["name"] == "Microsoft.ApplicationInsights.Message"
    assert envelope["time"] == _TS
    assert "iKey" not in envelope
    data = cast(dict[str, object], envelope["data"])
    assert data["baseType"] == "MessageData"
    base = _base_data(envelope)
    assert base["message"] == "tool invoked"
    assert base["severityLevel"] == 1
    tags = cast(dict[str, object], envelope["tags"])
    assert tags["ai.operation.id"] == "issue-220"
    assert tags["ai.operation.parentId"] == "aaaaaaaaaaaaaaaa"


def test_message_envelope_omits_parent_id_when_no_span() -> None:
    """An uncorrelated record has NO ai.operation.parentId tag."""
    envelope = message_envelope(_ERROR_RECORD)
    tags = cast(dict[str, object], envelope["tags"])
    assert "ai.operation.parentId" not in tags
    assert tags["ai.operation.id"] == "issue-220"


def test_message_envelope_properties_allowlist_stringified() -> None:
    """properties carry only allowlisted keys, stringified; secrets dropped."""
    envelope = message_envelope(_INFO_RECORD)
    props = cast(dict[str, object], _base_data(envelope)["properties"])
    assert props["gen_ai.tool.name"] == "bash"
    assert "harness.args_summary" not in props
    for value in props.values():
        assert isinstance(value, str)


def test_project_otlp_marker_counts_and_body_shape() -> None:
    """project_otlp returns skip/count markers and the resourceLogs body."""
    text = "\n".join(
        [
            '{"log_schema_version":1,"timestamp":"' + _TS + '","level":"info",'
            '"harness.issue":220,"message":"a","span_id":"aaaaaaaaaaaaaaaa"}',
            "not json at all",
            '{"log_schema_version":1,"timestamp":"' + _TS + '","level":"error",'
            '"harness.issue":220,"message":"b"}',
        ]
    )
    skipped, count, body = project_otlp(text)
    assert skipped == 1
    assert count == 2
    records = body["resourceLogs"][0]["scopeLogs"][0]["logRecords"]  # type: ignore[index]
    assert len(records) == 2
    assert all(r["traceId"] == "000000000000000000000000000000dc" for r in records)


def test_project_appinsights_one_envelope_per_record() -> None:
    """project_appinsights returns skip marker and one envelope per record."""
    text = "\n".join(
        [
            '{"log_schema_version":1,"timestamp":"' + _TS + '","level":"warn",'
            '"harness.issue":220,"message":"a"}',
            "",
            '{"log_schema_version":1,"timestamp":"' + _TS + '","level":"error",'
            '"harness.issue":220,"message":"b"}',
        ]
    )
    skipped, envelopes = project_appinsights(text)
    assert skipped == 1
    assert len(envelopes) == 2
    assert all(e["name"] == "Microsoft.ApplicationInsights.Message" for e in envelopes)
