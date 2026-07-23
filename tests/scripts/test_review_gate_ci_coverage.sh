#!/usr/bin/env bash
# test_review_gate_ci_coverage.sh — regression + e2e sensor for issue #129,
# feature f2: the fail-closed ci-gate in scripts/review-gate.sh.
#
# Asserts:
#   1. `review-gate.sh ci-gate` FAILS CLOSED (non-zero) when a code surface is
#      present but no project-CI workflow runs its gates.
#   2. It PASSES (exit 0) once a workflow references the gate commands.
#   3. It SKIPS/passes for a docs-only repo (no code surface).
#   4. SKIP_CI_GATE=1 bypasses the gate with a logged WARN (exit 0).
#   5. The `check` path enforces ci-gate, so create-pr.sh blocks; create-pr.sh
#      opens the PR once a covering workflow exists.
#
# Exit codes: 0 all behaviors honored · 1 a behavior regressed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/fixture.sh"
fixture_repo --with-scripts review-gate.sh,ci-coverage-lib.sh
TMP_DIR="$FIXTURE_TMP_DIR"
A="$FIXTURE_REPO"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

PY_SURFACE=$'[project]\nname = "fixture"\nversion = "0.0.0"\n'
CI_WORKFLOW=$'name: ci\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: uv run ruff check\n      - run: uv run mypy\n      - run: uv run pytest -q'
SMOKE_WORKFLOW=$'name: harness-smoke\non: [push]\njobs:\n  smoke:\n    runs-on: ubuntu-latest\n    steps:\n      - run: pytest -q'

# ============================================================================
# Part A — standalone `ci-gate` subcommand (single git repo)
# ============================================================================
cp -R "${ROOT}/profiles" "${A}/profiles"
git -C "$A" add profiles
git -C "$A" commit -q -m "add profiles"

OUT="${TMP_DIR}/a.out"
run_a() { ( cd "$A"; "$@" ) >"$OUT" 2>&1; }

# 3. docs-only -> passes (exit 0)
if ! run_a ./scripts/review-gate.sh ci-gate; then
  cat "$OUT"; fail "ci-gate must pass for a docs-only repo"
fi

# 1. code surface, no project CI -> fail closed
printf '%s' "$PY_SURFACE" > "${A}/pyproject.toml"
if run_a ./scripts/review-gate.sh ci-gate; then
  cat "$OUT"; fail "ci-gate must FAIL CLOSED when a code surface has no project CI"
fi
grep -qi "no project CI runs the gates" "$OUT" || { cat "$OUT"; fail "ci-gate failure missing the expected message"; }

# 1b. harness-smoke.yml only -> still fails (not project CI)
mkdir -p "${A}/.github/workflows"
printf '%s\n' "$SMOKE_WORKFLOW" > "${A}/.github/workflows/harness-smoke.yml"
if run_a ./scripts/review-gate.sh ci-gate; then
  cat "$OUT"; fail "harness-smoke.yml must not count as project CI"
fi

# 4. SKIP_CI_GATE=1 bypass with a logged WARN
if ! run_a env SKIP_CI_GATE=1 ./scripts/review-gate.sh ci-gate; then
  cat "$OUT"; fail "SKIP_CI_GATE=1 must bypass ci-gate (exit 0)"
fi
grep -qi "SKIP_CI_GATE" "$OUT" || { cat "$OUT"; fail "SKIP_CI_GATE bypass must log a WARN"; }

# 2. covering workflow -> passes
printf '%s\n' "$CI_WORKFLOW" > "${A}/.github/workflows/ci.yml"
if ! run_a ./scripts/review-gate.sh ci-gate; then
  cat "$OUT"; fail "ci-gate must pass once a workflow runs the gates"
fi

# 2b. a .yaml (not .yml) workflow is also recognised
rm "${A}/.github/workflows/ci.yml"
printf '%s\n' "$CI_WORKFLOW" > "${A}/.github/workflows/ci.yaml"
if ! run_a ./scripts/review-gate.sh ci-gate; then
  cat "$OUT"; fail "ci-gate must recognise .yaml (not just .yml) workflows"
fi

