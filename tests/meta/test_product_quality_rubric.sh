#!/usr/bin/env bash
# Regression sensor (issue #82): the functionality product-quality rubric must
# define blocking gates, scorecard dimensions, 0/1/2 scoring anchors, score
# interpretation (FAIL/NEEDS_REVISION/PASS/STRONG_PASS), and handback routing.
#
# This sensor fails if the rubric file is missing or lacks required sections so
# the rubric cannot silently lose its contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Subcommand dispatch (for future features: code-review-subagent,
# lifecycle-docs).
subcommand="${1:-all}"

section_has_pattern() {
  local doc="$1"
  local header_pattern="$2"
  local body_pattern="$3"

  awk -v header_pattern="$header_pattern" -v body_pattern="$body_pattern" '
    /^## / {
      in_section = ($0 ~ header_pattern)
      next
    }
    in_section && $0 ~ body_pattern { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$doc"
}

test_doc() {
  local fail=0
  local note_fn="$1"
  local doc="docs/evaluation/product-quality-rubric.md"

  [ -f "$doc" ] || { "$note_fn" "missing $doc"; return 1; }

  # Definition of functionality product quality.
  grep -Eqi 'functionality.*product quality|product quality.*functionality' "$doc" ||
    "$note_fn" "$doc must define 'functionality product quality'"

  # Blocking gates section with the four named gates.
  grep -Eqi 'blocking gate' "$doc" ||
    "$note_fn" "$doc must document blocking gates"
  grep -Eqi 'spec fidelity' "$doc" ||
    "$note_fn" "$doc must name 'spec fidelity' as a blocking gate"
  grep -Eqi 'executable verification' "$doc" ||
    "$note_fn" "$doc must name 'executable verification' as a blocking gate"
  grep -Eqi 'main workflow works' "$doc" ||
    "$note_fn" "$doc must name 'main workflow works' as a blocking gate"
  grep -Eqi 'no known critical breakage' "$doc" ||
    "$note_fn" "$doc must name 'no known critical breakage' as a blocking gate"

  # Scorecard with six dimensions.
  grep -Eqi 'scorecard|score ?card' "$doc" ||
    "$note_fn" "$doc must document a scorecard"
  grep -Eqi 'workflow completeness' "$doc" ||
    "$note_fn" "$doc scorecard must include 'workflow completeness' dimension"
  grep -Eqi 'failure.*edge handling|edge.*failure handling' "$doc" ||
    "$note_fn" "$doc scorecard must include 'failure and edge handling' dimension"
  grep -Eqi 'state.*data coherence|data.*state coherence' "$doc" ||
    "$note_fn" "$doc scorecard must include 'state and data coherence' dimension"
  grep -Eqi 'integration depth' "$doc" ||
    "$note_fn" "$doc scorecard must include 'integration depth' dimension"
  grep -Eqi 'recoverability.*operability|operability.*recoverability' "$doc" ||
    "$note_fn" "$doc scorecard must include 'recoverability and operability' dimension"
  grep -Eqi 'verification adequacy' "$doc" ||
    "$note_fn" "$doc scorecard must include 'verification adequacy' dimension"

  # 0/1/2 scoring or score anchors.
  if ! grep -Eqi '\b0\b.*\b1\b.*\b2\b|\b2\b.*\b1\b.*\b0\b' "$doc" &&
     ! grep -Eqi 'score anchor|scoring anchor' "$doc"; then
    "$note_fn" "$doc must document 0/1/2 scoring or score anchors"
  fi

  # Score interpretation with four outcomes.
  grep -Eqi 'scor(e|ing).*(interpretation|interpret)|(interpretation|interpret).*scor(e|ing)' "$doc" ||
    "$note_fn" "$doc must document score interpretation"
  grep -Eqi '\bFAIL\b' "$doc" ||
    "$note_fn" "$doc score interpretation must include FAIL"
  grep -Eqi 'NEEDS_REVISION|NEEDS REVISION' "$doc" ||
    "$note_fn" "$doc score interpretation must include NEEDS_REVISION"
  grep -Eqi '\bPASS\b' "$doc" ||
    "$note_fn" "$doc score interpretation must include PASS"
  grep -Eqi 'STRONG_PASS|STRONG PASS' "$doc" ||
    "$note_fn" "$doc score interpretation must include STRONG_PASS"

  # Numeric score bands are single-sourced here (issue #201): the agents point at
  # this doc instead of restating the bands, so the bands must live in the doc.
  grep -Eq '0[–-]5.*FAIL|FAIL.*0[–-]5' "$doc" ||
    "$note_fn" "$doc must map score 0-5 to FAIL"
  grep -Eq '6[–-]8.*NEEDS_REVISION|NEEDS_REVISION.*6[–-]8|6[–-]8.*NEEDS REVISION|NEEDS REVISION.*6[–-]8' "$doc" ||
    "$note_fn" "$doc must map score 6-8 to NEEDS_REVISION"
  grep -Eq '9[–-]10.*PASS|PASS.*9[–-]10' "$doc" ||
    "$note_fn" "$doc must map score 9-10 to PASS"
  grep -Eq '11[–-]12.*STRONG_PASS|STRONG_PASS.*11[–-]12|11[–-]12.*STRONG PASS|STRONG PASS.*11[–-]12' "$doc" ||
    "$note_fn" "$doc must map score 11-12 to STRONG_PASS"

  # Handback routing to the three roles.
  grep -Eqi 'handback routing|routing handback' "$doc" ||
    "$note_fn" "$doc must document handback routing"
  grep -Eqi 'implementation-subagent' "$doc" ||
    "$note_fn" "$doc handback routing must mention implementation-subagent"
  grep -Eqi 'test-subagent' "$doc" ||
    "$note_fn" "$doc handback routing must mention test-subagent"
  grep -Eqi 'conductor.*human|human.*gate' "$doc" ||
    "$note_fn" "$doc handback routing must mention conductor/human gate"

  return "$fail"
}

