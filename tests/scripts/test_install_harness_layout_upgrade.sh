#!/usr/bin/env bash
# harness-sensor-trigger: upgrade
# harness-sensor-depends: scripts/install-harness* scripts/lib/reconcile-lib.sh scripts/lib/github-identity-lib.sh scripts/lib/trace-lib.sh scripts/lib/issue-lib.sh scripts/run-sensors.sh scripts/validation/run-sensors.sh scripts/validation/affected-sensors.sh profiles/adopter-smoke.yml tests/harness-dev-sensors.txt docs/harness-contract.yml optional/runtime-adapters/* VERSION
# Genuine v0.45.2 installed-layout acceptance, separated from profile selection.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'layout-upgrade disposition: %s\n' "$*" >&2; exit 1; }
upgrades=(
	tests/scripts/test_install_harness_layout_upgrade.sh
	tests/scripts/test_install_harness_version_skew.sh
)
resolver="$ROOT/scripts/validation/affected-sensors.sh"
"$resolver" --gate pre-pr unrelated-product.txt >"$TMP_DIR/selected"
for sensor in "${upgrades[@]}"; do
	if grep -Fxq "$sensor" "$TMP_DIR/selected"; then fail "unrelated change selected $sensor"; fi
done
for path in scripts/install-harness.sh scripts/install-harness.assets scripts/install-harness.dev-assets \
	scripts/install-harness.tombstones scripts/lib/reconcile-lib.sh scripts/lib/trace-lib.sh \
	docs/harness-contract.yml profiles/adopter-smoke.yml; do
	"$resolver" --gate pre-pr "$path" >"$TMP_DIR/selected"
	for sensor in "${upgrades[@]}"; do
		grep -Fxq "$sensor" "$TMP_DIR/selected" || fail "$path omitted $sensor"
	done
done
"$resolver" --gate release >"$TMP_DIR/selected"
for sensor in "${upgrades[@]}"; do
	grep -Fxq "$sensor" "$TMP_DIR/selected" || fail "release omitted $sensor"
done
if grep -q 'archive v0.45.2' "$ROOT/tests/scripts/test_install_harness_adopter_profile.sh"; then
	fail "routine profile sensor still replays the historical matrix"
fi

layout_log="${TMP_DIR}/layout-upgrade.log"
fail_layout() {
	[ ! -f "$layout_log" ] || cat "$layout_log" >&2
	printf 'FAIL: layout upgrade: %s\n' "$*" >&2
	exit 1
}
install_layout() {
	layout_install_calls=$((layout_install_calls + 1))
	"$@" >"$layout_log" 2>&1
}
legacy_source="${TMP_DIR}/previous-layout"
mkdir -p "$legacy_source"
# The pre-layout release is an explicit reusable-asset fixture, not a checkout
# archive: project-owned environment files and local bindings are not inputs.
git -C "$ROOT" archive v0.45.2 scripts profiles tests .copilot docs schemas optional VERSION \
	.github/harness-identity.env.example | tar -x -C "$legacy_source"
