#!/usr/bin/env bash
# Shared fresh-layout assertions and narrow, real-installer filesystem fixtures.
# Full-profile dependency and self-hosting coverage belongs to installed smoke.

INSTALLER_FIXTURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

installer_assert_fresh_layout() {
	local target="$1" profile="$2" manifest asset expected_source old canonical audience public layout_map output
	local manifests=("${INSTALLER_FIXTURE_ROOT}/scripts/install-harness.assets")
	case "$profile" in
		default) ;;
		developer) manifests+=("${INSTALLER_FIXTURE_ROOT}/scripts/install-harness.dev.assets") ;;
		*) fail "unknown fresh installation profile: ${profile}" ;;
	esac
	for manifest in "${manifests[@]}"; do
		while IFS= read -r asset; do
			case "$asset" in ""|\#*) continue ;; esac
			[ -f "${target}/${asset}" ] && [ ! -L "${target}/${asset}" ] \
				|| fail "fresh ${profile} missing regular dependency ${asset}"
			expected_source="${INSTALLER_FIXTURE_ROOT}/${asset}"
			if [ "$asset" = .github/workflows/harness-smoke.yml ]; then
				expected_source="${INSTALLER_FIXTURE_ROOT}/profiles/adopter-smoke.yml"
			fi
			cmp -s "$expected_source" "${target}/${asset}" \
				|| fail "fresh ${profile} changed dependency ${asset}"
		done <"$manifest"
	done
	layout_map="$(awk '
		function emit() {
			if (old != "") print old "\t" canonical "\t" (audience == "" ? "installed" : audience) "\t" public
			old=canonical=public=audience=""
		}
		/^layout_moves:/ { selected=1; next }
		selected && /^[^ #]/ { exit }
		selected && /^  - from:/ { emit(); old=$3 }
		selected && /^    to:/ { canonical=$2 }
		selected && /^    public_entrypoint:/ { public=$2 }
		selected && /^    audience:/ { audience=$2 }
		END { emit() }
	' "${INSTALLER_FIXTURE_ROOT}/docs/harness-contract.yml")"
	[ -n "$layout_map" ] || fail "canonical path map is empty"
	while IFS=$'\t' read -r old canonical audience public; do
		if [ "$audience" = source-only ] || grep -Fxq "$canonical" "${INSTALLER_FIXTURE_ROOT}/tests/harness-dev-sensors.txt"; then
			[ ! -e "${target}/${canonical}" ] || fail "fresh ${profile} installed source-only ${canonical}"
		fi
		if [ -z "$public" ]; then
			[ ! -e "${target}/${old}" ] || fail "fresh ${profile} restored flat ${old}"
		fi
	done <<<"$layout_map"
	[ ! -e "${target}/optional/runtime-adapters" ] || fail "fresh ${profile} restored Claude payload"
	output="${target}/fresh-layout.out"
	mkdir -p "${target}/unrelated cwd"
	(cd "${target}/unrelated cwd" && "${target}/scripts/install-harness.sh" --help) >"$output" 2>&1 \
		|| { cat "$output" >&2; fail "fresh ${profile} installer failed from unrelated cwd"; }
	(cd "${target}/unrelated cwd" && "${target}/scripts/scaffold-language.sh" go --write) >"$output" 2>&1 \
		|| { cat "$output" >&2; fail "fresh ${profile} scaffolder failed from unrelated cwd"; }
	[ -f "${target}/profiles/go.profile.sh" ] && [ ! -e "${target}/unrelated cwd/profiles" ] \
		|| fail "fresh ${profile} scaffolder lost installed root"
	mv "${target}/scripts/lib/reconcile-lib.sh" "${target}/reconcile.saved"
	if (cd "${target}/unrelated cwd" && "${target}/scripts/install-harness.sh" --help) >"$output" 2>&1; then
		fail "fresh ${profile} hid a missing installed dependency with source fallback"
	fi
	grep -Fq 'reconcile-lib.sh' "$output" || fail "fresh ${profile} missing-dependency diagnostic lost"
	mv "${target}/reconcile.saved" "${target}/scripts/lib/reconcile-lib.sh"
	rm "${target}/profiles/go.profile.sh" "${target}/.copilot/instructions/go.instructions.md" "$output"
}

installer_fixture_source() {
	local destination="$1" script
	mkdir -p "${destination}/scripts/lib" "${destination}/scripts/install" "${destination}/tests" "${destination}/docs"
	for script in install-harness.sh install/install-harness.sh lib/reconcile-lib.sh lib/github-identity-lib.sh; do
		cp "${INSTALLER_FIXTURE_ROOT}/scripts/${script}" "${destination}/scripts/${script}"
	done
	printf '#!/usr/bin/env bash\nprintf "fixture asset\\n"\n' >"${destination}/scripts/init.sh"
	chmod +x "${destination}/scripts/init.sh"
	printf 'scripts/init.sh\n' >"${destination}/scripts/install-harness.assets"
	: >"${destination}/scripts/install-harness.tombstones"
	: >"${destination}/tests/harness-dev-sensors.txt"
	printf 'layout_moves:\n' >"${destination}/docs/harness-contract.yml"
}