test_examples() {
  local fail=0
  local note_fn="$1"
  local doc="docs/evaluation/product-quality-rubric.md"

  [ -f "$doc" ] || { "$note_fn" "missing $doc"; return 1; }

  # Examples or calibration section.
  if ! grep -Eqi 'example|calibration' "$doc"; then
    "$note_fn" "$doc must include examples or calibration section"
  fi

  # Good evaluation example.
  if ! grep -Eqi 'good.*example|example.*good|strong.*example|example.*strong' "$doc"; then
    "$note_fn" "$doc must include a good/strong evaluation example"
  fi

  # Bad evaluation example.
  if ! grep -Eqi 'bad.*example|example.*bad|weak.*example|example.*weak|fail.*example|example.*fail' "$doc"; then
    "$note_fn" "$doc must include a bad/weak/fail evaluation example"
  fi

  # Edge-case or waiver example.
  if ! grep -Eqi 'edge.*example|example.*edge|waiver.*example|example.*waiver|needs.revision.*example|example.*needs.revision' "$doc"; then
    "$note_fn" "$doc must include an edge-case or waiver example"
  fi

  # Examples include feature/acceptance context.
  if ! grep -Eqi 'feature.*context|acceptance.*criteri|issue.*\#[0-9]|F[0-9]+' "$doc"; then
    "$note_fn" "$doc examples must include feature or acceptance context"
  fi

  # Examples include sensors and results or sensor evidence.
  if ! grep -Eqi 'sensor|test.*result|regression.*sensor|e2e.*sensor' "$doc"; then
    "$note_fn" "$doc examples must include sensors and run results or sensor evidence"
  fi

  # Examples include blocking gate results.
  if ! grep -Eqi 'gate.*pass|gate.*fail|gate.*result|spec fidelity.*pass|spec fidelity.*fail|executable verification.*pass|executable verification.*fail' "$doc"; then
    "$note_fn" "$doc examples must include blocking gate results"
  fi

  # Examples include scorecard results or dimension scores.
  if ! grep -Eqi 'scorecard.*[0-2]|dimension.*score|workflow completeness.*[0-2]|total.*score' "$doc"; then
    "$note_fn" "$doc examples must include scorecard results or dimension scores"
  fi

  # Examples include routeable handbacks.
  if ! grep -Eqi 'handback.*implementation|handback.*test|handback.*conductor' "$doc"; then
    "$note_fn" "$doc examples must include routeable handbacks"
  fi

  # Calibration guidance for 0/1/2 score boundaries.
  if ! grep -Eqi 'calibration|score.*anchor|0.*vs.*1|1.*vs.*2|distinguish.*[0-2]|boundary.*[0-2]' "$doc"; then
    "$note_fn" "$doc must include calibration guidance for 0/1/2 score boundaries"
  fi

  return "$fail"
}

