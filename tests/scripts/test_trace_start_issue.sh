#!/usr/bin/env bash
# test_trace_start_issue.sh — regression sensor for start-issue.sh trace
# emission (issue #94, feature trace-start-issue, plan Phase 2).
#
# Contract under test (plan instrumentation table, decisions D3/D6):
#
#   1. A successful `start-issue.sh N` run emits, to the MAIN checkout root's
#      .copilot-tracking/issues/issue-NN/trace.jsonl, a `preflight` lifecycle
#      span followed by a `worktree_create` lifecycle span (file append
#      order). Every span carries harness.outcome, a NUMERIC
#      harness.exit_status and a NUMERIC harness.duration_ms, and passes the
#      contract-driven jq filter (issue #92). start-issue runs on branch
#      `main`, so emission requires the script to export TRACE_ISSUE (D6) —
#      spans silently dropped by branch resolution are a failure here.
#   2. Preflight failure path (init.sh exits non-zero): a `preflight` span
#      with harness.outcome=fail and a non-zero numeric harness.exit_status
#      is still emitted, NO `worktree_create` span appears (that stage never
#      ran), and the script's observable behavior is unchanged: non-zero
#      exit, "Preflight failed" message, no worktree, no branch.
#   3. Guarded sourcing (plan D5): when trace-lib.sh is absent from the
#      fixture's scripts/ dir, start-issue.sh must still work end-to-end
#      (exit 0, worktree created) — a missing tracing library never breaks
#      the lifecycle.
#
# Fixture style follows test_lifecycle_order.sh: throwaway repos under
# mktemp -d, harness scripts copied in individually, per-case pinned PATH
# (real coreutils/git/jq + fake gh), stub init.sh success/failure.
#
# Exit codes: 0 emission contract honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# jq drives both trace-lib emission and the contract validation filter.
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate start-issue trace emission"

