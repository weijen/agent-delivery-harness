#!/usr/bin/env bash
# Stable public PR preparation and publication entrypoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/lifecycle/create-pr.sh" "$@"
