#!/usr/bin/env bash
# harness-sensor-depends: scripts/lifecycle/* scripts/install/* scripts/install-harness.assets scripts/install-harness.dev.assets scripts/install-harness.tombstones docs/harness-contract.yml tests/harness-dev-sensors.txt scripts/validation/affected-sensors.sh
# Completed lifecycle/install identities and public dispatch must agree.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'lifecycle-install-layout: %s\n' "$*" >&2; exit 1; }
cd "$ROOT"
awk '
	function emit() {
		if (to ~ /^(scripts|tests\/scripts)\/(lifecycle|install)\//)
			print old "\t" to "\t" public
		old=to=public=""
	}
	/^layout_moves:/ { active=1; next }
	active && /^[^ #]/ { exit }
	active && /^  - from:/ { emit(); old=$3 }
	active && /^    to:/ { to=$2 }
	active && /^    public_entrypoint:/ { public=$2 }
	END { emit() }
' docs/harness-contract.yml >"${TMP_DIR}/moves"
[ -s "${TMP_DIR}/moves" ] || fail "category migration map missing"
for column in 1 2; do
	[ -z "$(cut -f "$column" "${TMP_DIR}/moves" | LC_ALL=C sort | uniq -d)" ] \
		|| fail "duplicate migration identity in column ${column}"
done
./scripts/validation/affected-sensors.sh --list >"${TMP_DIR}/discovered"
# These pre-migration identities are independent of the map being validated.
migrated_sensors=(
	lifecycle/test_create_pr_failure.sh
	lifecycle/test_create_pr_sensor_gate.sh
	lifecycle/test_finish_issue_conclusion.sh
	lifecycle/test_harness_contract.sh
	lifecycle/test_init_gates.sh
	lifecycle/test_issue_scaffold.sh
	lifecycle/test_lifecycle_order.sh
	lifecycle/test_merge_pr_ci_gate.sh
	lifecycle/test_post_pr_guardrails.sh
	lifecycle/test_prepare_pr.sh
	install/test_install_harness.sh
	install/test_install_harness_adopter_profile.sh
	install/test_install_harness_atomic_write.sh
	install/test_install_harness_claude.sh
	install/test_install_harness_dangling_destination.sh
	install/test_install_harness_dev_profile.sh
	install/test_install_harness_layout_upgrade.sh
	install/test_install_harness_symlinked_parent.sh
	install/test_install_harness_three_way.sh
	install/test_install_harness_version_skew.sh
	install/test_scaffold_language.sh
)
for identity in "${migrated_sensors[@]}"; do
	canonical="tests/scripts/${identity}"
	old="tests/scripts/${identity#*/}"
	awk -F '\t' -v from="$old" -v to="$canonical" \
		'$1==from && $2==to && $3=="" { found=1 } END { exit !found }' "${TMP_DIR}/moves" \
		|| fail "missing migrated sensor mapping ${old}"
	[ ! -e "$old" ] || fail "retired flat sensor restored ${old}"
done
while IFS=$'\t' read -r old canonical public; do
	[ -f "$canonical" ] || fail "missing mapped implementation ${canonical}"
	if [ -z "$public" ]; then
		[ ! -e "$old" ] || fail "duplicate flat implementation ${old}"
		if grep -Fxq "$old" scripts/install-harness.assets scripts/install-harness.dev.assets; then
			fail "retired identity still selected ${old}"
		fi
		awk -F '\t' -v path="$old" '$2==path { found=1 } END { exit !found }' scripts/install-harness.tombstones \
			|| fail "retired identity lacks migration history ${old}"
	else
		[ "$public" = "$old" ] || fail "public identity mismatch ${old}"
	fi
done <"${TMP_DIR}/moves"
for canonical in scripts/lifecycle/*.sh scripts/install/*.sh; do
	[ "$(cut -f2 "${TMP_DIR}/moves" | grep -Fxc "$canonical")" -eq 1 ] \
		|| fail "command missing exact map ${canonical}"
	[ "$(grep -Fxc "$canonical" scripts/install-harness.assets)" -eq 1 ] \
		|| fail "command missing exact payload ${canonical}"
	public="scripts/$(basename "$canonical")"
	awk -F '\t' -v from="$public" -v to="$canonical" \
		'$1==from && $2==to && $3==from { found=1 } END { exit !found }' "${TMP_DIR}/moves" \
		|| fail "stable public command missing ${public}"
	[ "$(grep -Fxc "$public" scripts/install-harness.assets)" -eq 1 ] || fail "public command not selected"
	mkdir -p "${TMP_DIR}/dispatch/$(dirname "$canonical")" "${TMP_DIR}/dispatch/nested/cwd"
	cp "$public" "${TMP_DIR}/dispatch/${public}"
	cat >"${TMP_DIR}/dispatch/${canonical}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD" "$@"
exit 37
SH
	chmod +x "${TMP_DIR}/dispatch/${canonical}"
	rc=0
	(cd "${TMP_DIR}/dispatch/nested/cwd" && "../../${public}" 'argument with spaces' --probe) \
		>"${TMP_DIR}/dispatch.out" 2>&1 || rc=$?
	[ "$rc" -eq 37 ] || fail "public command lost nested exit status ${public}"
	printf '%s\n' "$(cd "${TMP_DIR}/dispatch/nested/cwd" && pwd)" 'argument with spaces' --probe \
		>"${TMP_DIR}/expected"
	cmp -s "${TMP_DIR}/expected" "${TMP_DIR}/dispatch.out" || fail "public command changed cwd/arguments ${public}"
done
for sensor in tests/scripts/lifecycle/test_*.sh tests/scripts/install/test_*.sh; do
	[ "$(grep -Fxc "$sensor" "${TMP_DIR}/discovered")" -eq 1 ] || fail "sensor not discovered exactly once ${sensor}"
	[ "$(awk -v path="$sensor" '$0==path { count++ } END { print count+0 }' \
		scripts/install-harness.assets tests/harness-dev-sensors.txt)" -eq 1 ] \
		|| fail "sensor audience missing or duplicated ${sensor}"
done
if grep -E '/(lib|helpers|fixtures)/' "${TMP_DIR}/discovered"; then fail "helper discovered as runnable sensor"; fi
printf 'lifecycle/install maps, payload identities, discovery and public dispatch agree\n'
