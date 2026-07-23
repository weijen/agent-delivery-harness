#!/usr/bin/env bash
# Meta drift sensor (issue #173): the schema-derived enums that used to be
# hand-copied into several scripts must stay byte-for-byte in step with the
# single frozen authority, docs/evaluation/trace-schema.v1.json.
#
# Authority arrays (added additively, open-world safe):
#   .numeric_keys          — exact attribute keys trace-lib types as JSON numbers
#   .numeric_key_prefixes  — key prefixes typed as JSON numbers (gen_ai.usage.)
#   .roles                 — the closed log-handback / consistency role enum
#   .span_types            — the closed span-type enum (pre-existing)
#
# Each script-local copy is wrapped in sentinel markers:
#   # >>> trace-schema:<name> ...
#   ... the literal ...
#   # <<< trace-schema:<name>
# so this sensor can extract exactly that region and diff its token set against
# the authority. A drift (add/remove/typo in any copy) fails this test.
#
# This is the sanctioned "drift sensor proves equivalence where sourcing is
# impractical inside jq programs" path from the issue #173 acceptance criteria:
# the numeric-key typing and role filters live inside jq program bodies that
# cannot source a shell/JSON file at eval time.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CONTRACT="$ROOT/docs/evaluation/trace-schema.v1.json"
TRACE_LIB="$ROOT/scripts/trace-lib.sh"
CONSISTENCY="$ROOT/scripts/check-trace-consistency.sh"
LOG_HANDBACK="$ROOT/scripts/log-handback.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate the trace schema single-source contract"
[ -f "$CONTRACT" ] || fail "trace schema contract not found: $CONTRACT"

# --- authority sets ---------------------------------------------------------
auth_set() { jq -r --arg k "$1" '.[$k] // [] | .[]' "$CONTRACT" 2>/dev/null | LC_ALL=C sort -u; }

AUTH_NUMERIC="$(auth_set numeric_keys)"
AUTH_PREFIX="$(auth_set numeric_key_prefixes)"
AUTH_STRUCT="$(auth_set structural_numeric_keys)"
AUTH_ROLES="$(auth_set roles)"
AUTH_SPANS="$(auth_set span_types)"
AUTH_FAILURE_CLASSES="$(auth_set failure_classes)"
AUTH_FAILURE_DISPOSITIONS="$(auth_set failure_dispositions)"

[ -n "$AUTH_NUMERIC" ] \
  || fail "authority .numeric_keys is missing/empty in $CONTRACT — add the numeric-key map to the contract (issue #173)"
[ -n "$AUTH_PREFIX" ] \
  || fail "authority .numeric_key_prefixes is missing/empty in $CONTRACT — add the numeric prefix list (gen_ai.usage.) (issue #173)"
[ -n "$AUTH_STRUCT" ] \
  || fail "authority .structural_numeric_keys is missing/empty in $CONTRACT — add the structural numeric keys (harness.issue, schema_version) (issue #173)"
[ -n "$AUTH_ROLES" ] \
  || fail "authority .roles is missing/empty in $CONTRACT — add the role enum to the contract (issue #173)"
[ -n "$AUTH_SPANS" ] \
  || fail "authority .span_types is missing/empty in $CONTRACT"
[ -n "$AUTH_FAILURE_CLASSES" ] \
  || fail "authority .failure_classes is missing/empty in $CONTRACT — add the failure_classes enum (issue #318)"
[ -n "$AUTH_FAILURE_DISPOSITIONS" ] \
  || fail "authority .failure_dispositions is missing/empty in $CONTRACT — add the failure_dispositions enum (issue #317)"
for role in generator-subagent implementation-subagent test-subagent; do
  printf '%s\n' "$AUTH_ROLES" | grep -qxF "$role" \
    || fail "authority .roles must retain active generator and historical implementation/test roles (missing ${role})"
done
for step in red_handback impl_handback green_handback; do
  jq -e --arg step "$step" '.lifecycle_steps | index($step) != null' "$CONTRACT" >/dev/null \
    || fail "authority .lifecycle_steps must retain the stable '${step}' name"
done
# Retention guard for failure_classes cross-issue dependencies (issue #318):
# validation-bypass (#298), knowledge-gap/complexity/known-flaky/polling (#317).
for fc_slug in validation-bypass knowledge-gap complexity known-flaky polling spec-violation other; do
  printf '%s\n' "$AUTH_FAILURE_CLASSES" | grep -qxF "$fc_slug" \
    || fail "authority .failure_classes must retain cross-issue slug '${fc_slug}' (issue #318 cross-issue key model)"
