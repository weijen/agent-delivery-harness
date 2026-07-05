#!/usr/bin/env bash
# Regression sensor (issue #115, feature tf-state-secret-hygiene): the root
# .gitignore must keep Terraform state, provider caches, and real tfvars out of
# git while explicitly KEEPING the committed dependency lock file and the
# non-secret tfvars example (conductor-resolved: .terraform.lock.hcl IS
# committed, not ignored). Also proves no state/tfvars file is already tracked.
# Static git-only sensor — no terraform binary required (CI has none).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

# --- 1. Paths that MUST be ignored -------------------------------------------
# git check-ignore works on hypothetical paths; the files need not exist.
must_ignore=(
	"infra/terraform/.terraform/providers/x"
	"infra/terraform/terraform.tfstate"
	"infra/terraform/dev.tfvars"
)
for p in "${must_ignore[@]}"; do
	if ! git check-ignore -q -- "$p"; then
		note "not gitignored (state/secret leak surface): $p"
	fi
done

# --- 2. Paths that must NOT be ignored ----------------------------------------
# The tfvars example is the documented non-secret template; the dependency lock
# file is committed for reproducible provider pins (conductor decision on plan
# Open Question 1). Neither may be swallowed by the *.tfvars / .terraform globs.
must_keep=(
	"infra/terraform/terraform.tfvars.example"
	"infra/terraform/.terraform.lock.hcl"
)
for p in "${must_keep[@]}"; do
	if git check-ignore -q -- "$p"; then
		note "must stay committable but is gitignored: $p"
	fi
done

# --- 3. Nothing state/secret-shaped is already tracked -------------------------
tracked_state="$(git ls-files -- '*.tfstate' '*.tfstate.*')"
if [ -n "$tracked_state" ]; then
	note "tracked terraform state file(s): $tracked_state"
fi

tracked_tfvars="$(git ls-files -- '*.tfvars' | grep -v '\.tfvars\.example$' || true)"
if [ -n "$tracked_tfvars" ]; then
	note "tracked non-example tfvars file(s): $tracked_tfvars"
fi

if [ "$fail" -ne 0 ]; then
	echo "terraform state/secret hygiene sensor FAILED"
	exit 1
fi
echo "terraform state/secret hygiene checks passed"
