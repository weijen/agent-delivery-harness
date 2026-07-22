#!/usr/bin/env bash
# test_evaluation_archive_layout.sh — regression sensor for issue #337
# feature `archive-evaluation-docs` (epic #331, decision 3a).
#
# docs/evaluation/ archived the zero-runtime-reference L1+ eval-platform prose
# into docs/archive/evaluation/ (mirroring the old relative subtree layout),
# left a tombstone README pointing at #331, and repaired every markdown
# hyperlink the move crossed. This sensor pins that layout so a future PR
# cannot silently re-inflate docs/evaluation/ or leave a dangling link.
#
# Contract under test:
#   1. Every archived relative path is ABSENT from docs/evaluation/ and
#      PRESENT under docs/archive/evaluation/ (same relative subtree).
#   2. docs/archive/evaluation/README.md exists and names both the epic (#331)
#      and that the content was archived.
#   3. A generic relative-link resolver proves every non-http(s) markdown
#      hyperlink in the boundary-crossing docs (and every *.md file under the
#      archive, recursively) resolves to a real file — this single pass
#      covers both the boundary-crossing link fixes and the archive-internal
#      links that must keep working after the move.
#   4. The boundary sensor that hard-gates a moved file by path
#      (test_trace_schema_docs.sh) still passes once retargeted — proves the
#      move did not regress a pre-existing green gate. (The three dedicated
#      archived-content sensors this list once carried were deleted under
#      #337 feature retarget-archive-sensors: archived prose is no longer
#      content-gated.)
#   5. Every path in the kept trace-schema.v1.json
#      `.redaction.authorities[]` array resolves to a real file. Those two
#      schema files stayed in docs/evaluation/ (preserved set) but their
#      embedded authority pointers name files that the move relocated, so a
#      move that only checks filenames (steps 1-4 above) can leave a
#      dangling authority pointer undetected.
#
# RED before the move: docs/archive/evaluation/README.md is absent.
# GREEN after the move + link repair + sensor retargeting.
#
# Exit codes: 0 archive layout honored · 1 a layout/link/sensor obligation
# regressed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

# --- 1. Archived set: absent from docs/evaluation/, present under the archive
archived_paths=(
  agent-delivery-accuracy-matrix.md
  agent-delivery-accuracy-matrix.v1.json
  azure-evaluation-runtime.md
  dashboards/README.md
  dashboards/workbook-redesign.md
  dataset-governance.md
  evaluation-matrix.md
  failure-review-template.md
  feature-breakdown-evals.md
  judge-evaluation.md
  mutation-evals.md
  outcome-evals.md
  research-notes.md
  script-lifecycle-evals.md
  security-evals.md
  skill-evals.md
  statistical-methodology.md
  subagent-role-evals.md
  telemetry-retention-pii.md
  trace-action-log-evals.md
  trajectory-evals.md
)

for rel in "${archived_paths[@]}"; do
  [ ! -e "docs/evaluation/${rel}" ] \
    || fail "docs/evaluation/${rel} must be absent (archived by #337/#331)"
  [ -e "docs/archive/evaluation/${rel}" ] \
    || fail "docs/archive/evaluation/${rel} must exist — archived subtree must mirror the old relative layout"
done

# Preserved set stays live-referenced (runtime-referenced or L0/l1-solution) —
# must NOT have moved. trace-scorecard.v1.json is intentionally absent: issue
# #335 retired it together with its sole consumer after #337 landed.
preserved_paths=(
  README.md
  cost-efficiency-evals.md
  failure-mode-taxonomy.md
  meta-test-triage.md
  observability-and-trace-schema.md
  product-quality-rubric.md
  trace-schema.v1.json
  trace-summary.v1.json
  l0-solution/README.md
  l0-solution/architecture.md
  l0-solution/implementation-issues.md
  l0-solution/spec.md
  l1-solution/README.md
  l1-solution/architecture.md
  l1-solution/implementation-issues.md
  l1-solution/public-dataset-seeds.md
  l1-solution/spec.md
)
for rel in "${preserved_paths[@]}"; do
  [ -e "docs/evaluation/${rel}" ] \
    || fail "docs/evaluation/${rel} must stay in place (live runtime/doctrine reference or L0/l1-solution asset)"
