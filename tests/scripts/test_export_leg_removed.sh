#!/usr/bin/env bash
# Regression sensor for issue #272 feature `remove-export-scripts-and-callsites`.
#
# The L4 deletion review removed the cloud export leg (trace/log export to App
# Insights / OTLP) and the local trace-reconstruct step: no in-loop gate or
# recurring human decision reads their output. This sensor is the teeth that
# keep the leg deleted — it fails if any doomed script, the trace_tools package,
# a finish-lib/finish-issue/create-pr call site, or a cloud-export env var in
# .env.example comes back.
#
# KEEP (must NOT be flagged): trace-lib.sh, the runtime hooks, check-trace-consistency.sh,
# check-trace-consistency.sh, log-handback.sh, trace-report.sh, trace-report.sh --all,
# and COPILOT_OTEL_FILE_EXPORTER_PATH (the local span-file sink for the hook).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

fail=0
note() { printf 'FAIL: %s\n' "$1"; fail=1; }

# 1. The retired trace_tools path has an explicit root-anchored ignore rule.
if ! grep -Fxq '/scripts/trace_tools/' .gitignore; then
  note ".gitignore must contain the root-anchored /scripts/trace_tools/ rule"
fi

# 2. The doomed scripts are gone.
for s in trace-export.sh log-export.sh gen-export-env.sh sanitize-trace.sh trace-reconstruct.sh; do
  [ -e "scripts/$s" ] && note "scripts/$s must be deleted (dead export/reconstruct leg)"
done

# 3. The trace_tools Python export package is gone (nothing kept imports it).
[ -e "scripts/trace_tools" ] && note "scripts/trace_tools/ must be deleted (Python export pilot, no kept importer)"

# 4. No call sites survive in the kept lifecycle scripts.
for pair in \
  "scripts/finish-lib.sh:best_effort_trace_export" \
  "scripts/finish-lib.sh:best_effort_log_export" \
  "scripts/finish-lib.sh:best_effort_trace_reconstruct" \
  "scripts/finish-issue.sh:best_effort_trace_export" \
  "scripts/finish-issue.sh:best_effort_log_export" \
  "scripts/finish-issue.sh:best_effort_trace_reconstruct"; do
  f="${pair%%:*}"; sym="${pair##*:}"
  if grep -q "$sym" "$f"; then note "$f still references removed helper $sym"; fi
done

# create-pr.sh must not shell out to the deleted log-export.sh.
if grep -q 'log-export\.sh' scripts/create-pr.sh; then
  note "scripts/create-pr.sh still invokes the deleted log-export.sh"
fi

# 5. The cloud-export env vars are gone from the committed template, but the
#    local Copilot OTel file sink stays (it feeds the kept trace hook).
for v in TRACE_EXPORT_OTLP TRACE_EXPORT_OTLP_HTTP LOG_EXPORT_OTLP LOG_EXPORT_OTLP_HTTP \
         CREATE_PR_LOG_EXPORT APPLICATIONINSIGHTS_CONNECTION_STRING; do
  if grep -q "^${v}=" .env.example; then note ".env.example still declares removed cloud-export var ${v}"; fi
done
if ! grep -q '^COPILOT_OTEL_FILE_EXPORTER_PATH=' .env.example; then
  note ".env.example must keep COPILOT_OTEL_FILE_EXPORTER_PATH (local hook span sink)"
fi

if [ "$fail" -ne 0 ]; then
  echo "export leg is NOT fully removed"
  exit 1
fi
echo "export/reconstruct leg removed: scripts, trace_tools, call sites, and cloud-export env vars all gone"
