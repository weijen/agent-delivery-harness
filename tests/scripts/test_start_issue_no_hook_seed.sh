#!/usr/bin/env bash
# test_start_issue_no_hook_seed.sh — regression sensor for issue #305, feature
# start-issue-no-hook-seed.
#
# Contract under test (PINNED HERE as the executable spec): the runtime capture
# layer is retiring, so scripts/start-issue.sh must no longer seed the
# developer-local Copilot trace hook config into a fresh worktree, and must no
# longer frame a missing .github/hooks/harness-trace.json as a "dark run".
#
#   1. No seeding: start-issue.sh contains no `cp` of harness-trace.json into a
#      worktree destination, no HOOK_DST/HOOK_SRC seeding vars, and no
#      "Seeded developer-local hook config" success message.
#   2. No dark-run warning: the obsolete launch warning that told the operator a
#      missing hook config means "runtime spans are only captured …" / a "dark
#      run" is gone (dark_run is now a semantic-spine check — issue #305 F1).
#
# Structural sensor (greps the script SOURCE).
#
# Exit codes: 0 all obligations met · 1 an obligation is violated (RED gate —
# start-issue.sh still seeds the hook / still warns about a dark run).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
START_ISSUE="${ROOT}/scripts/start-issue.sh"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

if [ ! -f "${START_ISSUE}" ]; then
  printf 'FAIL: start-issue.sh not found (%s)\n' "${START_ISSUE}" >&2
  exit 1
fi

# 1a. The "Seeded developer-local hook config" success message must be gone.
if grep -qF 'Seeded developer-local hook config' "${START_ISSUE}"; then
  fail "start-issue.sh must not print 'Seeded developer-local hook config' (seeding retired)"
fi

# 1b. The seeding destination/source vars must be gone (they existed only in the
#     §5 seeding block).
for tok in HOOK_DST HOOK_SRC; do
  if grep -qE "^[[:space:]]*${tok}=" "${START_ISSUE}"; then
    fail "start-issue.sh must not define ${tok} (hook-seeding block retired)"
  fi
done

# 1c. No `cp` of the hook file into the worktree.
if grep -qE '\bcp\b[^#]*harness-trace\.json' "${START_ISSUE}"; then
  fail "start-issue.sh must not cp harness-trace.json into the worktree (seeding retired)"
fi
if grep -qE '\bcp\b[^#]*HOOK_SRC' "${START_ISSUE}"; then
  fail "start-issue.sh must not cp the seed hook source into the worktree (seeding retired)"
fi

# 2. The obsolete dark-run launch warning must be gone.
if grep -qiF 'dark run' "${START_ISSUE}"; then
  fail "start-issue.sh must not frame a missing hook config as a 'dark run' (obsolete after #305 F1)"
fi
if grep -qiF 'runtime spans are only captured' "${START_ISSUE}"; then
  fail "start-issue.sh must not carry the 'runtime spans are only captured …' warning (capture retiring)"
fi

if [ "${fails}" -ne 0 ]; then
  printf '\n%d assertion(s) failed — start-issue.sh still seeds the hook / warns of a dark run.\n' \
    "${fails}" >&2
  exit 1
fi

printf 'PASS: start-issue.sh no longer seeds the runtime hook config or warns of a dark run.\n'
