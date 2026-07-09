#!/usr/bin/env bash
# Regression sensor (issue #243, feature start-issue-hook-preflight):
# start-issue.sh must best-effort warn when the main checkout lacks the
# developer-local Copilot trace hook config, stay silent when it is present, and
# never let that warning alter start-issue exit behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH_ROOT="${ROOT}/.copilot-tracking/test-tmp"
TMP_DIR="${SCRATCH_ROOT}/start-issue-hook-preflight.$$"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ ! -e "$TMP_DIR" ] || fail "scratch directory already exists: ${TMP_DIR}"
mkdir -p "$TMP_DIR"

command -v jq >/dev/null 2>&1 \
  || fail "jq is required because the fixture uses the real trace-lib.sh"

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

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local tool path
  for tool in "$@"; do
    path="$(command -v "$tool" || true)"
    [ -n "$path" ] && ln -sf "$path" "${dir}/${tool}"
  done
}

write_fake_gh() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1"
}

make_repo() {
  local dir="$1" hook_state="$2"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/issue-lib.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/start-issue.sh" "${dir}/scripts/"
  cp "${ROOT}/scripts/trace-lib.sh" "${dir}/scripts/"
  cat > "${dir}/scripts/init.sh" <<'SH'
#!/usr/bin/env bash
echo "stub preflight should be skipped"
exit 0
SH
  chmod +x "${dir}/scripts/init.sh"

  if [ "$hook_state" = "present" ]; then
    mkdir -p "${dir}/.github/hooks"
    printf '{"enabled":true}\n' > "${dir}/.github/hooks/harness-trace.json"
  fi

  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  printf '.copilot-tracking/\n' > "${dir}/.gitignore"
  printf 'fixture\n' > "${dir}/README.md"
  git -C "$dir" add .gitignore README.md scripts
  if [ -d "${dir}/.github" ]; then
    git -C "$dir" add .github
  fi
  (cd "$dir" && make_commit "initial" main)
}

has_hook_liveness_warning() {
  local file="$1"
  grep -qF '.github/hooks' "$file" \
    && grep -qF 'harness-trace.json' "$file" \
    && grep -Eiq 'tracing hooks|runtime spans|launched from the repo|trusted folder|trace' "$file"
}

run_start_issue() {
  local label="$1" repo="$2" issue="$3" rc=0
  local out="${TMP_DIR}/${label}.out"
  local err="${TMP_DIR}/${label}.err"
  (cd "$repo" && PATH="$BIN" SKIP_INIT=1 ./scripts/start-issue.sh "$issue" SLUG=hook-preflight >"$out" 2>"$err") \
    || rc=$?
  printf '%s' "$rc" > "${TMP_DIR}/${label}.rc"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc cp
write_fake_gh "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID SKIP_INIT 2>/dev/null || true

# LEG A: missing hooks -> loud warning, but start-issue still succeeds.
R_MISSING="${TMP_DIR}/missing-hooks"
make_repo "$R_MISSING" "missing"
run_start_issue "missing" "$R_MISSING" 243
rc_missing="$(cat "${TMP_DIR}/missing.rc")"
[ "$rc_missing" = "0" ] \
  || { cat "${TMP_DIR}/missing.err"; fail "LEG A/C: missing hook config warning must be non-fatal; start-issue exited ${rc_missing}"; }
if ! has_hook_liveness_warning "${TMP_DIR}/missing.err"; then
  cat "${TMP_DIR}/missing.err" >&2
  fail "LEG A: no hook-liveness warning emitted for missing .github/hooks/harness-trace.json"
fi

# LEG B: present hooks -> no hook-liveness warning.
R_PRESENT="${TMP_DIR}/present-hooks"
make_repo "$R_PRESENT" "present"
run_start_issue "present" "$R_PRESENT" 244
rc_present="$(cat "${TMP_DIR}/present.rc")"
[ "$rc_present" = "0" ] \
  || { cat "${TMP_DIR}/present.err"; fail "LEG C: present hook config must still allow start-issue to succeed; exited ${rc_present}"; }
if has_hook_liveness_warning "${TMP_DIR}/present.err"; then
  cat "${TMP_DIR}/present.err" >&2
  fail "LEG B: hook-liveness warning must stay silent when .github/hooks/harness-trace.json exists"
fi

printf 'start-issue hook-liveness preflight sensor passed\n'
