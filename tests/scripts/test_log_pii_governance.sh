#!/usr/bin/env bash
# test_log_pii_governance.sh — regression sensor for the step-level log PII
# governance clause (issue #219, feature log-pii-governance).
#
# Contract under test (PINNED HERE as the executable spec):
#
#   L — docs/evaluation/telemetry-retention-pii.md documents the step-level
#       log (`log.jsonl`) as its own PII surface, distinct from exported
#       telemetry:
#   L1. It names BOTH `message` AND `payload` as excluded / redacted
#       free-text fields of the step-level log — asserted in a log-PII
#       context (anchored to a `log.jsonl` / step-level-log heading or row),
#       not merely anywhere in the page.
#   L2. It states `log.jsonl` is LOCAL-ONLY — gitignored / never part of the
#       remote export window — near the log-field context.
#
# RED until the doc grows a log.jsonl / message / payload governance clause.
#
# Exit codes: 0 spec contract honored · 1 an obligation regressed (the doc
# lacks the log-PII governance clause — RED gate for this feature).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOC="${ROOT}/docs/evaluation/telemetry-retention-pii.md"

fails=0
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  fails=$((fails + 1))
}

finish() {
  if [ "$fails" -ne 0 ]; then
    printf '\n%d step-level log PII governance contract violation(s).\n' "$fails" >&2
    exit 1
  fi
  printf 'step-level log PII governance contract honored\n'
  exit 0
}

if [ ! -f "$DOC" ]; then
  fail "spec doc not found (${DOC}) — feature log-pii-governance (issue #219) has no doc to govern"
  finish
fi

# The log-PII clause lives in one region of the page. Isolate that region so
# the field/local-only pins are anchored to the log.jsonl context rather than
# passing on an unrelated mention elsewhere. The region is delimited by the
# first line that references the step-level log up to the next top-level (##)
# heading. It is flattened (newlines -> spaces) so a phrase wrapped across
# markdown lines cannot dodge a multi-word pin.
REGION="$(awk '
  tolower($0) ~ /log\.jsonl|step-level log/ { grabbing = 1 }
  grabbing && /^## / && collected { exit }
  grabbing { print; collected = 1 }
' "$DOC" | tr '\n' ' ')"

if [ -z "$REGION" ]; then
  fail "doc has no step-level log (log.jsonl / 'step-level log') section — the log-PII governance clause is absent (L1/L2)"
  finish
fi

# --- L1. Both free-text log fields named in the log-PII context ---------------
grep -qiE '\bmessage\b' <<<"$REGION" \
  || fail "doc must name the excluded free-text log field 'message' in the log.jsonl context (L1)"
grep -qiE '\bpayload\b' <<<"$REGION" \
  || fail "doc must name the excluded free-text log field 'payload' in the log.jsonl context (L1)"

# The context must be an exclusion/redaction one, not a passing mention.
grep -qiE 'exclud|redact|never ship|not (export|ship)|stripped|omit' <<<"$REGION" \
  || fail "doc must frame message/payload as excluded/redacted free-text fields, not merely mention them (L1)"

# --- L2. log.jsonl is local-only / never exported to the remote window --------
grep -qiE 'local[- ]only|gitignore|never (part of|export)|not (part of|export)|stays? on the machine|does not ship' <<<"$REGION" \
  || fail "doc must state log.jsonl is local-only (gitignored / never part of the remote export window) (L2)"

finish
