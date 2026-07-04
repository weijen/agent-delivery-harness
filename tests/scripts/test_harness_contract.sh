#!/usr/bin/env bash
# test_harness_contract.sh — validate the harness scripts against the frozen
# lifecycle contract in docs/harness-contract.yml.
#
# docs/harness-contract.yml is the machine-readable authority for the harness
# lifecycle. This sensor reads it (with a small awk YAML reader — no PyYAML
# dependency) and verifies that the current scripts still expose the declared
# behavior. It is intentionally conservative and shell-based:
#
#   1. Every contract-declared script exists, is executable, and parses (bash -n).
#   2. A hardcoded required-script backstop: the contract itself must still
#      declare all seven harness entrypoints (so deleting one from the YAML and
#      the script together does not silently shrink the contract).
#   3. Every declared lifecycle step, env flag, state transition, and failure
#      mode still appears (as its `present:` regex) in its owning script.
#   4. The language-neutral owner scripts contain none of the declared language /
#      toolchain tokens (issue naming, worktree lifecycle, feature-list schema,
#      review-gate state, and PR closeout must stay language-neutral).
#   5. Internal consistency: every `owner:` referenced is a declared script.
#
# The sensor FAILS if a required script, lifecycle obligation, Action Log
# scaffold, feature-list requirement, or review-gate boundary is removed from the
# scripts without an intentional update to the contract and this test.
#
# Exit codes: 0 contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/harness-contract.yml"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

[ -f "$CONTRACT" ] || { printf 'FAIL: contract not found at %s\n' "$CONTRACT" >&2; exit 1; }

# --- awk YAML readers (tailored to docs/harness-contract.yml's flat shape) ----

# parse_records SECTION
#   Emit one line per list item under top-level SECTION. Fields are joined with a
#   TAB; each field is `key=value`. A bare scalar item `- value` emits `_=value`.
#   Splitting is on the FIRST ": " (colon+space) so regex values keeping a `:`
#   without a following space survive intact.
parse_records() {
  awk -v section="$1" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function flush(){ if (have) { print rec; have=0; rec="" } }
    # top-level key (column 0, ends in ":")
    /^[A-Za-z_]+:/ {
      flush()
      k=$0; sub(/:.*/, "", k)
      insec=(k==section)
      next
    }
    !insec { next }
    /^  - / {
      flush()
      have=1
      body=$0; sub(/^  - /, "", body)
      if (body ~ /: /) {
        key=body; sub(/: .*/, "", key); key=trim(key)
        val=body; sub(/^[^:]*: /, "", val)
        rec=key "=" val
      } else if (body != "") {
        rec="_=" trim(body)
      }
      next
    }
    /^    [A-Za-z_]+:/ {
      if (!have) next
      line=trim($0)
      key=line; sub(/:.*/, "", key)
      val=line; sub(/^[^:]*:[ ]?/, "", val)
      rec=rec "\t" key "=" val
      next
    }
    END { flush() }
  ' "$CONTRACT"
}

# parse_nested_list SECTION SUBKEY
#   Emit the scalar items of a 4-space-indented `- value` list that lives under a
#   2-space `SUBKEY:` mapping inside top-level SECTION (used for language_neutral).
parse_nested_list() {
  awk -v section="$1" -v subkey="$2" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^[A-Za-z_]+:/ { k=$0; sub(/:.*/, "", k); insec=(k==section); insub=0; next }
    !insec { next }
    /^  [A-Za-z_]+:/ { sk=trim($0); sub(/:.*/, "", sk); insub=(sk==subkey); next }
    insub && /^    - / { v=$0; sub(/^    - /, "", v); print trim(v) }
  ' "$CONTRACT"
}

# field RECORD KEY — extract value of KEY from a TAB-joined record line.
field() {
  printf '%s\n' "$1" | tr '\t' '\n' | awk -F= -v k="$2" '$1==k { sub(/^[^=]*=/, ""); print; exit }'
}

# --- 1. Declared scripts: exist, executable, parse ---------------------------
declared_scripts=""
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  p="$(field "$rec" path)"
  [ -n "$p" ] || continue
  declared_scripts="${declared_scripts} ${p}"
  abs="${ROOT}/${p}"
  if [ ! -f "$abs" ]; then
    fail "declared script missing: ${p}"
    continue
  fi
  [ -x "$abs" ] || fail "declared script not executable: ${p}"
  bash -n "$abs" 2>/dev/null || fail "declared script does not parse (bash -n): ${p}"
done < <(parse_records scripts)

# --- 2. Required-script backstop (contract must not silently shrink) ---------
for required in \
  scripts/init.sh \
  scripts/issue-lib.sh \
  scripts/start-issue.sh \
  scripts/check-feature-list.sh \
  scripts/review-gate.sh \
  scripts/create-pr.sh \
  scripts/merge-pr.sh \
  scripts/finish-issue.sh \
  scripts/trace-lib.sh; do
  case " ${declared_scripts} " in
    *" ${required} "*) : ;;
    *) fail "contract no longer declares required script: ${required}" ;;
  esac
done