# 1c. multi-surface: an added, uncovered Node surface still fails (per-surface)
printf '{"name":"fixture"}\n' > "${A}/package.json"
if run_a ./scripts/review-gate.sh ci-gate; then
  cat "$OUT"; fail "ci-gate must fail when ANY surface (node) lacks project CI"
fi
grep -qi 'missing for:.*node' "$OUT" || { cat "$OUT"; fail "multi-surface failure must name the uncovered surface (node)"; }
rm "${A}/package.json"

# ============================================================================
# Part B — create-pr.sh enforces ci-gate via the `check` path
# ============================================================================
make_commit() {
  local message="$1" tree commit
  tree="$(git write-tree)"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree" -p HEAD)"
  else
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree")"
  fi
  git update-ref refs/heads/feature/ci-cov "$commit"
  git reset -q --hard "$commit"
}

mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2" = "pr view" ]; then [ -n "${GH_LOG:-}" ] && [ -f "${GH_LOG}.created" ] || exit 1; printf '123\n'; exit 0; fi
if [ "$1 $2" = "pr create" ]; then printf '%s\n' "$*" >> "${GH_LOG:?}"; : > "${GH_LOG}.created"; exit 0; fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${TMP_DIR}/bin/gh"

# origin/main with the harness scripts + profiles + a docs/PROGRESS.md baseline
fixture_repo --with-scripts create-pr.sh,review-gate.sh,ci-coverage-lib.sh
OW="$FIXTURE_REPO"
mkdir -p "${OW}/docs"
cp -R "${ROOT}/profiles" "${OW}/profiles"
printf '# Progress\n\nbaseline\n' > "${OW}/docs/PROGRESS.md"
git -C "$OW" add docs/PROGRESS.md profiles
git -C "$OW" commit -q -m "add progress and profiles"
git clone -q --bare "$OW" "${TMP_DIR}/origin.git"

# working repo on a feature branch off origin/main
fixture_repo --with-scripts create-pr.sh,review-gate.sh,ci-coverage-lib.sh
R="$FIXTURE_REPO"
cd "$R"
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main
git reset -q --hard origin/main
git checkout -q -b feature/ci-cov

export PATH="${TMP_DIR}/bin:${PATH}"
export GH_LOG="${TMP_DIR}/gh.log"

# 5a. code surface + status-doc edit + approval, but NO project CI -> create-pr blocks at ci-gate
printf '%s' "$PY_SURFACE" > pyproject.toml
printf '# Progress\n\nissue-129\n' > docs/PROGRESS.md
git add pyproject.toml docs/PROGRESS.md
make_commit "surface + status doc, no project CI"
./scripts/review-gate.sh approve >/dev/null
: > "$GH_LOG"
if ./scripts/create-pr.sh --title "t" --body "b" >"${TMP_DIR}/b-block.out" 2>&1; then
  cat "${TMP_DIR}/b-block.out"; fail "create-pr opened a PR despite missing project CI"
fi
grep -qi "no project CI runs the gates" "${TMP_DIR}/b-block.out" \
  || { cat "${TMP_DIR}/b-block.out"; fail "create-pr did not stop at ci-gate"; }
[ ! -s "$GH_LOG" ] || fail "create-pr opened a PR despite the ci-gate block"

# 5b. add a covering workflow -> create-pr opens the PR
mkdir -p .github/workflows
printf '%s\n' "$CI_WORKFLOW" > .github/workflows/ci.yml
printf '# Progress\n\nissue-129 covered\n' > docs/PROGRESS.md
git add .github/workflows/ci.yml docs/PROGRESS.md
make_commit "surface + status doc + project CI"
./scripts/review-gate.sh approve >/dev/null
: > "$GH_LOG"
if ! ./scripts/create-pr.sh --title "t" --body "b" >"${TMP_DIR}/b-pass.out" 2>&1; then
  cat "${TMP_DIR}/b-pass.out"; fail "create-pr blocked even with a covering workflow"
fi
[ -s "$GH_LOG" ] || fail "create-pr did not open a PR after adding project CI"

printf 'review gate ci-coverage sensor passed\n'