awk '
	/^layout_moves:/ { selected=1; next }
	selected && /^[^ #]/ { exit }
	selected && /^  - from:/ { old=$3 }
	selected && /^    to:/ { print old "\t" $2 }
' "${ROOT}/docs/harness-contract.yml" >"${TMP_DIR}/layout-moves"
[ -s "${TMP_DIR}/layout-moves" ] || fail_layout "canonical path map is empty"

for profile in default developer claude; do
	layout_install_calls=0
	options=()
	case "$profile" in
		developer) options=(--with-dev-sensors) ;;
		claude) options=(--with-claude) ;;
	esac
	target="${TMP_DIR}/layout-${profile}"
	install_layout "${legacy_source}/scripts/install-harness.sh" "$target" --write "${options[@]}" \
		|| fail_layout "${profile} baseline installation"
	[ -f "${target}/scripts/trace-lib.sh" ] && \
		[ ! -e "${target}/scripts/lib/trace-lib.sh" ] \
		|| fail_layout "${profile} fixture is not the actual previous layout"
	if [ "$profile" = default ]; then
		printf '\n# adopter trace customization\n' >>"${target}/scripts/trace-lib.sh"
		printf '\n# protected identity customization\n' >>"${target}/scripts/github-identity-lib.sh"
		printf 'scripts/github-identity-lib.sh\n' >"${target}/.harness-keep"
		awk -F '\t' '$2 != "scripts/issue-lib.sh"' "${target}/.harness-lock" >"${TMP_DIR}/lock"
		mv "${TMP_DIR}/lock" "${target}/.harness-lock"
	fi
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/before-dry"
	install_layout "$INSTALL" "$target" "${options[@]}" \
		|| fail_layout "${profile} dry-run"
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/after-dry"
	cmp -s "${TMP_DIR}/before-dry" "${TMP_DIR}/after-dry" \
		|| fail_layout "${profile} dry-run changed files or ownership"

	status=0
	install_layout "$INSTALL" "$target" --update "${options[@]}" || status=$?
	if [ "$profile" = default ]; then
		[ "$status" -ne 0 ] || fail_layout "modified/unknown old paths must conflict"
		for old in scripts/trace-lib.sh scripts/issue-lib.sh; do
			grep -Fq "conflict ${old}" "$layout_log" \
				|| fail_layout "missing actionable conflict for ${old}"
			[ -f "${target}/${old}" ] && [ -f "${target}/${old}.rej" ] \
				|| fail_layout "conflicting old copy or rejection lost: ${old}"
		done
		grep -Fq 'ownership unknown' "$layout_log" || fail_layout "unknown ownership was not explained"
		grep -Fq 'adopter trace customization' "${target}/scripts/trace-lib.sh" \
			|| fail_layout "customized old library overwritten"
		grep -Fq 'protected identity customization' "${target}/scripts/github-identity-lib.sh" \
			|| fail_layout "protected old library overwritten"
		grep -Fq 'kept scripts/github-identity-lib.sh (.harness-keep)' "$layout_log" \
			|| fail_layout "protected old path was not acknowledged"
	else
		[ "$status" -eq 0 ] || fail_layout "${profile} clean upgrade failed"
	fi
	while IFS=$'\t' read -r old canonical; do
		[ -f "${target}/${canonical}" ] || fail_layout "${profile} missing canonical ${canonical}"
		[ "$old" != scripts/run-sensors.sh ] || continue
		if [ "$profile" = default ]; then
			case "$old" in scripts/trace-lib.sh|scripts/issue-lib.sh|scripts/github-identity-lib.sh) continue ;; esac
		fi
		[ ! -e "${target}/${old}" ] || fail_layout "${profile} left an owned clean old copy: ${old}"
	done <"${TMP_DIR}/layout-moves"
	if [ "$profile" = default ]; then
		# Conflicts must first transition to an acknowledged, successful update.
		install_layout "$INSTALL" "$target" --update "${options[@]}" \
			|| fail_layout "${profile} repeat update"
	fi
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/before-repeat"
	install_layout "$INSTALL" "$target" --update "${options[@]}" \
		|| fail_layout "${profile} idempotent update"
	find "$target" -type f -exec shasum -a 256 {} + | sort >"${TMP_DIR}/after-repeat"
	cmp -s "${TMP_DIR}/before-repeat" "${TMP_DIR}/after-repeat" \
		|| fail_layout "${profile} repeated update changed installed content"
	expected_calls=4
	[ "$profile" != default ] || expected_calls=5
	[ "$layout_install_calls" -eq "$expected_calls" ] \
		|| fail_layout "${profile} performed ${layout_install_calls} installer calls; expected ${expected_calls}"

	mkdir -p "${target}/unrelated/nested"
	git -C "$target" init -q -b main
	git -C "$target" config user.name "Harness Test"
	git -C "$target" config user.email "harness-test@example.invalid"
	git -C "$target" config commit.gpgsign false
	# Runtime evidence is local state, not a source change for the installed probe.
	printf '/.copilot-tracking/\n' >>"${target}/.git/info/exclude"
	printf '9.8.7-layout\n' >"${target}/VERSION"
	printf '#!/usr/bin/env bash\nexit 0\n' >"${target}/tests/scripts/validation/test_installed_probe.sh"
	git -C "$target" add .
	git -C "$target" commit -qm 'test: upgraded installed layout'
	for runner in scripts/run-sensors.sh scripts/validation/run-sensors.sh; do
		(cd "${target}/unrelated/nested" && "${target}/${runner}" green \
			--declared tests/scripts/validation/test_installed_probe.sh --diff HEAD) \
			>"$layout_log" 2>&1 || fail_layout "${profile} installed ${runner}"
		grep -q 'scope=scoped ran=1 failed=0$' "$layout_log" \
			|| fail_layout "${profile} runner did not use installed sensor selection"
	done
	(
		cd "${target}/unrelated/nested"
		# shellcheck source=/dev/null
		source "${target}/scripts/lib/trace-lib.sh"
		TRACE_ISSUE=91 trace_span tool "gen_ai.tool.name=installed-layout"
	)
	jq -se 'length == 1 and .[0]["harness.version"] == "9.8.7-layout"' \
		"${target}/.copilot-tracking/issues/issue-91/trace.jsonl" >/dev/null \
		|| fail_layout "${profile} emitter used source identity instead of installed VERSION"
	printf '#!/usr/bin/env bash\nexit 1\n' >"${target}/tests/scripts/validation/test_installed_probe.sh"
	if (cd "${target}/unrelated/nested" && "${target}/scripts/run-sensors.sh" green \
		--declared tests/scripts/validation/test_installed_probe.sh --diff HEAD) >"$layout_log" 2>&1; then
		fail_layout "${profile} ignored the installed nested failure"
	fi
	grep -q '^FAIL tests/scripts/validation/test_installed_probe.sh$' "$layout_log" \
		|| fail_layout "${profile} failure did not name the installed sensor"
	grep -q 'scope=scoped ran=1 failed=1$' "$layout_log" \
		|| fail_layout "${profile} targeted failure selected unrelated sensors"
done
# A modified installed contract must not turn migration candidates into paths
# outside the target, even before ownership checks run.
sed 's|from: scripts/affected-sensors.sh|from: scripts/../../outside|' \
	"${target}/docs/harness-contract.yml" >"${TMP_DIR}/unsafe-contract"
mv "${TMP_DIR}/unsafe-contract" "${target}/docs/harness-contract.yml"
printf 'outside sentinel\n' >"${TMP_DIR}/outside"
if "${target}/scripts/install-harness.sh" "${TMP_DIR}/unsafe-map-target" --write \
	>"$layout_log" 2>&1; then
	fail_layout "unsafe migration path accepted"
fi
grep -Fq 'unsafe excluded asset path' "$layout_log" \
	|| fail_layout "unsafe migration path did not explain the refusal"
[ "$(cat "${TMP_DIR}/outside")" = 'outside sentinel' ] && \
	[ ! -e "${TMP_DIR}/unsafe-map-target/VERSION" ] \
	|| fail_layout "unsafe migration map wrote files before refusal"
printf 'previous-layout upgrades preserve ownership and execute installed categories\n'
