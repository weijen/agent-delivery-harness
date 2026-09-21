#!/usr/bin/env bash
# Stable public preflight entrypoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/lifecycle/init.sh" "$@"
