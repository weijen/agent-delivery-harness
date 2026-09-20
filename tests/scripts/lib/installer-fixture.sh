#!/usr/bin/env bash
# Narrow filesystem fixtures run the real installer with one synthetic asset.
# Full-profile dependency and self-hosting coverage belongs to installed smoke.

INSTALLER_FIXTURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

installer_fixture_source() {
	local destination="$1" script
	mkdir -p "${destination}/scripts/lib" "${destination}/tests" "${destination}/docs"
	for script in install-harness.sh lib/reconcile-lib.sh lib/github-identity-lib.sh; do
		cp "${INSTALLER_FIXTURE_ROOT}/scripts/${script}" "${destination}/scripts/${script}"
	done
	printf '#!/usr/bin/env bash\nprintf "fixture asset\\n"\n' >"${destination}/scripts/init.sh"
	chmod +x "${destination}/scripts/init.sh"
	printf 'scripts/init.sh\n' >"${destination}/scripts/install-harness.assets"
	: >"${destination}/scripts/install-harness.tombstones"
	: >"${destination}/tests/harness-dev-sensors.txt"
	printf 'layout_moves:\n' >"${destination}/docs/harness-contract.yml"
}
