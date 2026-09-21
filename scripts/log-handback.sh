#!/usr/bin/env bash
# Stable public semantic writer entrypoint.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/trace/log-handback.sh" "$@"
