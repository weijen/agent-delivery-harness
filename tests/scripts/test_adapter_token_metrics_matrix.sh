#!/usr/bin/env bash
# test_adapter_token_metrics_matrix.sh — regression sensor for issue #319
# feature adapter-token-metrics-matrix.
#
# Contract under test: docs/runtime-adapters/github-copilot.md must replace
# the old unqualified "Token usage: the events.jsonl caveat" section with a
# version-pinned matrix that clearly separates observed token-metrics
# availability by CLI version and provenance category.
#
# Sensor legs:
#   A: A heading matching "Token-metrics version matrix" exists in the doc
#   B: Matrix section mentions CLI version "1.0.54" (the <=1.0.54 boundary)
#   C: Matrix section mentions CLI version "1.0.72" (the 1.0.72-1 observation)
#   D: Matrix section names "modelMetrics" as the per-model bucket field path
#   E: Matrix section names "totalNanoAiu" as the 1.0.72-1 observed field
#   F: Matrix section names "getMetrics" (the live RPC alternative)
#   G: Matrix section carries "undocumented" caveat language
#   H: Matrix section carries "unversioned" caveat language
#   I: Provenance — section contains "community" or "empirical" label
#   J: Citation — section references ccusage issue 1174
#   K: Citation — section references DamianEdwards/copilot-cli-cost
#   L: Citation — section references copilot-cli issue 3551
#   M: NEGATIVE — section must NOT contain old unqualified "best-effort read"
#      claim without version context nearby
#   N: Matrix section mentions "input" and "output" token fields for <=1.0.54
#   O: TEETH (mutation exec) — a temp doc with all 1.0.54 removed must cause
#      a child sensor execution to fail (proves version-pin is load-bearing)
#   P: TEETH (mutation exec) — a temp doc with "stable contract" injected must
#      cause a child sensor execution to fail; the legitimate negative caveat
#      must pass independently
#
# Environment overrides (test-only):
#   DOC — path to the adapter doc; defaults to the production path.
#   SKIP_RECURSIVE_MUTATIONS — when set to "1", skip Legs O/P child execution
#       (prevents infinite recursion when this sensor is invoked on a mutant).
#
# Exit codes: 0 all pass · 1 any obligation fails (RED gate).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${DOC:-${ROOT}/docs/runtime-adapters/github-copilot.md}"

fails=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  fails=$((fails + 1))
}

[ -f "$DOC" ] || { fail "pre" "adapter doc not found at ${DOC}"; exit 1; }

# --- Extract the token-metrics matrix section ---------------------------------
# Scoped from heading "## Token-metrics version matrix" to the next "## "
SECTION="$(sed -n '/^##[[:space:]]*Token-metrics version matrix/,/^##[[:space:]]/{
  /^##[[:space:]]*Token-metrics version matrix/p
  /^##[[:space:]]/!p
}' "$DOC")"

# --- Leg A: Heading exists ----------------------------------------------------
if [ -z "$SECTION" ]; then
  fail "A" "adapter doc must contain heading '## Token-metrics version matrix'"
fi

# --- Leg B: CLI version 1.0.54 boundary ---------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qF '1.0.54'; then
  fail "B" "Matrix section must reference CLI version '1.0.54' (the <=1.0.54 boundary)"
fi

# --- Leg C: CLI version 1.0.72 observation ------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qF '1.0.72'; then
  fail "C" "Matrix section must reference CLI version '1.0.72' (adopter observation)"
fi

# --- Leg D: modelMetrics field path -------------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qF 'modelMetrics'; then
  fail "D" "Matrix section must name 'modelMetrics' (per-model bucket field path)"
fi

# --- Leg E: totalNanoAiu field ------------------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qF 'totalNanoAiu'; then
  fail "E" "Matrix section must name 'totalNanoAiu' (1.0.72-1 observed field)"
fi

# --- Leg F: getMetrics RPC alternative ----------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qF 'getMetrics'; then
  fail "F" "Matrix section must name 'getMetrics' (live-session RPC alternative)"
fi

# --- Leg G: "undocumented" caveat ---------------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qiF 'undocumented'; then
  fail "G" "Matrix section must carry 'undocumented' caveat language"
fi

# --- Leg H: "unversioned" caveat ----------------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qiF 'unversioned'; then
  fail "H" "Matrix section must carry 'unversioned' caveat language"
fi

# --- Leg I: Provenance label ("community" or "empirical") ---------------------
if ! printf '%s\n' "$SECTION" | grep -qiE '(community|empirical)'; then
  fail "I" "Matrix section must carry a provenance label ('community' or 'empirical')"
fi

# --- Leg J: Citation — ccusage #1174 ------------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qE '(ccusage.*1174|1174.*ccusage)'; then
  fail "J" "Matrix section must cite ccusage issue 1174"
fi

# --- Leg K: Citation — DamianEdwards/copilot-cli-cost -------------------------
if ! printf '%s\n' "$SECTION" | grep -qF 'DamianEdwards/copilot-cli-cost'; then
  fail "K" "Matrix section must cite DamianEdwards/copilot-cli-cost"
