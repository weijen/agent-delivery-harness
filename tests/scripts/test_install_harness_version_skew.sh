#!/usr/bin/env bash
# End-to-end upgrade rehearsal (#432): a v0.36.0 install with the five
# issue-49-shaped local divergences reconciles safely against current HEAD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
SOURCE="${TMP_DIR}/v0.36.0"
TARGET="${TMP_DIR}/adopter"
FIRST_OUT="${TMP_DIR}/first-update.out"
REPEAT_OUT="${TMP_DIR}/repeat-update.out"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

git -C "$ROOT" rev-parse --verify 'refs/tags/v0.36.0^{commit}' >/dev/null 2>&1 \
	|| fail "v0.36.0 tag is unavailable; the rehearsal requires full repository history"
mkdir -p "$SOURCE"
git -C "$ROOT" archive v0.36.0 | tar -x -C "$SOURCE"
"${SOURCE}/scripts/install-harness.sh" "$TARGET" --write --with-dev-sensors \
	>"${TMP_DIR}/install.out" 2>&1 \
	|| {
		cat "${TMP_DIR}/install.out" >&2
		fail "could not create the v0.36.0 adopter baseline"
	}
[ "$(cat "${TARGET}/VERSION")" = "0.36.0" ] \
	|| fail "fixture baseline is not v0.36.0"

diverged_paths=(
	tests/scripts/test_install_harness_three_way.sh
	scripts/check-install-harness-tombstones.sh
	tests/scripts/test_install_harness_tombstone_history.sh
	tests/scripts/test_install_harness_tombstone_exclusion.sh
	tests/scripts/test_tombstone_workflow_history.sh
)

for path in "${diverged_paths[@]}"; do
	mkdir -p "${TARGET}/$(dirname "$path")"
	printf '#!/usr/bin/env bash\n# adopter issue-49 local divergence\n' \
		>"${TARGET}/${path}"
	chmod +x "${TARGET}/${path}"
done

if "$INSTALL" "$TARGET" --update --with-dev-sensors >"$FIRST_OUT" 2>&1; then
	cat "$FIRST_OUT" >&2
	fail "five both-changed paths must make the first update exit nonzero"
fi
grep -Eq '^  conflicts:[[:space:]]+5$' "$FIRST_OUT" \
	|| {
		cat "$FIRST_OUT" >&2
		fail "first update did not report exactly five conflicts"
	}
[ "$(cat "${TARGET}/VERSION")" = "$(cat "${ROOT}/VERSION")" ] \
	|| fail "upstream-only VERSION did not advance to current"

for path in "${diverged_paths[@]}"; do
	grep -Fq "conflict ${path}" "$FIRST_OUT" \
		|| fail "first update did not report conflict for ${path}"
	grep -Fq '# adopter issue-49 local divergence' "${TARGET}/${path}" \
		|| fail "first update overwrote adopter file ${path}"
	[ -f "${TARGET}/${path}.rej" ] \
		|| fail "first update did not write ${path}.rej"
	case "$path" in
		tests/scripts/test_install_harness_three_way.sh)
			rejected_marker="Regression and e2e sensor"
			;;
		scripts/check-install-harness-tombstones.sh)
			rejected_marker="shallow checkout"
			;;
		tests/scripts/test_install_harness_tombstone_history.sh)
			rejected_marker="tombstone history contract honored"
			;;
		tests/scripts/test_install_harness_tombstone_exclusion.sh)
			rejected_marker="tombstone exclusion policy honored"
			;;
		tests/scripts/test_tombstone_workflow_history.sh)
			rejected_marker="workflow full-history contract honored"
			;;
		*) fail "missing rejection marker for ${path}" ;;
	esac
	grep -Fq "$rejected_marker" "${TARGET}/${path}.rej" \
		|| fail "${path}.rej does not contain the rejected current change"
done

"$INSTALL" "$TARGET" --update --with-dev-sensors >"$REPEAT_OUT" 2>&1 \
	|| {
		cat "$REPEAT_OUT" >&2
		fail "repeat update should classify captured conflicts as adopter-only"
	}
grep -Eq '^  conflicts:[[:space:]]+0$' "$REPEAT_OUT" \
	|| {
		cat "$REPEAT_OUT" >&2
		fail "repeat update retained unresolved conflicts"
	}

for path in "${diverged_paths[@]}"; do
	grep -Fq "kept ${path} (adopter changed)" "$REPEAT_OUT" \
		|| fail "repeat update did not keep adopter-only ${path}"
	grep -Fq '# adopter issue-49 local divergence' "${TARGET}/${path}" \
		|| fail "repeat update overwrote adopter file ${path} despite logging it as kept"
	printf 'reconcile %s: conflict -> adopter preserved + .rej; repeat -> kept adopter-only\n' "$path"
done

printf 'install-harness version skew rehearsal passed: v0.36.0 -> %s\n' \
	"$(cat "${ROOT}/VERSION")"