test_subagent() {
  local fail=0
  local note_fn="$1"
  local agent=".copilot/agents/test-subagent.agent.md"

  [ -f "$agent" ] || { "$note_fn" "missing $agent"; return 1; }

  # References product-quality blocking gates or product-quality rubric.
  if ! grep -Eqi 'product.quality.*blocking gate|blocking gate.*product.quality|product.quality.*rubric|rubric.*product.quality' "$agent"; then
    "$note_fn" "$agent must reference product-quality blocking gates or rubric"
  fi

  # References the rubric doc path.
  if ! grep -q 'docs/evaluation/product-quality-rubric.md' "$agent"; then
    "$note_fn" "$agent must reference docs/evaluation/product-quality-rubric.md"
  fi

  # Requires gate evidence before passes:true.
  if ! grep -Eqi 'gate.*evidence.*before.*pass|gate.*check.*before.*pass|check.*gate.*before.*pass' "$agent"; then
    "$note_fn" "$agent must require gate evidence before marking passes:true"
  fi

  # Includes the four blocking gates.
  grep -Eqi 'spec fidelity' "$agent" ||
    "$note_fn" "$agent must reference 'spec fidelity' gate"
  grep -Eqi 'executable verification' "$agent" ||
    "$note_fn" "$agent must reference 'executable verification' gate"
  grep -Eqi 'main workflow works' "$agent" ||
    "$note_fn" "$agent must reference 'main workflow works' gate"
  grep -Eqi 'no known critical breakage' "$agent" ||
    "$note_fn" "$agent must reference 'no known critical breakage' gate"

  # Pass status output requires blocking gate results.
  if ! grep -Eqi 'pass.*status.*gate|gate.*result.*pass.*status|blocking.*gate.*result' "$agent"; then
    "$note_fn" "$agent Pass status output must require blocking gate results"
  fi

  # Pass status output requires criterion-to-sensor mapping.
  if ! grep -Eqi 'criterion.*sensor.*map|sensor.*map.*criterion|criterion.*sensor|acceptance.*criterion.*sensor' "$agent"; then
    "$note_fn" "$agent Pass status output must require criterion-to-sensor mapping"
  fi

  # Failed gates are BLOCKING handbacks.
  if ! grep -Eqi 'failed.*gate.*blocking|gate.*fail.*blocking|blocking.*gate.*fail' "$agent"; then
    "$note_fn" "$agent must treat failed gates as BLOCKING handbacks"
  fi

  # Handbacks include required information.
  if ! grep -Eqi 'handback.*gate.*evidence|handback.*gate.*fail|gate.*evidence.*handback' "$agent"; then
    "$note_fn" "$agent handbacks must include gate failed and evidence"
  fi
  if ! grep -Eqi 'handback.*fix.*direction|fix.*direction.*handback|expected.*fix' "$agent"; then
    "$note_fn" "$agent handbacks must include expected fix direction"
  fi
  if ! grep -Eqi 'handback.*sensor.*rerun|sensor.*rerun.*handback|review.*rerun' "$agent"; then
    "$note_fn" "$agent handbacks must include sensor or review to rerun"
  fi

  return "$fail"
}

