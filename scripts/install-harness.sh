#!/usr/bin/env bash
# Stable public harness installation entrypoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install/install-harness.sh" "$@"
