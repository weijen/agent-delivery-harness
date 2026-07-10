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

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

# This sensor already accumulates rather than fail-fast: fail() records a
# diagnostic and bumps a PER-SCENARIO counter WITHOUT aborting, and
# end_scenario() turns that counter into exactly one TAP row and resets it for
# the next scenario. HOW results are reported changes (accumulate -> per-scenario
# TAP); WHAT each section exercises is unchanged.
sec_fails=0
fail() {
  printf '# %s\n' "$*" >&2
  sec_fails=$((sec_fails + 1))
}
end_scenario() {
  if [ "$sec_fails" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  sec_fails=0
}

[ -f "$CONTRACT" ] || { printf '# BLOCKING: contract not found at %s\n' "$CONTRACT" >&2; exit 1; }

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

# require_contract_record SECTION KEY VALUE [OWNER|OWNER2]
#   Backstop a required contract entry even if deleting the YAML record would
#   otherwise make the generic section scan silently skip it.
require_contract_record() {
  local section="$1" key="$2" expected_value="$3" expected_owners="${4:-}"
  local rec actual_owner found
  found=0
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    if [ "$(field "$rec" "$key")" = "$expected_value" ]; then
      found=1
      if [ -n "$expected_owners" ]; then
        actual_owner="$(field "$rec" owner)"
        case "|${expected_owners}|" in
          *"|${actual_owner}|"*) : ;;
          *) fail "${section}/${expected_value}: owner must be one of ${expected_owners}, got ${actual_owner:-<empty>}" ;;
        esac
      fi
    fi
  done < <(parse_records "$section")
  [ "$found" -eq 1 ] || fail "contract no longer declares ${section}/${expected_value}"
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
end_scenario "declared scripts exist, are executable, and parse (bash -n)"

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
end_scenario "contract still declares every required harness script"

# --- 2b. CI-green merge precondition backstop (issue #51) --------------------
# The contract must keep declaring that a green CI run is required before merge,
# owned by scripts/merge-pr.sh. Deleting the lifecycle obligation from the YAML
# must fail this sensor even though section 3 would no longer check it.
grep -Eq '^[[:space:]]*-[[:space:]]*id:[[:space:]]*ci-green-precondition[[:space:]]*$' "$CONTRACT" \
  || fail "contract no longer declares the ci-green-precondition lifecycle obligation"
grep -Eq '^[[:space:]]*-[[:space:]]*id:[[:space:]]*ci-not-green-refused[[:space:]]*$' "$CONTRACT" \
  || fail "contract no longer declares the ci-not-green-refused failure mode"
end_scenario "contract declares the CI-green merge precondition and its failure mode"

# --- 2c. Breakdown-ownership backstop (issue #78) ----------------------------
# The contract must keep declaring that the conductor owns authoring the
# feature_list.json breakdown (after the plan + human-input gate), owned by
# scripts/start-issue.sh. Deleting the obligation from the YAML must fail this
# sensor even though section 3 would then no longer check it.
grep -Eq '^[[:space:]]*-[[:space:]]*id:[[:space:]]*breakdown-ownership[[:space:]]*$' "$CONTRACT" \
  || fail "contract no longer declares the breakdown-ownership lifecycle obligation"
end_scenario "contract declares the breakdown-ownership lifecycle obligation"

# --- 2d. Trace-lib registration backstop (issue #93) -------------------------
# scripts/trace-lib.sh is the language-neutral tracing primitive sourced by the
# lifecycle scripts. The required-script backstop above forces the contract to
# keep declaring it in the scripts list (section 1 then enforces that it
# exists, is executable, and parses with bash -n), and section 4 asserts it
# stays inside the language-neutral boundary alongside the other owners.

