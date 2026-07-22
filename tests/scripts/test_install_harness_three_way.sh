#!/usr/bin/env bash
# Regression and e2e sensor (#314): lock-backed updates distinguish upstream
# changes from adopter changes and preserve both-changed files with .rej output.
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

# Build a self-contained v1 harness source using the public installer surface.
"$INSTALL" "$SOURCE" --write >"${TMP_DIR}/bootstrap.out" 2>&1 \
	|| {
		cat "${TMP_DIR}/bootstrap.out" >&2
		fail "could not build temporary v1 harness source"
	}
"${SOURCE}/scripts/install-harness.sh" "$TARGET" --write >"${TMP_DIR}/install.out" 2>&1 \
	|| {
		cat "${TMP_DIR}/install.out" >&2
		fail "initial v1 install failed"
	}

[ -f "${TARGET}/.harness-lock" ] \
	|| fail "initial install did not persist .harness-lock"
grep -Fq $'\tscripts/init.sh' "${TARGET}/.harness-lock" \
	|| fail "lock does not record installed upstream hashes"

# Upstream-only: target stays at v1 while source moves to v2.
printf '\n# upstream init v2\n' >>"${SOURCE}/scripts/init.sh"
# Adopter-only: target changes while source stays at v1.
printf '\n# adopter issue-lib customization\n' >>"${TARGET}/scripts/issue-lib.sh"
# Both changed: target and source diverge independently from v1.
printf '\n# adopter create-pr customization\n' >>"${TARGET}/scripts/create-pr.sh"
printf '\n# upstream create-pr v2\n' >>"${SOURCE}/scripts/create-pr.sh"

printf 'outside sentinel\n' >"${TMP_DIR}/outside"
ln -s "${TMP_DIR}/outside" "${TARGET}/scripts/create-pr.sh.rej"
if "${SOURCE}/scripts/install-harness.sh" "$TARGET" --update >"$OUT" 2>&1; then
	cat "$OUT" >&2
	fail "an unresolved both-changed conflict must exit nonzero"
fi
[ "$(cat "${TMP_DIR}/outside")" = "outside sentinel" ] \
	|| fail "rejection output followed a symlink outside the target"
grep -Fq 'destination is not a regular file' "$OUT" \
	|| {
		cat "$OUT" >&2
		fail "unsafe rejection destination was not reported"
	}
rm "${TARGET}/scripts/create-pr.sh.rej"

if "${SOURCE}/scripts/install-harness.sh" "$TARGET" --update >"$OUT" 2>&1; then
	cat "$OUT" >&2
	fail "unresolved conflict must remain visible on a repeat update"
fi

grep -Fq '# upstream init v2' "${TARGET}/scripts/init.sh" \
	|| fail "upstream-only change was not safely installed"
grep -Fq '# adopter issue-lib customization' "${TARGET}/scripts/issue-lib.sh" \
	|| fail "adopter-only change was overwritten"
grep -Fq '# adopter create-pr customization' "${TARGET}/scripts/create-pr.sh" \
	|| fail "both-changed adopter file was overwritten"
if grep -Fq '# upstream create-pr v2' "${TARGET}/scripts/create-pr.sh"; then
	fail "both-changed upstream content replaced adopter content"
fi

REJECT="${TARGET}/scripts/create-pr.sh.rej"
[ -f "$REJECT" ] || fail "both-changed conflict did not emit adjacent .rej"
grep -Fq '# upstream create-pr v2' "$REJECT" \
	|| fail ".rej does not contain the rejected upstream change"
grep -Fq 'conflict scripts/create-pr.sh' "$OUT" \
	|| fail "conflict path was not reported"
grep -Fq 'kept scripts/issue-lib.sh (adopter changed)' "$OUT" \
	|| fail "adopter-only classification was not reported"

if ! "${SOURCE}/scripts/install-harness.sh" "$TARGET" --update >"$OUT" 2>&1; then
	cat "$OUT" >&2
	fail "a conflict already captured in .rej must become adopter-only on repeat"
fi
grep -Fq 'kept scripts/create-pr.sh (adopter changed)' "$OUT" \
	|| fail "captured conflict did not advance its installed upstream base"
[ -f "$REJECT" ] || fail "resolved classification removed the conflict artifact"

printf 'install-harness three-way update contract honored\n'
