#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="${ROOT}/.github/workflows/harness-smoke.yml"
PYTHON="${ROOT}/.github/workflows/python-ci.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	printf 'ci-gate-ownership: %s\n' "$*" >&2
	exit 1
}

count_literal() {
	local literal="$1" path count=0 occurrences
	for path in "$SMOKE" "$PYTHON"; do
		occurrences="$(grep -Fc "$literal" "$path" || true)"
		count=$((count + occurrences))
	done
	printf '%s\n' "$count"
}

assert_owner() {
	local gate="$1" literal="$2" owner="$3"
	[ "$(count_literal "$literal")" -eq 1 ] \
		|| fail "${gate} must have exactly one workflow owner"
	grep -Fq "$literal" "$owner" \
		|| fail "${gate} is not owned by $(basename "$owner")"
}

extract_shell_step() {
	local workflow="$1" name="$2" output="$3"
	awk -v name="$name" '
		/^      - / { selected=0; body=0 }
		$0 ~ "name: " name "$" { selected=1 }
		selected && /run: / {
			if (/run: \|$/) { body=1; next }
			sub(/^.*run: /, ""); print; next
		}
		body && /^          / { print substr($0, 11) }
	' "$workflow" >"$output"
	[ -s "$output" ] || fail "shell step missing: ${name}"
}

FIX="${TMP_DIR}/repo"
mkdir -p "$FIX" "${TMP_DIR}/bin"
paths=(scripts/flat.sh scripts/lifecycle/nested.sh scripts/lib/shared.sh
	tests/scripts/test_flat.sh tests/scripts/nested/test_nested.sh tests/scripts/lib/helper.sh
	tests/meta/test_flat.sh tests/meta/nested/test_nested.sh profiles/example.profile.sh
	tests/evals/bin/tool.sh optional/runtime-adapters/hook.sh
	optional/runtime-adapters/tests/test_hook.sh)
for path in "${paths[@]}"; do
	mkdir -p "${FIX}/$(dirname "$path")"
	printf '#!/usr/bin/env bash\nset -euo pipefail\n:\n' >"${FIX}/${path}"
done
if [ -f "${ROOT}/scripts/validation/check-shell.sh" ]; then
	mkdir -p "${FIX}/scripts/validation"
	cp "${ROOT}/scripts/validation/check-shell.sh" "${FIX}/scripts/validation/"
	paths+=(scripts/validation/check-shell.sh)
fi
mkdir -p "${FIX}/tests/scripts/fixtures"
printf 'deliberately not shell\n' >"${FIX}/tests/scripts/fixtures/invalid.sh"
printf '%s\n' "${paths[@]}" | LC_ALL=C sort >"${TMP_DIR}/expected"
export REAL_BASH REAL_SHELLCHECK SHELL_INPUT_LOG
REAL_BASH="$(command -v bash)"
REAL_SHELLCHECK="$(command -v shellcheck)"
SHELL_INPUT_LOG="${TMP_DIR}/inputs"
cat >"${TMP_DIR}/bin/bash" <<'SH'
#!/bin/sh
if [ "${1:-}" = -n ]; then
	shift
	printf '%s\n' "$@" >>"$SHELL_INPUT_LOG"
	exec "$REAL_BASH" -n "$@"
fi
exec "$REAL_BASH" "$@"
SH
cat >"${TMP_DIR}/bin/shellcheck" <<'SH'
#!/bin/sh
for arg in "$@"; do
	case "$arg" in -*) ;; *) printf '%s\n' "$arg" >>"$SHELL_INPUT_LOG";; esac
done
exec "$REAL_SHELLCHECK" "$@"
SH
chmod +x "${TMP_DIR}/bin/bash" "${TMP_DIR}/bin/shellcheck"
run_shell_step() {
	(cd "$FIX" && PATH="${TMP_DIR}/bin:${PATH}" bash "${TMP_DIR}/step.sh") \
		>"${TMP_DIR}/step.log" 2>&1
}
for profile in source adopter; do
	workflow="$SMOKE"; syntax_name="Check shell syntax"
	if [ "$profile" = adopter ]; then
		workflow="${ROOT}/profiles/adopter-smoke.yml"
		syntax_name="Check installed shell syntax"
	fi
	extract_shell_step "$workflow" "$syntax_name" "${TMP_DIR}/step.sh"
	printf '#!/usr/bin/env bash\nif then\n' >"${FIX}/scripts/lifecycle/nested.sh"
	if run_shell_step; then
		fail "${profile} syntax gate omitted a nested syntax error"
	fi
	grep -q 'scripts/lifecycle/nested.sh' "${TMP_DIR}/step.log" \
		|| fail "${profile} syntax failure must name the nested file"
	printf '#!/usr/bin/env bash\nset -euo pipefail\n:\n' >"${FIX}/scripts/lifecycle/nested.sh"
	: >"$SHELL_INPUT_LOG"
	run_shell_step || { cat "${TMP_DIR}/step.log"; fail "${profile} valid syntax failed"; }
	LC_ALL=C sort "$SHELL_INPUT_LOG" >"${TMP_DIR}/actual"
	cmp -s "${TMP_DIR}/expected" "${TMP_DIR}/actual" \
		|| fail "${profile} syntax must parse each intended identity exactly once"

	extract_shell_step "$workflow" "Run shellcheck" "${TMP_DIR}/step.sh"
	# shellcheck disable=SC2016 # Deliberately emit a lint violation.
	printf '#!/usr/bin/env bash\nprintf "%%s" $HOME\n' >"${FIX}/scripts/lib/shared.sh"
	if run_shell_step; then
		fail "${profile} lint gate omitted a nested library violation"
	fi
	grep -q SC2086 "${TMP_DIR}/step.log" || fail "${profile} lint failed for the wrong reason"
	printf '#!/usr/bin/env bash\nset -euo pipefail\n:\n' >"${FIX}/scripts/lib/shared.sh"
	: >"$SHELL_INPUT_LOG"
	run_shell_step || { cat "${TMP_DIR}/step.log"; fail "${profile} valid lint failed"; }
	LC_ALL=C sort "$SHELL_INPUT_LOG" >"${TMP_DIR}/actual"
	cmp -s "${TMP_DIR}/expected" "${TMP_DIR}/actual" \
		|| fail "${profile} lint must cover each intended identity exactly once"
done

assert_owner "Python profile gates" './scripts/validation/python-gates.sh' "$SMOKE"
assert_owner "Python dependency sync" 'uv sync --all-groups' "$SMOKE"
assert_owner "Python lock integrity" 'uv lock --check' "$PYTHON"
assert_owner "tombstone history" './scripts/check-install-harness-tombstones.sh' "$SMOKE"
assert_owner "shell syntax" './scripts/validation/check-shell.sh syntax' "$SMOKE"
assert_owner "shellcheck" './scripts/validation/check-shell.sh lint' "$SMOKE"
assert_owner "frontmatter validation" 'validate-customization-frontmatter.sh' "$SMOKE"
assert_owner "harness sensor suite" 'Run harness sensor suite' "$SMOKE"
assert_owner "L0 suite" 'run-l0-suite.sh' "$SMOKE"

for workflow in "$SMOKE" "$PYTHON"; do
	if grep -Eq 'uv run (ruff|mypy|pytest)' "$workflow"; then
		fail "$(basename "$workflow") duplicates a Python gate command"
	fi
done

(
	cd "$ROOT"
	./scripts/validation/review-gate.sh ci-gate >/dev/null
) || fail "unique Harness Smoke ownership must satisfy the project CI coverage gate"

printf 'CI gate ownership is unique\n'
