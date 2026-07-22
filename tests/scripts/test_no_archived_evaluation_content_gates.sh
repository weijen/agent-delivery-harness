#!/usr/bin/env bash
# test_no_archived_evaluation_content_gates.sh — regression sensor for issue
# #337 feature `retarget-archive-sensors` (epic #331, decision 3a).
#
# Final-review ruling: archived evaluation prose must NOT stay content-gated.
# The four sensors that either pinned now-archived doc CONTENT or audited the
# archive move were DELETED, not retargeted. This sensor pins that outcome
# behaviorally so a later PR cannot re-introduce an archived-content gate:
#   1. those four archived-content / archive-audit sensors are ABSENT;
#   2. the kept boundary sensor test_trace_schema_docs.sh reads no archived
#      prose (no docs/archive/evaluation reference) and stays green;
#   3. the L0 gates test_eval_dir_contract.sh and test_l0_manifests.sh stay
#      green — retiring the content gates did not weaken the L0 surface.
# Bash 3.2 compatible. Exit 0 all obligations honored · 1 a regression.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

# 1. The archived-content and archive-audit sensors must be gone.
for sensor in \
  tests/meta/test_agent_delivery_accuracy_matrix_contract.sh \
  tests/scripts/test_telemetry_retention_docs.sh \
  tests/scripts/test_log_pii_governance.sh \
  tests/scripts/test_eval_archive_sensor_audit.sh; do
  [ ! -e "$sensor" ] \
    || fail "${sensor} must be deleted — archived evaluation prose must not stay content-gated"
done

# 2. Kept boundary sensor reads no archived prose and stays green.
KEPT="tests/scripts/test_trace_schema_docs.sh"
if [ ! -f "$KEPT" ]; then
  fail "${KEPT} must exist — the live trace-schema boundary check is preserved"
else
  ! grep -q 'docs/archive/evaluation' "$KEPT" \
    || fail "${KEPT} must not reference docs/archive/evaluation — it must not gate archived prose"
  bash "$KEPT" >/dev/null 2>&1 \
    || fail "${KEPT} must stay green after the content gates are retired"
fi

# 3. L0 gates stay green.
for gate in tests/scripts/test_eval_dir_contract.sh tests/scripts/test_l0_manifests.sh; do
  [ -f "$gate" ] || { fail "expected L0 gate missing: ${gate}"; continue; }
  bash "$gate" >/dev/null 2>&1 \
    || fail "${gate} must stay green — retiring the content gates must not weaken L0"
done

if [ "$fails" -ne 0 ]; then
  printf '\n%d archived-content-gate violation(s).\n' "$fails" >&2
  exit 1
fi
echo "no archived evaluation content gates; kept boundary + L0 gates green"