test_code_review_subagent() {
  local fail=0
  local note_fn="$1"
  local agent=".copilot/agents/code-review-subagent.agent.md"

  [ -f "$agent" ] || { "$note_fn" "missing $agent"; return 1; }

  # References product-quality rubric.
  if ! grep -Eqi 'product.quality.*rubric|rubric.*product.quality' "$agent"; then
    "$note_fn" "$agent must reference product-quality rubric"
  fi

  # References the rubric doc path.
  if ! grep -q 'docs/evaluation/product-quality-rubric.md' "$agent"; then
    "$note_fn" "$agent must reference docs/evaluation/product-quality-rubric.md"
  fi

  # Blocking gates in Verdict 2 / test/sensor adequacy.
  if ! grep -Eqi 'verdict 2.*blocking gate|blocking gate.*verdict 2|test.*sensor adequacy.*blocking gate' "$agent"; then
    "$note_fn" "$agent must place blocking gates in Verdict 2 / test/sensor adequacy"
  fi

  # Names the four blocking gates.
  grep -Eqi 'spec fidelity' "$agent" ||
    "$note_fn" "$agent must name 'spec fidelity' as a blocking gate"
  grep -Eqi 'executable verification' "$agent" ||
    "$note_fn" "$agent must name 'executable verification' as a blocking gate"
  grep -Eqi 'main workflow works' "$agent" ||
    "$note_fn" "$agent must name 'main workflow works' as a blocking gate"
  grep -Eqi 'no known critical breakage' "$agent" ||
    "$note_fn" "$agent must name 'no known critical breakage' as a blocking gate"

  # Scorecard in Verdict 3 / code quality or maintainability.
  if ! grep -Eqi 'verdict 3.*scorecard|scorecard.*verdict 3|code quality.*scorecard|maintainability.*scorecard' "$agent"; then
    "$note_fn" "$agent must place scorecard in Verdict 3 / code quality or maintainability"
  fi

  # Names the six dimensions.
  grep -Eqi 'workflow completeness' "$agent" ||
    "$note_fn" "$agent scorecard must include 'workflow completeness' dimension"
  grep -Eqi 'failure.*edge handling|edge.*failure handling' "$agent" ||
    "$note_fn" "$agent scorecard must include 'failure and edge handling' dimension"
  grep -Eqi 'state.*data coherence|data.*state coherence' "$agent" ||
    "$note_fn" "$agent scorecard must include 'state and data coherence' dimension"
  grep -Eqi 'integration depth' "$agent" ||
    "$note_fn" "$agent scorecard must include 'integration depth' dimension"
  grep -Eqi 'recoverability.*operability|operability.*recoverability' "$agent" ||
    "$note_fn" "$agent scorecard must include 'recoverability and operability' dimension"
  grep -Eqi 'verification adequacy' "$agent" ||
    "$note_fn" "$agent scorecard must include 'verification adequacy' dimension"

  # Scores each dimension 0/1/2. The numeric score bands
  # (0-5/6-8/9-10/11-12 → FAIL/NEEDS_REVISION/PASS/STRONG_PASS) are single-sourced
  # in the rubric doc (asserted by test_doc), not restated in the agent (issue #201).
  if ! grep -Eqi '\b0\b.*\b1\b.*\b2\b|\b2\b.*\b1\b.*\b0\b|0/1/2' "$agent"; then
    "$note_fn" "$agent must reference 0/1/2 dimension scoring"
  fi

  # Failed blocking gates override the score.
  if ! grep -Eqi 'failed.*gate.*override.*score|gate.*fail.*override|blocking.*gate.*override' "$agent"; then
    "$note_fn" "$agent must state that failed blocking gates override the score"
  fi
  if ! grep -Eqi 'failed.*gate.*\bFAIL\b|gate.*fail.*\bFAIL\b|blocking.*gate.*\bFAIL\b' "$agent"; then
    "$note_fn" "$agent must state that a failed blocking gate forces a FAIL verdict"
  fi

  # Routes product-quality findings to implementation-subagent, test-subagent, or conductor/human gate.
  if ! grep -Eqi 'implementation-subagent' "$agent"; then
    "$note_fn" "$agent must route findings to implementation-subagent"
  fi
  if ! grep -Eqi 'test-subagent' "$agent"; then
    "$note_fn" "$agent must route findings to test-subagent"
  fi
  if ! grep -Eqi 'conductor.*human|human.*gate|conductor.*gate' "$agent"; then
    "$note_fn" "$agent must route findings to conductor/human gate"
  fi

  return "$fail"
}

