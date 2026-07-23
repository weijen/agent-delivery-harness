#!/usr/bin/env bash
# Structural sensor for retired feature_start enforcement (#370).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKER="${ROOT}/scripts/check-trace-consistency.sh"
SCHEMA="${ROOT}/docs/evaluation/trace-schema.v1.json"

if grep -qF 'feature_start_missing' "${CHECKER}"; then
  printf 'FAIL: checker still emits feature_start_missing\n' >&2
  exit 1
fi

jq -e '.lifecycle_steps | index("feature_start") != null' "${SCHEMA}" >/dev/null \
  || {
    printf 'FAIL: historical feature_start spans are no longer schema-valid\n' >&2
    exit 1
  }

printf 'PASS: feature_start enforcement is retired with schema tolerance.\n'