done

# check-trace-consistency.sh types both the trace-lib numeric keys and the structural
# numerics (harness.issue, schema_version), so its expected set is the union.
AUTH_VALIDATE="$(printf '%s\n%s\n' "$AUTH_NUMERIC" "$AUTH_STRUCT" | LC_ALL=C sort -u)"

# --- region extraction ------------------------------------------------------
# Print the lines strictly between the >>> and <<< markers for <name> in <file>.
region() {
  local name="$1" file="$2" out
  [ -f "$file" ] || fail "expected source file not found: $file"
  out="$(awk -v n="$name" '
    $0 ~ ("trace-schema:" n "([^A-Za-z0-9_-]|$)") && /># *trace-schema:|>>> trace-schema:/ { f=1; next }
    $0 ~ ("trace-schema:" n "([^A-Za-z0-9_-]|$)") && /<<< trace-schema:/ { f=0 }
    f { print }
  ' "$file")"
  [ -n "$out" ] \
    || fail "no '>>> trace-schema:$name ... <<< trace-schema:$name' marked region found in $(basename "$file") — add the drift-guard markers (issue #173)"
  printf '%s\n' "$out"
}

# Extract tokens matching a regex from a region, sorted-unique.
tokens() { grep -oE "$1" | LC_ALL=C sort -u; }

diff_or_fail() {
  local label="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    printf 'FAIL: %s drifted from the authority (docs/evaluation/trace-schema.v1.json)\n' "$label" >&2
    printf '  authority:\n%s\n  found:\n%s\n' "$(printf '%s' "$want" | sed 's/^/    /')" "$(printf '%s' "$got" | sed 's/^/    /')" >&2
    exit 1
  fi
}

HKEY_RE='harness\.[a-z_]+'
KEY_RE='"[A-Za-z_][A-Za-z0-9_.]*"'
ROLEQ_RE='"[a-z][a-z-]*"'
ROLE_RE='[a-z][a-z-]*[a-z]'
SPAN_RE='(agent|model|tool|lifecycle)'

# Every authority prefix must literally appear in a file (file-wide, since the
# prefix predicate is not always inside the marked key-list region).
prefix_present_or_fail() {
  local label="$1" file="$2" p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    grep -qF "$p" "$file" \
      || fail "$label is missing the numeric key prefix '$p' (authority .numeric_key_prefixes)"
  done <<< "$AUTH_PREFIX"
}

# --- 1. trace-lib.sh numeric exact-keys + usage prefix + span-type enum ------
# A numeric key PREFIX in the harness.* namespace (issue #267 added the first
# one, harness.economics.) is expressed as a startswith("harness.economics.")
# predicate inside the same trace-lib numeric-typing block. HKEY_RE would
# otherwise capture the prefix stem (harness.economics) as if it were an exact
# key, so strip every harness.* prefix stem to keep this a true exact-key diff.
harness_prefix_stems="$(printf '%s\n' "$AUTH_PREFIX" | sed -n 's/^harness\.\(.*\)\.$/harness.\1/p' | LC_ALL=C sort -u)"
strip_prefix_stems() {
  if [ -z "$harness_prefix_stems" ]; then cat; else grep -vxF "$harness_prefix_stems"; fi
}
tl_numeric="$(region numeric_keys "$TRACE_LIB" | tokens "$HKEY_RE" | strip_prefix_stems)"
diff_or_fail "trace-lib.sh numeric exact-keys" "$AUTH_NUMERIC" "$tl_numeric"
prefix_present_or_fail "trace-lib.sh numeric block" "$TRACE_LIB"

tl_spans="$(region span_types "$TRACE_LIB" | tokens "$SPAN_RE")"
diff_or_fail "trace-lib.sh span-type enum" "$AUTH_SPANS" "$tl_spans"

# --- 2. check-trace-consistency.sh numeric_keys array (numeric_keys + structural) -----
vt_keys="$(region numeric_keys "$CONSISTENCY" | grep -oE "$KEY_RE" | tr -d '"' | LC_ALL=C sort -u)"
diff_or_fail "check-trace-consistency.sh \$numeric_keys" "$AUTH_VALIDATE" "$vt_keys"
prefix_present_or_fail "check-trace-consistency.sh types_valid" "$CONSISTENCY"

