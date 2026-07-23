#!/usr/bin/env bash
# Regression sensor (#348): repository GitHub identity is resolved per process
# without executing config content or switching gh's global active account.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "${TMP_DIR}/bin" "${TMP_DIR}/bound/.github" "${TMP_DIR}/missing"
GH_LOG="${TMP_DIR}/gh.log"
export GH_LOG

cat >"${TMP_DIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GH_LOG}"
if [ "${1:-} ${2:-}" = "auth token" ]; then
  [ "${GH_FAKE_UNAVAILABLE:-0}" != "1" ] || exit 1
  [ "${3:-} ${4:-}" = "--user weijen" ] || exit 2
  printf '%s\n' 'token-for-weijen'
  exit 0
fi
if [ "${1:-} ${2:-}" = "api user" ]; then
  if [ "${GH_TOKEN:-}" = "token-for-weijen" ]; then
    printf '%s\n' 'weijen'
  else
    printf '%s\n' 'wrong-global-account'
  fi
  exit 0
fi
exit 2
EOF
chmod +x "${TMP_DIR}/bin/gh"

sentinel="${TMP_DIR}/must-not-exist"
cat >"${TMP_DIR}/bound/.github/harness-identity.env" <<EOF
# Repository-local identity; this file is data, not shell.
HARNESS_GH_ACCOUNT=weijen
HARNESS_GIT_NAME=\$(touch ${sentinel})
HARNESS_GIT_EMAIL=11629+weijen@users.noreply.github.com
EOF

# shellcheck source=scripts/github-identity-lib.sh
source "${ROOT}/scripts/github-identity-lib.sh"

export GH_TOKEN="token-for-wrong-account"
export GITHUB_TOKEN="another-wrong-token"
PATH="${TMP_DIR}/bin:/usr/bin:/bin" \
  harness_identity_activate "${TMP_DIR}/bound" \
  >"${TMP_DIR}/bound.out" 2>"${TMP_DIR}/bound.err" \
  || fail "a usable bound account must activate"

[ "${GH_TOKEN}" = "token-for-weijen" ] \
  || fail "bound token must override ambient GH_TOKEN"
[ ! -e "${sentinel}" ] || fail "identity config content must never be executed"
grep -Fxq 'auth token --user weijen' "${GH_LOG}" \
  || fail "token must be minted explicitly for the bound account"
if grep -q 'auth switch' "${GH_LOG}"; then
  fail "activation must never mutate gh global state with auth switch"
fi

unset GH_TOKEN GITHUB_TOKEN HARNESS_GH_ACCOUNT HARNESS_GIT_NAME HARNESS_GIT_EMAIL
GH_FAKE_UNAVAILABLE=1
export GH_FAKE_UNAVAILABLE
if PATH="${TMP_DIR}/bin:/usr/bin:/bin" \
  harness_identity_activate "${TMP_DIR}/bound" \
  >"${TMP_DIR}/unavailable.out" 2>"${TMP_DIR}/unavailable.err"; then
  fail "an unavailable bound account must hard-fail"
fi
grep -Fq "cannot mint a token for bound GitHub account 'weijen'" \
  "${TMP_DIR}/unavailable.err" \
  || fail "unavailable-account failure must identify the bound account"
unset GH_FAKE_UNAVAILABLE

unset HARNESS_GH_ACCOUNT HARNESS_GIT_NAME HARNESS_GIT_EMAIL
__HARNESS_IDENTITY_WARNING_EMITTED=0
: >"${TMP_DIR}/missing.err"
PATH="${TMP_DIR}/bin:/usr/bin:/bin" \
  harness_identity_activate "${TMP_DIR}/missing" 2>>"${TMP_DIR}/missing.err" \
  || fail "missing binding must preserve legacy behavior"
PATH="${TMP_DIR}/bin:/usr/bin:/bin" \
  harness_identity_activate "${TMP_DIR}/missing" 2>>"${TMP_DIR}/missing.err" \
  || fail "repeated missing binding must preserve legacy behavior"
[ "$(grep -c 'harness-identity.env not found' "${TMP_DIR}/missing.err")" -eq 1 ] \
  || fail "missing binding must warn exactly once per process"


# --- Placeholder + committed-binding guards (apex-vs incident, 2026-07-23) ----
PH="${TMP_DIR}/ph-repo"
mkdir -p "${PH}/.github"
git init -q -b main "$PH"
cp "${ROOT}/.github/harness-identity.env.example" "${PH}/.github/harness-identity.env"
ph_rc=0
ph_out="$( (cd "$PH" && . "${ROOT}/scripts/github-identity-lib.sh" && harness_identity_load "$PH") 2>&1 )" || ph_rc=$?
[ "$ph_rc" -eq 2 ] || fail "placeholder binding must be treated as absent (rc=2), got rc=${ph_rc}: ${ph_out}"
grep -qi "placeholder" <<<"$ph_out" || fail "placeholder binding must warn about placeholders: ${ph_out}"
printf 'HARNESS_GH_ACCOUNT=real-account\nHARNESS_GIT_EMAIL=a@users.noreply.github.com\n' > "${PH}/.github/harness-identity.env"
git -C "$PH" -c user.email=t@t.invalid -c user.name=t add -f .github/harness-identity.env
git -C "$PH" -c user.email=t@t.invalid -c user.name=t commit -qm bind
tr_out="$( (cd "$PH" && . "${ROOT}/scripts/github-identity-lib.sh" && harness_identity_load "$PH") 2>&1 )" || true
grep -qi "COMMITTED" <<<"$tr_out" || fail "a committed binding must emit the machine-local warning: ${tr_out}"

printf 'GitHub identity binding contract honored\n'

(
cd "$ROOT"

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
)

(
cd "$ROOT"

BINDING="${ROOT}/.github/harness-identity.env"
TEMPLATE="${ROOT}/.github/harness-identity.env.example"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -f "$BINDING" ] || fail "repository identity binding is missing"
grep -Fxq 'HARNESS_GH_ACCOUNT=weijen' "$BINDING" \
  || fail "repository must bind the weijen GitHub account"
grep -Fxq 'HARNESS_GIT_NAME=Wei Jen Lu' "$BINDING" \
  || fail "repository Git author name is incorrect"
grep -Fxq 'HARNESS_GIT_EMAIL=11629+weijen@users.noreply.github.com' "$BINDING" \
  || fail "repository Git noreply email is incorrect"

[ -f "$TEMPLATE" ] || fail "adopter identity template is missing"
if grep -Eq 'weijen|11629' "$TEMPLATE"; then
  fail "adopter template leaks this repository's identity"
fi

printf 'repository identity binding contract honored\n'
)
