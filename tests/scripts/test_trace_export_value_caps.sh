#!/usr/bin/env bash
# test_trace_export_value_caps.sh — regression sensor for the allowlisted
# STRING value caps in scripts/trace-export.sh (issue #113, feature
# trace-export-value-caps).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   Every allowlisted STRING value that would ride into an envelope's
#   properties (→ customDimensions) via the `def props` projection MUST be
#   capped before shipping:
#     1. MAX LENGTH 256 characters — a value of 256 is OK, 257 is over.
#     2. PRINTABLE CHARSET ONLY — no control / non-printable bytes.
#   These bound the shippable-attribute risk surface: an off-machine sink
#   should never receive an unbounded blob or a raw control byte smuggled
#   through an allowlisted key.
#
#   On ANY violation the WHOLE export REFUSES — all-or-nothing, exit
#   non-zero, and NOTHING is written (no dry-run file, no shipped
#   envelopes). The exporter must NEVER silently truncate an over-long
#   value nor strip a control byte: a value that cannot ship intact does
#   not ship at all, and it takes the whole batch down with it (mirroring
#   the harness.version all-or-nothing doctrine).
#
#   EXEMPTIONS: numeric fields and the `measurements` map (numeric
#   gen_ai.usage.* rides there as JSON NUMBERS) are NOT subject to the
#   string caps — length/charset checks apply to STRING customDimensions
#   values only.
#
#   GREEN-guard: a normal, in-bounds allowlisted value (a 40-char SHA
#   harness.version, a plain gen_ai.tool.name) must STILL ship unchanged —
#   the cap must not become an over-eager filter that drops legitimate
#   short printable values, and it must not mutate them.
#
# RED while `def props` in scripts/trace-export.sh only stringifies (line
# ~411): today an over-long value and a control-byte value both ride
# straight into the dry-run envelopes, so cases A / B / boundary-257
# currently SHIP → the refusal assertions FAIL. The GREEN-guard case and
# the 256-boundary case already ship today and stay green.
#
# Exit codes: 0 value-cap contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPORTER="${ROOT}/scripts/trace-export.sh"
TRACE_LIB="${ROOT}/scripts/trace-lib.sh"
ISSUE_LIB="${ROOT}/scripts/issue-lib.sh"
VALIDATOR="${ROOT}/scripts/validate-trace.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
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

# --- Prerequisites -----------------------------------------------------------
command -v jq >/dev/null 2>&1 \
  || hard_fail "jq is required to validate exporter value-cap behavior"
[ -f "$EXPORTER" ] \
  || hard_fail "scripts/trace-export.sh not found (${EXPORTER})"
[ -f "$TRACE_LIB" ] || hard_fail "scripts/trace-lib.sh not found (${TRACE_LIB})"
[ -f "$ISSUE_LIB" ] || hard_fail "scripts/issue-lib.sh not found (${ISSUE_LIB})"
[ -f "$VALIDATOR" ] || hard_fail "scripts/validate-trace.sh not found (${VALIDATOR})"
[ -f "$CONTRACT" ] || hard_fail "trace schema contract not found (${CONTRACT})"

# Pinned PATH with a tripwire curl: caps are an OUTPUT gate that must stop
# everything before any transport; any curl invocation here is a failure.
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for t in bash sh env git jq grep sed awk tr cut cat printf head tail sort wc \
  date dirname basename mkdir rm cp mv od cmp touch mktemp; do
  p="$(command -v "$t" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${t}"
done
CURL_MARKER="${TMP_DIR}/curl-was-called"
cat > "${BIN}/curl" <<SH
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "${CURL_MARKER}"
exit 7
SH
chmod +x "${BIN}/curl"

mk_repo() { # mk_repo <dir> — harness-shaped repo with the real scripts
  local d="$1"
  mkdir -p "${d}/scripts" "${d}/docs/evaluation"
  cp "$EXPORTER" "${d}/scripts/trace-export.sh"
  cp "$TRACE_LIB" "${d}/scripts/trace-lib.sh"
  cp "$ISSUE_LIB" "${d}/scripts/issue-lib.sh"
  cp "$VALIDATOR" "${d}/scripts/validate-trace.sh"
  cp "$CONTRACT" "${d}/docs/evaluation/trace-schema.v1.json"
  chmod +x "${d}/scripts/trace-export.sh" "${d}/scripts/validate-trace.sh"
  git -C "$d" init -q -b main
  git -C "$d" config user.name "Harness Test"
  git -C "$d" config user.email "harness-test@example.invalid"
}

FIX="${TMP_DIR}/fixture-repo"
mk_repo "$FIX"

run_export() { # run_export <repo> <report-file> [ENVKV...] -- <args...>
  local repo="$1" rep="$2"; shift 2
  local -a envkv=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envkv+=("$1"); shift
  done
  [ "${1:-}" = "--" ] && shift
  (cd "$repo" \
    && env -u TRACE_EXPORT_OTLP -u APPLICATIONINSIGHTS_CONNECTION_STRING \
       ${envkv[@]+"${envkv[@]}"} PATH="$BIN" \
       "./scripts/trace-export.sh" "$@") > "$rep" 2>&1
}

