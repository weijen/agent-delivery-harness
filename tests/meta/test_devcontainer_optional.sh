#!/usr/bin/env bash
# Optional devcontainer sensor.
#
# The reusable harness does NOT require a dev container. A project may add one,
# but the harness must not assume project-specific tooling (Azure CLI, Terraform,
# tflint, checkov, Node/pnpm, a pinned Ubuntu base, etc.). This sensor therefore:
#
#   * SKIPS cleanly (exit 0) when no .devcontainer/ exists — the default for an
#     adopting project that has not opted into a container; and
#   * when a .devcontainer/ IS present, only enforces generic, project-agnostic
#     invariants: a devcontainer.json must exist, and any Dockerfile base image
#     must be pinned (no `:latest`).
#
# It deliberately enforces no Azure/Terraform/Node/Foundry pins — those belong to
# a specific product repo, not the harness.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [ ! -d ".devcontainer" ]; then
	echo "no .devcontainer/ — devcontainer is optional, skipping (pass)"
	exit 0
fi

fail=0
note() { echo "✗ $*"; fail=1; }

json_file=".devcontainer/devcontainer.json"
[ -f "$json_file" ] || note "a .devcontainer/ exists but $json_file is missing"

# A pinned, reproducible base image is a generic good practice; `:latest` is not.
for dockerfile in .devcontainer/Dockerfile .devcontainer/*.Dockerfile; do
	[ -f "$dockerfile" ] || continue
	if grep -Eq '^[[:space:]]*FROM[[:space:]].+:latest([[:space:]]|$)' "$dockerfile"; then
		note "$dockerfile uses a :latest base image; pin it to a specific tag"
	fi
done

if [ "$fail" -ne 0 ]; then
	exit 1
fi
echo "devcontainer optional check passed"
