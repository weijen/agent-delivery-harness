#!/usr/bin/env bash
# Check the shared source/installed shell surface without executing sensors.
set -euo pipefail

case "${1:-}" in
  syntax|lint) MODE="$1" ;;
  *) printf 'usage: check-shell.sh syntax|lint\n' >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { printf 'check-shell.sh: expected one mode\n' >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
roots=()
for directory in scripts profiles tests/scripts tests/meta tests/evals/bin optional/runtime-adapters; do
  [ ! -d "$directory" ] || roots+=("$directory")
done
[ "${#roots[@]}" -gt 0 ] || { printf 'check-shell.sh: no shell roots found\n' >&2; exit 1; }
if ! discovered="$(find "${roots[@]}" -type d -name fixtures -prune -o \
  -type f -name '*.sh' -print | LC_ALL=C sort -u)"; then
  printf 'check-shell.sh: shell discovery failed\n' >&2
  exit 1
fi
[ -n "$discovered" ] || { printf 'check-shell.sh: no shell files found\n' >&2; exit 1; }
mapfile -t files <<< "$discovered"
if [ "$MODE" = syntax ]; then
  for file in "${files[@]}"; do
    bash -n "$file"
  done
else
  shellcheck -x "${files[@]}"
fi
