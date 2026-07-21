#!/usr/bin/env bash
# test_review_gate_patch_id_store.sh — regression sensor for feature
# approve-stores-patch-id (issue #310):
#   Scenario A: approve writes a 2-line marker (line 1 = HEAD SHA,
#               line 2 = stable patch-id hex string, 40 or 64 chars).
#   Scenario B: check passes with a 2-line marker (reads only line 1).
#   Scenario C: backward compat — a legacy single-line marker still passes check.
#   Scenario D: mutation witness — a patched-away patch-id write yields a
#               1-line marker, proving Scenario A's assertion detects the regression.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/tests/scripts/lib/tap.sh"

_sfail=0
fail() { printf '# %s\n' "$*" >&2; _sfail=1; }
emit() {
  if [ "$_sfail" -eq 0 ]; then tap_ok "$1"; else tap_not_ok "$1"; fi
  _sfail=0
}

make_commit() {
  local message="$1"
  local tree commit
  tree="$(git write-tree)"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree" -p HEAD)"
  else
    commit="$(printf '%s\n' "$message" | git commit-tree "$tree")"
  fi
  git update-ref refs/heads/feature/review-gate "$commit"
  git reset -q --hard "$commit"
}

# ── Setup ────────────────────────────────────────────────────────────────────

# Fake gh (approve/check do not need gh; included so PATH isolation is complete).
mkdir -p "${TMP_DIR}/bin"
cat > "${TMP_DIR}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 1
GHEOF
chmod +x "${TMP_DIR}/bin/gh"
export PATH="${TMP_DIR}/bin:${PATH}"

# Create a bare origin with a main branch that has docs/PROGRESS.md.
mkdir -p "${TMP_DIR}/origin-work/docs"
git init -q -b main "${TMP_DIR}/origin-work"
git -C "${TMP_DIR}/origin-work" config user.name "Harness Test"
git -C "${TMP_DIR}/origin-work" config user.email "harness-test@example.invalid"
printf '# Progress\n\nbaseline\n' > "${TMP_DIR}/origin-work/docs/PROGRESS.md"
printf 'initial\n' > "${TMP_DIR}/origin-work/README.md"
git -C "${TMP_DIR}/origin-work" add docs/PROGRESS.md README.md
git -C "${TMP_DIR}/origin-work" commit -q -m "initial"
git clone -q --bare "${TMP_DIR}/origin-work" "${TMP_DIR}/origin.git"

# Feature repo on a feature/review-gate branch (no issue-NN slug →
# resolve_issue_number skips gracefully → all trace-based gates skip).
mkdir -p "${TMP_DIR}/repo/scripts" "${TMP_DIR}/repo/docs"
cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/repo/scripts/review-gate.sh"

cd "${TMP_DIR}/repo"
git init -q -b feature/review-gate
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main

# Establish feature commits on top of origin/main.
# docs/PROGRESS.md must differ from origin/main so status_doc_gate passes.
git reset -q --hard origin/main
printf 'feature work\n' > feature.txt
printf '# Progress\n\npatch-id store implementation\n' > docs/PROGRESS.md
git add .gitignore feature.txt docs/PROGRESS.md
make_commit "first feature commit"

printf 'more feature work\n' >> feature.txt
git add feature.txt
make_commit "second feature commit"

head_sha="$(git rev-parse HEAD)"
marker_dir="${TMP_DIR}/repo/.copilot-tracking/review-gate"
marker_file="${marker_dir}/approved-head"
rg="${TMP_DIR}/repo/scripts/review-gate.sh"

# ── Scenario A: approve writes a 2-line marker ───────────────────────────────
approve_rc=0
"$rg" approve >"${TMP_DIR}/approve-a.out" 2>&1 || approve_rc=$?

if [ "$approve_rc" -ne 0 ]; then
  fail "approve exited ${approve_rc} — expected 0"
elif [ ! -f "$marker_file" ]; then
  fail "marker file was not created"
