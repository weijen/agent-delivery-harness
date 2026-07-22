#!/usr/bin/env bash
# Regression sensor (#348): start-issue stamps repository-local Git identity
# and routes HTTPS GitHub credentials through the repository-bound account.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

REPO="${TMP_DIR}/repo"
BIN="${TMP_DIR}/bin"
mkdir -p "${REPO}/scripts" "${REPO}/.github" "$BIN"
cp "${ROOT}/scripts/start-issue.sh" \
  "${ROOT}/scripts/issue-lib.sh" \
  "${ROOT}/scripts/github-identity-lib.sh" \
  "${REPO}/scripts/"

cat >"${REPO}/.github/harness-identity.env" <<'EOF'
HARNESS_GH_ACCOUNT=weijen
HARNESS_GIT_NAME=Wei Jen Lu
HARNESS_GIT_EMAIL=11629+weijen@users.noreply.github.com
EOF

GH_LOG="${TMP_DIR}/gh.log"
export GH_LOG
cat >"${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'token=%s args=%s\n' "${GH_TOKEN:-<unset>}" "$*" >>"${GH_LOG}"
case "${1:-} ${2:-}" in
  'auth token')
    [ "${3:-} ${4:-}" = "--user weijen" ] || exit 2
    printf '%s\n' token-for-weijen
    ;;
  'api user')
    if [ "${GH_TOKEN:-}" = token-for-weijen ]; then
      printf '%s\n' weijen
    else
      printf '%s\n' wrong-global-account
    fi
    ;;
  'issue view')
    printf '%s\n' 'Identity-bound issue'
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "${BIN}/gh"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Wrong Global Name"
git -C "$REPO" config user.email "wrong@example.invalid"
git -C "$REPO" remote add origin https://github.com/example/project.git
git -C "$REPO" add .
git -C "$REPO" commit -qm "test: seed repository"

(
  cd "$REPO"
  GH_TOKEN=wrong-token PATH="${BIN}:/usr/bin:/bin" SKIP_INIT=1 \
    ./scripts/start-issue.sh 348 SLUG=identity-test
) >"${TMP_DIR}/start.out" 2>"${TMP_DIR}/start.err" \
  || {
    cat "${TMP_DIR}/start.out" >&2
    cat "${TMP_DIR}/start.err" >&2
    fail "start-issue must succeed with the bound account"
  }

[ "$(git -C "$REPO" config --local user.name)" = "Wei Jen Lu" ] \
  || fail "start-issue must stamp the repository-local Git author name"
[ "$(git -C "$REPO" config --local user.email)" = \
  "11629+weijen@users.noreply.github.com" ] \
  || fail "start-issue must stamp the repository-local noreply email"
[ "$(git -C "$REPO" remote get-url origin)" = \
  "https://weijen@github.com/example/project.git" ] \
  || fail "start-issue must owner-qualify an HTTPS GitHub origin"
git -C "$REPO" config --local --get-all \
  credential.https://github.com.helper >"${TMP_DIR}/helpers"
[ "$(sed -n '1p' "${TMP_DIR}/helpers")" = "" ] \
  || fail "repository helper chain must reset inherited GitHub helpers"
[ "$(sed -n '2p' "${TMP_DIR}/helpers")" = "!gh auth git-credential" ] \
  || fail "repository helper chain must delegate through gh"

grep -Fq 'token=token-for-weijen args=issue view 348' "$GH_LOG" \
  || fail "GitHub lifecycle calls must inherit the bound process token"
if grep -q 'auth switch' "$GH_LOG"; then
  fail "start-issue must not switch global gh state"
fi

for entrypoint in init.sh start-issue.sh create-pr.sh merge-pr.sh finish-issue.sh; do
  grep -q 'harness_identity_activate' "${ROOT}/scripts/${entrypoint}" \
    || fail "${entrypoint} must activate the repository identity before GitHub operations"
done

printf 'start-issue GitHub identity contract honored\n'
