#!/usr/bin/env bash
# Stable public CI-gated merge entrypoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/lifecycle/merge-pr.sh" "$@"