else
  line_count="$(wc -l < "$marker_file" | tr -d ' ')"
  line1="$(sed -n '1p' "$marker_file" | tr -d '[:space:]')"
  line2="$(sed -n '2p' "$marker_file" | tr -d '[:space:]')"

  if [ "$line_count" -ne 2 ]; then
    fail "expected 2-line marker, got ${line_count} line(s)"
  fi
  if [ "$line1" != "$head_sha" ]; then
    fail "line 1 '${line1}' != HEAD SHA '${head_sha}'"
  fi
  if [ -z "$line2" ]; then
    fail "line 2 (patch-id) must not be empty"
  fi
  if ! printf '%s\n' "$line2" | grep -qE '^[0-9a-f]{40}$|^[0-9a-f]{64}$'; then
    fail "line 2 '${line2}' is not a 40- or 64-char lowercase hex string"
  fi
fi
emit "Scenario A: approve writes 2-line marker (line 1 = HEAD sha, line 2 = patch-id hex)"

# ── Scenario B: check passes with a 2-line marker ────────────────────────────
# Uses the marker written by Scenario A (still current HEAD).
check_b_rc=0
SKIP_CI_GATE=1 "$rg" check >"${TMP_DIR}/check-b.out" 2>&1 || check_b_rc=$?
if [ "$check_b_rc" -ne 0 ]; then
  fail "check failed with 2-line marker (rc=${check_b_rc})"
  cat "${TMP_DIR}/check-b.out" >&2
fi
emit "Scenario B: check passes with 2-line marker (reads only line 1)"

# ── Scenario C: backward compat — single-line marker still passes check ──────
mkdir -p "$marker_dir"
printf '%s\n' "$head_sha" > "$marker_file"   # synthetic legacy format
check_c_rc=0
SKIP_CI_GATE=1 "$rg" check >"${TMP_DIR}/check-c.out" 2>&1 || check_c_rc=$?
if [ "$check_c_rc" -ne 0 ]; then
  fail "check failed with legacy single-line marker (rc=${check_c_rc})"
  cat "${TMP_DIR}/check-c.out" >&2
fi
emit "Scenario C: check passes with legacy single-line marker (backward compatible)"

# ── Scenario D: mutation witness ─────────────────────────────────────────────
# Direct mutation evidence (GREEN phase): a mutant review-gate.sh with the
# patch-id append line removed. The mutant writes only line 1 (HEAD sha);
# Scenario A's 2-line assertion would catch this regression in production.
# This proves the printf append is the load-bearing contract mechanism.
# (Red-first evidence from Scenario A failing pre-implementation already
# satisfies the teeth obligation; this is additional positive mutation proof.)
mutant_rg="${TMP_DIR}/review-gate-mutant.sh"
# Remove the line that appends the patch-id to the marker. The pattern matches
# the literal $marker_file in the script source (\$ → sed escaped dollar sign).
# shellcheck disable=SC2016
sed '/printf.*_patch_id.*>> "\$marker_file"/d' "${ROOT}/scripts/review-gate.sh" > "$mutant_rg"
chmod +x "$mutant_rg"

rm -f "$marker_file"
bash "$mutant_rg" approve >"${TMP_DIR}/mutant-approve.out" 2>&1 || true

if [ ! -f "$marker_file" ]; then
  fail "mutant approve did not create the marker file"
else
  d_line_count="$(wc -l < "$marker_file" | tr -d ' ')"
  d_line2="$(sed -n '2p' "$marker_file" | tr -d '[:space:]')"
  if [ "$d_line_count" -ne 1 ] || [ -n "$d_line2" ]; then
    fail "mutant approve wrote ${d_line_count} line(s) with line2='${d_line2}'; expected 1 line and no line 2 — the contract append is missing"
  fi
fi
emit "Scenario D: mutation witness — mutant missing the patch-id append writes a 1-line marker (Scenario A would catch it)"

# ── Scenario E: patch identity is invariant across a content-preserving rebase ─
# Advance origin/main with an unrelated commit, rebase the feature branch onto
# it, and verify that line 2 of the approved-head marker is unchanged.
# This is the core semantic guarantee: patch-id is commit-hash–agnostic.

# Clean up Scenario D's 1-line mutant marker and get a fresh 2-line marker.
rm -f "$marker_file"
e_before_rc=0
"$rg" approve >"${TMP_DIR}/approve-e-before.out" 2>&1 || e_before_rc=$?

