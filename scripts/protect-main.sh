#!/usr/bin/env bash
# protect-main.sh — apply branch protection to `main` as code (idempotent).
#
# Encodes the enforcement decision: failing CI must block merge.
# Re-running converges `main` to the same protected state, so this is the
# reproducible source of truth — never click-ops.
#
# Required status checks (must match the CI check-run contexts exactly):
#   - "lint · markdown"   (the docs-era contract; bump this once Python lands)
#
# Strict mode (branch must be up to date) ON; enforce_admins ON; no required
# reviews (single-maintainer repo — CI is the gate).
#
# Usage:
#   ./scripts/protect-main.sh                       # apply to the current repo
#   REPO=owner/name ./scripts/protect-main.sh       # target an explicit repo
#   DRY_RUN=1 ./scripts/protect-main.sh             # print the payload, change nothing
#
# Exit codes: 0 applied (or dry-run printed) · 1 precondition failed

set -euo pipefail

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

BRANCH="main"

# Required CI check-run contexts. Keep in lockstep with .github/workflows/ci.yml
# job NAMES (not job ids) — those are the contexts GitHub reports per commit.
CONTEXTS=(
  "lint · markdown"
)

command -v gh >/dev/null 2>&1 || { red "✗ gh CLI not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { red "✗ jq not found"; exit 1; }

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
[ -n "$REPO" ] || { red "✗ could not determine repo (set REPO=owner/name)"; exit 1; }

# Build the protection payload. The checks array uses {context} entries so the
# same contexts are required regardless of which app reports them.
checks_json="$(printf '%s\n' "${CONTEXTS[@]}" | jq -R '{context: .}' | jq -s '.')"
payload="$(jq -n --argjson checks "$checks_json" '{
  required_status_checks: { strict: true, checks: $checks },
  enforce_admins: true,
  required_pull_request_reviews: null,
  restrictions: null,
  required_linear_history: false,
  allow_force_pushes: false,
  allow_deletions: false
}')"

bold "==> Protecting ${REPO}@${BRANCH}"
printf '%s\n' "${CONTEXTS[@]}" | sed 's/^/  required check: /'

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "--- payload (dry run) ---"
  echo "$payload"
  green "✓ Dry run — no changes made."
  exit 0
fi

echo "$payload" | gh api -X PUT \
  -H "Accept: application/vnd.github+json" \
  "repos/${REPO}/branches/${BRANCH}/protection" \
  --input - >/dev/null

green "✓ Branch protection applied to ${REPO}@${BRANCH}"
echo "  strict up-to-date: on · enforce_admins: on · required reviews: off"
