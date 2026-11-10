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
  [ "${GH_FAKE_EMPTY:-0}" != "1" ] || exit 0
  printf '%s\n' 'token-for-weijen'
  exit 0
fi
if [ "${1:-} ${2:-}" = "api user" ]; then
  [ "${GH_FAKE_VERIFY_FAILURE:-0}" != "1" ] || exit 1
  if [ "${GH_TOKEN:-}" = "token-for-weijen" ]; then
    printf '%s\n' "${GH_FAKE_IDENTITY:-weijen}"
  else
    printf '%s\n' 'wrong-global-account'
  fi
  exit 0
fi
if [ "${1:-} ${2:-}" = "repo view" ]; then
  [ "${GH_TOKEN:-}" = "token-for-weijen" ] || exit 2
  printf 'repository access denied for designated account\n' >&2
  exit 1
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
git -C "${TMP_DIR}/bound" init -q -b main
git -C "${TMP_DIR}/missing" init -q -b main
printf '/.github/harness-identity.env\n' >>"${TMP_DIR}/bound/.git/info/exclude"
git -C "${TMP_DIR}/bound" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit --allow-empty -qm seed
git -C "${TMP_DIR}/bound" worktree add -q -b linked "${TMP_DIR}/linked"
mkdir -p "${TMP_DIR}/linked/.github"
printf 'HARNESS_GH_ACCOUNT=wrong-local-account\nHARNESS_GIT_EMAIL=wrong@example.invalid\n' \
  >"${TMP_DIR}/linked/.github/harness-identity.env"

for checkout in bound linked; do
  PATH="${TMP_DIR}/bin:/usr/bin:/bin" GH_TOKEN=wrong-token GITHUB_TOKEN=wrong-token \
    bash -euc '
      cd "$2"
      source "$1"
      harness_identity_activate "$PWD"
      [ "$HARNESS_GH_ACCOUNT" = weijen ] && [ "$GH_TOKEN" = token-for-weijen ]
      [ -z "${GITHUB_TOKEN:-}" ]
      harness_identity_activate
      [ "$HARNESS_GH_ACCOUNT" = weijen ] && [ "$GH_TOKEN" = token-for-weijen ]
    ' bash "${ROOT}/scripts/lib/github-identity-lib.sh" "${TMP_DIR}/${checkout}" \
    >"${TMP_DIR}/fresh.out" 2>"${TMP_DIR}/fresh.err" \
    || fail "fresh ${checkout} process must use the canonical account, not ambient/local identity"
done
mv "${TMP_DIR}/bound/.github/harness-identity.env" "${TMP_DIR}/binding.saved"
: >"$GH_LOG"
if PATH="${TMP_DIR}/bin:/usr/bin:/bin" bash -euc '
  source "$1"
  harness_identity_activate "$2"
' bash "${ROOT}/scripts/lib/github-identity-lib.sh" "${TMP_DIR}/linked" \
  >"${TMP_DIR}/local.out" 2>"${TMP_DIR}/local.err"; then
  fail "a worktree-local binding must not replace a missing canonical binding"
fi
[ ! -s "$GH_LOG" ] || fail "missing canonical binding must fail before gh"
mv "${TMP_DIR}/binding.saved" "${TMP_DIR}/bound/.github/harness-identity.env"

# shellcheck source=scripts/lib/github-identity-lib.sh
source "${ROOT}/scripts/lib/github-identity-lib.sh"

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

