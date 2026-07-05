#!/usr/bin/env bash
# test_eval_dir_contract.sh — regression sensor for feature f1-eval-dir-contract
# (issue #61): the target-first eval framework directory skeleton exists and is
# kept tracked.
#
# Executable spec: git does not track empty directories, so each contract
# directory must carry a `.gitkeep` file that keeps it present in every
# checkout. This sensor asserts, per directory, that the directory exists AND a
# `.gitkeep` keeps it tracked. The `tests/evals/scorecards/` directory is
# already kept by an existing `.gitkeep` (issue #104) and is accepted as-is.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# The target-first eval directory contract (issue #61 f1). Every entry must
# exist as a directory and be kept tracked by a `.gitkeep`.
CONTRACT_DIRS=(
  "tests/evals/manifests/scripts"
  "tests/evals/manifests/skills"
  "tests/evals/fixtures/scripts"
  "tests/evals/fixtures/skills"
  "tests/evals/scorecards"
  "tests/evals/baselines"
)

for rel in "${CONTRACT_DIRS[@]}"; do
  dir="${ROOT}/${rel}"
  [ -d "$dir" ] \
    || fail "missing contract directory: ${rel} — the eval framework skeleton must include this directory"
  [ -f "${dir}/.gitkeep" ] \
    || fail "missing keeper: ${rel}/.gitkeep — git does not track empty directories, so ${rel} needs a .gitkeep to stay present in checkouts"
done

printf 'PASS: eval directory contract satisfied — all %d directories exist and are kept by .gitkeep\n' "${#CONTRACT_DIRS[@]}"
