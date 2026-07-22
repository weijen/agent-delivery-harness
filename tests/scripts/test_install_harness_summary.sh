#!/usr/bin/env bash
# Regression and e2e sensor (#314): update classification is summary-first and
# the documented round-trip preserves adopter work.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

SOURCE="${TMP_DIR}/source"
TARGET="${TMP_DIR}/target"
OUT="${TMP_DIR}/update.out"

"$INSTALL" "$SOURCE" --write >/dev/null 2>&1
"${SOURCE}/scripts/install-harness.sh" "$TARGET" --write >/dev/null 2>&1

printf '\n# upstream init v2\n' >>"${SOURCE}/scripts/init.sh"
printf '\n# adopter issue-lib\n' >>"${TARGET}/scripts/issue-lib.sh"
printf '\n# adopter create-pr\n' >>"${TARGET}/scripts/create-pr.sh"
printf '\n# upstream create-pr v2\n' >>"${SOURCE}/scripts/create-pr.sh"

if "${SOURCE}/scripts/install-harness.sh" "$TARGET" --update >"$OUT" 2>&1; then
	fail "round-trip conflict must exit nonzero"
fi

grep -Eq '^  safe:[[:space:]]+1$' "$OUT" \
	|| { cat "$OUT" >&2; fail "summary did not count one safe update"; }
grep -Eq '^  kept:[[:space:]]+1$' "$OUT" \
	|| { cat "$OUT" >&2; fail "summary did not count one kept adopter file"; }
grep -Eq '^  conflicts:[[:space:]]+1$' "$OUT" \
	|| { cat "$OUT" >&2; fail "summary did not count one conflict"; }

summary_line="$(grep -n -m1 '^Update classification:' "$OUT" | cut -d: -f1)"
detail_line="$(grep -n -m1 -E '^  (updating|kept|conflict) ' "$OUT" | cut -d: -f1)"
if [ -z "$summary_line" ] || [ -z "$detail_line" ] \
	|| [ "$summary_line" -ge "$detail_line" ]; then
	fail "classification summary must precede every per-file update detail"
fi

grep -Fq '.harness-keep' "${ROOT}/docs/getting-started.md" \
	|| fail "getting-started does not document protected paths"
grep -Fq '.harness-lock' "${ROOT}/docs/getting-started.md" \
	|| fail "getting-started does not document installed base state"
grep -Fq '.rej' "${ROOT}/docs/getting-started.md" \
	|| fail "getting-started does not document conflict recovery"

printf 'install-harness summary-first upgrade contract honored\n'