for scenario in missing placeholder malformed duplicate symlink parent-symlink; do
  binding="${TMP_DIR}/missing/.github/harness-identity.env"
  mkdir -p "$(dirname "$binding")"
  case "$scenario" in
    missing) ;;
    placeholder) cp "${ROOT}/.github/harness-identity.env.example" "$binding" ;;
    malformed) printf 'HARNESS_GH_ACCOUNT=bad account\n' >"$binding" ;;
    duplicate) printf 'HARNESS_GH_ACCOUNT=weijen\nHARNESS_GH_ACCOUNT=other\n' >"$binding" ;;
    symlink) ln -s "${TMP_DIR}/bound/.github/harness-identity.env" "$binding" ;;
    parent-symlink)
      rmdir "${TMP_DIR}/missing/.github"
      ln -s "${TMP_DIR}/bound/.github" "${TMP_DIR}/missing/.github" ;;
  esac
  : >"$GH_LOG"
  if PATH="${TMP_DIR}/bin:/usr/bin:/bin" GH_TOKEN=wrong-token GITHUB_TOKEN=wrong-token \
    harness_identity_activate "${TMP_DIR}/missing" >"${TMP_DIR}/invalid.out" 2>"${TMP_DIR}/invalid.err"; then
    fail "${scenario} binding must prevent activation"
  fi
  [ ! -s "$GH_LOG" ] || fail "${scenario} binding must fail before any gh call"
  if [ "$scenario" = parent-symlink ]; then
    rm "${TMP_DIR}/missing/.github"
  elif [ -e "$binding" ] || [ -L "$binding" ]; then
    rm "$binding"
  fi
done

for scenario in unavailable empty verify-failure mismatch; do
  : >"$GH_LOG"
  if PATH="${TMP_DIR}/bin:/usr/bin:/bin" bash -euc '
    source "$1"
    case "$3" in
      unavailable) export GH_FAKE_UNAVAILABLE=1 ;;
      empty) export GH_FAKE_EMPTY=1 ;;
      verify-failure) export GH_FAKE_VERIFY_FAILURE=1 ;;
      mismatch) export GH_FAKE_IDENTITY=other-account ;;
    esac
    harness_identity_activate "$2"
  ' bash "${ROOT}/scripts/lib/github-identity-lib.sh" "${TMP_DIR}/bound" "$scenario" \
    >"${TMP_DIR}/auth.out" 2>"${TMP_DIR}/auth.err"; then
    fail "${scenario} must fail without trying another account"
  fi
  [ "$(grep -c '^auth token' "$GH_LOG")" -eq 1 ] || fail "${scenario} retried account selection"
  if grep -Eq 'wrong-token|token-for-weijen' "${TMP_DIR}/auth.err"; then
    fail "${scenario} diagnostics exposed credentials"
  fi
done

: >"$GH_LOG"
if PATH="${TMP_DIR}/bin:/usr/bin:/bin" bash -euc '
  source "$1"
  harness_identity_activate "$2"
  gh repo view
' bash "${ROOT}/scripts/lib/github-identity-lib.sh" "${TMP_DIR}/bound" \
  >"${TMP_DIR}/denied.out" 2>"${TMP_DIR}/denied.err"; then
  fail "repository denial must remain a failure"
fi
[ "$(grep -c '^auth token' "$GH_LOG")" -eq 1 ] || fail "repository denial selected another account"
grep -Fq 'repository access denied' "${TMP_DIR}/denied.err" || fail "access denial must be reported"


# --- Placeholder + committed-binding guards (apex-vs incident, 2026-07-23) ----
PH="${TMP_DIR}/ph-repo"
mkdir -p "${PH}/.github"
git init -q -b main "$PH"
cp "${ROOT}/.github/harness-identity.env.example" "${PH}/.github/harness-identity.env"
ph_rc=0
ph_out="$( (cd "$PH" && . "${ROOT}/scripts/lib/github-identity-lib.sh" && harness_identity_load "$PH") 2>&1 )" || ph_rc=$?
[ "$ph_rc" -ne 0 ] || fail "placeholder binding must fail, got rc=${ph_rc}: ${ph_out}"
grep -qi "placeholder" <<<"$ph_out" || fail "placeholder binding must warn about placeholders: ${ph_out}"
printf 'HARNESS_GH_ACCOUNT=real-account\nHARNESS_GIT_EMAIL=a@users.noreply.github.com\n' > "${PH}/.github/harness-identity.env"
git -C "$PH" -c user.email=t@t.invalid -c user.name=t add -f .github/harness-identity.env
git -C "$PH" -c user.email=t@t.invalid -c user.name=t commit -qm bind
tr_out="$( (cd "$PH" && . "${ROOT}/scripts/lib/github-identity-lib.sh" && harness_identity_load "$PH") 2>&1 )" || true
grep -qi "COMMITTED" <<<"$tr_out" || fail "a committed binding must emit the machine-local warning: ${tr_out}"

