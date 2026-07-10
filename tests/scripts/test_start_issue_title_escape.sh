#!/usr/bin/env bash
# Regression sensor (#270 f2): start-issue.sh must JSON-escape the GitHub issue
# title it writes into the scaffolded feature_list.json. A title containing a
# double-quote, a backslash, or a newline must still produce valid JSON whose
# .title round-trips exactly.
#
# RED at authoring time: the title is interpolated raw into the JSON heredoc,
# so a title with a `"` breaks the document and jq refuses to parse it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

# The adversarial title: an embedded double-quote, a backslash, and a newline.
NASTY_TITLE='He said "hi" \back
and newline'

link_tools() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local t p
  for t in "$@"; do
    p="$(command -v "$t" || true)"
    [ -n "$p" ] && ln -sf "$p" "${dir}/${t}"
  done
}

make_commit() {
  local message="$1" branch="$2" tree commit
  tree="$(git write-tree)"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree" -p HEAD)"
  else
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree")"
  fi
  git update-ref "refs/heads/${branch}" "$commit"
  git reset -q --hard "$commit"
}

BIN="${TMP_DIR}/bin"
link_tools "$BIN" bash sh env git basename dirname mkdir rm cat sed tr cut grep printf jq date od wc head tail

# Fake gh: `issue view … -q .title` prints the adversarial title; everything
# else fails so the slug still comes from the explicit SLUG= argument.
cat > "${BIN}/gh" <<SH
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "view" ]; then
  cat <<'TITLE'
${NASTY_TITLE}
TITLE
  exit 0
fi
exit 1
SH
chmod +x "${BIN}/gh"

unset TRACE_ISSUE TRACE_PARENT_SPAN_ID 2>/dev/null || true

REPO="${TMP_DIR}/repo"
mkdir -p "${REPO}/scripts"
cp "${ROOT}/scripts/issue-lib.sh" "${REPO}/scripts/"
cp "${ROOT}/scripts/start-issue.sh" "${REPO}/scripts/"
cp "${ROOT}/scripts/trace-lib.sh" "${REPO}/scripts/"
cat > "${REPO}/scripts/init.sh" <<'SH'
#!/usr/bin/env bash
echo "stub preflight"
exit 0
SH
chmod +x "${REPO}/scripts/init.sh"

cd "$REPO"
git init -q -b main
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf 'fixture\n' > README.md
git add .gitignore README.md scripts
make_commit "initial" main

PATH="$BIN" ./scripts/start-issue.sh 88 SLUG=nasty-title >"${TMP_DIR}/start.out" 2>&1 \
  || { cat "${TMP_DIR}/start.out"; fail "start-issue.sh must exit 0 while scaffolding"; }

FL="${TMP_DIR}/repo-worktrees/issue-88/.copilot-tracking/issues/issue-88/feature_list.json"
if [ ! -f "$FL" ]; then
  cat "${TMP_DIR}/start.out" 2>/dev/null || true
  fail "feature_list.json was not scaffolded at ${FL}"
else
  if ! jq -e . "$FL" >/dev/null 2>&1; then
    printf '# offending feature_list.json:\n' >&2
    cat "$FL" >&2
    fail "feature_list.json is not valid JSON when the issue title contains a quote/backslash/newline"
  else
    got_title="$(jq -r '.title' "$FL")"
    [ "$got_title" = "$NASTY_TITLE" ] \
      || fail "title did not round-trip: expected <${NASTY_TITLE}>, got <${got_title}>"
  fi
fi

if [ "$fails" -ne 0 ]; then
  printf '\n%d start-issue title-escape violation(s).\n' "$fails" >&2
  exit 1
fi
printf 'start-issue title JSON-escape contract honored\n'