# --- 3. check-trace-consistency.sh role enum (quoted array) -----------------
cc_roles="$(region roles "$CONSISTENCY" | grep -oE "$ROLEQ_RE" | tr -d '"' | LC_ALL=C sort -u)"
diff_or_fail "check-trace-consistency.sh \$roles" "$AUTH_ROLES" "$cc_roles"

# --- 4. log-handback.sh role case enum (bareword, pipe-separated) -----------
lh_roles="$(region roles "$LOG_HANDBACK" | tokens "$ROLE_RE")"
diff_or_fail "log-handback.sh role enum" "$AUTH_ROLES" "$lh_roles"

# --- 5. check-trace-consistency.sh failure_classes frozen fallback -----------
# Slugs one per line inside the >>> trace-schema:failure_classes ... <<< region.
FC_SLUG_RE='[a-z][a-z-]+'
cc_failure_classes="$(region failure_classes "$CONSISTENCY" | grep -oE "$FC_SLUG_RE" | LC_ALL=C sort -u)"
diff_or_fail "check-trace-consistency.sh failure_classes frozen fallback" "$AUTH_FAILURE_CLASSES" "$cc_failure_classes"

# --- 6. log-handback.sh failure_classes frozen fallback (comment-listed) -----
# Slugs are listed as `# slug` comment lines inside the sentinel region so
# the extractor doesn't pick up shell variable names.
lh_failure_classes="$(region failure_classes "$LOG_HANDBACK" | grep -oE "$FC_SLUG_RE" | LC_ALL=C sort -u)"
diff_or_fail "log-handback.sh failure_classes frozen fallback" "$AUTH_FAILURE_CLASSES" "$lh_failure_classes"

# --- 7. failure_dispositions frozen fallbacks --------------------------------
cc_failure_dispositions="$(region failure_dispositions "$CONSISTENCY" | grep -oE "$FC_SLUG_RE" | LC_ALL=C sort -u)"
diff_or_fail "check-trace-consistency.sh failure_dispositions frozen fallback" "$AUTH_FAILURE_DISPOSITIONS" "$cc_failure_dispositions"

lh_failure_dispositions="$(region failure_dispositions "$LOG_HANDBACK" | grep -oE "$FC_SLUG_RE" | LC_ALL=C sort -u)"
diff_or_fail "log-handback.sh failure_dispositions frozen fallback" "$AUTH_FAILURE_DISPOSITIONS" "$lh_failure_dispositions"

printf 'trace-schema single-source contract honored (numeric_keys, prefixes, roles, span_types, failure_classes, failure_dispositions)\n'

(
cd "$ROOT"

CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
SCRIPTS="${ROOT}/scripts"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

command -v jq >/dev/null 2>&1 \
  || { printf 'FAIL: jq is required to read the trace schema contract\n' >&2; exit 1; }
[ -f "$CONTRACT" ] \
  || { printf 'FAIL: contract not found (%s)\n' "$CONTRACT" >&2; exit 1; }
jq empty "$CONTRACT" 2>/dev/null \
  || { printf 'FAIL: contract is not valid JSON (%s)\n' "$CONTRACT" >&2; exit 1; }
[ -d "$SCRIPTS" ] \
  || { printf 'FAIL: scripts dir not found (%s)\n' "$SCRIPTS" >&2; exit 1; }

# --- Documented vocabulary: everything the contract names --------------------
documented="${TMP_DIR}/documented"
jq -r '
  (.required_common[]),
  (.required_by_span | to_entries[] | .value[]),
  (.optional_fields | keys[])
' "$CONTRACT" | sort -u > "$documented"

# --- Emitted vocabulary: every harness.*/gen_ai.* key on a trace_span attr ---
# Match the literal "<key>= shape that trace_span attribute arguments use
# across the lifecycle scripts and both runtime hooks. Strip the leading
# quote and the trailing =<value...>.
emitted="${TMP_DIR}/emitted"
grep -rhoE '"(harness|gen_ai)\.[a-z_.]+=' "$SCRIPTS" \
  | sed -E 's/^"//; s/=.*$//' \
  | sort -u > "$emitted"

if [ ! -s "$emitted" ]; then
  printf 'FAIL: no emitted harness.*/gen_ai.* keys found under scripts/ — the grep contract broke\n' >&2
  exit 1
fi

# --- Every emitted key must be documented ------------------------------------
undocumented="$(comm -23 "$emitted" "$documented" || true)"

if [ -n "$undocumented" ]; then
  printf 'FAIL: emitted trace keys missing from the contract (add to optional_fields or justify):\n' >&2
  printf '%s\n' "$undocumented" | sed 's/^/  /' >&2
  exit 1
fi

printf 'PASS: all %s emitted trace keys are documented in the contract\n' "$(wc -l < "$emitted" | tr -d ' ')"
exit 0
)

