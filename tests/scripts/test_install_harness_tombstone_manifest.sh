#!/usr/bin/env bash
# Regression sensor (issue #313): every managed asset retired after the
# installer was introduced must retain its final upstream digest as a tombstone.
set -euo pipefail

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
