#!/usr/bin/env bash
# Regression and e2e sensor (#361): new issue worktrees stay inside the trusted
# repository root under an ignored .worktrees directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

REPO="${TMP_DIR}/repo"
BIN="${TMP_DIR}/bin"
mkdir -p "${REPO}/scripts" "$BIN"
cp "${ROOT}/scripts/start-issue.sh" "${ROOT}/scripts/issue-lib.sh" "${REPO}/scripts/"
cat >"${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Repo-local worktree fixture'
EOF
chmod +x "${BIN}/gh"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Harness Test"
git -C "$REPO" config user.email "harness-test@example.invalid"
printf '/.worktrees/\n.copilot-tracking/\n' >"${REPO}/.gitignore"
printf 'fixture\n' >"${REPO}/README.md"
git -C "$REPO" add .gitignore README.md scripts
git -C "$REPO" commit -qm "test: seed repository"

(
	cd "$REPO"
	PATH="${BIN}:/usr/bin:/bin" SKIP_INIT=1 \
		./scripts/start-issue.sh 77 SLUG=repo-local
) >"${TMP_DIR}/start.out" 2>&1 \
	|| {
		cat "${TMP_DIR}/start.out" >&2
		fail "start-issue failed"
	}

WORKTREE="${REPO}/.worktrees/issue-77"
[ -d "$WORKTREE" ] || fail "new worktree was not created under repo/.worktrees"
[ ! -e "${TMP_DIR}/repo-worktrees/issue-77" ] \
	|| fail "new worktree still used the historical sibling layout"
git -C "$REPO" check-ignore -q .worktrees/issue-77 \
	|| fail "repo-local worktree is not covered by the root ignore rule"
[ -z "$(git -C "$REPO" status --porcelain)" ] \
	|| fail "repo-local worktree dirtied the main checkout"
grep -Fq "worktree: ${WORKTREE}" "${TMP_DIR}/start.out" \
	|| fail "start-issue did not report the repo-local path"

printf 'repo-local issue worktree contract honored\n'