test_lifecycle_docs() {
  local fail=0
  local note_fn="$1"
  local docs=(
    "docs/HARNESS.md"
    ".copilot/instructions/harness.instructions.md"
  )
  local doc

  for doc in "${docs[@]}"; do
    [ -f "$doc" ] || { "$note_fn" "missing $doc"; fail=1; continue; }

    # Both lifecycle docs must route readers to the product-quality rubric.
    if ! grep -Eqi 'docs/evaluation/product-quality-rubric\.md|product[- ]quality rubric|product quality.*rubric|rubric.*product quality' "$doc"; then
      "$note_fn" "$doc must reference docs/evaluation/product-quality-rubric.md or the product-quality rubric"
    fi

    # Blocking gates belong to evaluator/test-subagent lifecycle responsibilities before passes:true.
    if ! grep -Eqi 'blocking gate' "$doc"; then
      "$note_fn" "$doc must mention product-quality blocking gates in the lifecycle"
    fi
    if ! grep -Eqi 'test-subagent|Evaluator' "$doc"; then
      "$note_fn" "$doc must preserve test-subagent/evaluator lifecycle responsibility"
    fi
    if ! grep -Eqi 'passes:true' "$doc"; then
      "$note_fn" "$doc must preserve the passes:true lifecycle marker"
    fi
    if ! grep -Eqi '(test-subagent|Evaluator).*(blocking gate|product[- ]quality|rubric).*(passes:true|before.*pass|mark.*pass)|(blocking gate|product[- ]quality|rubric).*(test-subagent|Evaluator).*(passes:true|before.*pass|mark.*pass)' "$doc"; then
      "$note_fn" "$doc must make blocking-gate verification a test-subagent/evaluator responsibility before passes:true"
    fi

    # The scorecard belongs to review/reviewer responsibilities before closeout.
    if ! grep -Eqi 'scorecard|score ?card' "$doc"; then
      "$note_fn" "$doc must mention the product-quality scorecard"
    fi
    if ! grep -Eqi 'code-review-subagent|Reviewer' "$doc"; then
      "$note_fn" "$doc must preserve code-review-subagent/reviewer lifecycle responsibility"
    fi
    if ! grep -Eqi 'closeout|review' "$doc"; then
      "$note_fn" "$doc must preserve review/closeout lifecycle placement"
    fi
    if ! grep -Eqi '(code-review-subagent|Reviewer).*(scorecard|score ?card|product[- ]quality|rubric).*(review|closeout)|(scorecard|score ?card|product[- ]quality|rubric).*(code-review-subagent|Reviewer).*(review|closeout)' "$doc"; then
      "$note_fn" "$doc must make scorecard evaluation a code-review-subagent/reviewer responsibility before closeout/review"
    fi

    # Conductor-owned routing and role boundaries must remain explicit.
    if ! grep -Eqi 'conductor' "$doc"; then
      "$note_fn" "$doc must preserve conductor role text"
    fi
    if ! grep -Eqi 'implementation-subagent' "$doc"; then
      "$note_fn" "$doc must preserve implementation-subagent role text"
    fi
    if ! grep -Eqi 'conductor.*(owns|drives|routes|selects|commits|pushes)|conductor.*must not|must not.*conductor|conductor-owned' "$doc"; then
      "$note_fn" "$doc must keep conductor-owned routing and role boundaries explicit"
    fi
    if ! grep -Eqi 'role boundaries|preserve role boundaries|must not directly|non-delegable|does not implement|never writes' "$doc"; then
      "$note_fn" "$doc must keep role boundaries explicit"
    fi
  done

  return "$fail"
}

# Single-source drift check (issue #201): the canonical gate and dimension NAMES
# live only in the rubric doc headings. The agents must reference those names
# (pointer + names, not restated definitions). If the doc renames a gate or
# dimension, an agent that still uses the old name fails here.
test_name_drift() {
  local fail=0
  local note_fn="$1"
  local doc="docs/evaluation/product-quality-rubric.md"
  local review_agent=".copilot/agents/code-review-subagent.agent.md"
  local test_agent=".copilot/agents/test-subagent.agent.md"

  [ -f "$doc" ] || { "$note_fn" "missing $doc"; return 1; }

  # Parse canonical names from '### N. Name' headings inside the named sections.
  extract_names() {
    local section="$1"
    awk -v section="$section" '
      /^## / { in_section = (index($0, section) > 0); next }
      in_section && /^### [0-9]+\. / {
        sub(/^### [0-9]+\. /, "")
        print
      }
    ' "$doc"
  }

  local gates dims
  mapfile -t gates < <(extract_names "Blocking Gates")
  mapfile -t dims < <(extract_names "Scorecard Dimensions")

  # Guard the doc structure: exactly four gates and six dimensions.
  [ "${#gates[@]}" -eq 4 ] ||
    "$note_fn" "$doc must define exactly 4 blocking-gate names under '## Blocking Gates' (found ${#gates[@]})"
  [ "${#dims[@]}" -eq 6 ] ||
    "$note_fn" "$doc must define exactly 6 dimension names under '## Scorecard Dimensions' (found ${#dims[@]})"

  # Both agents reference the four blocking gates; only the reviewer owns the
  # six-dimension scorecard, so dimension names are required there only.
  local name
  for name in "${gates[@]}"; do
    grep -qiF "$name" "$review_agent" ||
      "$note_fn" "$review_agent must reference canonical gate name '$name' (drift from $doc)"
    grep -qiF "$name" "$test_agent" ||
      "$note_fn" "$test_agent must reference canonical gate name '$name' (drift from $doc)"
  done
  for name in "${dims[@]}"; do
    grep -qiF "$name" "$review_agent" ||
      "$note_fn" "$review_agent must reference canonical dimension name '$name' (drift from $doc)"
  done

  return "$fail"
}

