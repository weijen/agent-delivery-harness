#!/usr/bin/env bash
# Regression sensor for issue #129, feature f1: scripts/init.sh preflight WARNs
# (exit 0) when a code surface is present but NO project-CI workflow runs that
# surface's gates. harness-smoke.yml is the harness's own CI, not project CI, so
# it never counts. Docs-only repos and repos whose workflow references the gate
# commands must NOT warn.
#
# Runs the real init.sh under a restricted PATH with fake gh / az / uv binaries
# so the result does not depend on the developer's login state or toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
  local dir="${TMP_DIR}/$1"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/init.sh" "${dir}/scripts/init.sh"
  [ -f "${ROOT}/scripts/ci-coverage-lib.sh" ] && cp "${ROOT}/scripts/ci-coverage-lib.sh" "${dir}/scripts/ci-coverage-lib.sh"
  cp -R "${ROOT}/profiles" "${dir}/profiles"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign true
  printf 'fixture\n' > "${dir}/README.md"
  printf '%s' "$dir"
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
r="$(new_repo warn-no-ci)"
python_surface "$r"
if ! run_init "$r"; then
  cat "$OUT"; fail "code surface without project CI must WARN, not fail (exit 0 expected)"
fi
grep -qi "$COVERAGE_WARN" "$OUT" || { cat "$OUT"; fail "missing project-CI coverage WARN for Python"; }

# --- 2. Only harness-smoke.yml present -> still WARN (it is not project CI) ---
r="$(new_repo warn-smoke-only)"
python_surface "$r"
add_workflow "$r" harness-smoke.yml $'name: harness-smoke\non: [push]\njobs:\n  smoke:\n    runs-on: ubuntu-latest\n    steps:\n      - run: pytest -q'
if ! run_init "$r"; then
  cat "$OUT"; fail "harness-smoke.yml only must still WARN (exit 0 expected)"
fi
grep -qi "$COVERAGE_WARN" "$OUT" || { cat "$OUT"; fail "harness-smoke.yml must not count as project CI"; }

# --- 3. Project workflow referencing the gate commands -> NO coverage WARN ---
r="$(new_repo covered)"
python_surface "$r"
add_workflow "$r" ci.yml $'name: ci\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: uv run ruff check\n      - run: uv run mypy\n      - run: uv run pytest -q'
if ! run_init "$r"; then
  cat "$OUT"; fail "covered project must pass preflight (exit 0)"
fi
if grep -qi "$COVERAGE_WARN" "$OUT"; then
  cat "$OUT"; fail "a workflow running the gates must NOT trigger the coverage WARN"
fi

# --- 4. Docs-only repo -> NO coverage WARN -----------------------------------
r="$(new_repo docs-only)"
if ! run_init "$r"; then
  cat "$OUT"; fail "docs-only repo must pass preflight (exit 0)"
fi
if grep -qi "project CI coverage missing" "$OUT"; then
  cat "$OUT"; fail "docs-only repo must NOT emit a coverage WARN"
fi

printf 'init ci-coverage WARN checks passed\n'
