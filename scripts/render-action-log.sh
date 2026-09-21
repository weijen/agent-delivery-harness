#!/usr/bin/env bash
# Stable public Action Log renderer entrypoint.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/trace/render-action-log.sh" "$@"
