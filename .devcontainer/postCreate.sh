#!/usr/bin/env bash
set -euo pipefail

# Ensure pnpm is available from the Node feature via corepack.
corepack enable
corepack prepare pnpm@10.12.1 --activate

# Install markdownlint-cli2 with a pinned version.
sudo npm install -g markdownlint-cli2@0.15.0

# In fresh devcontainers, allow gh auth to be completed as a follow-up step.
ALLOW_GH_UNAUTH=1 ./init.sh

# Startup smoke prints to surface version drift in build logs.
node --version
pnpm --version
uv --version
az --version
gh --version
