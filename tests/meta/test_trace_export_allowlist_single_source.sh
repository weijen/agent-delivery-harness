#!/usr/bin/env bash
# test_trace_export_allowlist_single_source.sh — meta drift sensor for issue
# #220, feature `trace-export-dispatcher` (plan Phase 4).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   The shippable-attribute allowlist is reimplemented in THREE places that
#   MUST NOT drift from one another:
#     1. the Python pilot tuple `ALLOWLIST` in scripts/trace_tools/mapping.py
#        (its comment states it "MUST stay byte-identical (same members,
#        order)" to the jq copies);
#     2. the `def allowlist:` member list in the App-Insights projection of
#        scripts/trace-export.sh (~L624);
#     3. the `def allowlist:` member list in the OTLP projection of the same
#        file (~L828).
#
#   All three lists must carry the SAME members in the SAME order. If any copy
#   adds, removes, or reorders a key, the Python engine and the jq engine can
#   silently ship different attribute sets — the exact drift the dispatcher's
#   both-paths-green contract forbids. This sensor is the single-source guard.
#
#   The gen_ai.usage.* PREFIX family is NOT a member of these arrays (it lives
#   in the startswith rule of `shippable_key` / `is_shippable`), so it is
#   correctly excluded from the ordered member comparison.
#
# SOURCE OF TRUTH: no separate ORDERED 27-key allowlist is published under
# docs/ — docs/evaluation/trace-schema.v1.json is a SUPERSET vocabulary (it
# also documents deliberately-excluded free-text keys), and the subset
# invariant allowlist ⊆ documented is already guarded by
# tests/meta/test_trace_export_allowlist_contract.sh. Therefore the CODE
# copies above are the source of truth for the allowlist's members AND order,
# and this sensor asserts the three code copies agree exactly. If an ordered
# contract list is ever published, add it here as a fourth source.
#
# MUTATION-VERIFIABLE: adding, removing, or reordering a key in ANY of the
# three copies makes at least one ordered comparison differ → non-zero exit.
#
# Exit codes: 0 all three copies carry identical members in identical order ·
# 1 a copy drifted (or an extraction returned nothing — a shape change).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MAPPING="$ROOT/scripts/trace_tools/mapping.py"
EXPORT="$ROOT/scripts/trace-export.sh"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$MAPPING" ] || hard_fail "Python mapping not found: $MAPPING"
[ -f "$EXPORT" ] || hard_fail "trace-export.sh not found: $EXPORT"

# --- Extractor 1: the Python ALLOWLIST tuple, in source order ----------------
# Slice from the tuple assignment to its closing paren, then pull the quoted
# members in order (one per line).
py_allowlist() {
  sed -n '/^ALLOWLIST: tuple/,/^)/p' "$MAPPING" \
    | grep -oE '"[A-Za-z0-9_.]+"' \
    | tr -d '"'
}

# --- Extractor 2/3: the Nth `def allowlist:` jq member list, in source order --
# State machine: count `def allowlist:` occurrences; capture lines of the
# requested block up to and including the terminating `];`; pull quoted members.
jq_allowlist() { # jq_allowlist <block-index>
  awk -v want="$1" '
    /def allowlist:/ { blk++; if (blk == want) { cap = 1 } }
    cap { print }
    cap && /\];/ { cap = 0 }
  ' "$EXPORT" \
    | grep -oE '"[A-Za-z0-9_.]+"' \
    | tr -d '"'
}

# --- Confirm there are exactly TWO jq copies (the two projections) -----------
jq_copies="$(grep -c 'def allowlist:' "$EXPORT" || true)"
if [ "$jq_copies" != "2" ]; then
  fail "expected exactly 2 jq \`def allowlist:\` copies in trace-export.sh (App-Insights + OTLP), found ${jq_copies} — the extraction shape changed"
fi

PY="$(py_allowlist)"
JQ1="$(jq_allowlist 1)"
JQ2="$(jq_allowlist 2)"

# --- Non-empty extraction (a shape change would silently pass an == of "") ---
[ -n "$PY" ] || fail "Python ALLOWLIST tuple extraction returned nothing — the tuple shape in mapping.py changed"
[ -n "$JQ1" ] || fail "jq allowlist copy #1 (App-Insights projection) extraction returned nothing — the def allowlist shape changed"
[ -n "$JQ2" ] || fail "jq allowlist copy #2 (OTLP projection) extraction returned nothing — the def allowlist shape changed"

# --- Ordered equality across all three code copies ---------------------------
# Compare exact ordered member lists (newline-delimited) — a reorder differs
# even when the member SETS are equal.
if [ "$JQ1" != "$JQ2" ]; then
  fail "the two jq \`def allowlist:\` copies (App-Insights vs OTLP) differ in members/order:"$'\n'"$(diff <(printf '%s\n' "$JQ1") <(printf '%s\n' "$JQ2") || true)"
fi
if [ "$PY" != "$JQ1" ]; then
  fail "the Python ALLOWLIST tuple and the jq App-Insights \`def allowlist:\` differ in members/order (mapping.py must stay byte-identical — same members, same order):"$'\n'"$(diff <(printf '%s\n' "$PY") <(printf '%s\n' "$JQ1") || true)"
fi
if [ "$PY" != "$JQ2" ]; then
  fail "the Python ALLOWLIST tuple and the jq OTLP \`def allowlist:\` differ in members/order:"$'\n'"$(diff <(printf '%s\n' "$PY") <(printf '%s\n' "$JQ2") || true)"
fi

if [ "$fails" -ne 0 ]; then
  printf 'FAIL: trace-export allowlist single-source guard failed (%d issue(s))\n' "$fails" >&2
  exit 1
fi

printf 'PASS: all 3 allowlist copies (Python ALLOWLIST + 2 jq def allowlist) carry %s members in identical order\n' \
  "$(printf '%s\n' "$PY" | wc -l | tr -d ' ')"
exit 0
