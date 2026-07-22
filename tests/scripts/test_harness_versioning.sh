#!/usr/bin/env bash
# test_harness_versioning.sh — regression sensor for feature harness-versioning
# (issue #153).
#
# The harness stamps every trace span with a `harness.version` identity so
# before/after comparisons across a harness upgrade stay interpretable. Today
# that field carries the git SHA of the harness scripts (see scripts/trace-lib.sh:
# version="$(git -C "$TRACE_LIB_DIR" rev-parse --short HEAD ...)"), which conflates
# "which code" with "which release". This feature introduces an explicit SemVer
# release identity:
#
#   * a top-level VERSION file (SemVer) is the source of truth for harness.version;
#   * scripts/trace-lib.sh reads VERSION (fallback 0.0.0-dev when absent) instead
#     of the git SHA;
#   * a NEW optional span field harness.commit carries the short git SHA (the
#     "which code" signal that harness.version used to carry), typed as a string;
#   * docs/evaluation/trace-schema.v1.json declares harness.commit and drops the
#     "harness.version is the git SHA" claim in favor of release/VERSION semantics;
#   * docs document the versioning/bump policy.
#
# This sensor builds throwaway git-repo fixtures the way test_trace_lib.sh does
# (mktemp + git init, copy scripts/trace-lib.sh in, source under strict mode,
# call trace_span, read the emitted JSONL with jq) and pins the following, all as
# BEHAVIOR/CONTENT (never presence-only):
#
#   1. VERSION file: a top-level VERSION exists and its content is SemVer-shaped
#      (^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$). The shape is asserted, not
#      a specific number, so a later bump doesn't break the sensor.
#   2. harness.version FROM VERSION (behavior): in a hermetic repo whose VERSION
#      holds a distinctive value (9.9.9-test), an emitted span's harness.version
#      equals that VERSION content AND does NOT equal the repo's short HEAD SHA.
#   3. harness.commit (behavior): the same span carries harness.commit equal to the
#      repo's git rev-parse --short HEAD, typed as a JSON string.
#   4. Fallback: in a hermetic repo with NO VERSION file, harness.version is the
#      documented fallback 0.0.0-dev, and harness.commit is still the short SHA.
#   5. Schema: docs/evaluation/trace-schema.v1.json declares
#      .optional_fields["harness.commit"] as a non-empty string doc, and the
#      harness.version semantics note no longer claims it is "the git SHA" — the
#      note must mention VERSION or release (tolerant but real).
#   6. Policy doc: docs/HARNESS.md or README.md documents the versioning/bump
#      policy — flattened grep for VERSION AND (SemVer|version) AND (bump) AND
#      (contract|behaviour|behavior).
#   7. Backward compat: a hermetic trace whose harness.version is a SHA-valued
#      string (abc1234) still validates under scripts/check-trace-consistency.sh (exit 0) —
#      the field stays an open string.
#
# RED-before-green: with no VERSION file, no VERSION-driven stamping, no
# harness.commit, and no schema/policy updates, pins 1–6 fail; pin 7 passes today
# (open-world string field). After implementation the whole sensor passes.
#
# Exit codes: 0 all obligations honored · 1 a contract obligation regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/scripts/trace-lib.sh"
CONTRACT="${ROOT}/docs/evaluation/trace-schema.v1.json"
VALIDATE="${ROOT}/scripts/check-trace-consistency.sh"
VERSION_FILE="${ROOT}/VERSION"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$'

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# jq drives the emitter and every assertion below; hard-require it like the
# sibling trace sensors do.
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to validate harness versioning behavior"

[ -f "$LIB" ] \
  || fail "scripts/trace-lib.sh not found (${LIB})"
[ -f "$CONTRACT" ] \
  || fail "trace schema contract not found (${CONTRACT})"