# --- 2e. Trace-emission backstop (issue #94) ----------------------------------
# The six lifecycle scripts each emit schema-v1 trace spans via trace-lib.sh
# (guarded source + trace_span calls). Two layers, mirroring 2b/2c:
#   (a) script-side presence backstop: every instrumented owner must still
#       reference trace_span AND trace-lib.sh — deleting the instrumentation
#       from a script fails this sensor even if the YAML entry is deleted too;
#   (b) the contract must declare a trace_emission section listing all six
#       owners (each entry's present: regex is enforced by section 3's
#       check_owner_present) and pin the schema authority
#       docs/evaluation/trace-schema.v1.json.
te_required=(
  scripts/start-issue.sh
  scripts/check-feature-list.sh
  scripts/review-gate.sh
  scripts/create-pr.sh
  scripts/merge-pr.sh
  scripts/finish-issue.sh
)
for owner in "${te_required[@]}"; do
  abs="${ROOT}/${owner}"
  if [ ! -f "$abs" ]; then
    fail "trace_emission/${owner}: instrumented script missing"
    continue
  fi
  grep -Eq 'trace_span' "$abs" \
    || fail "trace_emission/${owner}: no trace_span reference — trace emission removed (issue #94)"
  grep -Eq 'trace-lib\.sh' "$abs" \
    || fail "trace_emission/${owner}: no trace-lib.sh sourcing reference (issue #94)"
done

if grep -Eq '^trace_emission:' "$CONTRACT"; then
  te_owners="$(parse_records trace_emission | while IFS= read -r rec; do
    [ -n "$rec" ] && field "$rec" owner
  done)"
  for owner in "${te_required[@]}"; do
    printf '%s\n' "$te_owners" | grep -qx "$owner" \
      || fail "trace_emission: contract does not declare owner ${owner} (issue #94)"
  done
  awk '/^trace_emission:/{f=1;next} /^[A-Za-z_]+:/{f=0} f' "$CONTRACT" \
    | grep -q 'docs/evaluation/trace-schema.v1.json' \
    || fail "trace_emission: contract section does not reference the schema authority docs/evaluation/trace-schema.v1.json (issue #94)"
else
  fail "contract no longer declares the trace_emission section (issue #94)"
fi
end_scenario "lifecycle scripts emit schema-v1 trace spans (script-side + contract)"

# --- 2f. Trace evidence contract backstop (issue #264) -----------------------
# The contract must freeze the issue #264 teeth-proof gate boundary explicitly.
# If any YAML record is deleted, this scenario fails before the generic
# check_owner_present scans can silently shrink their worklist.
require_contract_record scripts path scripts/check-trace-consistency.sh
require_contract_record lifecycle id local-hook-seeding scripts/start-issue.sh
require_contract_record lifecycle id interval-attribution scripts/copilot-trace-hook.sh
require_contract_record failure_modes id missing-teeth-proof-evidence scripts/review-gate.sh
require_contract_record failure_modes id red-first-ordering-absent scripts/check-trace-consistency.sh
require_contract_record lifecycle id pr-path-red-first-gate scripts/review-gate.sh
end_scenario "contract declares the #264 teeth-proof gate boundary"

# --- 2g. Teeth-proof warning contract backstop (issue #263) ------------------
require_contract_record failure_modes id teeth-proof-missing-warn scripts/check-feature-list.sh
end_scenario "contract declares the teeth-proof-missing warn failure mode"

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
end_scenario "lifecycle obligations still present in their owner scripts"
check_owner_present env_flags
end_scenario "env-flag obligations still present in their owner scripts"
check_owner_present state_transitions
end_scenario "state-transition obligations still present in their owner scripts"
check_owner_present failure_modes
end_scenario "failure-mode obligations still present in their owner scripts"
check_owner_present trace_emission
end_scenario "trace_emission obligations still present in their owner scripts"

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
end_scenario "language-neutral scripts contain no language/toolchain tokens"

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
end_scenario "no stale IMPLEMENTATION-STATUS references in tracked files"

# --- Result: one TAP plan line; non-zero exit iff any scenario failed ---------
tap_done
