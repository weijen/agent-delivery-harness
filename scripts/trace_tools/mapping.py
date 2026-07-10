"""Shared span-projection primitives for the trace exporters.

This module is the single source of truth for the shippable-attribute
**allowlist v1** and the jq-compatible value/line helpers that the
App-Insights (and, later, OTLP) projections build on. Keeping the allowlist
here — rather than duplicated inside each jq heredoc — lets a fitness test
assert the Python surface matches the jq copy byte-for-byte.

The helpers deliberately mirror jq semantics so a Python projection can emit
the *logical* JSON structure while jq owns final serialization:

* :func:`shippable_key` mirrors the jq ``shippable_key`` (allowlist membership
  OR the ``gen_ai.usage.`` prefix rule);
* :func:`jq_tostring` mirrors jq ``tostring`` (strings pass through; booleans
  become ``true``/``false``; ``null`` becomes ``"null"``; numbers use their
  canonical decimal form);
* :func:`jq_alt` mirrors the jq ``//`` alternative operator (replace only
  ``null``/``false``, never an empty string);
* :func:`split_input_lines` mirrors ``jq -R`` line splitting so the
  skip-and-count census matches jq exactly.
"""

from __future__ import annotations

import json

# Shippable-attribute ALLOWLIST v1 — MUST stay byte-identical (same members,
# same order is not required for membership but is preserved for parity with
# the jq copy) to the ``def allowlist`` lists in scripts/trace-export.sh. Any
# key not matched here (and not under the gen_ai.usage.* prefix) is dropped
# before envelope construction.
ALLOWLIST: tuple[str, ...] = (
    "schema_version",
    "timestamp",
    "span",
    "span_id",
    "parent_span_id",
    "harness.issue",
    "harness.version",
    "harness.lifecycle_step",
    "harness.outcome",
    "harness.failure_mode",
    "harness.exit_status",
    "harness.duration_ms",
    "harness.incomplete_count",
    "harness.violation_count",
    "harness.warning_count",
    "harness.feature_id",
    "harness.stage",
    "gen_ai.tool.name",
    "gen_ai.operation.name",
    "gen_ai.agent.name",
    "gen_ai.request.model",
    "harness.review_gate_sha",
    "harness.pr_number",
    "harness.require_complete",
    "harness.warning",
    "harness.skill.name",
    "harness.subagent",
)

_USAGE_PREFIX = "gen_ai.usage."


def shippable_key(key: str) -> bool:
    """Return ``True`` when ``key`` may reach the exported envelope.

    Mirrors the jq ``shippable_key``: an allowlist member, or any key under
    the ``gen_ai.usage.`` prefix family.
    """
    return key in ALLOWLIST or key.startswith(_USAGE_PREFIX)


def is_usage_key(key: str) -> bool:
    """Return ``True`` for keys under the ``gen_ai.usage.`` prefix family."""
    return key.startswith(_USAGE_PREFIX)


def jq_tostring(value: object) -> str:
    """Stringify ``value`` the way jq's ``tostring`` filter does.

    Strings pass through unchanged; booleans become ``true``/``false``;
    ``None`` becomes ``"null"``; integers and floats use their canonical
    decimal form; containers fall back to compact JSON.
    """
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return _format_float(value)
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _format_float(value: float) -> str:
    """Render a float the way jq would (integral floats drop the fraction)."""
    if value.is_integer():
        return str(int(value))
    return repr(value)


def jq_alt(value: object, default: object) -> object:
    """Mirror the jq ``//`` operator: replace only ``null``/``false``.

    Unlike Python truthiness, an empty string, ``0``, or an empty container
    is kept — only ``None`` and ``False`` fall through to ``default``.
    """
    if value is None or value is False:
        return default
    return value


def split_input_lines(text: str) -> list[str]:
    """Split raw exporter input into lines the way ``jq -R`` reads them.

    A single trailing newline is a line terminator (not an extra empty line);
    interior blank lines are preserved so the skip-and-count census matches
    jq exactly. An empty input yields no lines.
    """
    if text.endswith("\n"):
        text = text[:-1]
    if text == "":
        return []
    return text.split("\n")


def parse_spans(text: str) -> tuple[int, list[dict[str, object]]]:
    """Parse exporter input into spans, returning ``(skipped, spans)``.

    Mirrors the jq ``[inputs] | fromjson? | select(type == "object")``
    pipeline: lines that are not valid JSON, or valid JSON that is not an
    object, are dropped and counted as ``skipped``.
    """
    lines = split_input_lines(text)
    spans: list[dict[str, object]] = []
    for line in lines:
        try:
            parsed = json.loads(line)
        except ValueError:
            continue
        if isinstance(parsed, dict):
            spans.append(parsed)
    return len(lines) - len(spans), spans