fi

# --- Leg L: Citation — copilot-cli #3551 --------------------------------------
if ! printf '%s\n' "$SECTION" | grep -qE '(copilot-cli.*3551|3551)'; then
  fail "L" "Matrix section must cite copilot-cli issue 3551 (schema formalization request)"
fi

# --- Leg M: NEGATIVE — no unqualified "best-effort read" ----------------------
if printf '%s\n' "$SECTION" | grep -qiE 'best-effort read'; then
  fail "M" "Matrix section must NOT contain old unqualified 'best-effort read' language (version-pin or remove)"
fi

# --- Leg N: input/output token fields for <=1.0.54 ----------------------------
if ! printf '%s\n' "$SECTION" | grep -qiE 'input.*token|output.*token'; then
  if ! (printf '%s\n' "$SECTION" | grep -qiE '\binput\b' && printf '%s\n' "$SECTION" | grep -qiE '\boutput\b'); then
    fail "N" "Matrix section must mention input/output token fields for <=1.0.54 observation"
  fi
fi

# --- Legs O & P: TEETH via real child-process mutation execution ---------------
# Skip when invoked as a child mutation run (prevents infinite recursion).
if [ "${SKIP_RECURSIVE_MUTATIONS:-0}" != "1" ]; then

  SELF="${BASH_SOURCE[0]}"
  MUTANT_DIR=""
  # Trap cleans up the temp directory on any exit path.
  cleanup_mutants() { [ -n "$MUTANT_DIR" ] && rm -rf "$MUTANT_DIR"; }
  trap cleanup_mutants EXIT

  MUTANT_DIR="$(mktemp -d)"

  # --- Leg O: TEETH — version-pin removal must cause child failure ---------------
  # Create a mutated copy of the doc with all "1.0.54" occurrences removed, then
  # invoke this sensor against it. The child MUST fail (exit != 0).
  MUTANT_O="${MUTANT_DIR}/mutant-o.md"
  sed 's/1\.0\.54//g' "$DOC" > "$MUTANT_O"

  if DOC="$MUTANT_O" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "O" "TEETH: sensor still passes on a mutant doc with all '1.0.54' removed (version-pin is not load-bearing)"
  fi

  # --- Leg P: TEETH — stable-contract injection must cause child failure ----------
  # Create a mutated copy with an affirmative "stable contract" claim appended to
  # the matrix section, then invoke this sensor against it.
  MUTANT_P="${MUTANT_DIR}/mutant-p.md"
  sed '/^##[[:space:]]*Token-metrics version matrix/a\
This provides a stable contract for all consumers.' "$DOC" > "$MUTANT_P"

  if DOC="$MUTANT_P" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "P" "TEETH: sensor still passes on a mutant doc with 'provides a stable contract' injected"
  fi

  # --- Leg P caveat: legitimate negative caveat must not trigger the injection ----
  # Verify the real (unmodified) doc's "Nothing below is a stable contract" passes
  # Leg P's logic without false-positive rejection. This runs as a normal child
  # execution against the unmodified doc (which should pass all legs).
  if ! DOC="$DOC" SKIP_RECURSIVE_MUTATIONS=1 bash "$SELF" >/dev/null 2>&1; then
    fail "P-neg" "NEGATIVE FIXTURE: legitimate negative caveat is rejected by sensor on unmodified doc"
  fi

else
  # --- Recursive-child mode: Leg P stable-contract check only (no recursion) -----
  # Verify section does NOT affirmatively claim a stable contract/schema/API.
  # Allow negatives: "not a stable ...", "nothing ... stable ...", "no stable ..."
  NORMALIZED_SECTION="$(printf '%s\n' "$SECTION" | tr '\n' ' ')"
  AFFIRM_CHECK="$(printf '%s' "$NORMALIZED_SECTION" | sed -E \
    -e 's/[Nn]ot(hing)?[^.;]*(stable (contract|schema|API))//g' \
    -e 's/[Nn]o[^.;]*(stable (contract|schema|API))//g' \
    -e 's/is not a stable (contract|schema|API)//g')"
  if printf '%s' "$AFFIRM_CHECK" | grep -qiE '\b(is|provides|guarantees) a stable (contract|schema|API)'; then
    fail "P" "section must NOT affirmatively claim a 'stable contract/schema/API'"
  fi
  if printf '%s' "$AFFIRM_CHECK" | grep -qiE '\bstable (contract|schema|API)'; then
    fail "P" "section must NOT contain affirmative 'stable contract/schema/API'"
  fi
fi

# --- Summary ------------------------------------------------------------------
if [ "$fails" -gt 0 ]; then
  printf '\n%d obligation(s) failed.\n' "$fails" >&2
  exit 1
fi

printf 'OK: all token-metrics matrix obligations pass (16 legs, 3 mutation-exec assertions).\n'
