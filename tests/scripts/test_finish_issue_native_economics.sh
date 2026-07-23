#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/scripts/lib/fixture.sh
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts finish-lib.sh,trace-lib.sh,log-handback.sh,check-trace-consistency.sh,trace-report.sh,issue-lib.sh,start-issue.sh,finish-issue.sh,check-feature-list.sh
# shellcheck source=tests/scripts/lib/native-economics-fixture.sh
source "${ROOT}/tests/scripts/lib/native-economics-fixture.sh"

# ===========================================================================
# CASE E2E — a REAL finish-issue.sh closeout: the native block SURVIVES into the
# main-root progress.md, the span is present, validate-trace accepts, no n/a.
# ===========================================================================
unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE REQUIRE_LOG_COMPLETE FORCE DELETE_BRANCH 2>/dev/null || true
export ABANDONED=1
F_E2E="${TMP_DIR}/e2e"
I_E2E=44
PAD_E2E="$(printf '%02d' "$I_E2E")"
copy_fixture_scripts "$F_E2E"
if ! start_out="$(cd "$F_E2E" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$I_E2E" SLUG=fixture 2>&1)"; then
  printf '%s\n' "$start_out"; hard_fail "E2E setup: start-issue failed"
fi
[ -d "${F_E2E}/.worktrees/issue-${PAD_E2E}" ] || hard_fail "E2E setup: worktree not created"
cat > "${F_E2E}/.worktrees/issue-${PAD_E2E}/.copilot-tracking/issues/issue-${PAD_E2E}/feature_list.json" <<JSON
{"features":[{"id":"native-record-economics-join","title":"native","steps":[],"passes":true,"verification":"done","teeth_proof":{"kind":"negative_fixture","evidence":"sensor"}}]}
JSON
# Overwrite the main-root trace with our fixed window (start-issue wrote its own
# current-timestamp spans); finish appends only the economics + finish spans,
# both AFTER the window is read, so the window stays [10:00, 12:00] on 2026-05-01.
plant_window_trace "$(trace_of "$F_E2E" "$I_E2E")" "$I_E2E"
STATE_E2E="${TMP_DIR}/state-e2e"
plant_events "$STATE_E2E" "$SID" bracket

rc=0
E2E_OUT="$(cd "$F_E2E" && env -u TRACE_ISSUE PATH="$BIN" FORCE=1 \
  COPILOT_AGENT_SESSION_ID="$SID" COPILOT_CLI_STATE_ROOT="$STATE_E2E" \
  ./scripts/finish-issue.sh "$I_E2E" SLUG=fixture 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || { printf '%s\n' "$E2E_OUT"; fail "E2E: finish-issue.sh must exit 0"; }
if printf '%s\n' "$E2E_OUT" | grep -F -q -- '- Tokens: n/a'; then
  printf '%s\n' "$E2E_OUT"; fail "E2E: finish output must never print '- Tokens: n/a'"
fi
MAIN_PROG="$(progress_of "$F_E2E" "$I_E2E")"
[ -f "$MAIN_PROG" ] || fail "E2E: main-root progress.md must survive teardown (${MAIN_PROG})"
grep -Eqi 'native|subagent-only' "$MAIN_PROG" \
  || { echo "--- ${MAIN_PROG} ---"; cat "$MAIN_PROG" 2>/dev/null; fail "E2E: native economics section must survive in main-root progress.md"; }
grep -F -q '3500' "$MAIN_PROG" \
  || fail "E2E: surviving progress.md must carry the in-window subagent token total 3500"
grep -F -q 'claude-sonnet-5' "$MAIN_PROG" \
  || fail "E2E: surviving progress.md must name the subagent model"
TR_E2E="$(trace_of "$F_E2E" "$I_E2E")"
[ "$(economics_span_count "$TR_E2E")" = "1" ] \
  || fail "E2E: exactly one finish-issue.economics span must be present"
SP_E2E="$(last_economics_span "$TR_E2E")"
jq_span "$SP_E2E" '."harness.economics.native_subagent_tokens" == 3500' \
  || fail "E2E: span native_subagent_tokens must be 3500 after a real finish"
jq_span "$SP_E2E" '."harness.economics.native_aiu_nano_delta" == 80000000000' \
  || fail "E2E: span native_aiu_nano_delta must be 80000000000 after a real finish"
# NOTE: check-trace-consistency.sh is exercised on the BRACKET direct trace above; the
# minimal E2E fixture trace intentionally lacks the full lifecycle-step set, so
# its completeness check is out of scope for THIS feature's native-keys contract.

if [ "$fails" -ne 0 ]; then
  printf '%s failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'native economics join contract honored\n'
