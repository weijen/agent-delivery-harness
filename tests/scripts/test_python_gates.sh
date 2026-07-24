#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATES="${ROOT}/scripts/python-gates.sh"
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

for workflow in harness-smoke.yml python-ci.yml; do
	path="${ROOT}/.github/workflows/${workflow}"
	grep -qF './scripts/python-gates.sh' "$path" \
		|| fail "${workflow} bypasses the authority"
	if grep -Eq 'uv run (ruff|mypy|pytest)' "$path"; then
		fail "${workflow} duplicates a Python gate command"
	fi
done

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

MYPY_RC=2 assert_rc 2 "$GATES" typecheck
PYTEST_RC=5 assert_rc 2 "$GATES" test
PYTEST_RC=4 assert_rc 4 "$GATES" test

: >"$UV_LOG"
MYPY_RC=2 PYTEST_RC=5 "$GATES" all \
	|| fail "full run must accept dormant-root skips"
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
