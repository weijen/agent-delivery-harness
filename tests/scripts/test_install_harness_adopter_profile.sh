#!/usr/bin/env bash
# Regression and e2e sensor (issue #312): adopter installs omit harness-dev
# sensors by default, prune clean legacy copies, and expose an explicit opt-in.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$TMP_DIR"; rm -f "$OUT"' EXIT

"$INSTALL" --help >"$OUT"
grep -qF -- "--with-dev-sensors" "$OUT" || {
	cat "$OUT"
	echo "installer help does not expose the dev-sensor opt-in"
	exit 1
}

default_target="${TMP_DIR}/default"
"$INSTALL" "$default_target" --write >"$OUT" 2>&1
[ -f "${default_target}/tests/harness-dev-sensors.txt" ] || {
	echo "default install did not ship the sensor profile manifest"
	exit 1
}
[ -f "${default_target}/tests/scripts/test_harness_contract.sh" ] || {
	echo "default install omitted a core lifecycle sensor"
	exit 1
}
[ ! -e "${default_target}/tests/scripts/test_release_workflow.sh" ] || {
	echo "default install shipped a harness-dev release sensor"
	exit 1
}
if find "${default_target}/tests/meta" -type f -name 'test_*.sh' 2>/dev/null | grep -q .; then
	echo "default install shipped harness-dev meta sensors"
	exit 1
fi
if ! "${default_target}/scripts/install-harness.sh" "$default_target" >"$OUT" 2>&1; then
	cat "$OUT"
	echo "installed adopter-profile installer is not self-contained"
	exit 1
fi

upgrade_target="${TMP_DIR}/upgrade"
"$INSTALL" "$upgrade_target" --write --with-dev-sensors >"$OUT" 2>&1
[ -f "${upgrade_target}/tests/scripts/test_release_workflow.sh" ] || {
	echo "dev-sensor opt-in omitted an explicit harness-dev sensor"
	exit 1
}
[ -f "${upgrade_target}/tests/meta/test_agent_model_pins.sh" ] || {
	echo "dev-sensor opt-in omitted meta sensors"
	exit 1
}
printf '\n# adopter customization\n' >>"${upgrade_target}/tests/scripts/test_commit_convention_doc.sh"
if "$INSTALL" "$upgrade_target" --write >"$OUT" 2>&1; then
	cat "$OUT"
	echo "default upgrade must report a modified excluded sensor"
	exit 1
fi
[ ! -e "${upgrade_target}/tests/scripts/test_release_workflow.sh" ] || {
	echo "default upgrade left an unmodified harness-dev sensor"
	exit 1
}
grep -qF "adopter customization" "${upgrade_target}/tests/scripts/test_commit_convention_doc.sh" || {
	echo "default upgrade removed a modified harness-dev sensor"
	exit 1
}
grep -qF "preserving modified harness-dev sensor tests/scripts/test_commit_convention_doc.sh" "$OUT" || {
	cat "$OUT"
	echo "default upgrade did not report the preserved modified sensor"
	exit 1
}

printf 'install-harness adopter profile sensor passed\n'