if [ "$e_before_rc" -ne 0 ]; then
  fail "Scenario E: pre-rebase approve failed (rc=${e_before_rc})"
  cat "${TMP_DIR}/approve-e-before.out" >&2
elif [ ! -f "$marker_file" ]; then
  fail "Scenario E: pre-rebase approve did not create marker file"
else
  e_id_before="$(sed -n '2p' "$marker_file" | tr -d '[:space:]')"
  if [ -z "$e_id_before" ]; then
    fail "Scenario E: pre-rebase patch identity must not be blank (origin/main is configured)"
  fi

  # Add an unrelated commit to origin/main (touches a file not in the feature branch).
  printf 'extra origin work\n' > "${TMP_DIR}/origin-work/docs/EXTRA.md"
  git -C "${TMP_DIR}/origin-work" add docs/EXTRA.md
  git -C "${TMP_DIR}/origin-work" -c user.name="Harness Test" \
    -c user.email="harness-test@example.invalid" \
    commit -q -m "chore: add extra doc (unrelated to feature)"
  git -C "${TMP_DIR}/origin-work" push -q "${TMP_DIR}/origin.git" main:main

  git -C "${TMP_DIR}/repo" fetch -q origin main

  e_rebase_rc=0
  git -C "${TMP_DIR}/repo" -c user.name="Harness Test" \
    -c user.email="harness-test@example.invalid" \
    rebase -q origin/main >"${TMP_DIR}/rebase-e.out" 2>&1 || e_rebase_rc=$?
  if [ "$e_rebase_rc" -ne 0 ]; then
    fail "Scenario E: rebase failed (rc=${e_rebase_rc})"
    cat "${TMP_DIR}/rebase-e.out" >&2
    git -C "${TMP_DIR}/repo" rebase --abort 2>/dev/null || true
  else
    # Re-approve after rebase (HEAD SHA has changed; identity must be unchanged).
    e_after_rc=0
    "$rg" approve >"${TMP_DIR}/approve-e-after.out" 2>&1 || e_after_rc=$?
    if [ "$e_after_rc" -ne 0 ]; then
      fail "Scenario E: post-rebase approve failed (rc=${e_after_rc})"
      cat "${TMP_DIR}/approve-e-after.out" >&2
    elif [ ! -f "$marker_file" ]; then
      fail "Scenario E: post-rebase approve did not create marker file"
    else
      e_id_after="$(sed -n '2p' "$marker_file" | tr -d '[:space:]')"
      if [ -z "$e_id_after" ]; then
        fail "Scenario E: post-rebase patch identity must not be blank"
      elif [ "$e_id_before" != "$e_id_after" ]; then
        fail "Scenario E: identity changed across rebase: before='${e_id_before}' after='${e_id_after}'"
      fi
    fi
  fi
fi
emit "Scenario E: patch identity is unchanged across a content-preserving rebase"

# ── Scenario F: empty branch with valid origin/main gets deterministic identity ─
# A branch with zero commits above origin/main must record the deterministic
# empty-stream identity (git hash-object --stdin </dev/null), not a blank line.
# This distinguishes it from the origin-unavailable case (Scenario G).
mkdir -p "${TMP_DIR}/f-repo/scripts" "${TMP_DIR}/f-repo/docs"
cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/f-repo/scripts/review-gate.sh"
_saved_dir="$(pwd)"
cd "${TMP_DIR}/f-repo"
git init -q -b feature/empty-test
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
git remote add origin "${TMP_DIR}/origin.git"
git fetch -q origin main
# Reset to exactly origin/main — zero commits above the base.
git reset -q --hard origin/main

f_approve_rc=0
./scripts/review-gate.sh approve >"${TMP_DIR}/approve-f.out" 2>&1 || f_approve_rc=$?
f_marker="${TMP_DIR}/f-repo/.copilot-tracking/review-gate/approved-head"

if [ "$f_approve_rc" -ne 0 ]; then
  fail "Scenario F: approve failed for empty branch (rc=${f_approve_rc})"
  cat "${TMP_DIR}/approve-f.out" >&2
elif [ ! -f "$f_marker" ]; then
  fail "Scenario F: approve did not create marker file for empty branch"
