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

(

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
)

(

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$TMP_DIR"; rm -f "$OUT"' EXIT

dry_target="${TMP_DIR}/dry"
mkdir -p "${dry_target}/scripts"
: >"${dry_target}/scripts/.gitkeep"
"$INSTALL" "$dry_target" >"$OUT" 2>&1
grep -qF "would remove retired scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "dry run did not report the retired file"
	exit 1
}
[ -f "${dry_target}/scripts/.gitkeep" ] || {
	echo "dry run removed a retired file"
	exit 1
}

clean_target="${TMP_DIR}/clean"
mkdir -p "${clean_target}/scripts"
: >"${clean_target}/scripts/.gitkeep"
"$INSTALL" "$clean_target" --write >"$OUT" 2>&1
grep -qF "removed retired scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "--write did not report the retired file removal"
	exit 1
}
[ ! -e "${clean_target}/scripts/.gitkeep" ] || {
	echo "--write left a byte-identical retired file"
	exit 1
}

modified_target="${TMP_DIR}/modified"
mkdir -p "${modified_target}/scripts"
printf 'adopter content\n' >"${modified_target}/scripts/.gitkeep"
if "$INSTALL" "$modified_target" --write >"$OUT" 2>&1; then
	cat "$OUT"
	echo "--write must fail when a retired file was modified"
	exit 1
fi
grep -qF "preserving modified retired scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "--write did not warn about the modified retired file"
	exit 1
}
grep -qE '^--- |^\\+\\+\\+ ' "$OUT" || {
	cat "$OUT"
	echo "--write did not show a digest diff for the modified retired file"
	exit 1
}
grep -qF "adopter content" "${modified_target}/scripts/.gitkeep" || {
	echo "--write changed the modified retired file"
	exit 1
}

printf 'install-harness safe prune sensor passed\n'
)

(

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${ROOT}/scripts/install-harness.sh"
TMP_DIR="$(mktemp -d)"
OUT="$(mktemp)"
trap 'rm -rf "$TMP_DIR"; rm -f "$OUT"' EXIT

"$INSTALL" --help >"$OUT"
grep -qF "retired" "$OUT" || {
	cat "$OUT"
	echo "help does not disclose retired-asset pruning"
	exit 1
}
grep -qF "modified retired" "$OUT" || {
	cat "$OUT"
	echo "help does not disclose --update removal of modified retired assets"
	exit 1
}

target="${TMP_DIR}/target"
mkdir -p "${target}/scripts"
printf 'adopter content\n' >"${target}/scripts/.gitkeep"
if "$INSTALL" "$target" --update >"$OUT" 2>&1; then
	cat "$OUT"
	echo "--update must fail visibly on a modified retired conflict"
	exit 1
fi
grep -qF 'conflict scripts/.gitkeep' "$OUT" || {
	cat "$OUT"
	echo "--update did not report the retired-file conflict"
	exit 1
}
[ -f "${target}/scripts/.gitkeep" ] || {
	echo "--update removed the modified retired file"
	exit 1
}
[ -f "${target}/scripts/.gitkeep.rej" ] || {
	echo "--update did not emit a rejected deletion patch"
	exit 1
}
grep -qF 'adopter content' "${target}/scripts/.gitkeep.rej" || {
	echo "retired-file rejection patch does not contain adopter content"
	exit 1
}

directory_target="${TMP_DIR}/directory"
mkdir -p "${directory_target}/scripts/.gitkeep"
if "$INSTALL" "$directory_target" --update >"$OUT" 2>&1; then
	cat "$OUT"
	echo "--update must fail rather than recursively remove a replacement directory"
	exit 1
fi
[ -d "${directory_target}/scripts/.gitkeep" ] || {
	echo "--update removed a replacement directory"
	exit 1
}
grep -qF "conflict scripts/.gitkeep" "$OUT" || {
	cat "$OUT"
	echo "--update did not explain the non-file conflict"
	exit 1
}

printf 'install-harness update prune sensor passed\n'
)

(

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
)

(

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER="${ROOT}/scripts/install-harness.tombstones"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

[ -f "$LEDGER" ] || {
	echo "tombstone ledger missing: $LEDGER"
	exit 1
}

start_commit="$(git -C "$ROOT" log --diff-filter=A --format=%H --reverse -- scripts/install-harness.sh | head -1)"
[ -n "$start_commit" ] || {
	echo "could not locate installer introduction commit"
	exit 1
}

# The introduction commit only adds the installer. Excluding it avoids
# dereferencing a parent that is unavailable when CI checks out a shallow root.
git -C "$ROOT" log --diff-filter=D --format= --name-only "${start_commit}..HEAD" -- \
	scripts profiles tests .copilot .github/workflows docs VERSION .env.example |
	sort -u |
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		[ ! -e "${ROOT}/${path}" ] || continue
		case "$path" in
		.github/workflows/*)
			[ "$path" = ".github/workflows/harness-smoke.yml" ] || continue
			;;
		docs/*)
			case "$path" in
			docs/HARNESS.md | docs/getting-started.md | docs/multi-language-profiles.md | \
				docs/harness-contract.yml | docs/RELEASING.md | docs/evaluation/* | docs/runtime-adapters/*) ;;
			*) continue ;;
			esac
			;;
		esac

		deletion_commit="$(git -C "$ROOT" log --full-history --diff-filter=D -1 --format=%H -- "$path" </dev/null)"
		blob="${deletion_commit}^:${path}"
		digest="$(git -C "$ROOT" show "$blob" </dev/null | shasum -a 256 | awk '{print $1}')"
		printf '%s\t%s\n' "$digest" "$path"
	done |
	sort >"${TMP_DIR}/expected"

grep -Ev '^[[:space:]]*(#|$)' "$LEDGER" | sort >"${TMP_DIR}/actual"

if grep -Ev '^[0-9a-f]{64}[[:space:]][^/[:space:]][^[:space:]]*$' "${TMP_DIR}/actual" | grep -q .; then
	echo "tombstone ledger contains a malformed digest or path"
	exit 1
fi
if [ "$(wc -l <"${TMP_DIR}/actual" | tr -d ' ')" -ne "$(sort -u "${TMP_DIR}/actual" | wc -l | tr -d ' ')" ]; then
	echo "tombstone ledger contains duplicate entries"
	exit 1
fi
if ! comm -23 "${TMP_DIR}/expected" "${TMP_DIR}/actual" >"${TMP_DIR}/missing" ||
	[ -s "${TMP_DIR}/missing" ]; then
	cat "${TMP_DIR}/missing"
	echo "tombstone ledger is missing managed deletion history"
	exit 1
fi

printf 'install-harness tombstone manifest sensor passed\n'
)
