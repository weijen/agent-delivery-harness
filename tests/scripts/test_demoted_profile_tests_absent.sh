#!/usr/bin/env bash
# Regression sensor (issue #274, feature tests-updated): the per-language
# profile tests for the demoted languages must be gone, and the multi-surface
# init fixture must no longer exercise go/java/ruby surfaces (those descriptors
# no longer ship, so init.sh cannot detect them).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

# --- 1. The demoted per-language profile tests are gone. ----------------------
for lang in go java ruby; do
  [ -e "tests/scripts/test_${lang}_profile.sh" ] \
    && note "tests/scripts/test_${lang}_profile.sh must be deleted (demoted language)"
done

# --- 2. The shipped-set interface + generator tests remain. -------------------
for keep in tests/scripts/test_profiles.sh tests/scripts/test_node_profile.sh \
            tests/scripts/test_scaffold_language.sh; do
  [ -f "$keep" ] || note "$keep must remain"
done

# --- 3. The multi-surface init fixture no longer references demoted surfaces. --
fixture="tests/scripts/test_init_gates.sh"
if [ -f "$fixture" ]; then
  for token in 'go.mod' 'Gemfile' 'pom.xml' 'Go surface detected' \
               'Ruby surface detected' 'Java surface detected'; do
    grep -Fq "$token" "$fixture" \
      && note "$fixture must not reference demoted surface token: '$token'"
  done
  # The retained surfaces must still be asserted.
  for token in 'Python surface detected' 'Node surface detected' \
               'Terraform surface detected'; do
    grep -Fq "$token" "$fixture" \
      || note "$fixture must keep asserting the retained surface: '$token'"
  done
fi

if [ "$fail" -ne 0 ]; then
  echo "demoted-profile-tests-absent sensor FAILED"
  exit 1
fi
echo "demoted-profile-tests-absent sensor passed"
