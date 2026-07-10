"""OTLP/HTTP+JSON ``resourceSpans`` projection (Python parity with jq).

This module reimplements the ``export-otlp.jq`` program embedded in
scripts/trace-export.sh: it projects schema-v1 spans onto an OTLP
``{ resourceSpans: [...] }`` body. It emits the **logical** JSON structure in
jq's exact key-insertion order and value types; scripts/trace-export.sh then
pretty-prints the result through ``jq .`` so the on-disk bytes stay
jq-canonical in both engines (the #223 deep-link byte-parity contract).

The deterministic per-issue ``traceId`` derivation (``harness.issue`` → 32
lowercase hex) is the branch #223's App Insights deep-link keys on, so it is
reproduced here byte-for-byte. Nanosecond timestamps exceed float precision, so
``startTimeUnixNano`` / ``endTimeUnixNano`` are built by **string concatenation
and integer math only** — never floating-point multiplication — exactly as the
jq ``start_nanos`` / ``end_nanos`` defs do.
"""

from __future__ import annotations

import calendar
import time

from trace_tools.mapping import (
    jq_alt,
    jq_tostring,
    parse_spans,
    shippable_key,
)

_ISO_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def _int_floor_nonneg(value: object) -> int:
    """Mirror jq ``(. // 0) | floor | if . < 0 then 0 else . end`` for numbers."""
    number = value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0
    number = int(number)
    return 0 if number < 0 else number


def trace_id(span: dict[str, object]) -> str:
    """Derive the 32-lowercase-hex OTLP ``traceId`` from ``harness.issue``.

    Mirrors the jq ``trace_id`` def: ``harness.issue`` (missing → 0) floored and
    clamped to non-negative, rendered as lowercase hex, left-padded with ``0``
    to 32 chars. A zero/missing issue folds to 32 zeros.
    """
    issue = _int_floor_nonneg(span.get("harness.issue"))
    return format(issue, "x").zfill(32)


def _epoch_seconds(span: dict[str, object]) -> int:
    """Span ISO-8601 (``...Z``) timestamp → integer epoch seconds (UTC).

    Matches jq ``fromdateiso8601`` for the strict ``%Y-%m-%dT%H:%M:%SZ`` form
    the schema-v1 corpus uses.
    """
    stamp = jq_alt(span.get("timestamp"), "")
    return calendar.timegm(time.strptime(str(stamp), _ISO_FORMAT))


def start_nanos(span: dict[str, object]) -> str:
    """Build ``startTimeUnixNano`` by string concat: ``"<epoch>000000000"``."""
    return f"{_epoch_seconds(span)}000000000"


def end_nanos(span: dict[str, object]) -> str:
    """Build ``endTimeUnixNano`` folding ``harness.duration_ms`` exactly.

    Whole seconds of the duration fold into the epoch; the sub-second remainder
    is a zero-padded 9-digit nanosecond field. All string/integer math (never
    float), matching the jq ``end_nanos`` def; no/negative duration → end
    equals start (single-point).
    """
    epoch = _epoch_seconds(span)
    millis = _int_floor_nonneg(span.get("harness.duration_ms"))
    end_epoch = epoch + millis // 1000
    remainder_ns = (millis % 1000) * 1_000_000
    return f"{end_epoch}{str(remainder_ns).zfill(9)}"


def span_name(span: dict[str, object]) -> object:
    """Span display name with a per-type fallback to the span type.

    Mirrors the jq ``span_name`` def: tool→``gen_ai.tool.name``,
    lifecycle→``harness.lifecycle_step``, agent→``gen_ai.agent.name``,
    model→``gen_ai.request.model``; each falls back to ``.span`` (and the
    default branch falls back to the literal ``"span"``).
    """
    kind = span.get("span")
    fallback = span.get("span")
    if kind == "tool":
        return jq_alt(span.get("gen_ai.tool.name"), fallback)
    if kind == "lifecycle":
        return jq_alt(span.get("harness.lifecycle_step"), fallback)
    if kind == "agent":
        return jq_alt(span.get("gen_ai.agent.name"), fallback)
    if kind == "model":
        return jq_alt(span.get("gen_ai.request.model"), fallback)
    return jq_alt(span.get("span"), "span")


def otlp_attributes(span: dict[str, object]) -> list[dict[str, object]]:
    """Project allowlisted span keys onto OTLP attribute objects.

    Preserves the span's key order; every value is stringified onto
    ``stringValue`` (mirrors the jq ``otlp_attributes`` def).
    """
    return [
        {"key": key, "value": {"stringValue": jq_tostring(value)}}
        for key, value in span.items()
        if shippable_key(key)
    ]


def otlp_span(span: dict[str, object]) -> dict[str, object]:
    """Project a single schema-v1 span onto one OTLP span (jq key order).

    ``parentSpanId`` is appended last and OMITTED entirely when there is no
    non-empty ``parent_span_id`` (never fabricated).
    """
    result: dict[str, object] = {
        "traceId": trace_id(span),
        "spanId": jq_alt(span.get("span_id"), ""),
        "name": span_name(span),
        "kind": 1,
        "startTimeUnixNano": start_nanos(span),
        "endTimeUnixNano": end_nanos(span),
        "attributes": otlp_attributes(span),
    }
    parent = jq_alt(span.get("parent_span_id"), "")
    if isinstance(parent, str) and len(parent) > 0:
        result["parentSpanId"] = parent
    return result


def project(text: str) -> tuple[int, int, int, dict[str, object]]:
    """Project raw exporter input onto an OTLP ``resourceSpans`` body.

    Returns ``(skipped, noversion, count, body)`` mirroring the jq marker
    protocol: ``skipped`` non-object lines, ``noversion`` spans lacking
    ``harness.version``, ``count`` projected spans, and the ``resourceSpans``
    object with keys in the exact jq order.
    """
    skipped, spans = parse_spans(text)
    noversion = sum(1 for span in spans if "harness.version" not in span)
    body: dict[str, object] = {
        "resourceSpans": [
            {
                "resource": {
                    "attributes": [
                        {
                            "key": "service.name",
                            "value": {"stringValue": "agent-delivery-harness"},
                        }
                    ]
                },
                "scopeSpans": [
                    {
                        "scope": {"name": "agent-delivery-harness"},
                        "spans": [otlp_span(span) for span in spans],
                    }
                ],
            }
        ]
    }
    return skipped, noversion, len(spans), body
