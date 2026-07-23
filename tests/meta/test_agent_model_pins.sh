#!/usr/bin/env bash
# Regression sensor (issue #184, #173 drift-sensor pattern): subagent model pins.
#
# A `model:` pin in an agent's frontmatter rots — when the Copilot model lineup
# moves on, an unknown pin either silently falls back to a default or fails to
# launch, both invisible to the conductor (issue #184, report A-X6). Policy
# (decided with the human): the subagents inherit the session model; no agent
# frontmatter carries a `model:` pin.
#
# Two directions, both must hold:
#   1. No stranded pin — no `.copilot/agents/*.agent.md` frontmatter carries a
#      `model:` key. All subagents inherit the session model.
#   2. Documented drift guard — the sync-docs skill names stale model-pin
#      frontmatter as a high-rot pattern, so a future model generation that
#      re-introduces a pin is caught by the docs-hygiene surface, not silently.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

agents_dir=".copilot/agents"
sync_docs=".copilot/skills/sync-docs/SKILL.md"

fail=0
note() { echo "✗ $*"; fail=1; }

# --- Direction 1: no agent frontmatter carries a model: pin ---------------------
for f in "${agents_dir}"/*.agent.md; do
  [ -f "$f" ] || continue
  # Read only the frontmatter block (between the first and second `---`).
  frontmatter="$(awk 'NR==1 && $0=="---"{inb=1; next} inb && $0=="---"{exit} inb{print}' "$f")"
  if printf '%s\n' "$frontmatter" | grep -qE '^[[:space:]]*model:'; then
    pin="$(printf '%s\n' "$frontmatter" | grep -E '^[[:space:]]*model:' | head -1)"
    note "${f} frontmatter pins a model ('${pin# }') — remove it so the subagent inherits the session model"
  fi
done

# --- Direction 2: sync-docs documents stale model-pin frontmatter as high-rot ---
[ -f "$sync_docs" ] || { echo "✗ missing $sync_docs"; exit 1; }
if ! grep -qiE 'model[- ]pin' "$sync_docs"; then
  note "${sync_docs} does not name stale model-pin frontmatter as a high-rot pattern (add it so pin drift is caught)"
fi

if [ "$fail" -ne 0 ]; then
  echo "agent model-pin sensor FAILED"
  exit 1
fi
echo "agent model-pin checks passed"

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

shared=".copilot/skills/_audit-conventions.md"
skills_dir=".copilot/skills"
audit_skills=(find-brute-force find-duplicates find-over-design dead-code-detection)

[ -f "$shared" ] || note "missing $shared"
if [ -f "$shared" ]; then
  first_line="$(sed -n '1p' "$shared")"
  [ "$first_line" != '---' ] || note "$shared must not have YAML frontmatter"
fi

for skill in "${audit_skills[@]}"; do
  f="${skills_dir}/${skill}/SKILL.md"
  [ -f "$f" ] || { note "missing $f"; continue; }
  grep -q '_audit-conventions.md' "$f" || note "$f must reference _audit-conventions.md"
  if grep -Eq 'Score every .* on five dimensions|High / Medium / Low' "$f"; then
    note "$f still contains the old 5-dimension H/M/L grading matrix"
  fi
done

for skill in find-brute-force find-duplicates find-over-design; do
  f="${skills_dir}/${skill}/SKILL.md"
  [ -f "$f" ] || continue
  if grep -Eq '^## Remediation Plan Template|^# Plan: ' "$f"; then
    note "$f still contains a remediation plan template block"
  fi
done

dc="${skills_dir}/dead-code-detection/SKILL.md"
if [ -f "$dc" ]; then
  grep -q 'Default to Defer-protect' "$dc" || note "$dc lost the public-API Defer-protect default"
  grep -q 'public APIs, exported' "$dc" || note "$dc lost the public/exported API protection wording"
fi

if [ "$fail" -ne 0 ]; then
  echo "audit-conventions shared sensor FAILED"
  exit 1
fi

echo "audit-conventions shared checks passed"
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review=".copilot/agents/code-review-subagent.agent.md"

if [ ! -f "$review" ]; then
  note "missing $review"
  echo "code-review public-exposure sensor FAILED"
  exit 1
fi

# References the new skill by path and by name.
grep -Eq 'skills/public-exposure-audit/SKILL\.md' "$review" \
  || note "$review must link the public-exposure-audit SKILL.md"
grep -Eq 'public-exposure-audit' "$review" \
  || note "$review must reference public-exposure-audit by name"

# Scopes the check to pre-commit / pre-PR review.
grep -Eiq 'pre-commit' "$review" || note "$review must scope exposure check to pre-commit changes"
grep -Eiq 'pre-PR'     "$review" || note "$review must scope exposure check to pre-PR changes"

# Names the AC#4 review targets.
for target in 'public repo' 'docs' 'prompts' 'skills' 'agents' 'workflows' 'fixtures' 'logs' 'generated'; do
  grep -Eiq "$target" "$review" || note "$review must name review target: $target"
done

# AC#5 — customer-supplied material etc. is BLOCKING in pushed/soon-to-be-pushed content.
grep -Eiq 'raw media|screenshots|decks|exports' "$review" \
  || note "$review must name customer-supplied material (raw media/screenshots/decks/exports) as a blocking class"
grep -Eiq 'tenant|subscription' "$review" || note "$review must name tenant/subscription IDs as a blocking class"
grep -Eiq 'endpoint' "$review"            || note "$review must name resource endpoints as a blocking class"
grep -Eiq 'environment file|\.env'  "$review" || note "$review must name local environment files as a blocking class"
grep -Eiq 'pushed|soon-to-be-pushed' "$review" \
  || note "$review must scope the blocking rule to pushed/soon-to-be-pushed content"

# The exposure rule must be associated with BLOCKING somewhere in the file.
grep -Eq 'BLOCKING' "$review" || note "$review must mark public-exposure findings as BLOCKING"

if [ "$fail" -ne 0 ]; then
  echo "code-review public-exposure sensor FAILED"
  exit 1
fi
echo "code-review public-exposure checks passed"
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review=".copilot/agents/code-review-subagent.agent.md"

if [ ! -f "$review" ]; then
  note "missing $review"
  echo "code-review trace-evidence sensor FAILED"
  exit 1
fi

section="$({ awk '
  /Trace \/ Process Evidence/ { in_section=1 }
  in_section { print }
  in_section && /^##[[:space:]]+/ && !/Trace \/ Process Evidence/ { exit }
' "$review" || true; } )"

assert_file() {
  local pattern="$1"
  local message="$2"
  grep -Eiq "$pattern" "$review" || note "$message"
}

assert_section() {
  local pattern="$1"
  local message="$2"
  local normalized_section
  normalized_section="$(printf '%s\n' "$section" | tr '\n' ' ')"
  if ! grep -Eiq "$pattern" <<<"$normalized_section"; then
    note "$message"
  fi
}

reject_section() {
  local pattern="$1"
  local message="$2"
  local normalized_section
  normalized_section="$(printf '%s\n' "$section" | tr '\n' ' ')"
  if grep -Eiq "$pattern" <<<"$normalized_section"; then
    note "$message"
  fi
}

# 1. Required section heading.
assert_file 'Trace / Process Evidence' "$review must include a Trace / Process Evidence section"

# 2. Local trace artifacts to locate/read.
assert_section 'trace\.jsonl' "$review Trace / Process Evidence section must name trace.jsonl"
assert_section 'trace-summary\.json' "$review Trace / Process Evidence section must name trace-summary.json"

# 3. Trace tooling to run when a local trace exists.
assert_section 'check-trace-consistency\.sh' "$review Trace / Process Evidence section must name check-trace-consistency.sh"

# 4. Trace coverage reporting semantics.
assert_section 'has_tool_spans' "$review Trace / Process Evidence section must report has_tool_spans"
assert_section 'instrumentation.*absent|absent.*instrumentation' "$review Trace / Process Evidence section must state false means instrumentation absent"
assert_section 'tokens' "$review Trace / Process Evidence section must report token coverage"
assert_section 'unavailable' "$review Trace / Process Evidence section must define unavailable token semantics"
assert_section 'schema' "$review Trace / Process Evidence section must mention schema validation"

# 5. Contract-v2 current evidence set.
assert_section 'gate[_ -]?start' "$review Trace / Process Evidence section must name gate_start"
assert_section 'gate[_ -]?sensors' "$review Trace / Process Evidence section must name gate_sensors"
assert_section 'gate[_ -]?review' "$review Trace / Process Evidence section must name gate_review"
assert_section 'gate[_ -]?merge[_ -]?closeout' "$review Trace / Process Evidence section must name gate_merge_closeout"
assert_section 'SENSORS.*head=.*scope=.*ran=.*failed=' "$review Trace / Process Evidence section must require HEAD-bound feature green evidence"
assert_section 'review_verdict' "$review Trace / Process Evidence section must inspect review_verdict evidence"
assert_section 'deviation' "$review Trace / Process Evidence section must inspect deviation evidence"

# 6. Retired handbacks remain reader-compatible history, never current blocking evidence.
assert_section 'historical' "$review Trace / Process Evidence section must identify historical trace compatibility"
assert_section 'reader' "$review Trace / Process Evidence section must make historical compatibility reader-side"
reject_section 'Verify .*red_handback.*impl_handback.*green_handback.*ordering' \
  "$review Trace / Process Evidence section must not require the retired handback triple"
reject_section 'red_first_(ordering_absent|profile_mismatch).*(BLOCKING|blocking)' \
  "$review Trace / Process Evidence section must not block current reviews on retired red-first checks"

# 7. Unavailable evidence handling.
assert_section 'trace evidence unavailable' "$review Trace / Process Evidence section must use the phrase trace evidence unavailable"

# 8. Blocking process violations and review finding terms.
assert_section 'deviation' "$review Trace / Process Evidence section must surface deviations as review findings"
assert_section 'loop' "$review Trace / Process Evidence section must surface loop findings"
assert_section 'BLOCKING' "$review Trace / Process Evidence section must mark process violations BLOCKING"

# 9. Process discipline is separate from implementation correctness.
assert_section 'does not prove|not prove' "$review Trace / Process Evidence section must state trace discipline does not prove correctness"
assert_section 'process violation' "$review Trace / Process Evidence section must state clean code does not excuse process violations"

# 10. Process violations feed into verdict.
assert_section 'NEEDS_REVISION|BLOCKED|verdict' "$review Trace / Process Evidence section must tie process violations to NEEDS_REVISION/verdict/BLOCKED"

# 11. Log-detail citation for BLOCKING/CRITICAL process findings (issue #221).
assert_section 'log\.jsonl' "$review Trace / Process Evidence section must name log.jsonl"
assert_section 'payload' "$review Trace / Process Evidence section must require citing the log failure payload (actual failing output)"
assert_section 'failure record|failing output|failure detail|failure payload' "$review Trace / Process Evidence section must require citing the log failure record detail rather than only the span summary"
assert_section 'log evidence unavailable' "$review Trace / Process Evidence section must use the exact absence phrase log evidence unavailable"
assert_section 'log evidence unavailable[^.]*never inferred|log evidence unavailable[^.]*not inferred' "$review Trace / Process Evidence section must state log evidence unavailable is never inferred as pass"

if [ "$fail" -ne 0 ]; then
  echo "code-review trace-evidence sensor FAILED"
  exit 1
fi
echo "code-review trace-evidence checks passed"
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

skills_dir=".copilot/skills"

# The guarded section exists in at least the skills that carry the heading.
grep -Eq '^#+ .*Implementation-Usefulness' "${skills_dir}/find-over-design/SKILL.md" \
  || note "find-over-design/SKILL.md must keep the Implementation-Usefulness section"

for skill in find-brute-force find-duplicates find-over-design dead-code-detection; do
  f="${skills_dir}/${skill}/SKILL.md"
  [ -f "$f" ] || { note "missing $f"; continue; }
  case "$skill" in
    find-brute-force)    decision='Fix now' ;;
    find-duplicates)     decision='Fix now' ;;
    find-over-design)    decision='Simplify now' ;;
    dead-code-detection) decision='Delete now' ;;
  esac
  grep -qi 'implementation-usefulness' "$f" || note "$f must document implementation-usefulness grading"
  grep -Eqi 'separate from|distinct from' "$f" || note "$f must state the grading is separate from severity"
  grep -qi "$decision" "$f" || note "$f must include its tailored decision '$decision'"
  grep -qi 'usefulness' "$f" || note "$f report template must include a usefulness decision field"
  grep -Eqi 'does not override|still blocks' "$f" || note "$f must state a high usefulness score does not override blocking severity"
done

dc="${skills_dir}/dead-code-detection/SKILL.md"
if [ -f "$dc" ]; then
  grep -Eqi 'public api|extension point|migration|generated|compat' "$dc" \
    || note "$dc must protect public APIs/extension points/migrations/generated/compat from deletion"
fi

review=".copilot/agents/code-review-subagent.agent.md"
test_agent=".copilot/agents/test-subagent.agent.md"
if [ -f "$review" ]; then
  grep -Eqi 'implementation-usefulness|implementation decision' "$review" || note "$review must consume implementation-usefulness decisions"
  grep -Eqi 'CRITICAL|MAJOR|MINOR' "$review" || note "$review must preserve its CRITICAL/MAJOR/MINOR model"
fi
if [ -f "$test_agent" ]; then
  grep -qi 'verification clarity' "$test_agent" || note "$test_agent must use verification clarity when selecting sensors"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "implementation-usefulness grading checks passed"
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

sec=".copilot/skills/security-audit/SKILL.md"
cr=".copilot/skills/code-review/SKILL.md"

# --- No imported provenance frontmatter on either skill ---
for f in "$sec" "$cr"; do
  [ -f "$f" ] || { note "missing $f"; continue; }
  grep -Eiq '^(license|author):' "$f" && note "$f must not carry imported license/author frontmatter"
  grep -Eiq 'awesome-ai-agent-skills' "$f" && note "$f must not credit the awesome-ai-agent-skills import"
  grep -Eq '^name:[[:space:]]*'"$(basename "$(dirname "$f")")"'[[:space:]]*$' "$f" \
    || note "$f frontmatter name: must match its folder (kebab-case)"
done

# --- security-audit is repo-scoped, built-in-tools-first, and keeps severity ---
if [ -f "$sec" ]; then
  grep -Eiq 'workflow permission|permissions:' "$sec" || note "$sec must cover GitHub Actions workflow permissions"
  grep -Eiq 'injection' "$sec"                         || note "$sec must cover shell/CI script injection"
  grep -Eiq 'secret' "$sec"                            || note "$sec must cover secrets handling"
  grep -Eiq 'pin' "$sec"                               || note "$sec must cover dependency/action pinning"
  grep -Eiq 'built-in tools first|scanners? (are )?optional|optional accelerator' "$sec" \
    || note "$sec must take the built-in-tools-first, scanners-optional stance"
  grep -Eiq 'severity' "$sec"                          || note "$sec must keep a severity classification"
  # Must NOT mandate the imported generic scanners as hard requirements.
  grep -Eiq 'prowler|scoutsuite|owasp zap' "$sec" \
    && note "$sec must not mandate imported cloud/web scanners (Prowler/ScoutSuite/OWASP ZAP)"
fi

# --- code-review keeps its judgment scaffold and drops the worked examples ---
if [ -f "$cr" ]; then
  grep -Eiq 'understand the intent' "$cr" || note "$cr must keep the 'understand the intent first' review step"
  if ! { grep -Eq 'Critical' "$cr" && grep -Eq 'Warning' "$cr" && grep -Eq 'Info' "$cr"; }; then
    note "$cr must keep the Critical/Warning/Info severity vocabulary"
  fi
  grep -Eiq 'Review Checklist' "$cr" || note "$cr must keep the review checklist table"
  # The fabricated worked examples (fake SQLi / MD5 / N+1 demos) must be gone.
  grep -Eiq 'hashlib\.md5|OR .1.=.1|order_items WHERE order_id' "$cr" \
    && note "$cr must not reintroduce the fabricated worked examples"
fi

if [ "$fail" -ne 0 ]; then
  echo "imported-skills-repo-scoped sensor FAILED"
  exit 1
fi
echo "imported-skills-repo-scoped checks passed"
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

skill=".copilot/skills/public-exposure-audit/SKILL.md"

if [ ! -f "$skill" ]; then
  note "missing $skill"
  echo "public-exposure-audit skill sensor FAILED"
  exit 1
fi

# Valid opening + closing frontmatter fence.
awk 'NR==1 && $0!="---" {exit 2} NR>1 && $0=="---" {found=1; exit 0} END {if(!found) exit 3}' "$skill" \
  || note "$skill must open and close YAML frontmatter with ---"

# Frontmatter name.
grep -Eq '^name:[[:space:]]*public-exposure-audit[[:space:]]*$' "$skill" \
  || note "$skill frontmatter name: must be public-exposure-audit"

# --- Scope of the sweep ---
grep -Eiq 'tracked file' "$skill"                       || note "$skill must cover tracked files"
grep -Eiq 'reachable.*histor|git log|rev-list|--all'    "$skill" || note "$skill must cover reachable Git history"
grep -Eiq 'git metadata|author.*email|committer'        "$skill" || note "$skill must cover Git metadata / author email"
grep -Eiq 'ignored'  "$skill"                           || note "$skill must cover ignored files"
grep -Eiq 'untracked' "$skill"                          || note "$skill must cover untracked files"
grep -Eiq 'branch'   "$skill"                           || note "$skill must cover branch tips"

# --- Identifier categories ---
grep -Eiq 'personal' "$skill"                           || note "$skill must cover personal identifiers"
grep -Eiq 'company|internal' "$skill"                   || note "$skill must cover company/internal references"
grep -Eiq 'vendor|account|resource' "$skill"            || note "$skill must cover vendor/account/resource identifiers"
grep -Eiq 'local path|path' "$skill"                    || note "$skill must cover local paths"
grep -Eiq 'secret' "$skill"                             || note "$skill must cover secrets"
grep -Eiq 'token' "$skill"                              || note "$skill must cover tokens"
grep -Eiq 'cloud' "$skill"                              || note "$skill must cover cloud identifiers"
grep -Eiq 'subscription|tenant' "$skill"                || note "$skill must cover subscription/tenant IDs"
grep -Eiq 'url|endpoint' "$skill"                       || note "$skill must cover URLs/endpoints"

# --- Classification of non-exposure (AC#2) ---
grep -Eiq 'intentional public' "$skill"                 || note "$skill must classify intentional public documentation"
grep -Eiq 'synthetic|fixture' "$skill"                  || note "$skill must classify synthetic fixtures"
grep -Eiq 'example\.com|example email|invalid.*example' "$skill" || note "$skill must classify invalid example emails"
grep -Eiq 'placeholder' "$skill"                        || note "$skill must classify placeholder env var names"

# --- Report fields (AC#3) ---
grep -Eiq 'severity' "$skill"                           || note "$skill report must include severity"
grep -Eiq 'evidence' "$skill"                           || note "$skill report must include evidence"
grep -Eiq 'push' "$skill"                               || note "$skill report must include remote/push status"
grep -Eiq 'remediation' "$skill"                        || note "$skill report must include remediation guidance"
grep -Eiq 'residual risk' "$skill"                      || note "$skill report must include residual risk"

# --- No mandatory scanner dependency ---
grep -Eiq 'optional' "$skill"                           || note "$skill must mark third-party scanners optional"

if [ "$fail" -ne 0 ]; then
  echo "public-exposure-audit skill sensor FAILED"
  exit 1
fi
echo "public-exposure-audit skill checks passed"
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review=".copilot/agents/code-review-subagent.agent.md"

if [ -f "$review" ]; then
  # The checklist must pair "survive" with a lifecycle/teardown notion so a
  # presence-only "artifact is emitted" check is called out as insufficient.
  if grep -Eqi 'surviv' "$review" \
     && grep -Eqi 'lifecycle|teardown|worktree' "$review"; then
    grep -Eqi 'surviv.*(lifecycle|teardown|worktree)|(lifecycle|teardown|worktree).*surviv' "$review" \
      || note "$review must tie artifact survival to the full lifecycle in one checklist point"
  else
    note "$review must require verifying a file/record deliverable SURVIVES the full lifecycle (e.g. worktree teardown), not merely that it is emitted"
  fi
else
  note "missing $review"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "code-review artifact-survival checklist present"
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

review_agent=".copilot/agents/code-review-subagent.agent.md"

[ -f "$review_agent" ] || note "missing $review_agent"

if [ -f "$review_agent" ]; then
  grep -qF 'Execute-before-CRITICAL' "$review_agent" \
    || note "$review_agent must define a named Execute-before-CRITICAL rule"

  grep -qiF 'executed reproduction' "$review_agent" \
    || note "$review_agent must require an executed reproduction before CRITICAL"
  grep -Eqi 'reviewed HEAD' "$review_agent" \
    || note "$review_agent must require the reproduction to run on the reviewed HEAD"
  grep -Eqi 'command.+observed output|observed output.+command' "$review_agent" \
    || note "$review_agent must require both the command and observed output"

  grep -qiF 'confidence: low' "$review_agent" \
    || note "$review_agent must spell out the downgrade confidence: low"
  grep -Eqi 'MAJOR[^[:cntrl:]]+never CRITICAL|never CRITICAL[^[:cntrl:]]+MAJOR' "$review_agent" \
    || note "$review_agent must say missing executed reproduction is MAJOR, never CRITICAL"

  grep -qiF 'cannot run' "$review_agent" \
    || note "$review_agent must scope the rule to cannot run claims"
  grep -qiF 'cannot parse' "$review_agent" \
    || note "$review_agent must scope the rule to cannot parse claims"
  grep -qiF 'crashes' "$review_agent" \
    || note "$review_agent must scope the rule to crashes claims"
fi

if [ "$fail" -ne 0 ]; then
  echo "review execute-before-CRITICAL sensor FAILED"
  exit 1
fi

echo "review execute-before-CRITICAL checks passed"
)

(
cd "$ROOT"

cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }

registry=".copilot/skills/_review-known-false-positives.md"
agent=".copilot/agents/code-review-subagent.agent.md"

if [ ! -f "$registry" ]; then
  note "$registry must exist"
else
  grep -Eq 'PEP 758' "$registry" \
    || note "$registry must contain a PEP 758 entry"
  grep -Eq 'except A, B|except \(A, B\)|unparenthesized[- ]multi[- ]exception' "$registry" \
    || note "$registry must name the refuted multi-exception except form"
  grep -Eiq 'refuted|false' "$registry" \
    || note "$registry must identify the entry as a known false positive/refuted claim"
  grep -Eq 'python3? -c' "$registry" \
    || note "$registry must include a runnable disproving python -c command"
  grep -Eiq 'append-only|Known False Positives' "$registry" \
    || note "$registry must frame itself as an append-only known-false-positive registry"
fi

if [ ! -f "$agent" ]; then
  note "$agent must exist"
else
  grep -q '_review-known-false-positives' "$agent" \
    || note "$agent must reference _review-known-false-positives"
  grep -Eiq 'consult[^.[:cntrl:]]*(syntax|version-support)|(syntax|version-support)[^.[:cntrl:]]*consult' "$agent" \
    || note "$agent must require consulting the registry before syntax/version-support findings"
fi

if [ "$fail" -ne 0 ]; then
  echo "review-known-false-positives sensor FAILED"
  exit 1
fi
echo "review-known-false-positives checks passed"
)