# Synthetic value builders (never real secrets — plain printable filler).
# A 40-char SHA-shaped harness.version, valid and in-bounds.
SHA40="a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0"
repeat_x() { # repeat_x <n> — <n> literal 'x' bytes, printable ASCII filler
  local n="$1"
  printf 'x%.0s' $(seq 1 "$n")
}
V256="$(repeat_x 256)"   # exactly the 256 boundary (OK)
V257="$(repeat_x 257)"   # one over (must refuse)
V300="$(repeat_x 300)"   # comfortably over (must refuse)

# A single clean, unfinished lifecycle span (validator's completeness pass
# is skipped for an unfinished trace) carrying an in-bounds harness.version.
clean_line() {
  printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:00Z\",\"span\":\"lifecycle\",\"harness.issue\":113,\"harness.version\":\"${SHA40}\",\"span_id\":\"vcap0001\",\"harness.lifecycle_step\":\"preflight\"}"
}

# --- Fixtures ---------------------------------------------------------------
# GREEN-guard: a normal, in-bounds trace (short printable values) — must ship.
GOOD="${TMP_DIR}/good.trace.jsonl"
{
  clean_line
  printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:01Z\",\"span\":\"tool\",\"harness.issue\":113,\"harness.version\":\"${SHA40}\",\"span_id\":\"vcap0002\",\"gen_ai.tool.name\":\"git\",\"harness.outcome\":\"pass\",\"harness.exit_status\":0,\"harness.duration_ms\":50}"
} > "$GOOD"

# 256-boundary GREEN: harness.version of EXACTLY 256 printable chars — the
# cap is inclusive at 256, so this must still ship.
OK256="${TMP_DIR}/ok256.trace.jsonl"
printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:00Z\",\"span\":\"lifecycle\",\"harness.issue\":113,\"harness.version\":\"${V256}\",\"span_id\":\"vcap0256\",\"harness.lifecycle_step\":\"preflight\"}" > "$OK256"

# 257-boundary RED: one char over the cap — must refuse.
OVER257="${TMP_DIR}/over257.trace.jsonl"
printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:00Z\",\"span\":\"lifecycle\",\"harness.issue\":113,\"harness.version\":\"${V257}\",\"span_id\":\"vcap0257\",\"harness.lifecycle_step\":\"preflight\"}" > "$OVER257"

# Case A RED: an over-long (300-char) allowlisted harness.version. The
# over-long span is an UNFINISHED tool span so the validator's completeness
# pass stays OFF — the ONLY thing that can refuse this export today is the
# value cap (which does not exist yet → RED). A 'finish' lifecycle span
# would refuse for the WRONG reason (Gate 1 completeness), masking the cap.
LONG="${TMP_DIR}/long.trace.jsonl"
{
  clean_line
  printf '%s\n' "{\"schema_version\":1,\"timestamp\":\"2026-07-05T09:00:01Z\",\"span\":\"tool\",\"harness.issue\":113,\"harness.version\":\"${V300}\",\"span_id\":\"vcap0300\",\"gen_ai.tool.name\":\"git\",\"harness.outcome\":\"pass\"}"
} > "$LONG"

# Case B RED: a raw control byte (0x07 BEL) inside an allowlisted string
# value (gen_ai.tool.name). Built with jq so the byte is embedded literally
# in a valid JSON string: implode a codepoint array so after jq -c
# serialization the raw 0x07 byte sits inside the "gen_ai.tool.name" value.
CTRL="${TMP_DIR}/ctrl.trace.jsonl"
{
  clean_line
  jq -cn --arg sha "$SHA40" \
    '{schema_version:1,timestamp:"2026-07-05T09:00:01Z",span:"tool","harness.issue":113,"harness.version":$sha,span_id:"vcap0ctl","gen_ai.tool.name":("git"+([7]|implode)+"hook"),"harness.outcome":"pass"}'
} > "$CTRL"

# ==============================================================================
# GREEN-guard: normal in-bounds trace ships — exit 0, dry-run file written,
# and the short printable values survive UNCHANGED in the envelopes.
# ==============================================================================
OUTG="${TMP_DIR}/good.envelopes.json"
rc=0
run_export "$FIX" "${TMP_DIR}/good.out" TRACE_EXPORT_OTLP=1 -- "$GOOD" --dry-run-to-file "$OUTG" || rc=$?
[ "$rc" = "0" ] \
  || fail "GREEN: a normal in-bounds trace must ship (exit 0), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/good.out")"