# EMU logins contain underscores (name_shortcode); the account pattern must
# accept them (adopter finding, foundry PoC 2026-07-23).
printf 'HARNESS_GH_ACCOUNT=someone_contoso\nHARNESS_GIT_EMAIL=1+someone_contoso@users.noreply.github.com\n' \
  > "${PH}/.github/harness-identity.env"
emu_rc=0
( . "${ROOT}/scripts/lib/github-identity-lib.sh" && harness_identity_load "$PH" ) >/dev/null 2>&1 || emu_rc=$?
[ "$emu_rc" -eq 0 ] || fail "an EMU underscore account must be a valid binding (rc=${emu_rc})"

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
mkdir -p "${REPO}/scripts/lib" "${REPO}/scripts/validation" "${REPO}/.github" "$BIN"
cp "${ROOT}/scripts/start-issue.sh" "${REPO}/scripts/"
mkdir -p "${REPO}/scripts/lifecycle"
cp "${ROOT}/scripts/lifecycle/start-issue.sh" "${REPO}/scripts/lifecycle/"
cp "${ROOT}/scripts/lib/issue-lib.sh" \
  "${ROOT}/scripts/lib/lifecycle-runtime-lib.sh" \
  "${ROOT}/scripts/lib/github-identity-lib.sh" \
  "${REPO}/scripts/lib/"

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

for entrypoint in lifecycle/init.sh lifecycle/start-issue.sh lifecycle/create-pr.sh lifecycle/merge-pr.sh lifecycle/finish-issue.sh; do
  grep -q 'harness_identity_activate' "${ROOT}/scripts/${entrypoint}" \
    || fail "${entrypoint} must activate the repository identity before GitHub operations"
done

printf 'start-issue GitHub identity contract honored\n'
)

(
cd "$ROOT"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
REPO="${FIXTURE_DIR}/repository-contract"
BINDING="${REPO}/.github/harness-identity.env"
TEMPLATE="${ROOT}/.github/harness-identity.env.example"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Repository identity is machine-local even for the harness's own origin.
mkdir -p "${REPO}/.github"
git -C "$REPO" init -q -b main
git -C "$REPO" remote add origin https://github.com/weijen/agent-delivery-harness.git
load_rc=0
harness_identity_load "$REPO" || load_rc=$?
[ "$load_rc" -ne 0 ] || fail "a clean checkout must require a local binding"
if harness_identity_activate "$REPO" 2>"${FIXTURE_DIR}/clean-checkout.err"; then
  fail "a clean checkout must not use current gh authentication"
fi
grep -qF 'harness-identity.env' "${FIXTURE_DIR}/clean-checkout.err" \
  || fail "a clean checkout must identify the required configuration"

cat >"$BINDING" <<'EOF'
HARNESS_GH_ACCOUNT=fixture-account
HARNESS_GIT_NAME=Fixture Author
HARNESS_GIT_EMAIL=123+fixture-account@users.noreply.github.com
EOF
HARNESS_GH_ACCOUNT=wrong-account
HARNESS_GIT_NAME="Wrong Author"
HARNESS_GIT_EMAIL=wrong@example.invalid
harness_identity_load "$REPO" || fail "a populated local binding must load"
[ "$HARNESS_GH_ACCOUNT" = fixture-account ] \
  || fail "local binding must select the configured GitHub account"
[ "$HARNESS_GIT_NAME" = "Fixture Author" ] \
  || fail "local binding must preserve the configured author name"
[ "$HARNESS_GIT_EMAIL" = "123+fixture-account@users.noreply.github.com" ] \
  || fail "local binding must preserve the configured noreply email"

[ -f "$TEMPLATE" ] || fail "adopter identity template is missing"
if grep -Eq 'weijen|11629' "$TEMPLATE"; then
  fail "adopter template leaks this repository's identity"
fi

printf 'repository identity binding contract honored\n'
)
