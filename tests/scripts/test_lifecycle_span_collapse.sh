#!/usr/bin/env bash
# Aggregate behavioral sensor for lifecycle child-span collapse (#370).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bash "${ROOT}/tests/scripts/test_trace_create_pr.sh"
bash "${ROOT}/tests/scripts/test_trace_finish_issue.sh"

printf 'PASS: create-pr and finish collapse child spans into lifecycle parents.\n'
