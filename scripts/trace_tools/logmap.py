"""Step-level log projection — OTLP ``resourceLogs`` + App-Insights ``MessageData``.

This module projects the per-issue step-level detail stream
(``.copilot-tracking/issues/issue-NN/log.jsonl`` — schema:
``log_schema_version:1``, ``timestamp``, ``level`` (info|warn|error),
``harness.issue``, ``message``, optional ``span_id``/``parent_span_id``, plus
allowlisted ``key=value`` attrs) onto two signals, one record → one record:

* an OTLP/HTTP+JSON **logs** body (``{ resourceLogs: [...] }``) whose
  ``logRecords`` correlate to their issue's trace via the SAME deterministic
  per-issue ``traceId`` the span export emits (:func:`trace_tools.otlp.trace_id`)
  and to their span via the honest ``spanId`` (never fabricated); and
* Application Insights ``Microsoft.ApplicationInsights.Message`` envelopes
  (``MessageData``) correlated via ``ai.operation.id`` / ``ai.operation.parentId``.

It emits the **logical** JSON structure in jq's exact key-insertion order and
value types; scripts/log-export.sh then pretty-prints the result through
``jq .`` so the on-disk bytes stay jq-canonical in both engines (the #223
deep-link byte-parity contract). Nanosecond timestamps are built by string
concatenation only (never float), reusing the otlp epoch derivation.
"""

from __future__ import annotations

from trace_tools.mapping import jq_alt, jq_tostring, parse_spans, shippable_key
from trace_tools.otlp import otlp_attributes, start_nanos, trace_id

# OTLP SeverityNumber (INFO/WARN/ERROR) and App-Insights SeverityLevel
# (Information/Warning/Error). A level outside the schema-v1 enum folds to the
# unspecified/verbose floor rather than fabricating a bucket.
_OTLP_SEVERITY_NUMBER: dict[str, int] = {"info": 9, "warn": 13, "error": 17}
_APPINSIGHTS_SEVERITY_LEVEL: dict[str, int] = {"info": 1, "warn": 2, "error": 3}


def severity_number(level: object) -> int:
    """Map a log ``level`` onto its OTLP ``severityNumber`` (info→9/warn→13/error→17)."""
    return _OTLP_SEVERITY_NUMBER.get(level, 0) if isinstance(level, str) else 0


def severity_level(level: object) -> int:
    """Map a log ``level`` onto its App-Insights ``severityLevel`` (info→1/warn→2/error→3)."""
    return _APPINSIGHTS_SEVERITY_LEVEL.get(level, 0) if isinstance(level, str) else 0


def time_unix_nano(record: dict[str, object]) -> str:
    """Build ``timeUnixNano`` as ``"<epoch>000000000"`` (reuses the otlp derivation)."""
    return start_nanos(record)


def _span_id(record: dict[str, object]) -> str:
    """Return the record ``span_id`` when a non-empty string, else the empty string."""
    value = jq_alt(record.get("span_id"), "")
    return value if isinstance(value, str) else ""


def _properties(record: dict[str, object]) -> dict[str, str]:
    """Project allowlisted record keys onto stringified App-Insights ``customDimensions``.

    Deny-by-default (mirrors the span projection): only allowlisted keys (or a
    ``gen_ai.usage.*`` member) survive; every value is stringified. Free-text /
    non-allowlisted keys (``message``, ``level``, ``harness.args_summary`` …) are
    dropped entirely.
    """
    return {key: jq_tostring(value) for key, value in record.items() if shippable_key(key)}


def log_record(record: dict[str, object]) -> dict[str, object]:
    """Project one schema-v1 log record onto one OTLP ``logRecord`` (jq key order).

    ``spanId`` is appended last and OMITTED entirely when the record carries no
    non-empty ``span_id`` (honest correlation — never fabricated). ``traceId``
    reuses :func:`trace_tools.otlp.trace_id` so a log joins its issue's trace.
    """
    level = record.get("level")
    result: dict[str, object] = {
        "traceId": trace_id(record),
        "timeUnixNano": time_unix_nano(record),
        "severityNumber": severity_number(level),
        "severityText": jq_alt(level, ""),
        "body": {"stringValue": jq_alt(record.get("message"), "")},
        "attributes": otlp_attributes(record),
    }
    span_id = _span_id(record)
    if len(span_id) > 0:
        result["spanId"] = span_id
    return result


def message_envelope(record: dict[str, object]) -> dict[str, object]:
    """Project one schema-v1 log record onto one ``MessageData`` envelope (jq key order).

    Dry-run envelopes OMIT ``iKey`` (the transport injects it at ship time).
    ``tags["ai.operation.parentId"]`` carries the record ``span_id`` when present
    and is OMITTED when the record is uncorrelated (never fabricated).
    """
    issue = jq_tostring(jq_alt(record.get("harness.issue"), "unknown"))
    tags: dict[str, object] = {"ai.operation.id": f"issue-{issue}"}
    span_id = _span_id(record)
    if len(span_id) > 0:
        tags["ai.operation.parentId"] = span_id
    return {
        "ver": 1,
        "name": "Microsoft.ApplicationInsights.Message",
        "time": jq_alt(record.get("timestamp"), ""),
        "tags": tags,
        "data": {
            "baseType": "MessageData",
            "baseData": {
                "message": jq_alt(record.get("message"), ""),
                "severityLevel": severity_level(record.get("level")),
                "properties": _properties(record),
            },
        },
    }


def project_otlp(text: str) -> tuple[int, int, dict[str, object]]:
    """Project raw log input onto an OTLP ``resourceLogs`` body.

    Returns ``(skipped, count, body)`` mirroring the exporter marker protocol:
    ``skipped`` non-object lines, ``count`` projected records, and the
    ``resourceLogs`` object with keys in the exact jq order.
    """
    skipped, records = parse_spans(text)
    body: dict[str, object] = {
        "resourceLogs": [
            {
                "resource": {
                    "attributes": [
                        {
                            "key": "service.name",
                            "value": {"stringValue": "agent-delivery-harness"},
                        }
                    ]
                },
                "scopeLogs": [{"logRecords": [log_record(record) for record in records]}],
            }
        ]
    }
    return skipped, len(records), body


def project_appinsights(text: str) -> tuple[int, list[dict[str, object]]]:
    """Project raw log input onto App-Insights ``MessageData`` envelopes.

    Returns ``(skipped, envelopes)`` mirroring the exporter marker protocol:
    ``skipped`` non-object lines and one envelope per projected record.
    """
    skipped, records = parse_spans(text)
    envelopes = [message_envelope(record) for record in records]
    return skipped, envelopes