else
  f_line_count="$(wc -l < "$f_marker" | tr -d ' ')"
  f_line2="$(sed -n '2p' "$f_marker" | tr -d '[:space:]')"
  f_expected_empty_id="$(git hash-object --stdin </dev/null 2>/dev/null)" || f_expected_empty_id=""

  if [ "$f_line_count" -ne 2 ]; then
    fail "Scenario F: expected 2-line marker for empty branch, got ${f_line_count} line(s)"
  elif [ -z "$f_line2" ]; then
    fail "Scenario F: line 2 must be the deterministic empty-stream hash, not blank"
  elif [ -n "$f_expected_empty_id" ] && [ "$f_line2" != "$f_expected_empty_id" ]; then
    fail "Scenario F: line 2 '${f_line2}' != expected empty-stream hash '${f_expected_empty_id}'"
  elif ! printf '%s\n' "$f_line2" | grep -qE '^[0-9a-f]{40}$|^[0-9a-f]{64}$'; then
    fail "Scenario F: line 2 '${f_line2}' is not a 40- or 64-char lowercase hex string"
  fi
fi
cd "$_saved_dir"
emit "Scenario F: empty branch (zero commits above origin/main) gets deterministic empty-stream identity"

# ── Scenario G: origin/main unavailable — approve succeeds, line 2 is blank ──
# When origin/main cannot be reached, identity is unknown. Approve must still
# succeed (approval is valid), write 2 lines, and record a blank line 2 so that
# carry fails closed later. This case must not be confused with an empty branch
# (Scenario F: empty branch with valid origin/main gets a specific non-blank hash).
mkdir -p "${TMP_DIR}/g-repo/scripts" "${TMP_DIR}/g-repo/docs"
cp "${ROOT}/scripts/review-gate.sh" "${TMP_DIR}/g-repo/scripts/review-gate.sh"
cd "${TMP_DIR}/g-repo"
git init -q -b feature/no-origin-test
git config user.name "Harness Test"
git config user.email "harness-test@example.invalid"
printf '.copilot-tracking/\n' > .gitignore
printf '# Progress\n\nwork without origin\n' > docs/PROGRESS.md
git add .gitignore docs/PROGRESS.md
git -c user.name="Harness Test" -c user.email="harness-test@example.invalid" \
  commit -q -m "initial commit (no origin configured)"
printf 'more work\n' > work.txt
git add work.txt
git -c user.name="Harness Test" -c user.email="harness-test@example.invalid" \
  commit -q -m "second commit"
# No origin remote configured: git merge-base origin/main HEAD will fail.

g_approve_rc=0
./scripts/review-gate.sh approve >"${TMP_DIR}/approve-g.out" 2>&1 || g_approve_rc=$?
g_marker="${TMP_DIR}/g-repo/.copilot-tracking/review-gate/approved-head"
g_head_sha="$(git rev-parse HEAD)"

if [ "$g_approve_rc" -ne 0 ]; then
  fail "Scenario G: approve must succeed even when origin/main is unavailable (rc=${g_approve_rc})"
  cat "${TMP_DIR}/approve-g.out" >&2
elif [ ! -f "$g_marker" ]; then
  fail "Scenario G: approve did not create marker file"
else
  g_line_count="$(wc -l < "$g_marker" | tr -d ' ')"
  g_line1="$(sed -n '1p' "$g_marker" | tr -d '[:space:]')"
  g_line2="$(sed -n '2p' "$g_marker" | tr -d '[:space:]')"

  if [ "$g_line_count" -ne 2 ]; then
    fail "Scenario G: expected 2-line marker, got ${g_line_count} line(s)"
  fi
  if [ "$g_line1" != "$g_head_sha" ]; then
    fail "Scenario G: line 1 '${g_line1}' != HEAD '${g_head_sha}'"
  fi
  if [ -n "$g_line2" ]; then
    fail "Scenario G: line 2 must be blank when origin/main is unavailable, got '${g_line2}'"
  fi
fi
cd "$_saved_dir"
emit "Scenario G: origin/main unavailable — approve succeeds, marker has 2 lines, line 2 is blank"

tap_done