# Build a throwaway git repo that fakes a harness checkout: scripts/trace-lib.sh
# in place, optionally a VERSION file with a caller-chosen value. Mirrors the
# test_trace_lib.sh fixture bootstrap. Prints the repo's short HEAD SHA.
# Usage: build_repo <dest-dir> [version-content]
build_repo() {
  local dest="$1" version_content="${2-}"
  mkdir -p "${dest}/scripts"
  cp "$LIB" "${dest}/scripts/trace-lib.sh"
  printf 'fixture\n' > "${dest}/README.md"
  if [ "$#" -ge 2 ]; then
    printf '%s\n' "$version_content" > "${dest}/VERSION"
  fi
  (
    cd "$dest"
    git init -q -b main
    git config user.name "Harness Test"
    git config user.email "harness-test@example.invalid"
    git config commit.gpgsign false
    git add -A
    git commit -q -m initial
    git checkout -q -b feature/issue-07-versioning
  )
  git -C "$dest" rev-parse --short HEAD
}

# Source the repo's trace-lib in an isolated subshell, emit one lifecycle span,
# and print the single emitted JSON line. Env is pinned so issue resolution is
# deterministic (TRACE_ISSUE=7 -> issue-07). Runs in a subshell so a re-source
# never leaks TRACE_LIB_DIR into the parent, and cwd stays put.
# Usage: emit_span <repo-dir>
emit_span() {
  local repo="$1"
  (
    cd "$repo"
    export TRACE_ISSUE=7
    unset TRACE_PARENT_SPAN_ID 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${repo}/scripts/trace-lib.sh"
    trace_span lifecycle "harness.lifecycle_step=preflight" "harness.outcome=pass" \
      >/dev/null 2>&1 || true
    cat "${repo}/.copilot-tracking/issues/issue-07/trace.jsonl"
  )
}

# --- Pin 1: VERSION file exists at repo root and is SemVer-shaped --------------
[ -f "$VERSION_FILE" ] \
  || fail "pin 1: top-level VERSION file not found (${VERSION_FILE}) — the SemVer release source of truth for feature harness-versioning (issue #153) is not present yet"
version_seed="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$version_seed" ] \
  || fail "pin 1: VERSION file is empty; expected a SemVer string (e.g. 0.1.0)"
[[ "$version_seed" =~ $SEMVER_RE ]] \
  || fail "pin 1: VERSION content '${version_seed}' is not SemVer-shaped (${SEMVER_RE})"

# --- Pin 2 & 3: harness.version comes from VERSION; harness.commit is the SHA --
REPO_V="${TMP_DIR}/repo-with-version"
SHA_V="$(build_repo "$REPO_V" "9.9.9-test")"
[ -n "$SHA_V" ] || fail "pin 2: could not resolve the fixture repo short HEAD SHA"

line_v="$(emit_span "$REPO_V")"
[ -n "$line_v" ] \
  || fail "pin 2: emitting a span in a VERSION-bearing repo produced no trace line"
printf '%s\n' "$line_v" | jq -e '.' >/dev/null 2>&1 \
  || fail "pin 2: emitted span is not valid JSON: ${line_v}"

got_version="$(printf '%s\n' "$line_v" | jq -r '.["harness.version"]')"
[ "$got_version" = "9.9.9-test" ] \
  || fail "pin 2: harness.version must come from the VERSION file '9.9.9-test', got '${got_version}' (still stamping the git SHA?)"
[ "$got_version" != "$SHA_V" ] \
  || fail "pin 2: harness.version must NOT equal the repo short HEAD SHA '${SHA_V}' when a VERSION file is present"

# pin 3: harness.commit carries the short SHA, typed as a JSON string.
printf '%s\n' "$line_v" | jq -e '(.["harness.commit"] | type) == "string"' >/dev/null 2>&1 \
  || fail "pin 3: harness.commit is missing or not a JSON string: ${line_v}"
got_commit="$(printf '%s\n' "$line_v" | jq -r '.["harness.commit"]')"
[ "$got_commit" = "$SHA_V" ] \
  || fail "pin 3: harness.commit must equal the repo short HEAD SHA '${SHA_V}', got '${got_commit}'"

# --- Pin 4: fallback 0.0.0-dev when no VERSION file; commit still the SHA ------
REPO_NV="${TMP_DIR}/repo-no-version"
SHA_NV="$(build_repo "$REPO_NV")"
[ -n "$SHA_NV" ] || fail "pin 4: could not resolve the no-VERSION fixture repo short HEAD SHA"
[ ! -f "${REPO_NV}/VERSION" ] || fail "pin 4: the no-VERSION fixture unexpectedly has a VERSION file"

