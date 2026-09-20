#!/usr/bin/env bash
# Stable public entrypoint; the implementation lives with validation tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/validation/run-sensors.sh" "$@"
