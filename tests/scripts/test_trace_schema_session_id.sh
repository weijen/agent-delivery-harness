#!/usr/bin/env bash
# test_trace_schema_session_id.sh — regression sensor for the OPTIONAL
# harness.session_id trace attribute (issue #147, feature
# trace-schema-session-id).
#
# harness.session_id is the runtime-session identity carried on spans emitted
# by a runtime adapter (Copilot/Claude), the universal join key that links a
# hook payload, a per-session transcript, a debug-log dir, and the local
# session store (see docs/runtime-adapters/*). It is the OTel
# gen_ai.conversation.id role expressed under the harness.* namespace: a
# STRING, and OPTIONAL (absence must stay valid — legacy traces and
# non-session-aware emitters carry no session id).
#
# Executable spec, pinned here (tolerant but real):
#
#   1. The frozen schema contract (docs/evaluation/trace-schema.v1.json)
#      declares harness.session_id under .optional_fields, and its doc string
#      is a NON-EMPTY string (open-world additions land in optional_fields;
#      the required sets stay frozen).
#   2. That doc string conveys the two load-bearing facts: it is a `string`
#      and it carries session/conversation identity (grep for `session` and
#      `string`, case-insensitive — tolerant to wording).
#   3. The prose authority (docs/evaluation/observability-and-trace-schema.md)
#      documents harness.session_id and ties it to session/conversation
#      identity — a flattened-newline grep for `harness.session_id` AND
#      `session` AND one of {conversation, gen_ai.conversation.id,
#      runtime session}.
#   4. Backward-compat / validation: a hermetic trace holding (a) a normal
#      lifecycle span WITHOUT session_id and (b) a span WITH harness.session_id
#      set to a STRING value validates cleanly under scripts/check-trace-consistency.sh
#      (exit 0, zero violations) — proving session_id-bearing spans are
#      accepted and their absence stays valid. Both spans carry the mandatory
#      common fields (schema_version, timestamp, span, harness.issue,
#      harness.version) so session_id is the only dimension under test.
#   5. harness.session_id is treated as a STRING, never a number: it must NOT
#      appear in the numeric-keys list of scripts/check-trace-consistency.sh (a string
#      key typed as numeric would reject its string value as a
#      type_violation).
#
# RED before the schema/doc land (pins 1-3 fail: the attribute is undeclared);
# GREEN after. Pin 4 may already pass under the open-world contract; pin 5
# holds as long as the attribute is not mistyped as numeric.
#
# Exit codes: 0 all obligations honored · 1 an obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
OBS_DOC="${ROOT}/docs/evaluation/observability-and-trace-schema.md"
VALIDATOR="${ROOT}/scripts/check-trace-consistency.sh"
SESSION_KEY="harness.session_id"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}
hard_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Prerequisites -------------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required (the schema contract and validator are jq-driven)"
[ -f "$CONTRACT" ] \
  || hard_fail "trace schema contract not found (${CONTRACT})"
[ -f "$OBS_DOC" ] \
  || hard_fail "observability prose authority not found (${OBS_DOC})"
[ -x "$VALIDATOR" ] \
  || hard_fail "scripts/check-trace-consistency.sh not found or not executable (${VALIDATOR})"

# --- 1. Schema declares harness.session_id with a non-empty string doc ---------
if ! jq -e '.optional_fields["harness.session_id"] | type == "string" and (length > 0)' \
    "$CONTRACT" >/dev/null 2>&1; then
  fail "schema contract must declare .optional_fields[\"harness.session_id\"] as a non-empty string doc (${CONTRACT})"
fi

# --- 2. The doc string names it a string carrying session identity -------------
session_doc="$(jq -r '.optional_fields["harness.session_id"] // ""' "$CONTRACT" 2>/dev/null || true)"
if ! printf '%s' "$session_doc" | grep -qi 'session'; then
  fail "harness.session_id doc string must convey session identity (mention 'session')"
fi
if ! printf '%s' "$session_doc" | grep -qi 'string'; then
  fail "harness.session_id doc string must state its type is 'string'"
fi

