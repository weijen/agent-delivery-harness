#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GATES="${ROOT}/scripts/validation/python-gates.sh"
NODE_PROFILE="${ROOT}/profiles/node.profile.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
	echo "python-gates sensor: $*" >&2
	exit 1
}

[ -x "$GATES" ] || fail "authority is not executable"
bash -n "$GATES" || fail "authority does not parse"
if grep -Eq 'PROFILE_SYNC_|profile_sync[[:space:]]*\(\)' "$NODE_PROFILE"; then
	fail "Node profile retains dependency-sync declarations that init.sh never consumes"
fi

mkdir -p "${TMP_DIR}/bin"
cat >"${TMP_DIR}/bin/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${UV_LOG}"
case "$*" in
*"mypy"*) exit "${MYPY_RC:-0}" ;;
*"pytest"*) exit "${PYTEST_RC:-0}" ;;
*"ruff format"*) exit "${FORMAT_RC:-0}" ;;
*"ruff check"*) exit "${LINT_RC:-0}" ;;
*) exit 97 ;;
esac
EOF
chmod +x "${TMP_DIR}/bin/uv"
export PATH="${TMP_DIR}/bin:${PATH}"
export UV_LOG="${TMP_DIR}/uv.log"

assert_rc() {
	local want="$1"
	shift
	local got
	set +e
	"$@"
	got=$?
	set -e
	[ "$got" -eq "$want" ] || fail "expected rc ${want}, got ${got}: $*"
}

mkdir -p "$TMP_DIR/empty"
cd "$TMP_DIR/empty"
: >"$UV_LOG"
"$GATES" all >"$TMP_DIR/skip.out"
[ ! -s "$UV_LOG" ] || fail "empty project invoked Python tools"
grep -qi 'no applicable Python' "$TMP_DIR/skip.out" || fail "empty skip was not explained"
assert_rc 2 "$GATES" lint
assert_rc 2 "$GATES" unknown
mkdir -p .venv/lib node_modules/tool .worktrees/other
touch .venv/lib/ignored.py node_modules/tool/ignored.py .worktrees/other/ignored.py
"$GATES" all >/dev/null
[ ! -s "$UV_LOG" ] || fail "dependency or other worktree source activated product gates"

cat >pyproject.toml <<'TOML'
[project]
name = "tooling-only"
version = "0.1.0"
[tool.uv]
package = false
[dependency-groups]
dev = ["ruff", "mypy", "pytest"]
[tool.semantic_release]
version_toml = ["pyproject.toml:project.version"]
TOML
"$GATES" all >/dev/null
[ ! -s "$UV_LOG" ] || fail "release metadata or dormant tool dependencies activated product gates"
applicable() (
	# shellcheck source=profiles/python.profile.sh
	source "$ROOT/profiles/python.profile.sh"
	profile_detect
)
if applicable; then fail "profile and direct gates disagree about tooling-only metadata"; fi
touch component.py
applicable || fail "new Python source did not activate the profile"
"$GATES" lint
[ "$(cat "$UV_LOG")" = 'run ruff check' ] || fail "new source did not activate direct gates"
rm component.py
printf '\n[tool.ruff]\nline-length = 100\n' >>pyproject.toml
applicable || fail "new product configuration did not activate the profile"
: >"$UV_LOG"
"$GATES" lint
[ "$(cat "$UV_LOG")" = 'run ruff check' ] || fail "configuration-only change did not activate direct gates"
printf '[tool.uv]\npackage = false\n[tool."ruff"]\nline-length = 100\n' >pyproject.toml
applicable || fail "quoted product configuration was silently treated as tooling-only"
printf '[tool.uv]\npackage = false\n[tool.black]\nline-length = 100\n' >pyproject.toml
applicable || fail "other product-tool configuration was silently treated as tooling-only"
printf '[project]\nname = "product"\nversion = "0.1.0"\n' >pyproject.toml
applicable || fail "package project configuration did not activate the profile"
rm pyproject.toml
touch pytest.ini
applicable || fail "standalone product configuration did not activate the profile"
rm pytest.ini
cat >"$TMP_DIR/bin/find" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$TMP_DIR/bin/find"
assert_rc 2 "$GATES" all
rm "$TMP_DIR/bin/find"
touch product.py

MYPY_RC=2 assert_rc 2 "$GATES" typecheck
PYTEST_RC=5 assert_rc 2 "$GATES" test
PYTEST_RC=4 assert_rc 4 "$GATES" test

: >"$UV_LOG"
MYPY_RC=2 PYTEST_RC=5 "$GATES" all \
	|| fail "applicable run must preserve gate-specific skip statuses"
[ "$(wc -l <"$UV_LOG" | tr -d ' ')" -eq 4 ] \
	|| fail "full run did not execute all four gates"

: >"$UV_LOG"
LINT_RC=7 assert_rc 7 "$GATES" all
[ "$(wc -l <"$UV_LOG" | tr -d ' ')" -eq 2 ] \
	|| fail "full run did not stop at the first real failure"

# Adversarial: ruff's own exit code 2 means a fatal/usage error (e.g. a bad
# invocation or config crash), never "nothing to check" — unlike mypy's
# dormant-root exit 2 or pytest's exit 5. The dormant-root skip must not
# swallow a ruff fatal error for format_check or lint.
: >"$UV_LOG"
set +e
FORMAT_RC=2 "$GATES" all
got=$?
set -e
[ "$got" -ne 0 ] \
	|| fail "full run must not silently accept a ruff format fatal error (exit 2) as a dormant-root skip"

: >"$UV_LOG"
set +e
LINT_RC=2 "$GATES" all
got=$?
set -e
[ "$got" -ne 0 ] \
	|| fail "full run must not silently accept a ruff check fatal error (exit 2) as a dormant-root skip"

printf 'python gate authority sensor passed\n'