(
cd "$ROOT"

CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
DOC="${ROOT}/docs/evaluation/observability-and-trace-schema.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# jq reads the contract's attribute and lifecycle vocabularies as data, so the
# sensor never hardcodes a third copy. Hard-require it (CI installs jq).
command -v jq >/dev/null 2>&1 \
  || { printf 'FAIL: jq is required to read the trace schema contract\n' >&2; exit 1; }

[ -f "$CONTRACT" ] \
  || { printf 'FAIL: contract not found at docs/evaluation/trace-schema.v1.json (%s)\n' "$CONTRACT" >&2; exit 1; }
[ -f "$DOC" ] \
  || { printf 'FAIL: prose doc not found at docs/evaluation/observability-and-trace-schema.md\n' >&2; exit 1; }

# --- 1. Prose doc defers to the frozen contract ------------------------------
grep -qF 'trace-schema.v1.json' "$DOC" \
  || fail "observability-and-trace-schema.md must reference trace-schema.v1.json as the vocabulary authority"

# --- 2a. No duplicated complete lifecycle-step enumeration -------------------
# A couple of illustrative step names are allowed; reproducing the entire
# closed vocabulary is a second normative copy that can drift.
lifecycle_total=0
lifecycle_in_doc=0
while IFS= read -r step; do
  [ -n "$step" ] || continue
  lifecycle_total=$((lifecycle_total + 1))
  if grep -qE "(^|[^A-Za-z0-9_])${step}([^A-Za-z0-9_]|$)" "$DOC"; then
    lifecycle_in_doc=$((lifecycle_in_doc + 1))
  fi
done < <(jq -r '.lifecycle_steps[]' "$CONTRACT")

[ "$lifecycle_total" -gt 0 ] \
  || fail "contract .lifecycle_steps is empty — cannot check for a duplicated enumeration"
if [ "$lifecycle_total" -gt 0 ] && [ "$lifecycle_in_doc" -eq "$lifecycle_total" ]; then
  fail "prose doc duplicates the complete ${lifecycle_total}-step lifecycle enumeration; the closed list must live only in trace-schema.v1.json"
fi

# --- 2b. Every attribute name still mentioned in the doc exists in the contract
# Extract gen_ai.* / harness.* dotted attribute mentions from the doc, then
# check each against the contract's attribute vocabulary (required_common +
# per-span required + optional fields). A doc token may also be a namespace
# prefix of a contract attribute (e.g. `gen_ai.usage.*` -> gen_ai.usage).
doc_attrs="$(grep -oE '(gen_ai|harness)(\.[a-z_][a-z0-9_]*)+' "$DOC" | sort -u || true)"
while IFS= read -r attr; do
  [ -n "$attr" ] || continue
  # Skip file-path-like mentions (e.g. harness.instructions.md) — not span attributes.
  case "$attr" in
    *.md | *.json | *.yml | *.yaml | *.sh) continue ;;
  esac
  jq -e --arg t "$attr" '
    (.required_common
     + ([.required_by_span[]] | add)
     + (.optional_fields | keys)) as $attrs
    | any($attrs[]; . == $t or startswith($t + "."))
  ' "$CONTRACT" >/dev/null \
    || fail "prose doc mentions attribute '${attr}' that is not in trace-schema.v1.json — vocabulary drift"
done <<< "$doc_attrs"

# --- 2c. Doc mentions the new mandatory fields (not stale vs. v1) ------------
grep -qF 'schema_version' "$DOC" \
  || fail "prose doc must mention the mandatory field schema_version introduced by trace schema v1"
grep -qF 'harness.version' "$DOC" \
  || fail "prose doc must mention the mandatory field harness.version introduced by trace schema v1"

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d trace-schema docs single-source violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'trace schema docs defer to the frozen contract\n'
)
