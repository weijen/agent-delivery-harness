#!/usr/bin/env bash
# Historical bundle retirement requires installed ownership, not matching bytes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/scripts/lib/installer-fixture.sh
source "${ROOT}/tests/scripts/lib/installer-fixture.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
SOURCE="${TMP_DIR}/source"
installer_fixture_source "$SOURCE"
OUT="${TMP_DIR}/out"
fail() { cat "$OUT" >&2; printf 'retirement: %s\n' "$*" >&2; exit 1; }

legacy=(
	scripts/install-harness.claude.assets
	optional/runtime-adapters/claude-code-trace-hook.sh
	optional/runtime-adapters/tests/test_claude_hook_noop.sh
	tests/scripts/test_claude_adapter.sh
	scripts/claude-code-trace-hook.sh
	tests/scripts/test_claude_hook_noop.sh
)
printf 'retired payload\n' >"${TMP_DIR}/payload"
digest="$(shasum -a 256 "${TMP_DIR}/payload" | awk '{print $1}')"
for path in "${legacy[@]}" scripts/retired-common.sh; do
	printf '%s\t%s\n' "$digest" "$path" >>"${SOURCE}/scripts/install-harness.tombstones"
done

for mode in owned unknown modified protected; do
	target="${TMP_DIR}/${mode}"
	mkdir -p "${target}/.claude"
	printf '{"hooks":{"user":"untouched"}}\n' >"${target}/.claude/settings.json"
	: >"${target}/.harness-lock"
	for path in "${legacy[@]}" scripts/retired-common.sh; do
		mkdir -p "${target}/$(dirname "$path")"
		cp "${TMP_DIR}/payload" "${target}/${path}"
	done
	for path in "${legacy[@]}"; do
		if [ "$mode" != unknown ]; then
			printf '%s\t%s\n' "$digest" "$path" >>"${target}/.harness-lock"
		fi
		[ "$mode" != modified ] || printf 'adopter customization\n' >>"${target}/${path}"
		[ "$mode" != protected ] || printf '%s\n' "$path" >>"${target}/.harness-keep"
	done
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/before"
	"${SOURCE}/scripts/install-harness.sh" "$target" >"$OUT" 2>&1 || fail "${mode} dry run"
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/after"
	cmp -s "${TMP_DIR}/before" "${TMP_DIR}/after" || fail "${mode} dry run mutated state"

	rc=0
	"${SOURCE}/scripts/install-harness.sh" "$target" --update >"$OUT" 2>&1 || rc=$?
	case "$mode" in
		unknown|modified)
			[ "$rc" -ne 0 ] || fail "${mode} retirement must report conflicts"
			if [ "$mode" = unknown ]; then
				grep -q 'ownership unknown' "$OUT" || fail "unknown ownership was not explained"
			fi ;;
		*) [ "$rc" -eq 0 ] || fail "${mode} retirement failed" ;;
	esac
	for path in "${legacy[@]}"; do
		if [ "$mode" = owned ]; then
			[ ! -e "${target}/${path}" ] || fail "owned unchanged asset was not pruned: ${path}"
		else
			[ -f "${target}/${path}" ] || fail "${mode} asset was removed: ${path}"
			grep -q 'retired payload' "${target}/${path}" || fail "${mode} asset was overwritten"
			case "$mode" in
				unknown|modified)
					[ -f "${target}/${path}.rej" ] || fail "${mode} omitted rejection: ${path}"
					grep -q 'retired payload' "${target}/${path}.rej" || fail "rejection is not actionable" ;;
			esac
			if [ "$mode" = modified ]; then
				grep -q 'adopter customization' "${target}/${path}" || fail "customization lost"
			fi
		fi
	done
	[ ! -e "${target}/scripts/retired-common.sh" ] || fail "unrelated historical retirement policy changed"
	grep -Fxq '{"hooks":{"user":"untouched"}}' "${target}/.claude/settings.json" \
		|| fail "adopter hook settings changed"
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/before"
	"${SOURCE}/scripts/install-harness.sh" "$target" --update >"$OUT" 2>&1 || fail "${mode} repeat update"
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/after"
	cmp -s "${TMP_DIR}/before" "${TMP_DIR}/after" || fail "${mode} repeat update changed content or ownership"
done
printf 'legacy bundle retirement preserves unknown, modified and protected assets\n'
