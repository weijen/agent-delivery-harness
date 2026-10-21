#!/usr/bin/env bash
# Compose existing budget-aware gates in one session; independent static work is excluded.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/test-budget-lib.sh
source "$ROOT/scripts/lib/test-budget-lib.sh"
[ "$#" -gt 0 ] || { printf 'Usage: %s <command> [args...]\n' "$0" >&2; exit 2; }
budget_session "$@"
