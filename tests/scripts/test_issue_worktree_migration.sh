#!/usr/bin/env bash
# Regression sensor (#361): in-flight sibling worktrees remain the resolved
# lifecycle/tracking path during migration to repo-local .worktrees.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

REPO="${TMP_DIR}/repo"
LEGACY="${TMP_DIR}/repo-worktrees/issue-88"
mkdir -p "${REPO}/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${REPO}/scripts/"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Harness Test"
git -C "$REPO" config user.email "harness-test@example.invalid"
printf 'fixture\n' >"${REPO}/README.md"
git -C "$REPO" add README.md scripts
git -C "$REPO" commit -qm "test: seed repository"
git -C "$REPO" worktree add -q -b feature/issue-88-legacy "$LEGACY" main
LEGACY_CANON="$(cd "$LEGACY" && pwd -P)"

(
	cd "$REPO"
	# shellcheck source=scripts/issue-lib.sh
	source scripts/issue-lib.sh
	resolve_issue_env 88 legacy
	[ "$(cd "$WORKTREE_DIR" && pwd -P)" = "$LEGACY_CANON" ] \
		|| fail "main checkout did not resolve the existing sibling worktree"
	[ "$TRACKING_DIR" = "${WORKTREE_DIR}/.copilot-tracking/issues/issue-88" ] \
		|| fail "tracking path did not follow the legacy worktree"
)

(
	cd "$LEGACY"
	# shellcheck source=scripts/issue-lib.sh
	source "${REPO}/scripts/issue-lib.sh"
	resolve_issue_env 88 legacy
	[ "$(cd "$WORKTREE_DIR" && pwd -P)" = "$LEGACY_CANON" ] \
		|| fail "resolution from inside the sibling worktree drifted"
)

git -C "$REPO" worktree remove --force "$LEGACY"
(
	cd "$REPO"
	# shellcheck source=scripts/issue-lib.sh
	source scripts/issue-lib.sh
	resolve_issue_env 89 fresh
	case "$WORKTREE_DIR" in
	*/repo/.worktrees/issue-89) : ;;
	*) fail "fresh issue did not prefer the repo-local worktree path" ;;
	esac
)

printf 'legacy sibling worktree migration contract honored\n'
