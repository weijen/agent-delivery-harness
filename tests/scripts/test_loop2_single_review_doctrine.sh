#!/usr/bin/env bash
# test_loop2_single_review_doctrine.sh — regression sensor for the Loop 2
# single-end-review doctrine (issue #303, feature loop2-single-end-review).
#
# Contract under test (PINNED HERE as the executable spec): independent code
# review moves from a per-feature, mid-stream step to a SINGLE independent review
# at issue completion. The harness Loop 2 doctrine
# (.copilot/instructions/harness.instructions.md, §3 "Grading-driven revision
# loops") must state:
#   1. The conductor does NOT invoke `code-review-subagent` per feature
#      mid-stream — per-feature verification is fully owned by `generator-subagent`.
#   2. The ONE independent review runs at issue completion (all features
#      `passes:true`) over the WHOLE branch diff in `full` mode, and issues
#      PER-FEATURE verdicts.
#   3. A `NEEDS_REVISION` verdict routes back to `generator-subagent` PER FEATURE.
#   4. The post-repair re-review runs in `repair` mode SCOPED to that feature only.
#   5. The 3-rejection cap semantics are unchanged (per-feature counting,
#      `review_reject_cap_exceeded` + `review-gate.sh` hard block).
#
# Exit codes: 0 all obligations present · 1 an obligation is missing (RED gate —
# the doctrine still describes a per-feature mid-stream review round).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC_HARNESS="${ROOT}/.copilot/instructions/harness.instructions.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

if [ ! -f "${DOC_HARNESS}" ]; then
  printf 'FAIL: harness doctrine not found (%s)\n' "${DOC_HARNESS}" >&2
  exit 1
fi

# Extract the Loop 2 block: from the Loop 2 heading down to the Loop 3 heading.
# ASCII-only anchors so a UTF-8 em-dash in the heading never defeats the match.
block="$(sed -n '/\*\*Loop 2/,/\*\*Loop 3/p' "${DOC_HARNESS}")"

if [ -z "${block}" ]; then
  fail "could not locate the §3 Loop 2 doctrine block"
fi

# 1. Conductor must NOT invoke code-review-subagent per feature mid-stream.
printf '%s\n' "${block}" \
  | grep -qiE 'does not invoke .*code-review-subagent.* per feature|not invoke .*code-review-subagent.* per feature mid-stream' \
  || fail "Loop 2 must state the conductor does NOT invoke code-review-subagent per feature mid-stream"

# 1b. Per-feature verification is fully owned by the generator.
printf '%s\n' "${block}" \
  | grep -qiE 'per-feature verification .*(fully )?owned by .*generator-subagent|generator-subagent .*owns .*per-feature verification' \
  || fail "Loop 2 must state per-feature verification is fully owned by generator-subagent"

# 2. Single independent review at issue completion (all features passes:true).
printf '%s\n' "${block}" \
  | grep -qiE 'single .*(independent )?review|one .*independent review' \
  || fail "Loop 2 must describe a single independent review (not a per-feature review)"
printf '%s\n' "${block}" \
  | grep -qiE 'issue completion|all[^a-z]*features?.*passes:true|features? are (all )?.*passes:true' \
  || fail "Loop 2 must state the review runs at issue completion (all features passes:true)"

# 2b. Whole branch diff in full mode.
printf '%s\n' "${block}" \
  | grep -qiE 'whole .*branch diff' \
  || fail "Loop 2 must state the review runs over the whole branch diff"
printf '%s\n' "${block}" \
  | grep -qiE 'full.{0,3}mode|full mode' \
  || fail "Loop 2 must state the end-of-issue review runs in full mode"

# 2c. Per-feature verdicts.
printf '%s\n' "${block}" \
  | grep -qiE 'per-feature verdict' \
  || fail "Loop 2 must state the single review issues per-feature verdicts"

# 3. NEEDS_REVISION routes back to generator-subagent per feature.
printf '%s\n' "${block}" \
  | grep -qiE 'NEEDS_REVISION.*per feature|per feature.*generator-subagent|for that feature only.*generator-subagent|generator-subagent.*for that feature only' \
  || fail "Loop 2 must route a NEEDS_REVISION verdict back to generator-subagent per feature"

# 4. Post-repair re-review runs in repair mode scoped to that feature only.
printf '%s\n' "${block}" \
  | grep -qiE 'repair.{0,60}(mode|profile).{0,80}(scoped|that feature)|(scoped|that feature).{0,80}repair.{0,20}(mode|profile)' \
  || fail "Loop 2 must state the post-repair re-review runs in repair mode scoped to that feature only"

# 5. The 3-rejection cap semantics are unchanged.
printf '%s\n' "${block}" \
  | grep -qiE 'review_reject_cap_exceeded' \
  || fail "Loop 2 must keep the review_reject_cap_exceeded reject-cap finding"
printf '%s\n' "${block}" \
  | grep -qiE 'review-gate\.sh' \
  || fail "Loop 2 must keep review-gate.sh as the deterministic reject-cap enforcer"
printf '%s\n' "${block}" \
  | grep -qiE '3rd .*rejection|three or more .*review_verdict|third .*rejection' \
  || fail "Loop 2 must keep the 3rd-rejection (three-or-more) cap semantics"

# 6. Negative: the doctrine must NOT still mandate a per-feature review round as
# the default mid-stream step. The old framing reviewed "the feature or closeout
# diff" per feature and re-ran code-review-subagent "on the new HEAD/diff" after
# every fix as the standard loop; that per-feature review round must be gone.
if printf '%s\n' "${block}" \
  | grep -qiE 'After the feature or closeout diff is reviewed by'; then
  fail "Loop 2 must NOT open with the old per-feature 'feature or closeout diff is reviewed' framing"
fi

if [ "${fails}" -ne 0 ]; then
  printf '\n%d assertion(s) failed — Loop 2 single-end-review doctrine not satisfied.\n' \
    "${fails}" >&2
  exit 1
fi

printf 'PASS: Loop 2 doctrine describes a single end-of-issue review with per-feature verdicts.\n'
