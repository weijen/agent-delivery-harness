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

(
cd "$ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Restricted bin: real coreutils + git, plus controllable fakes -----------
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for tool in bash sh env git basename dirname find grep sed tr cut head cat rm mkdir ls uname awk sleep printf; do
  p="$(command -v "$tool" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${tool}"
done

# gh: auth status succeeds; api user prints a login.
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "api user")    printf 'fixture-user\n' ; exit 0 ;;
esac
exit 1
SH
chmod +x "${BIN}/gh"

# az: account show succeeds.
cat > "${BIN}/az" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "account" ] && [ "$2" = "show" ]; then printf 'fixture-sub\n'; exit 0; fi
exit 0
SH
chmod +x "${BIN}/az"

# uv: stub so a Python surface's sync + gates succeed (exit 0) — this test is
# about the coverage WARN, not the uv path, which has its own sensor.
cat > "${BIN}/uv" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${BIN}/uv"

# new_repo <name> — fresh git repo carrying a copy of init.sh + profiles + lib.
new_repo() {
  fixture_repo --with-scripts init.sh,ci-coverage-lib.sh
  local dir="$FIXTURE_REPO"
  cp -R "${ROOT}/profiles" "${dir}/profiles"
  git -C "$dir" config commit.gpgsign true
  NEW_REPO="$dir"
}

python_surface() {
  local dir="$1"
  printf '[project]\nname = "fixture"\nversion = "0.0.0"\n' > "${dir}/pyproject.toml"
  mkdir -p "${dir}/tests"
  printf 'def test_ok():\n    assert True\n' > "${dir}/tests/test_fixture.py"
}

add_workflow() {
  # add_workflow <dir> <filename> <body>
  mkdir -p "$1/.github/workflows"
  printf '%s\n' "$3" > "$1/.github/workflows/$2"
}

OUT="${TMP_DIR}/out.txt"
run_init() {
  local dir="$1"; shift
  ( cd "$dir"
    for kv in "$@"; do export "${kv?}"; done
    PATH="${BIN}" ./scripts/init.sh
  ) >"$OUT" 2>&1
}

COVERAGE_WARN="project CI coverage missing for: python"

# --- 1. Python surface, NO workflows -> WARN (exit 0) ------------------------
new_repo warn-no-ci
r="$NEW_REPO"
python_surface "$r"
if ! run_init "$r"; then
  cat "$OUT"; fail "code surface without project CI must WARN, not fail (exit 0 expected)"
fi
grep -qi "$COVERAGE_WARN" "$OUT" || { cat "$OUT"; fail "missing project-CI coverage WARN for Python"; }

# --- 2. Only harness-smoke.yml present -> still WARN (it is not project CI) ---
new_repo warn-smoke-only
r="$NEW_REPO"
python_surface "$r"
add_workflow "$r" harness-smoke.yml $'name: harness-smoke\non: [push]\njobs:\n  smoke:\n    runs-on: ubuntu-latest\n    steps:\n      - run: pytest -q'
if ! run_init "$r"; then
  cat "$OUT"; fail "harness-smoke.yml only must still WARN (exit 0 expected)"
fi
grep -qi "$COVERAGE_WARN" "$OUT" || { cat "$OUT"; fail "harness-smoke.yml must not count as project CI"; }

# --- 3. Project workflow referencing the gate commands -> NO coverage WARN ---
new_repo covered
r="$NEW_REPO"
python_surface "$r"
add_workflow "$r" ci.yml $'name: ci\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: uv run ruff check\n      - run: uv run mypy\n      - run: uv run pytest -q'
if ! run_init "$r"; then
  cat "$OUT"; fail "covered project must pass preflight (exit 0)"
fi
if grep -qi "$COVERAGE_WARN" "$OUT"; then
  cat "$OUT"; fail "a workflow running the gates must NOT trigger the coverage WARN"
fi

# --- 4. Docs-only repo -> NO coverage WARN -----------------------------------
new_repo docs-only
r="$NEW_REPO"
if ! run_init "$r"; then
  cat "$OUT"; fail "docs-only repo must pass preflight (exit 0)"
fi
if grep -qi "project CI coverage missing" "$OUT"; then
  cat "$OUT"; fail "docs-only repo must NOT emit a coverage WARN"
fi

printf 'init ci-coverage WARN checks passed\n'
)