line_nv="$(emit_span "$REPO_NV")"
[ -n "$line_nv" ] \
  || fail "pin 4: emitting a span in a repo with no VERSION produced no trace line"
got_version_nv="$(printf '%s\n' "$line_nv" | jq -r '.["harness.version"]')"
[ "$got_version_nv" = "0.0.0-dev" ] \
  || fail "pin 4: with no VERSION file, harness.version must fall back to '0.0.0-dev', got '${got_version_nv}'"
got_commit_nv="$(printf '%s\n' "$line_nv" | jq -r '.["harness.commit"] // ""')"
[ "$got_commit_nv" = "$SHA_NV" ] \
  || fail "pin 4: harness.commit must still be the short SHA '${SHA_NV}' under the fallback, got '${got_commit_nv}'"

# --- Pin 5: schema declares harness.commit and drops the "git SHA" claim -------
# Feed valid JSON (null) as stdin: the assertion reads the contract via
# --slurpfile and ignores the input document, but a non-`-n` jq must still parse
# stdin — invalid input (e.g. a bare `x`) aborts jq >= 1.8 before the filter runs.
printf 'null\n' | jq -e --slurpfile c "$CONTRACT" '
    ($c[0].optional_fields["harness.commit"] // "") as $doc
    | ($doc | type) == "string" and ($doc | length) > 0
  ' >/dev/null 2>&1 \
  || fail "pin 5: schema does not declare .optional_fields[\"harness.commit\"] as a non-empty string doc"

harness_version_note="$(jq -r '.notes.harness_version // ""' "$CONTRACT")"
[ -n "$harness_version_note" ] \
  || fail "pin 5: schema note .notes.harness_version is missing"
printf '%s\n' "$harness_version_note" | grep -qiE 'version file|release' \
  || fail "pin 5: the harness.version note must describe VERSION/release semantics (no longer solely 'the git SHA'); got: ${harness_version_note}"

# --- Pin 6: versioning/bump policy is documented ------------------------------
policy_blob="${TMP_DIR}/policy.txt"
: > "$policy_blob"
for doc in "${ROOT}/docs/HARNESS.md" "${ROOT}/README.md"; do
  [ -f "$doc" ] && cat "$doc" >> "$policy_blob"
done
grep -q 'VERSION' "$policy_blob" \
  || fail "pin 6: no versioning policy documented — expected a VERSION reference in docs/HARNESS.md or README.md"
grep -qiE 'semver|version' "$policy_blob" \
  || fail "pin 6: versioning policy must mention SemVer/version"
grep -qi 'bump' "$policy_blob" \
  || fail "pin 6: versioning policy must document how/when to bump the version"
grep -qiE 'contract|behaviou?r' "$policy_blob" \
  || fail "pin 6: versioning policy must tie a bump to a contract/behavior change"

# --- Pin 7: a SHA-valued harness.version still validates (open string) ---------
# Backward compatibility: an old trace stamped with a git-SHA harness.version must
# still pass scripts/check-trace-consistency.sh. Place it at the contract-shaped path so no
# location warning muddies the result; a lone preflight span leaves the trace
# unfinished, so the completeness pass is skipped (exit 0 expected).
[ -x "$VALIDATE" ] || [ -f "$VALIDATE" ] \
  || fail "pin 7: scripts/check-trace-consistency.sh not found (${VALIDATE})"
COMPAT_DIR="${TMP_DIR}/.copilot-tracking/issues/issue-07"
mkdir -p "$COMPAT_DIR"
COMPAT_TRACE="${COMPAT_DIR}/trace.jsonl"
printf '# Progress\n\n## Action Log\n' > "${COMPAT_DIR}/progress.md"
jq -cn '{
    schema_version: 1,
    timestamp: "2026-07-04T12:00:00Z",
    span: "lifecycle",
    "harness.issue": 7,
    "harness.version": "abc1234",
    "harness.lifecycle_step": "preflight",
    "harness.outcome": "pass"
  }' > "$COMPAT_TRACE"

if ! bash "$VALIDATE" "$COMPAT_TRACE" >/dev/null 2>&1; then
  fail "pin 7: a trace with a SHA-valued harness.version ('abc1234') must still validate (exit 0); scripts/check-trace-consistency.sh rejected it"
fi

printf 'PASS: %s\n' "$(basename "$0")"
