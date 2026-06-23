#!/usr/bin/env bash
# Regression sensor (issue #35): init.sh must drive its Python surface label,
# uv sync, and quality gates from the sourced profile descriptor (not hard-coded
# strings), while preserving byte-identical output and exit codes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "${TMP_DIR}"; rm -f "${OUT}"' EXIT

cd "$ROOT"

make_gh() {
  mkdir -p "$1"
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) exit 0 ;;
	api) printf 'fixture-user\n' ;;
esac
SH
  chmod +x "$1/gh"
}

# --- Case (a): wiring — init.sh must read the descriptor, not a hard-coded string
a="${TMP_DIR}/a"
mkdir -p "$a/scripts" "$a/profiles" "$a/bin"
cp "${ROOT}/scripts/init.sh" "$a/scripts/init.sh"
cat > "$a/profiles/python.profile.sh" <<'SH'
# shellcheck shell=bash
# shellcheck disable=SC2034
PROFILE_ID="python"
PROFILE_DETECT="pyproject.toml"
PROFILE_TOOL_REQUIREMENTS="uv"
PROFILE_INSTRUCTIONS="x"
PROFILE_FRAMEWORKS="x"
PROFILE_SURFACE_LABEL="STUB-PY-SURFACE"
profile_detect() { [ -f "$PWD/pyproject.toml" ]; }
PROFILE_SYNC_OK="STUB-SYNC-OK"
PROFILE_SYNC_FAIL="x"
PROFILE_SYNC_FIX="x"
PROFILE_TOOL_MISSING="x"
PROFILE_TOOL_MISSING_FIX="x"
PROFILE_SYNC_SKIP_MSG="x"
profile_sync() { uv sync --all-groups; }
PROFILE_GATES=(test)
profile_gate_test() { uv run pytest -q; }
PROFILE_GATE_test_OK="STUB-TEST-OK"
PROFILE_GATE_test_FAIL="x"
PROFILE_GATE_test_FIX="x"
SH
make_gh "$a/bin"
cat > "$a/bin/uv" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$a/bin/uv"
( cd "$a" && git init -q -b main && printf '[project]\nname="x"\n' > pyproject.toml
  PATH="$a/bin:${PATH}" ./scripts/init.sh >"$OUT" 2>&1 ) || { cat "$OUT"; echo "case-a init.sh failed"; exit 1; }
grep -q "STUB-PY-SURFACE" "$OUT" || { cat "$OUT"; echo "case-a: surface label not read from descriptor"; exit 1; }
grep -q "STUB-SYNC-OK" "$OUT" || { cat "$OUT"; echo "case-a: sync OK not read from descriptor"; exit 1; }
grep -q "STUB-TEST-OK" "$OUT" || { cat "$OUT"; echo "case-a: gate OK not read from descriptor"; exit 1; }

# --- Case (b): Python parity with the REAL descriptor ------------------------
b="${TMP_DIR}/b"
mkdir -p "$b/scripts" "$b/bin"
cp "${ROOT}/scripts/init.sh" "$b/scripts/init.sh"
cp -R "${ROOT}/profiles" "$b/profiles"
make_gh "$b/bin"
cat > "$b/bin/uv" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$b/bin/uv"
( cd "$b" && git init -q -b main && printf '[project]\nname="x"\n' > pyproject.toml
  PATH="$b/bin:${PATH}" ./scripts/init.sh >"$OUT" 2>&1 ) || { cat "$OUT"; echo "case-b init.sh failed"; exit 1; }
for s in "Python surface detected (pyproject.toml)" "uv environment synced" \
         "ruff format clean" "ruff clean" "mypy clean" "pytest passing"; do
  grep -qF "$s" "$OUT" || { cat "$OUT"; echo "case-b: missing parity string: $s"; exit 1; }
done

# --- Case (c): a failing gate hard-fails -------------------------------------
c="${TMP_DIR}/c"
mkdir -p "$c/scripts" "$c/bin"
cp "${ROOT}/scripts/init.sh" "$c/scripts/init.sh"
cp -R "${ROOT}/profiles" "$c/profiles"
make_gh "$c/bin"
cat > "$c/bin/uv" <<'SH'
#!/usr/bin/env bash
case "$*" in
	"sync --all-groups") exit 0 ;;
	"run ruff format --check .") exit 1 ;;
	*) exit 0 ;;
esac
SH
chmod +x "$c/bin/uv"
if ( cd "$c" && git init -q -b main && printf '[project]\nname="x"\n' > pyproject.toml
     PATH="$c/bin:${PATH}" ./scripts/init.sh >"$OUT" 2>&1 ); then
  cat "$OUT"; echo "case-c: init.sh must hard-fail on a failing gate"; exit 1
fi
grep -qF "ruff format would reformat" "$OUT" || { cat "$OUT"; echo "case-c: failing gate not reported"; exit 1; }
grep -qi "Preflight FAILED" "$OUT" || { cat "$OUT"; echo "case-c: no preflight failure surfaced"; exit 1; }

# --- Case (d): docs-only parity ----------------------------------------------
d="${TMP_DIR}/d"
mkdir -p "$d/scripts" "$d/bin"
cp "${ROOT}/scripts/init.sh" "$d/scripts/init.sh"
cp -R "${ROOT}/profiles" "$d/profiles"
make_gh "$d/bin"
( cd "$d" && git init -q -b main
  PATH="$d/bin:${PATH}" ./scripts/init.sh >"$OUT" 2>&1 ) || { cat "$OUT"; echo "case-d init.sh failed"; exit 1; }
grep -q "docs-only project surface detected" "$OUT" || { cat "$OUT"; echo "case-d: docs-only label missing"; exit 1; }
grep -q "shellcheck" "$OUT" || { cat "$OUT"; echo "case-d: shellcheck advisory missing"; exit 1; }

printf 'init profile wiring/parity passed\n'
