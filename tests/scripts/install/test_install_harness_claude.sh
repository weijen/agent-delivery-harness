#!/usr/bin/env bash
# The retired selection is refused by source and self-hosted installations.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
OUT="${TMP_DIR}/install.out"
fail() { [ ! -f "$OUT" ] || cat "$OUT" >&2; printf 'retired-claude: %s\n' "$*" >&2; exit 1; }

# Archives and immutable fixtures describe history, not executable integration.
while IFS= read -r path; do
	case "$path" in
		docs/archive/*|tests/scripts/fixtures/*) continue ;;
		*/claude-code*|*/test_claude_*)
			[ ! -e "${ROOT}/${path}" ] || fail "active retired adapter asset remains: ${path}"
			;;
	esac
done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard)
for registry in scripts/install-harness.assets scripts/install-harness.dev.assets tests/harness-dev-sensors.txt; do
	if grep -Eq 'optional/runtime-adapters|tests/scripts/test_claude_' "${ROOT}/${registry}"; then
		fail "active retired adapter registration remains: ${registry}"
	fi
done
if git -C "$ROOT" grep -n -E 'CLAUDE_PROJECT_DIR|claude-code-trace-hook|claude-code.settings' \
	-- .github .copilot profiles >"$OUT"; then
	fail "active configuration advertises retired adapter"
fi
if grep -Fq optional/runtime-adapters "${ROOT}/scripts/validation/check-shell.sh"; then
	fail "shell discovery still registers retired adapter surface"
fi

check_refusal() {
	local source="$1" entry="" mode="" target="${TMP_DIR}/refused"
	for entry in scripts/install-harness.sh scripts/install/install-harness.sh; do
		for mode in dry --write --update; do
			args=("$target" --with-claude)
			[ "$mode" = dry ] || args+=("$mode")
			if "${source}/${entry}" "${args[@]}" >"$OUT" 2>&1; then
				fail "${entry} accepted retired flag in ${mode}"
			fi
			grep -Fq -- '--with-claude is retired' "$OUT" || fail "missing explicit retirement diagnosis"
			[ ! -e "$target" ] || fail "refused selection partially wrote a target"
		done
		"${source}/${entry}" --help >"$OUT" 2>&1 || fail "help failed"
		if grep -Fq -- '--with-claude' "$OUT"; then fail "help still advertises retired selection"; fi
	done
}
check_refusal "$ROOT"
[ ! -e "${ROOT}/scripts/install-harness.claude.assets" ] || fail "retired selection manifest remains"

for profile in default developer; do
	target="${TMP_DIR}/${profile} with spaces"
	mkdir -p "${target}/.claude"
	printf '{"permissions":{"deny":["Read(secret/**)"]},"hooks":{"Stop":[]}}\n' >"${target}/.claude/settings.json"
	printf '{"env":{"ADOPTER_SETTING":"preserve"}}\n' >"${target}/.claude/settings.local.json"
	cp "${target}/.claude/settings.json" "${TMP_DIR}/settings.before"
	cp "${target}/.claude/settings.local.json" "${TMP_DIR}/local.before"
	args=("$target" --write)
	[ "$profile" != developer ] || args+=(--with-dev-sensors)
	"${ROOT}/scripts/install-harness.sh" "${args[@]}" >"$OUT" 2>&1 || fail "${profile} fresh install"
	for path in scripts/install-harness.claude.assets optional/runtime-adapters tests/scripts/test_claude_adapter.sh; do
		[ ! -e "${target}/${path}" ] || fail "${profile} shipped retired bundle ${path}"
	done
	if grep -Ei 'claude' "${target}/.harness-lock"; then fail "${profile} owns retired bundle"; fi
	if [ "$profile" = developer ]; then
		[ -x "${target}/tests/evals/bin/run-l0-suite.sh" ] || fail "developer runtime was lost"
	else
		[ ! -e "${target}/tests/evals/bin/run-l0-suite.sh" ] || fail "default leaked developer runtime"
	fi
	for mode in dry --update; do
		args=("$target")
		[ "$mode" = dry ] || args+=("$mode")
		[ "$profile" != developer ] || args+=(--with-dev-sensors)
		"${target}/scripts/install/install-harness.sh" "${args[@]}" >"$OUT" 2>&1 \
			|| fail "${profile} installed ${mode} is not self-contained"
	done
	check_refusal "$target"
	cmp -s "${TMP_DIR}/settings.before" "${target}/.claude/settings.json" || fail "project settings changed"
	cmp -s "${TMP_DIR}/local.before" "${target}/.claude/settings.local.json" || fail "local settings changed"
	fresh="${TMP_DIR}/fresh-${profile}"
	args=("$fresh" --write)
	[ "$profile" != developer ] || args+=(--with-dev-sensors)
	"${target}/scripts/install-harness.sh" "${args[@]}" >"$OUT" 2>&1 || fail "${profile} installed-source fresh install"
	[ ! -e "${fresh}/.claude" ] || fail "fresh install enabled Claude settings"
	[ ! -e "${fresh}/optional/runtime-adapters" ] || fail "installed source emitted retired bundle"
done
printf 'retired Claude selection is refused; default/developer sources remain self-contained\n'