done

# --- 2. Tombstone README names the epic and the archival ---------------------
TOMBSTONE="docs/archive/evaluation/README.md"
if [ -f "$TOMBSTONE" ]; then
  grep -qF '#331' "$TOMBSTONE" \
    || fail "${TOMBSTONE} must name epic #331"
  grep -qiE 'archiv' "$TOMBSTONE" \
    || fail "${TOMBSTONE} must state that this content was archived"
else
  fail "${TOMBSTONE} not found — the archive move must leave a tombstone README"
fi

# --- 3. Generic relative-link resolver ---------------------------------------
# Extracts ](target) markdown link targets that are not http(s)/mailto, strips
# any #fragment, and resolves each relative to the linking file's directory.
check_links_in_file() {
  local file="$1"
  local dir target resolved
  dir="$(dirname "$file")"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    case "$target" in
      http://* | https://* | mailto:*) continue ;;
    esac
    target="${target%%#*}"
    [ -n "$target" ] || continue
    resolved="${dir}/${target}"
    if [ ! -e "$resolved" ]; then
      fail "${file}: broken relative link -> ${target} (resolved: ${resolved})"
    fi
  done < <(grep -oE '\]\([^)[:space:]]+\)' "$file" | sed -E 's/^\]\((.*)\)$/\1/')
}

link_check_files=(
  docs/evaluation/README.md
  docs/evaluation/cost-efficiency-evals.md
  docs/evaluation/observability-and-trace-schema.md
  infra/terraform/README.md
  tests/evals/fixtures/traces/README.md
)
for f in "${link_check_files[@]}"; do
  [ -f "$f" ] || { fail "expected link-checked file missing: ${f}"; continue; }
  check_links_in_file "$f"
done

while IFS= read -r -d '' archived_md; do
  check_links_in_file "$archived_md"
done < <(find docs/archive/evaluation -type f -name '*.md' -print0 | sort -z)

# --- 4. The retargeted, path-coupled boundary sensor stays green -------------
retargeted_sensors=(
  tests/scripts/test_trace_schema_docs.sh
)
for sensor in "${retargeted_sensors[@]}"; do
  if [ -x "$sensor" ] || [ -f "$sensor" ]; then
    if ! bash "$sensor" >/dev/null 2>&1; then
      fail "${sensor} must stay green after the archive move (retarget its docs/evaluation path constant)"
    fi
  else
    fail "retargeted sensor missing: ${sensor}"
  fi
done

# --- 5. Redaction authority pointers in the kept schemas resolve ------------
# trace-schema.v1.json did not move, but the move
# relocated the files their .redaction.authorities[] pointers name. Checking
# only that the pointer strings match a filename (as steps 1-4 do) would miss
# a pointer left aimed at the pre-move docs/evaluation/ location, so this
# resolves each authority path against the repo root and requires it to exist.
authority_schemas=(
  docs/evaluation/trace-schema.v1.json
)
for schema in "${authority_schemas[@]}"; do
  [ -f "$schema" ] || { fail "expected authority schema missing: ${schema}"; continue; }
  while IFS= read -r authority; do
    [ -n "$authority" ] || continue
    [ -e "$authority" ] \
      || fail "${schema}: .redaction.authorities[] entry '${authority}' does not resolve to a real file"
  done < <(jq -r '.redaction.authorities[]' "$schema")
done

if [ "$fails" -ne 0 ]; then
  printf '\n%d evaluation-archive-layout violation(s).\n' "$fails" >&2
  exit 1
fi
echo "docs/evaluation archive layout, tombstone, links, and retargeted sensors verified"
