#!/usr/bin/env bash
# test_finish_issue_env_autoload.sh — e2e sensor for closeout trace export
# auto-loading the gitignored main-checkout .env from finish-lib.sh.
#
# Contract under test (issue #244, feature finish-env-autoload):
# best_effort_trace_export must load ${SCRIPT_DIR}/../.env before its export
# gate checks so a developer who ran gen-export-env.sh once gets automatic
# closeout export from the main checkout, including when finishing an issue
# worktree, while absent/incomplete .env remains a clean best-effort no-op.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_PARENT="${ROOT}/.copilot-tracking/test-tmp"
mkdir -p "$TMP_PARENT"
TMP_DIR="$(mktemp -d "${TMP_PARENT}/finish-env-autoload.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"; rmdir "${TMP_PARENT}" 2>/dev/null || true' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 \
  || fail "jq is required (check-feature-list.sh validates the feature_list)"

for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh trace-lib.sh; do
  [ -f "${ROOT}/scripts/${s}" ] \
    || fail "required harness script missing: scripts/${s}"
done

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

write_fake_gh() {
  cat > "$1" <<'FAKE_GH'
#!/usr/bin/env bash
exit 1
FAKE_GH
  chmod +x "$1"
}

write_fake_exporter() {
  cat > "$1" <<'FAKE_EXPORTER'
#!/usr/bin/env bash
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "$*" >> "${here}/../trace-export-calls.log"
exit "${FAKE_EXPORT_EXIT:-0}"
FAKE_EXPORTER
  chmod +x "$1"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rmdir rm cat sed tr cut grep printf jq date od wc mktemp chmod
write_fake_gh "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID REQUIRE_FEATURES_COMPLETE FORCE DELETE_BRANCH \
  TRACE_EXPORT_OTLP APPLICATIONINSIGHTS_CONNECTION_STRING TRACE_EXPORT_OTLP_HTTP \
  OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_TRACES_ENDPOINT \
  OTEL_EXPORTER_OTLP_HEADERS FAKE_EXPORT_EXIT 2>/dev/null || true

COMPLETE_LIST='{"features":[{"id":"finish-env-autoload","title":"Finish env autoload","steps":[],"passes":true,"verification":"done"}]}'

make_export_fixture() {
  local dir="$1" issue="$2" pad
  pad="$(printf '%02d' "$issue")"
  mkdir -p "${dir}/scripts"
  for s in issue-lib.sh start-issue.sh finish-issue.sh finish-lib.sh check-feature-list.sh trace-lib.sh; do
    cp "${ROOT}/scripts/${s}" "${dir}/scripts/"
  done
  write_fake_exporter "${dir}/scripts/trace-export.sh"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n.env\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  git -C "$dir" commit -q -m initial
  (cd "$dir" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=fixture) \
    > "${TMP_DIR}/start-${issue}.out" 2>&1 \
    || { cat "${TMP_DIR}/start-${issue}.out"; fail "setup: start-issue for issue ${issue} failed"; }
  [ -d "${dir}-worktrees/issue-${pad}" ] \
    || fail "setup: worktree for issue ${issue} was not created"
  printf '%s\n' "$COMPLETE_LIST" \
    > "${dir}-worktrees/issue-${pad}/.copilot-tracking/issues/issue-${pad}/feature_list.json"
}

run_finish_env_unset() {
  local repo="$1" issue="$2" output="$3"
  (cd "$repo" && env -u TRACE_EXPORT_OTLP -u APPLICATIONINSIGHTS_CONNECTION_STRING \
    -u TRACE_EXPORT_OTLP_HTTP -u OTEL_EXPORTER_OTLP_ENDPOINT \
    -u OTEL_EXPORTER_OTLP_TRACES_ENDPOINT -u OTEL_EXPORTER_OTLP_HEADERS \
    PATH="$BIN" FORCE=1 FAKE_EXPORT_EXIT=0 \
    ./scripts/finish-issue.sh "$issue" SLUG=fixture) > "$output" 2>&1
}

# ============================================================================
# 1. AUTOLOAD: valid main-root .env, process env unset → exporter invoked.
#    RED now until best_effort_trace_export loads ${SCRIPT_DIR}/../.env before
#    checking TRACE_EXPORT_OTLP / APPLICATIONINSIGHTS_CONNECTION_STRING.
# ============================================================================
R_AUTO="${TMP_DIR}/r244"
AUTO_SECRET='InstrumentationKey=fake-244;IngestionEndpoint=https://x/'
make_export_fixture "$R_AUTO" 244
cat > "${R_AUTO}/.env" <<ENV_FILE
TRACE_EXPORT_OTLP='1'
APPLICATIONINSIGHTS_CONNECTION_STRING='${AUTO_SECRET}'
ENV_FILE
run_finish_env_unset "$R_AUTO" 244 "${TMP_DIR}/fin-autoload.out" \
  || { cat "${TMP_DIR}/fin-autoload.out"; fail "autoload: finish-issue.sh must exit 0"; }
[ ! -e "${R_AUTO}-worktrees/issue-244" ] \
  || fail "autoload: worktree must still be removed"
[ -s "${R_AUTO}/trace-export-calls.log" ] \
  || fail "autoload: exporter MUST be invoked from a valid main-root .env when process env trace keys are unset"
grep -qw '244' "${R_AUTO}/trace-export-calls.log" \
  || { cat "${R_AUTO}/trace-export-calls.log"; fail "autoload: exporter must be called with issue number 244"; }
if grep -q -- "$AUTO_SECRET" "${TMP_DIR}/fin-autoload.out"; then
  fail "autoload: finish output leaked the connection string"
fi
if git -C "$R_AUTO" grep -q -- "$AUTO_SECRET"; then
  fail "autoload: a tracked file contains the connection string"
fi

# ============================================================================
# 2. PROCESS-ENV-OVERRIDE: .env supplies TRACE_EXPORT_OTLP but has an empty
#    connection string; process env supplies the connection string and wins.
# ============================================================================
R_OVERRIDE="${TMP_DIR}/r245"
make_export_fixture "$R_OVERRIDE" 245
cat > "${R_OVERRIDE}/.env" <<'ENV_FILE'
TRACE_EXPORT_OTLP='1'
APPLICATIONINSIGHTS_CONNECTION_STRING=''
ENV_FILE
(cd "$R_OVERRIDE" && env -u TRACE_EXPORT_OTLP \
    -u TRACE_EXPORT_OTLP_HTTP -u OTEL_EXPORTER_OTLP_ENDPOINT \
    -u OTEL_EXPORTER_OTLP_TRACES_ENDPOINT -u OTEL_EXPORTER_OTLP_HEADERS \
    PATH="$BIN" FORCE=1 FAKE_EXPORT_EXIT=0 \
    APPLICATIONINSIGHTS_CONNECTION_STRING='InstrumentationKey=fake-override;IngestionEndpoint=https://x/' \
    ./scripts/finish-issue.sh 245 SLUG=fixture) \
  > "${TMP_DIR}/fin-override.out" 2>&1 \
  || { cat "${TMP_DIR}/fin-override.out"; fail "process-env override: finish-issue.sh must exit 0"; }
[ ! -e "${R_OVERRIDE}-worktrees/issue-245" ] \
  || fail "process-env override: worktree must still be removed"
[ -s "${R_OVERRIDE}/trace-export-calls.log" ] \
  || fail "process-env override: exporter MUST be invoked when .env supplies opt-in and process env supplies the connection string"
grep -qw '245' "${R_OVERRIDE}/trace-export-calls.log" \
  || { cat "${R_OVERRIDE}/trace-export-calls.log"; fail "process-env override: exporter must be called with issue number 245"; }

# ============================================================================
# 3. NO-ENV NO-OP: no main-root .env and process env unset → exporter not
#    invoked, but best-effort teardown still completes.
# ============================================================================
R_NOENV="${TMP_DIR}/r246"
make_export_fixture "$R_NOENV" 246
run_finish_env_unset "$R_NOENV" 246 "${TMP_DIR}/fin-noenv.out" \
  || { cat "${TMP_DIR}/fin-noenv.out"; fail "no-env no-op: finish-issue.sh must exit 0"; }
[ ! -e "${R_NOENV}-worktrees/issue-246" ] \
  || fail "no-env no-op: worktree must still be removed"
[ ! -s "${R_NOENV}/trace-export-calls.log" ] \
  || { cat "${R_NOENV}/trace-export-calls.log"; fail "no-env no-op: exporter must NOT be invoked without .env or process env config"; }

printf 'finish-issue .env autoload closeout export contract honored\n'