# --- 3. Prose authority documents harness.session_id ---------------------------
# Flatten newlines so a table row / prose spanning lines still matches.
obs_flat="$(tr '\n' ' ' < "$OBS_DOC")"
if ! printf '%s' "$obs_flat" | grep -Fq "$SESSION_KEY"; then
  fail "observability doc must document ${SESSION_KEY} (${OBS_DOC})"
fi
if ! printf '%s' "$obs_flat" | grep -qi 'session'; then
  fail "observability doc must mention 'session' near ${SESSION_KEY}"
fi
if ! printf '%s' "$obs_flat" \
    | grep -Eqi 'conversation|gen_ai\.conversation\.id|runtime session'; then
  fail "observability doc must tie ${SESSION_KEY} to conversation/runtime-session identity (one of: conversation, gen_ai.conversation.id, runtime session)"
fi

# --- 4. A trace with and without session_id validates cleanly ------------------
# Hermetic path-mode trace: span A has no session id; span B carries a STRING
# harness.session_id. Both carry the mandatory common fields; both are
# lifecycle spans with a valid (non-finish) step, so the completeness pass is
# skipped and only the session_id dimension is exercised. Under the open-world
# contract this may already pass — that is the backward-compat guarantee, not a
# weakness of the sensor.
TRACE="${TMP_DIR}/trace.jsonl"
printf '# Progress\n\n## Action Log\n' > "${TMP_DIR}/progress.md"
{
  printf '{"schema_version":1,"timestamp":"2026-07-07T12:00:00Z","span":"lifecycle","harness.issue":147,"harness.version":"abc1234","harness.lifecycle_step":"preflight"}\n'
  printf '{"schema_version":1,"timestamp":"2026-07-07T12:00:01Z","span":"lifecycle","harness.issue":147,"harness.version":"abc1234","harness.lifecycle_step":"feature_start","harness.session_id":"sess-2f9c1a7b-0001"}\n'
} > "$TRACE"

# Fixture self-checks: exactly one span carries a STRING session_id, one omits
# it — so pin 4 cannot pass vacuously.
jq -es 'length == 2' "$TRACE" >/dev/null 2>&1 \
  || hard_fail "session_id fixture trace is not 2 valid JSONL spans — sensor bug"
jq -es 'any(.[]; (.["harness.session_id"] | type) == "string")' "$TRACE" >/dev/null 2>&1 \
  || hard_fail "session_id fixture must include a span with a STRING harness.session_id — sensor bug"
jq -es 'any(.[]; has("harness.session_id") | not)' "$TRACE" >/dev/null 2>&1 \
  || hard_fail "session_id fixture must include a span WITHOUT harness.session_id — sensor bug"

vout="${TMP_DIR}/validate.out"
verr="${TMP_DIR}/validate.err"
vrc=0
"$VALIDATOR" "$TRACE" >"$vout" 2>"$verr" || vrc=$?
if [ "$vrc" != "0" ]; then
  fail "check-trace-consistency.sh must accept a trace with and without harness.session_id (exit 0), got ${vrc} (stdout: $(tr '\n' '|' < "$vout"))"
fi
if grep -q 'VIOLATION' "$vout" "$verr" 2>/dev/null; then
  fail "a string-valued harness.session_id span must produce zero VIOLATION findings"
fi

# --- 5. harness.session_id is not typed as numeric -----------------------------
# The validator's numeric-keys array is the only place string keys would be
# forced to a number. Capture the array literal (from its first element line
# through the `as $numeric_keys` binding) and assert session_id is absent.
numeric_keys_block="$(awk '
  /\["harness\.exit_status"/ { cap = 1 }
  cap { print }
  /as \$numeric_keys/ { if (cap) exit }
' "$VALIDATOR")"
if [ -z "$numeric_keys_block" ]; then
  hard_fail "could not locate the numeric-keys array in ${VALIDATOR} — validator shape changed; update this sensor"
fi
if printf '%s' "$numeric_keys_block" | grep -Fq 'session_id'; then
  fail "harness.session_id must NOT be in the numeric-keys list of check-trace-consistency.sh — it is a string, not a number"
fi

# --- Verdict -------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d check(s) failed: harness.session_id is not fully declared/typed as an optional string.\n' "$fails" >&2
  exit 1
fi
printf 'PASS: harness.session_id declared as an optional string; session-bearing and session-free spans both validate.\n'
exit 0