if [ -f "$OUTG" ]; then
  grep -v '^//' "$OUTG" \
    | jq -e --arg sha "$SHA40" \
        'any(.[]; .data.baseData.properties["harness.version"] == $sha)' >/dev/null 2>&1 \
    || fail "GREEN: the in-bounds harness.version (${SHA40}) must survive unchanged in the shipped envelopes"
  grep -v '^//' "$OUTG" \
    | jq -e 'any(.[]; .data.baseData.properties["gen_ai.tool.name"] == "git")' >/dev/null 2>&1 \
    || fail "GREEN: a plain gen_ai.tool.name (git) must survive unchanged in the shipped envelopes"
else
  fail "GREEN: normal trace did not write the dry-run envelope file (${OUTG})"
fi

# ==============================================================================
# 256-boundary GREEN: a value of EXACTLY 256 printable chars is at the cap
# and must still ship (the cap is inclusive at 256).
# ==============================================================================
OUT256="${TMP_DIR}/ok256.envelopes.json"
rc=0
run_export "$FIX" "${TMP_DIR}/ok256.out" TRACE_EXPORT_OTLP=1 -- "$OK256" --dry-run-to-file "$OUT256" || rc=$?
[ "$rc" = "0" ] \
  || fail "BOUNDARY-256: a 256-char printable value is at the inclusive cap and must ship (exit 0), got ${rc}: $(tr '\n' '|' < "${TMP_DIR}/ok256.out")"
if [ -f "$OUT256" ]; then
  grep -v '^//' "$OUT256" \
    | jq -e --arg v "$V256" \
        'any(.[]; .data.baseData.properties["harness.version"] == $v)' >/dev/null 2>&1 \
    || fail "BOUNDARY-256: the 256-char value must survive UNCHANGED (never truncated) in the envelopes"
else
  fail "BOUNDARY-256: the 256-char trace did not write the dry-run file (${OUT256})"
fi

# ==============================================================================
# 257-boundary RED: one char over the cap → refuse (exit non-zero, nothing
# written). RED today: 257 chars currently ship.
# ==============================================================================
OUT257="${TMP_DIR}/over257.envelopes.json"
rc=0
run_export "$FIX" "${TMP_DIR}/over257.out" TRACE_EXPORT_OTLP=1 -- "$OVER257" --dry-run-to-file "$OUT257" || rc=$?
[ "$rc" != "0" ] \
  || fail "BOUNDARY-257: a 257-char allowlisted value is over the 256 cap and must REFUSE the whole export (exit non-zero), got exit 0"
[ ! -e "$OUT257" ] \
  || fail "BOUNDARY-257: over-cap value — NOTHING may be written (all-or-nothing), but the dry-run file exists at ${OUT257}"

# ==============================================================================
# Case A RED: an over-long (300-char) allowlisted harness.version → refuse
# the WHOLE export (all-or-nothing, exit non-zero, nothing written). Must
# NEVER truncate. RED today: the 300-char value currently ships.
# ==============================================================================
OUTA="${TMP_DIR}/long.envelopes.json"
rc=0
run_export "$FIX" "${TMP_DIR}/long.out" TRACE_EXPORT_OTLP=1 -- "$LONG" --dry-run-to-file "$OUTA" || rc=$?
[ "$rc" != "0" ] \
  || fail "A: an over-long (300-char) allowlisted value must REFUSE the whole export (exit non-zero, never truncate), got exit 0"
[ ! -e "$OUTA" ] \
  || fail "A: over-long value — all-or-nothing means NOTHING is written, but the dry-run file exists at ${OUTA}"
# Belt: if a file were written anyway it must never contain a silently
# truncated value (truncation is a forbidden degrade path).
if [ -e "$OUTA" ] && grep -qF -- "$V300" "$OUTA"; then
  fail "A: the over-long value reached the envelopes — it shipped instead of refusing"
fi

# ==============================================================================
# Case B RED: a raw control byte in an allowlisted string value
# (gen_ai.tool.name) → refuse (exit non-zero, nothing written). RED today:
# the control-byte value currently ships. Must NEVER strip the byte.
# ==============================================================================
OUTB="${TMP_DIR}/ctrl.envelopes.json"
rc=0
run_export "$FIX" "${TMP_DIR}/ctrl.out" TRACE_EXPORT_OTLP=1 -- "$CTRL" --dry-run-to-file "$OUTB" || rc=$?
[ "$rc" != "0" ] \
  || fail "B: a control/non-printable byte in an allowlisted value must REFUSE the whole export (exit non-zero, never strip), got exit 0"
[ ! -e "$OUTB" ] \
  || fail "B: control-byte value — all-or-nothing means NOTHING is written, but the dry-run file exists at ${OUTB}"

# ==============================================================================
# Zero-network pin: no run in this sensor may ever invoke curl (caps are an
# output gate that precedes transport).
# ==============================================================================
if [ -e "$CURL_MARKER" ]; then
  fail "the exporter invoked curl during a gated run — the value-cap gate must stop everything before transport: $(tr '\n' '|' < "$CURL_MARKER")"
fi

# --- Result --------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-export value-cap contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace-export value-cap contract honored\n'
