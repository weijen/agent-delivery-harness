#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${ROOT}/.test-init-gates.XXXXXX")"
OUT="${TMP_DIR}/out"
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "$ROOT"

# The real-root invocation deliberately fails GitHub auth before gate execution.
# This keeps the smoke check bounded while still exercising init.sh's real
# surface detection and fail-closed "skip gates" path.
DOCSBIN="${TMP_DIR}/docsbin"
mkdir -p "$DOCSBIN"
cat > "${DOCSBIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) [ "${GH_AUTH_OK:-0}" = "1" ] ;;
	api) printf 'fixture-user\n' ;;
esac
SH
cat > "${DOCSBIN}/az" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "${DOCSBIN}/terraform" <<'SH'
#!/usr/bin/env bash
touch "${GATE_SENTINEL}"
case "$1" in
	fmt|validate) exit 0 ;;
esac
exit 0
SH
cat > "${DOCSBIN}/uv" <<'SH'
#!/usr/bin/env bash
if [ "$*" != "sync --all-groups" ]; then
	touch "${GATE_SENTINEL}"
fi
exit 0
SH
cat > "${DOCSBIN}/pnpm" <<'SH'
#!/usr/bin/env bash
touch "${GATE_SENTINEL}"
exit 0
SH
cat > "${DOCSBIN}/node" <<'SH'
#!/usr/bin/env bash
touch "${GATE_SENTINEL}"
exit 0
SH
chmod +x "${DOCSBIN}"/*
if GH_AUTH_OK=0 ALLOW_GH_UNAUTH=0 REQUIRE_AZ=0 \
	GATE_SENTINEL="${TMP_DIR}/real-root-gate-ran" PATH="${DOCSBIN}:${PATH}" \
	./scripts/init.sh >"$OUT" 2>&1; then
	cat "$OUT"
	echo "real-root smoke must use the fail-closed preflight path"
	exit 1
fi

if [ -e "${TMP_DIR}/real-root-gate-ran" ]; then
	echo "real-root smoke must not execute quality gates"
	exit 1
fi

grep -q "Terraform surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "Python surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "skipping gates until earlier preflight failures are fixed" "$OUT" || { cat "$OUT"; exit 1; }
if grep -q "docs-only project" "$OUT"; then
	echo "init.sh must not report docs-only on a root with a Terraform surface"
	cat "$OUT"
	exit 1
fi

# --- Docs-only path (fixture repo with no language/infra surface) -------------
mkdir -p "${TMP_DIR}/docsrepo/scripts"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/docsrepo/scripts/init.sh"
cp -R "${ROOT}/profiles" "${TMP_DIR}/docsrepo/profiles"
(
	cd "${TMP_DIR}/docsrepo"
	git init -q -b main
	git config commit.gpgsign false
	printf '# docs-only fixture\n' > README.md
	GH_AUTH_OK=1 ALLOW_GH_UNAUTH=0 REQUIRE_AZ=0 \
		PATH="${DOCSBIN}:${PATH}" ./scripts/init.sh >"$OUT"
)
grep -q "docs-only project" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "shellcheck" "$OUT" || { cat "$OUT"; exit 1; }
# markdownlint must NOT be presented as a required local gate in the docs-only flow.
if grep -q "markdownlint" "$OUT"; then
	echo "init.sh docs-only output must not recommend markdownlint as a required gate"
	cat "$OUT"
	exit 1
fi

mkdir -p "${TMP_DIR}/repo/scripts" "${TMP_DIR}/fakebin"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/repo/scripts/init.sh"
cp -R "${ROOT}/profiles" "${TMP_DIR}/repo/profiles"
cat > "${TMP_DIR}/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) exit 0 ;;
	api) printf 'fixture-user\n' ;;
esac
SH
cat > "${TMP_DIR}/fakebin/az" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "account" ] && [ "$2" = "show" ]; then
	if [ "${AZURE_CONFIG_DIR:-}" ]; then :; fi
	printf 'fixture-sub\n'
	exit 0
fi
SH
cat > "${TMP_DIR}/fakebin/uv" <<'SH'
#!/usr/bin/env bash
printf 'uv %s\n' "$*" >> "${GATE_LOG}"
case "$1 $2" in
	"sync --all-groups") exit 0 ;;
	"run ruff") exit 0 ;;
	"run mypy") exit 0 ;;
	"run pytest") exit 0 ;;
esac
exit 0
SH
cat > "${TMP_DIR}/fakebin/pnpm" <<'SH'
#!/usr/bin/env bash
printf 'pnpm %s\n' "$*" >> "${GATE_LOG}"
exit 0
SH
cat > "${TMP_DIR}/fakebin/node" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "${TMP_DIR}/fakebin/terraform" <<'SH'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >> "${GATE_LOG}"
case "$1" in
	fmt|validate) exit 0 ;;
esac
exit 0
SH
chmod +x "${TMP_DIR}/fakebin"/*

cd "${TMP_DIR}/repo"
git init -q -b main
git config commit.gpgsign false
printf '[project]\nname = "fixture"\nversion = "0.1.0"\n' > pyproject.toml
printf '{"scripts":{"format":"true","lint":"true","test":"true"}}\n' > package.json
printf 'lockfileVersion: "9.0"\n' > pnpm-lock.yaml
printf '# fixture\n' > main.tf
mkdir -p tests
printf 'def test_fixture():\n    assert True\n' > tests/test_fixture.py

GH_AUTH_OK=0 ALLOW_GH_UNAUTH=0 REQUIRE_AZ=0 \
	GATE_LOG="${TMP_DIR}/gate.log" PATH="${TMP_DIR}/fakebin:${PATH}" ./scripts/init.sh >"$OUT"

grep -q "Python surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "Node surface detected (package.json, pnpm)" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "Terraform surface detected" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "uv environment synced" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "node tests passing" "$OUT" || { cat "$OUT"; exit 1; }
grep -q "terraform fmt clean" "$OUT" || { cat "$OUT"; exit 1; }
grep -qF "uv run pytest -q" "${TMP_DIR}/gate.log" || { cat "${TMP_DIR}/gate.log"; exit 1; }
grep -qF "pnpm run test" "${TMP_DIR}/gate.log" || { cat "${TMP_DIR}/gate.log"; exit 1; }
grep -qF "terraform fmt -check -recursive" "${TMP_DIR}/gate.log" || { cat "${TMP_DIR}/gate.log"; exit 1; }

# --- Failed-gate reporting ---------------------------------------------------
# A failing quality gate must be REPORTED and turn the run into a hard failure
# (exit 1), not be swallowed. Use a Python-only repo with a fake uv whose
# `ruff format --check` gate fails while `sync` succeeds.
FAILBIN="${TMP_DIR}/failbin"
mkdir -p "${TMP_DIR}/failrepo/scripts" "$FAILBIN"
cp "${ROOT}/scripts/init.sh" "${TMP_DIR}/failrepo/scripts/init.sh"
cp -R "${ROOT}/profiles" "${TMP_DIR}/failrepo/profiles"
cat > "${FAILBIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1" in
	auth) exit 0 ;;
	api) printf 'fixture-user\n' ;;
esac
SH
cat > "${FAILBIN}/uv" <<'SH'
#!/usr/bin/env bash
case "$*" in
	"sync --all-groups") exit 0 ;;
	"run ruff format --check .") exit 1 ;;
	*) exit 0 ;;
esac
SH
chmod +x "${FAILBIN}"/*

cd "${TMP_DIR}/failrepo"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '[project]\nname = "fixture"\nversion = "0.1.0"\n' > pyproject.toml

if GH_AUTH_OK=0 ALLOW_GH_UNAUTH=0 REQUIRE_AZ=0 \
	PATH="${FAILBIN}:${PATH}" ./scripts/init.sh >"$OUT" 2>&1; then
	cat "$OUT"
	echo "init.sh must hard-fail when a quality gate fails"
	exit 1
fi
grep -qi "ruff format would reformat" "$OUT" || { cat "$OUT"; echo "failed gate was not reported"; exit 1; }
grep -qi "Preflight FAILED" "$OUT" || { cat "$OUT"; echo "failed gate did not surface a preflight failure"; exit 1; }

printf 'init gates smoke passed\n'
(

cd "$ROOT"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# --- Restricted bin: real coreutils + git, plus controllable fake gh / az -----
BIN="${TMP_DIR}/bin"
mkdir -p "$BIN"
for tool in bash sh env git basename dirname find grep sed tr cut head cat rm mkdir ls uname awk sleep printf; do
  p="$(command -v "$tool" || true)"
  [ -n "$p" ] && ln -sf "$p" "${BIN}/${tool}"
done

# gh: `auth status` succeeds only when GH_AUTH_OK=1 (default 1); api user prints a login.
cat > "${BIN}/gh" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") [ "${GH_AUTH_OK:-1}" = "1" ] ; exit ;;
  "api user")    printf 'fixture-user\n' ; exit 0 ;;
esac
exit 1
SH
chmod +x "${BIN}/gh"

# az: `account show` succeeds only when AZ_OK=1 (default 1).
cat > "${BIN}/az" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "account" ] && [ "$2" = "show" ]; then
  [ "${AZ_OK:-1}" = "1" ] || exit 1
  printf 'fixture-sub\n'
  exit 0
fi
exit 0
SH
chmod +x "${BIN}/az"

# new_repo <name> — a fresh docs-only git repo carrying a copy of init.sh.
new_repo() {
  local dir="${TMP_DIR}/$1"
  mkdir -p "${dir}/scripts"
  cp "${ROOT}/scripts/init.sh" "${dir}/scripts/init.sh"
  cp -R "${ROOT}/profiles" "${dir}/profiles"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Harness Test"
  git -C "$dir" config user.email "harness-test@example.invalid"
  git -C "$dir" config commit.gpgsign true   # signing ON unless a test turns it off
  printf 'fixture\n' > "${dir}/README.md"
  printf '%s' "$dir"
}

# run_init <repo> — run init.sh under the restricted PATH; capture output + status.
# Extra VAR=VAL args are exported for the run. Echoes the exit code; writes
# combined output to $OUT.
OUT="${TMP_DIR}/out.txt"
run_init() {
  local dir="$1"; shift
  ( cd "$dir"
    for kv in "$@"; do export "${kv?}"; done
    PATH="${BIN}" ./scripts/init.sh
  ) >"$OUT" 2>&1
}

# --- 1. GitHub auth failure is HARD ------------------------------------------
r="$(new_repo gh-hard)"
if run_init "$r" GH_AUTH_OK=0; then
  cat "$OUT"; fail "gh auth failure must be a hard failure (exit 1)"
fi
grep -qi "gh not authenticated" "$OUT" || { cat "$OUT"; fail "missing gh-not-authenticated message"; }

# --- 2a. Azure optional by default (warn, exit 0) ----------------------------
r="$(new_repo az-default)"
if ! run_init "$r" AZ_OK=0; then
  cat "$OUT"; fail "az failure must NOT block by default (expected exit 0 warning)"
fi
grep -qi "az not authenticated" "$OUT" || { cat "$OUT"; fail "missing az optional warning"; }

# --- 2b. Azure hard with REQUIRE_AZ=1 ----------------------------------------
r="$(new_repo az-required)"
if run_init "$r" AZ_OK=0 REQUIRE_AZ=1; then
  cat "$OUT"; fail "REQUIRE_AZ=1 with az down must be a hard failure"
fi
grep -qi "REQUIRE_AZ=1" "$OUT" || { cat "$OUT"; fail "missing REQUIRE_AZ hard-fail message"; }

# --- 3. Commit signing disabled is a WARNING ---------------------------------
r="$(new_repo signing)"
git -C "$r" config commit.gpgsign false
if ! run_init "$r"; then
  cat "$OUT"; fail "disabled commit signing must warn, not fail"
fi
grep -qi "commit signing not enabled" "$OUT" || { cat "$OUT"; fail "missing commit-signing warning"; }

# --- 4. Detected surface whose tool is absent is a WARNING -------------------
# package.json present but `node` is not on the restricted PATH -> warn, exit 0.
r="$(new_repo node-missing)"
printf '{"name":"fixture"}\n' > "${r}/package.json"
if ! run_init "$r"; then
  cat "$OUT"; fail "missing language tool must warn, not fail"
fi
grep -qi "Node surface detected" "$OUT" || { cat "$OUT"; fail "missing Node surface detection"; }
grep -qi "node is not installed" "$OUT" || { cat "$OUT"; fail "missing 'node not installed' warning"; }

printf 'init preflight checks passed\n'
)

(

cd "$ROOT"
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
)