[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found at docs/evaluation/trace-schema.v1.json (${CONTRACT})"

# --- Contract-driven span validation ------------------------------------------
# ============================================================================
# TRACE SPAN VALIDATION FILTER (self-contained; issue #97 lifts this unchanged)
# Usage: jq -e --slurpfile contract docs/evaluation/trace-schema.v1.json \
#            -f validate-span.jq  <<< "$one_span_json_line"
# A span line is valid iff the filter outputs true (jq -e exit 0). A non-JSON
# line fails jq parsing itself (non-zero exit), which is also a rejection.
# ============================================================================
FILTER="${TMP_DIR}/validate-span.jq"
cat > "$FILTER" <<'JQ'
$contract[0] as $c
| . as $span
| (($span | type) == "object")
  and ((($c.required_common // []) - ($span | keys)) | length == 0)
  and (($c.span_types // []) | index($span.span) != null)
  and (((($c.required_by_span // {})[$span.span // ""] // []) - ($span | keys)) | length == 0)
  and (if $span.span == "lifecycle"
       then (($c.lifecycle_steps // []) | index($span["harness.lifecycle_step"]) != null)
       else true
       end)
JQ

validate_span() {
  printf '%s\n' "$1" \
    | jq -e --slurpfile contract "$CONTRACT" -f "$FILTER" >/dev/null 2>&1
}

validate_file() {
  local label="$1" file="$2" n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    validate_span "$line" \
      || fail "${label}: line ${n} rejected by the contract-driven jq validation filter: ${line}"
  done < "$file"
  [ "$n" -gt 0 ] || fail "${label}: trace file is empty (${file})"
}

# Assert one lifecycle span (given as a JSON line) carries outcome/status/
# duration with the D4 numeric typing.
check_lifecycle_metrics() {
  local label="$1" line="$2" want_outcome="$3"
  printf '%s\n' "$line" | jq -e --arg outcome "$want_outcome" '
      (.["harness.outcome"] == $outcome)
      and ((.["harness.exit_status"] | type) == "number")
      and (if $outcome == "pass"
           then (.["harness.exit_status"] == 0)
           else (.["harness.exit_status"] != 0)
           end)
      and ((.["harness.duration_ms"] | type) == "number")
      and (.["harness.duration_ms"] >= 0)
    ' >/dev/null \
    || fail "${label}: span must carry harness.outcome=${want_outcome}, numeric harness.exit_status ($([ "$want_outcome" = pass ] && printf '0' || printf 'non-zero')) and numeric harness.duration_ms >= 0: ${line}"
}

# --- Fixture helpers (test_lifecycle_order.sh style) ----------------------------
make_commit() {
  local message="$1" branch="$2" tree commit
  tree="$(git write-tree)"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree" -p HEAD)"
  else
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree")"
  fi
  git update-ref "refs/heads/${branch}" "$commit"
  git reset -q --hard "$commit"
}

# link_tools <dir> <tool...> — symlink real tool paths into an isolated bin dir.
link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

# Fake gh: `issue view` fails so callers fall back (SLUG= is always passed).
write_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1"
}

# make_repo <dir> <with_trace_lib:0|1> <init_exit_code>
# Builds a main-checkout fixture repo with the start-issue scripts, a stub
# init.sh exiting <init_exit_code>, and (optionally) trace-lib.sh.
make_repo() {
  local dir="$1" with_lib="$2" init_rc="$3"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/issue-lib.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/start-issue.sh" "${dir}/scripts/"
  if [ "$with_lib" = "1" ]; then
    cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  fi
  cat > "${dir}/scripts/init.sh" <<SH
#!/usr/bin/env bash
echo "stub preflight (exit ${init_rc})"
exit ${init_rc}
SH
  chmod +x "${dir}/scripts/init.sh"
  cd "$dir"
  git init -q -b main
  git config user.name "Harness Test"
  git config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > .gitignore
  printf 'fixture\n' > README.md
  git add .gitignore README.md scripts
  make_commit "initial" main
}

# Pinned PATH: real tools trace-lib + start-issue need, plus the fake gh.
BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc
write_fake_gh "${BIN}/gh"

# The fixtures must control issue resolution: no ambient overrides.
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

# ============================================================================
# 1. Happy path: preflight + worktree_create spans at the MAIN root
# ============================================================================
R1="${TMP_DIR}/r1"
make_repo "$R1" 1 0
cd "$R1"
PATH="$BIN" ./scripts/start-issue.sh 40 SLUG=trace >"${TMP_DIR}/start-ok.out" 2>&1 \
  || { cat "${TMP_DIR}/start-ok.out"; fail "start-issue.sh must exit 0 on the happy path (behavior unchanged)"; }
[ -d "${TMP_DIR}/r1-worktrees/issue-40" ] \
  || fail "happy path: worktree for issue 40 was not created"

TRACE1="${R1}/.copilot-tracking/issues/issue-40/trace.jsonl"
[ -f "$TRACE1" ] \
  || fail "successful start-issue.sh run must emit spans to the MAIN root trace file (${TRACE1} missing) — start-issue.sh is not instrumented (feature trace-start-issue)"
validate_file "happy-path trace" "$TRACE1"

# Lifecycle-step sequence in file (append) order: exactly preflight then
# worktree_create (plan instrumentation table).
steps="$(jq -r 'select(.span == "lifecycle") | .["harness.lifecycle_step"]' "$TRACE1" | paste -sd, -)"
[ "$steps" = "preflight,worktree_create" ] \
  || fail "happy path: lifecycle spans must be exactly 'preflight,worktree_create' in append order, got '${steps}'"

preflight_line="$(jq -c 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "preflight")' "$TRACE1")"
wt_line="$(jq -c 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "worktree_create")' "$TRACE1")"
check_lifecycle_metrics "happy-path preflight span" "$preflight_line" "pass"
check_lifecycle_metrics "happy-path worktree_create span" "$wt_line" "pass"

# start-issue runs on branch main — harness.issue must still be 40 (D6:
# the script exports TRACE_ISSUE; a dropped span already failed above).
jq -e 'select(.span == "lifecycle") | (.["harness.issue"] == 40) and ((.["harness.issue"] | type) == "number")' \
  "$TRACE1" >/dev/null \
  || fail "happy path: spans must stamp harness.issue=40 (JSON number) via the script's TRACE_ISSUE export"

# ============================================================================
# 2. Preflight failure: fail span emitted, behavior unchanged, no worktree span
# ============================================================================
R2="${TMP_DIR}/r2"
make_repo "$R2" 1 1
cd "$R2"
if PATH="$BIN" ./scripts/start-issue.sh 41 SLUG=trace >"${TMP_DIR}/start-fail.out" 2>&1; then
  cat "${TMP_DIR}/start-fail.out"
  fail "start-issue.sh must still abort (non-zero) when preflight fails (behavior unchanged)"
fi
grep -qi "Preflight failed" "${TMP_DIR}/start-fail.out" \
  || { cat "${TMP_DIR}/start-fail.out"; fail "preflight-fail path: 'Preflight failed' message must be unchanged"; }
[ ! -e "${TMP_DIR}/r2-worktrees/issue-41" ] \
  || fail "preflight-fail path: no worktree may be created (existing ordering invariant)"
if git show-ref --verify --quiet refs/heads/feature/issue-41-trace; then
  fail "preflight-fail path: no issue branch may be created"
fi

TRACE2="${R2}/.copilot-tracking/issues/issue-41/trace.jsonl"
[ -f "$TRACE2" ] \
  || fail "failed preflight must STILL emit a preflight fail span to the main-root trace file (${TRACE2} missing) — failure paths are exactly the trajectories the evals need"
validate_file "preflight-fail trace" "$TRACE2"

fail_steps="$(jq -r 'select(.span == "lifecycle") | .["harness.lifecycle_step"]' "$TRACE2" | paste -sd, -)"
[ "$fail_steps" = "preflight" ] \
  || fail "preflight-fail path: lifecycle spans must be exactly 'preflight' (fail span, and NO worktree_create — that stage never ran), got '${fail_steps}'"
fail_line="$(jq -c 'select(.span == "lifecycle" and .["harness.lifecycle_step"] == "preflight")' "$TRACE2")"
check_lifecycle_metrics "preflight-fail span" "$fail_line" "fail"

# ============================================================================
# 3. Guarded sourcing: trace-lib.sh absent — start-issue still works (plan D5)
# ============================================================================
R3="${TMP_DIR}/r3"
make_repo "$R3" 0 0
cd "$R3"
[ ! -e "${R3}/scripts/trace-lib.sh" ] || fail "fixture bug: R3 must not contain trace-lib.sh"
PATH="$BIN" ./scripts/start-issue.sh 42 SLUG=trace >"${TMP_DIR}/start-nolib.out" 2>&1 \
  || { cat "${TMP_DIR}/start-nolib.out"; fail "start-issue.sh must still succeed when trace-lib.sh is absent (guarded source / no-op fallback, plan D5)"; }
[ -d "${TMP_DIR}/r3-worktrees/issue-42" ] \
  || fail "trace-lib-absent path: worktree for issue 42 was not created"

printf 'start-issue trace emission contract honored\n'
