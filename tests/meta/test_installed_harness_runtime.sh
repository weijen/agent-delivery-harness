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
	VERSION
	docs/evaluation/trace-schema.v1.json
	docs/evaluation/log-schema.v1.json
	docs/evaluation/trace-summary.v1.json
	docs/evaluation/trace-scorecard.v1.json
	docs/evaluation/observability-and-trace-schema.md
)

JSON_FILES=(
	docs/evaluation/trace-schema.v1.json
	docs/evaluation/log-schema.v1.json
	docs/evaluation/trace-summary.v1.json
	docs/evaluation/trace-scorecard.v1.json
	docs/runtime-adapters/github-copilot.hooks.example.json
	docs/runtime-adapters/claude-code.settings.example.json
)

INSTALLED_SENSORS=(
	tests/scripts/test_harness_versioning.sh
	tests/scripts/test_trace_lib.sh
	tests/meta/test_log_schema_single_source.sh
	tests/scripts/test_trace_report_summary_json.sh
	tests/scripts/test_runtime_adapters_docs.sh
	tests/scripts/test_copilot_hook_tool_span.sh
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

[ -d "${ROOT}/docs/runtime-adapters" ] \
	|| fail "mandatory source directory is absent: docs/runtime-adapters"
while IFS= read -r source_file; do
	rel="${source_file#"${ROOT}/"}"
	assert_verbatim "$rel"
done < <(find "${ROOT}/docs/runtime-adapters" -type f | sort)

for rel in "${JSON_FILES[@]}"; do
	jq empty "${TARGET}/${rel}" >/dev/null 2>&1 \
		|| fail "installed runtime JSON asset does not parse: ${rel}"
done

for sensor in "${INSTALLED_SENSORS[@]}"; do
	run_installed_sensor "$sensor"
done

printf 'installed harness runtime sensor passed\n'