#!/usr/bin/env bash
# Regression sensor (issue #294): a real --write install must include the
# runtime dependency closure needed by the installed trace and hook sensors.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
TARGET="${TMP_DIR}/installed"
INSTALL_OUT="${TMP_DIR}/install.out"
HELP_OUT="${TMP_DIR}/install-help.out"
GETTING_STARTED="${ROOT}/docs/getting-started.md"
trap 'rm -rf "${TMP_DIR}"' EXIT

MANDATORY_FILES=(
	VERSION .env.example docs/RELEASING.md
)

MANDATORY_DIRS=(
	docs/evaluation docs/runtime-adapters tests/fixtures
	tests/evals/bin tests/evals/manifests tests/evals/fixtures tests/evals/baselines tests/evals/scorecards
)

INSTALLED_SENSORS=(
	tests/scripts/test_eval_dir_contract.sh
	tests/scripts/test_eval_manifest_validator.sh
	tests/scripts/test_run_evals_scorecard.sh
	tests/evals/bin/run-l0-suite.sh
	tests/scripts/test_meta_triage_record.sh
)

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

assert_verbatim() {
	local rel="$1"
	[ -f "${ROOT}/${rel}" ] \
		|| fail "mandatory source asset is absent: ${rel}"
	[ -f "${TARGET}/${rel}" ] \
		|| fail "mandatory installed runtime asset is absent: ${rel}"
	cmp -s "${ROOT}/${rel}" "${TARGET}/${rel}" \
		|| fail "installed runtime asset differs from source: ${rel}"
	case "$rel" in
	*.json)
		jq empty "${TARGET}/${rel}" >/dev/null 2>&1 \
			|| fail "installed runtime JSON asset does not parse: ${rel}"
		;;
	esac
}

assert_documented_category() {
	local surface="$1" file="$2" category="$3"
	shift 3
	local token
	for token in "$@"; do
		grep -qF "$token" "$file" \
			|| fail "${surface} does not name ${category} category token: ${token}"
	done
}

run_installed_sensor() {
	local sensor="$1"
	local output
	output="${TMP_DIR}/$(basename "$sensor").out"
	if ! (cd "$TARGET" && bash "$sensor") >"$output" 2>&1; then
		printf '%s\n' "--- installed sensor failed: ${sensor} ---" >&2
		cat "$output" >&2
		fail "installed sensor failed: ${sensor}"
	fi
	printf 'PASS: installed sensor %s\n' "$sensor"
}

command -v jq >/dev/null 2>&1 \
	|| fail "jq is required to validate installed runtime JSON assets"
[ -f "$INSTALL" ] || fail "installer source is absent: ${INSTALL}"
[ -f "$GETTING_STARTED" ] \
	|| fail "onboarding guide is absent: ${GETTING_STARTED}"

if ! "$INSTALL" --help >"$HELP_OUT" 2>&1; then
	cat "$HELP_OUT" >&2
	fail "installer --help failed"
fi

assert_documented_category "installer --help" "$HELP_OUT" \
	"runtime contract/schema assets" "runtime contract" "schemas"
assert_documented_category "installer --help" "$HELP_OUT" \
	"runtime-adapter guidance/templates" "runtime-adapter" "guides" "templates"
assert_documented_category "installer --help" "$HELP_OUT" \
	"VERSION identity" "VERSION" "identity"

assert_documented_category "docs/getting-started.md" "$GETTING_STARTED" \
	"runtime contract/schema assets" "runtime contract" "schemas"
assert_documented_category "docs/getting-started.md" "$GETTING_STARTED" \
	"runtime-adapter guidance/templates" "docs/runtime-adapters/" "guides" "templates"
assert_documented_category "docs/getting-started.md" "$GETTING_STARTED" \
	"VERSION identity" "VERSION" "identity"

mkdir -p "$TARGET"
if ! "$INSTALL" "$TARGET" --write >"$INSTALL_OUT" 2>&1; then
	cat "$INSTALL_OUT" >&2
	fail "installer --write failed"
fi

for rel in "${MANDATORY_FILES[@]}"; do
	assert_verbatim "$rel"
done

for directory in "${MANDATORY_DIRS[@]}"; do
	[ -d "${ROOT}/${directory}" ] \
		|| fail "mandatory source directory is absent: ${directory}"
	while IFS= read -r source_file; do
		rel="${source_file#"${ROOT}/"}"
		assert_verbatim "$rel"
	done < <(find "${ROOT}/${directory}" -type f | sort)
done

for sensor in "${INSTALLED_SENSORS[@]}"; do
	run_installed_sensor "$sensor"
done

printf 'installed harness runtime sensor passed\n'