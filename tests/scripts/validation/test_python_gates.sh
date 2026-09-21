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
export REAL_PYTHON
REAL_PYTHON="$(command -v python3)"
cat >"${TMP_DIR}/bin/uv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${UV_LOG}"
if [ "$1 ${2:-}" = 'run python' ]; then
	shift 2
	exec "$REAL_PYTHON" "$@"
fi
case "$*" in
*"mypy"*)
	[ "${REQUIRE_MYPY_TARGET:-0}" != 1 ] || [ "$*" = 'run mypy --strict .' ] || exit 2
	exit "${MYPY_RC:-0}" ;;
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
: >"$UV_LOG"
assert_rc 2 "$GATES" typecheck
if grep -q '^run mypy' "$UV_LOG"; then fail "empty source invoked mypy without targets"; fi
rm pytest.ini
cat >"$TMP_DIR/bin/find" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$TMP_DIR/bin/find"
assert_rc 2 "$GATES" all
rm "$TMP_DIR/bin/find"
touch product.py

MYPY_RC=2 assert_rc 1 "$GATES" typecheck
PYTEST_RC=5 assert_rc 2 "$GATES" test
PYTEST_RC=4 assert_rc 4 "$GATES" test

: >"$UV_LOG"
REQUIRE_MYPY_TARGET=1 PYTEST_RC=5 "$GATES" all \
	|| fail "new source must supply meaningful typecheck targets"
[ "$(grep -Fxc 'run mypy --strict .' "$UV_LOG")" -eq 1 ] \
	|| fail "default typecheck scope must be the project"
MYPY_RC=2 assert_rc 1 "$GATES" all

for config in pyproject.toml mypy.ini .mypy.ini setup.cfg; do
	if [ "$config" = pyproject.toml ]; then
		printf '[tool."mypy"]\nfiles = ["product.py"]\n' >"$config"
	else
		printf '[mypy]\nfiles = product.py\n' >"$config"
	fi
	: >"$UV_LOG"
	"$GATES" typecheck
	grep -Fxq 'run mypy' "$UV_LOG" || fail "configured targets were overridden in $config"
	rm "$config"
done
printf '[tool.mypy]\nstrict = false\n' >pyproject.toml
: >"$UV_LOG"
"$GATES" typecheck
grep -Fxq 'run mypy .' "$UV_LOG" || fail "fallback targets must retain explicit project options"
printf '[mypy]\nstrict = false\n' >mypy.ini
printf '[tool.mypy]\nfiles = ["elsewhere.py"]\n' >pyproject.toml
: >"$UV_LOG"
"$GATES" typecheck
grep -Fxq 'run mypy .' "$UV_LOG" || fail "lower-priority config overrode the active mypy configuration"
rm mypy.ini
rm pyproject.toml
printf '[tool.mypy]\nfiles = [invalid TOML\n' >pyproject.toml
assert_rc 1 "$GATES" typecheck
rm pyproject.toml

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
