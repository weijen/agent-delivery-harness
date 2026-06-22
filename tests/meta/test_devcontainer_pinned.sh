#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

json_file=".devcontainer/devcontainer.json"
dockerfile=".devcontainer/Dockerfile"

[ -f "$json_file" ] || { echo "missing $json_file"; exit 1; }
[ -f "$dockerfile" ] || { echo "missing $dockerfile"; exit 1; }

# Base image must be pinned and must not use latest.
grep -Eq '^FROM mcr\.microsoft\.com/devcontainers/base:ubuntu-24\.04$' "$dockerfile"
if grep -Eq '^FROM .+:latest$' "$dockerfile"; then
	echo "base image must not use latest tag"
	exit 1
fi

# postCreateCommand must call init via the postCreate script.
grep -Eq '"postCreateCommand"\s*:\s*"bash \.devcontainer/postCreate\.sh"' "$json_file"
grep -Eq 'ALLOW_GH_UNAUTH=1 ./init\.sh' .devcontainer/postCreate.sh

# Required CLI install markers in Dockerfile/postCreate config.
grep -Eq '\bgh\b' "$dockerfile"
grep -Eq '\bazure-cli\b' "$dockerfile"
grep -Eq '\bjq\b' "$dockerfile"
grep -Eq '\bshellcheck\b' "$dockerfile"
grep -Eq '\bterraform\b' "$dockerfile"
grep -Eq '\btflint\b' "$dockerfile"
grep -Eq '\bcheckov\b' "$dockerfile"
grep -Eq '\buv\b' "$dockerfile"
grep -Eq 'ghcr\.io/devcontainers/features/node:1' "$json_file"
grep -Eq 'corepack prepare pnpm@' .devcontainer/postCreate.sh
# markdownlint is optional docs hygiene, not a required harness tool, so the devcontainer
# is not required to pin markdownlint-cli2. (See docs/HARNESS.md § Gates And Sensors.)

echo "devcontainer regression checks passed"
