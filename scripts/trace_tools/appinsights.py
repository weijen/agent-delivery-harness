"""App-Insights Track API envelope projection (Python parity with jq).

This module reimplements the ``export-envelopes.jq`` program embedded in
scripts/trace-export.sh: it projects schema-v1 spans onto Application Insights
Track API envelopes (``RemoteDependencyData`` for tool/lifecycle spans,
``EventData`` for agent/model spans). It emits the **logical** JSON structure
in jq's exact key-insertion order and value types; scripts/trace-export.sh then
pretty-prints the result through ``jq .`` so the on-disk bytes stay
jq-canonical in both engines (the #223 deep-link byte-parity contract).
"""

from __future__ import annotations

from trace_tools.mapping import (
    is_usage_key,
    jq_alt,
    jq_tostring,
    parse_spans,
    shippable_key,
)

_DAY_MS = 86_400_000
_HOUR_MS = 3_600_000
_MINUTE_MS = 60_000
_SECOND_MS = 1_000


def _props(span: dict[str, object]) -> dict[str, str]:
    """Project allowlisted span keys onto stringified ``customDimensions``.

    Preserves the span's key order and stringifies every value (Track API
    ``customDimensions`` are strings; numeric analysis rides ``measurements``).
    """
    return {key: jq_tostring(value) for key, value in span.items() if shippable_key(key)}


def _fmt_duration(span: dict[str, object]) -> str:
    """Render ``harness.duration_ms`` as a .NET TimeSpan (``hh:mm:ss.fff``).

    Absent/``null`` input floors to ``00:00:00.000``; a negative input clamps
    to the same honest floor; ``>= 24h`` gains a ``d.`` day segment.
    """
    raw = span.get("harness.duration_ms")
    total = raw if isinstance(raw, (int, float)) and not isinstance(raw, bool) else 0
    total = int(total)
    if total < 0:
        total = 0
    days = total // _DAY_MS
    prefix = f"{days}." if days > 0 else ""
    hours = (total % _DAY_MS) // _HOUR_MS
    minutes = (total % _HOUR_MS) // _MINUTE_MS
    seconds = (total % _MINUTE_MS) // _SECOND_MS
    millis = total % _SECOND_MS
    return f"{prefix}{hours:02d}:{minutes:02d}:{seconds:02d}.{millis:03d}"


def _dependency_base(span: dict[str, object]) -> dict[str, object]:
    """Build ``RemoteDependencyData.baseData`` for a tool/lifecycle span."""
    is_tool = span.get("span") == "tool"
    if is_tool:
        name = jq_alt(span.get("gen_ai.tool.name"), "unknown")
    else:
        name = jq_alt(span.get("harness.lifecycle_step"), "unknown")
    base: dict[str, object] = {
        "ver": 2,
        "name": name,
        "id": jq_alt(span.get("span_id"), ""),
        "type": "harness.tool" if is_tool else "harness.lifecycle",
        "duration": _fmt_duration(span),
        "success": (span["harness.outcome"] == "pass") if "harness.outcome" in span else True,
        "properties": _props(span),
    }
    if "harness.exit_status" in span:
        base["resultCode"] = jq_tostring(span["harness.exit_status"])
    elif "harness.outcome" in span:
        base["resultCode"] = jq_tostring(span["harness.outcome"])
    return base


def _event_base(span: dict[str, object]) -> dict[str, object]:
    """Build ``EventData.baseData`` for an agent/model span."""
    is_agent = span.get("span") == "agent"
    if is_agent:
        name = f"harness.agent/{jq_tostring(jq_alt(span.get('gen_ai.agent.name'), 'unknown'))}"
    else:
        name = f"harness.model/{jq_tostring(jq_alt(span.get('gen_ai.request.model'), 'unknown'))}"
    base: dict[str, object] = {
        "ver": 2,
        "name": name,
        "properties": _props(span),
    }
    measurements = {
        key: value
        for key, value in span.items()
        if is_usage_key(key) and isinstance(value, (int, float)) and not isinstance(value, bool)
    }
    if measurements:
        base["measurements"] = measurements
    return base


def build_envelope(span: dict[str, object]) -> dict[str, object]:
    """Project a single span onto one Track API envelope (jq key order)."""
    kind = span.get("span")
    if kind in ("tool", "lifecycle"):
        shape_name = "Microsoft.ApplicationInsights.RemoteDependency"
        data: dict[str, object] = {
            "baseType": "RemoteDependencyData",
            "baseData": _dependency_base(span),
        }
    else:
        shape_name = "Microsoft.ApplicationInsights.Event"
        data = {"baseType": "EventData", "baseData": _event_base(span)}
    issue = jq_tostring(jq_alt(span.get("harness.issue"), "unknown"))
    return {
        "ver": 1,
        "name": shape_name,
        "time": jq_alt(span.get("timestamp"), ""),
        "sampleRate": 100,
        "tags": {
            "ai.cloud.role": "agent-delivery-harness",
            "ai.operation.id": f"issue-{issue}",
        },
        "data": data,
    }


def project(text: str) -> tuple[int, int, list[dict[str, object]]]:
    """Project raw exporter input onto envelopes.

    Returns ``(skipped, noversion, envelopes)`` mirroring the jq marker
    protocol: ``skipped`` non-object lines, ``noversion`` spans lacking
    ``harness.version``, and the built envelope array.
    """
    skipped, spans = parse_spans(text)
    noversion = sum(1 for span in spans if "harness.version" not in span)
    envelopes = [build_envelope(span) for span in spans]
    return skipped, noversion, envelopes