test_evaluation_readme() {
  local fail=0
  local note_fn="$1"
  local doc="docs/evaluation/README.md"

  [ -f "$doc" ] || { "$note_fn" "missing $doc"; return 1; }

  # The overview must list the product-quality rubric as an evaluation page.
  if ! grep -Eq '\[product-quality-rubric\.md\]\(product-quality-rubric\.md\)|\[([^]]*[Pp]roduct[ -][Qq]uality[^]]*|[^]]*[Rr]ubric[^]]*)\]\(product-quality-rubric\.md\)' "$doc"; then
    "$note_fn" "$doc must list/link product-quality-rubric.md in the evaluation overview"
  fi

  # The rubric should be discoverable from the page list or scorecard model.
  if ! section_has_pattern "$doc" 'Evaluation Areas|Scorecard Model' '[Pp]roduct[ -][Qq]uality.*[Rr]ubric|[Rr]ubric.*[Pp]roduct[ -][Qq]uality|product-quality-rubric\.md'; then
    "$note_fn" "$doc must mention the product-quality rubric near Evaluation Areas or Scorecard Model"
  fi

  # Implementation sequencing should tell readers when this rubric applies.
  if ! section_has_pattern "$doc" 'Implementation Priority' '[Pp]roduct[ -][Qq]uality.*[Rr]ubric|[Rr]ubric.*[Pp]roduct[ -][Qq]uality|product-quality-rubric\.md'; then
    "$note_fn" "$doc must mention the product-quality rubric near Implementation Priority"
  fi

  # Keep the rubric framed around coding-agent functionality product quality.
  if ! grep -Eqi 'coding-agent.*(functionality|functional).*product quality|(functionality|functional).*product quality.*coding-agent|agent.*functionality.*product quality|product quality.*agent.*functionality' "$doc"; then
    "$note_fn" "$doc must frame the rubric as coding-agent functionality product quality"
  fi

  # This rubric is not a visual-design grading rubric.
  if grep -Eqi 'visual design grading|visual-design grading|design grading|visual grading|aesthetic grading|UI design grading' "$doc"; then
    "$note_fn" "$doc must not frame the product-quality rubric as visual design grading"
  fi

  return "$fail"
}

case "$subcommand" in
  doc)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_doc note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric doc checks pass"
    ;;
  examples)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_examples note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric examples checks pass"
    ;;
  test-subagent)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_subagent note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric test-subagent checks pass"
    ;;
  code-review-subagent)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_code_review_subagent note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric code-review-subagent checks pass"
    ;;
  lifecycle-docs)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_lifecycle_docs note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric lifecycle docs checks pass"
    ;;
  evaluation-readme)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_evaluation_readme note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric evaluation README checks pass"
    ;;
  drift)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_name_drift note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ product-quality rubric name-drift checks pass"
    ;;
  all)
    fail=0
    note() { echo "✗ $*"; fail=1; }
    test_doc note
    test_examples note
    test_subagent note
    test_code_review_subagent note
    test_lifecycle_docs note
    test_evaluation_readme note
    test_name_drift note
    [ "$fail" -eq 0 ] || exit 1
    echo "✓ all product-quality rubric checks pass"
    ;;
  *)
    echo "unknown subcommand: $subcommand" >&2
    echo "usage: $0 {doc|examples|test-subagent|code-review-subagent|lifecycle-docs|evaluation-readme|drift|all}" >&2
    exit 1
    ;;
esac
