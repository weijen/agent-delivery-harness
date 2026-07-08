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
VALIDATE="$ROOT/scripts/validate-trace.sh"
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

# validate-trace.sh types both the trace-lib numeric keys and the structural
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
tl_numeric="$(region numeric_keys "$TRACE_LIB" | tokens "$HKEY_RE")"
diff_or_fail "trace-lib.sh numeric exact-keys" "$AUTH_NUMERIC" "$tl_numeric"
prefix_present_or_fail "trace-lib.sh numeric block" "$TRACE_LIB"

tl_spans="$(region span_types "$TRACE_LIB" | tokens "$SPAN_RE")"
diff_or_fail "trace-lib.sh span-type enum" "$AUTH_SPANS" "$tl_spans"

# --- 2. validate-trace.sh numeric_keys array (numeric_keys + structural) -----
vt_keys="$(region numeric_keys "$VALIDATE" | grep -oE "$KEY_RE" | tr -d '"' | LC_ALL=C sort -u)"
diff_or_fail "validate-trace.sh \$numeric_keys" "$AUTH_VALIDATE" "$vt_keys"
prefix_present_or_fail "validate-trace.sh types_valid" "$VALIDATE"

# --- 3. check-trace-consistency.sh role enum (quoted array) -----------------
cc_roles="$(region roles "$CONSISTENCY" | grep -oE "$ROLEQ_RE" | tr -d '"' | LC_ALL=C sort -u)"
diff_or_fail "check-trace-consistency.sh \$roles" "$AUTH_ROLES" "$cc_roles"

# --- 4. log-handback.sh role case enum (bareword, pipe-separated) -----------
lh_roles="$(region roles "$LOG_HANDBACK" | tokens "$ROLE_RE")"
diff_or_fail "log-handback.sh role enum" "$AUTH_ROLES" "$lh_roles"

printf 'trace-schema single-source contract honored (numeric_keys, prefixes, roles, span_types)\n'
