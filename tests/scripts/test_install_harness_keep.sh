#!/usr/bin/env bash
# Regression sensor (#314): .harness-keep globs are adopter-owned and never
# created, overwritten, or pruned by any installer mode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

TARGET="${TMP_DIR}/target"
OUT="${TMP_DIR}/update.out"
SENTINEL="${TMP_DIR}/must-not-exist"
mkdir -p "${TARGET}/scripts" "${TARGET}/docs"
cat >"${TARGET}/.harness-keep" <<EOF
# Adopter-owned harness surfaces
scripts/init.sh
docs/*.md
scripts/.gitkeep
\$(touch ${SENTINEL})
EOF
printf 'adopter init\n' >"${TARGET}/scripts/init.sh"
printf 'adopter lifecycle\n' >"${TARGET}/docs/HARNESS.md"
printf 'adopter retired sentinel\n' >"${TARGET}/scripts/.gitkeep"

"$INSTALL" "$TARGET" --update >"$OUT" 2>&1 \
	|| {
		cat "$OUT" >&2
		fail "protected paths must not make --update fail"
	}

[ "$(cat "${TARGET}/scripts/init.sh")" = "adopter init" ] \
	|| fail "exact protected file was overwritten"
[ "$(cat "${TARGET}/docs/HARNESS.md")" = "adopter lifecycle" ] \
	|| fail "glob-protected file was overwritten"
[ "$(cat "${TARGET}/scripts/.gitkeep")" = "adopter retired sentinel" ] \
	|| fail "protected retired file was pruned"
[ ! -e "${TARGET}/docs/getting-started.md" ] \
	|| fail "installer created a missing path covered by .harness-keep"
[ ! -e "$SENTINEL" ] || fail ".harness-keep content was executed as shell"

grep -Fq 'kept scripts/init.sh (.harness-keep)' "$OUT" \
	|| fail "exact protected path was not reported"
grep -Fq 'kept docs/HARNESS.md (.harness-keep)' "$OUT" \
	|| fail "glob-protected path was not reported"
grep -Fq 'kept scripts/.gitkeep (.harness-keep)' "$OUT" \
	|| fail "protected retired path was not reported"

printf '.harness-keep protection contract honored\n'
