#!/usr/bin/env bash
# Stable public language profile scaffolding entrypoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/install/scaffold-language.sh" "$@"