# --- 2b. CI-green merge precondition backstop (issue #51) --------------------
# The contract must keep declaring that a green CI run is required before merge,
# owned by scripts/merge-pr.sh. Deleting the lifecycle obligation from the YAML
# must fail this sensor even though section 3 would no longer check it.
grep -Eq '^[[:space:]]*-[[:space:]]*id:[[:space:]]*ci-green-precondition[[:space:]]*$' "$CONTRACT" \
  || fail "contract no longer declares the ci-green-precondition lifecycle obligation"
grep -Eq '^[[:space:]]*-[[:space:]]*id:[[:space:]]*ci-not-green-refused[[:space:]]*$' "$CONTRACT" \
  || fail "contract no longer declares the ci-not-green-refused failure mode"

# --- 2c. Breakdown-ownership backstop (issue #78) ----------------------------
# The contract must keep declaring that the conductor owns authoring the
# feature_list.json breakdown (after the plan + human-input gate), owned by
# scripts/start-issue.sh. Deleting the obligation from the YAML must fail this
# sensor even though section 3 would then no longer check it.
grep -Eq '^[[:space:]]*-[[:space:]]*id:[[:space:]]*breakdown-ownership[[:space:]]*$' "$CONTRACT" \
  || fail "contract no longer declares the breakdown-ownership lifecycle obligation"

# --- 2d. Trace-lib registration backstop (issue #93) -------------------------
# scripts/trace-lib.sh is the language-neutral tracing primitive sourced by the
# lifecycle scripts. The required-script backstop above forces the contract to
# keep declaring it in the scripts list (section 1 then enforces that it
# exists, is executable, and parses with bash -n), and section 4 asserts it
# stays inside the language-neutral boundary alongside the other owners.

# --- 3. Lifecycle / env flags / state transitions / failure modes ------------
# Each declared obligation must still appear (as its present: regex) in its owner.
check_owner_present() {
  local section="$1" rec id owner present abs kind
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    id="$(field "$rec" id)"; [ -n "$id" ] || id="$(field "$rec" name)"
    owner="$(field "$rec" owner)"
    present="$(field "$rec" present)"
    if [ -z "$owner" ] || [ -z "$present" ]; then
      fail "${section}/${id:-?}: missing owner or present in contract"
      continue
    fi
    case " ${declared_scripts} " in
      *" ${owner} "*) : ;;
      *) fail "${section}/${id}: owner '${owner}' is not a declared script" ;;
    esac
    abs="${ROOT}/${owner}"
    [ -f "$abs" ] || { fail "${section}/${id}: owner file missing: ${owner}"; continue; }
    if ! grep -Eiq -- "$present" "$abs"; then
      fail "${section}/${id}: pattern '${present}' no longer found in ${owner}"
    fi
    kind="$(field "$rec" kind)"
    if [ -n "$kind" ] && [ "$kind" != "hard" ] && [ "$kind" != "warn" ]; then
      fail "${section}/${id}: kind must be 'hard' or 'warn', got '${kind}'"
    fi
  done < <(parse_records "$section")
}

check_owner_present lifecycle
check_owner_present env_flags
check_owner_present state_transitions
check_owner_present failure_modes

# --- 4. Language-neutral boundary -------------------------------------------
neutral_owners="$(parse_nested_list language_neutral owners)"
neutral_tokens="$(parse_nested_list language_neutral tokens)"
[ -n "$neutral_owners" ] || fail "language_neutral.owners is empty in the contract"
[ -n "$neutral_tokens" ] || fail "language_neutral.tokens is empty in the contract"

# Trace-lib language-neutral backstop (issue #93): the tracing primitive must
# stay inside the language-neutral boundary so it never grows language
# branches; the owners loop below then applies the token guard to it.
printf '%s\n' "$neutral_owners" | grep -qx 'scripts/trace-lib.sh' \
  || fail "language_neutral.owners no longer includes scripts/trace-lib.sh (issue #93 tracing primitive)"

while IFS= read -r owner; do
  [ -n "$owner" ] || continue
  abs="${ROOT}/${owner}"
  if [ ! -f "$abs" ]; then
    fail "language_neutral owner missing: ${owner}"
    continue
  fi
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    if grep -Eiqw -- "$token" "$abs"; then
      fail "language token '${token}' leaked into language-neutral script ${owner}"
    fi
  done <<< "$neutral_tokens"
done <<< "$neutral_owners"

# --- 5. No stale IMPLEMENTATION-STATUS references in tracked files -----------
# The repo-wide status doc is named docs/PROGRESS.md everywhere (issue #84). Any
# surviving IMPLEMENTATION-STATUS reference reintroduces the naming split.
stale_status_refs="$(git -C "$ROOT" grep -I -l "IMPLEMENTATION-STATUS" -- . ':!tests/scripts/test_harness_contract.sh' 2>/dev/null || true)"
if [ -n "$stale_status_refs" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    fail "stale IMPLEMENTATION-STATUS reference in tracked file: ${f} (use docs/PROGRESS.md)"
  done <<< "$stale_status_refs"
fi

# --- Result ------------------------------------------------------------------
if [ "$fails" -ne 0 ]; then
  printf '\n%d harness-contract violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'harness contract honored\n'
