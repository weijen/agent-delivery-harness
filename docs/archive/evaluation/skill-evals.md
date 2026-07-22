# Skill Evals

## Purpose

Skill evals measure whether Copilot skills are selected for the right requests,
avoid false positives, and produce the expected artifacts or review behavior.
They answer whether a skill is useful and reliable in its intended boundary.

## Targets

Skills under `.copilot/skills/`, especially:

- `code-review`
- `create-pr`
- `security-audit`
- `sync-docs`
- `find-brute-force`
- `find-duplicates`
- `find-over-design`
- `dead-code-detection`

## Eval Categories

Each skill should have its own evaluation profile. A profile defines the skill's
intended boundary, the observable signals available for that skill, the graders
that are trusted for the current maturity level, and the signals that are
explicitly deferred. Do not assume one generic skill score applies across
`code-review`, `create-pr`, `security-audit`, and documentation sync skills.

### Trigger Evals

Use prompt sets with:

- Explicit invocation: the prompt names the skill.
- Implicit invocation: the prompt describes the skill's domain.
- Contextual invocation: realistic prompt with extra noise.
- Negative control: adjacent request that must not invoke the skill.
- Ambiguous prompt: should ask clarification or avoid over-triggering.

### Artifact Evals

For skills that create outputs, check artifacts:

- Expected file exists.
- Expected schema is valid.
- Required sections are present.
- No unrelated files are modified.
- No sensitive or local-only material is included.

### Behavior Evals

For review and audit skills, check verdict quality:

- Findings are severity ordered.
- Blocking defects are not downgraded.
- Missing tests are called out when behavior changed.
- Findings are actionable and tied to concrete code or behavior.
- No invented file paths or unsupported claims.

Behavior evals that depend on an LLM judge must calibrate that judge against
human labels using [judge-evaluation.md](judge-evaluation.md), otherwise the
verdict quality score is itself unverified.

### Deferred Signals

Some signals are useful for later product or trajectory evaluation, but are out
of scope for the first L1 skill slice:

- Developer feedback such as thumbs-up/down reactions, comment dismissal,
  suggestion acceptance, and comment resolution
- Time-to-resolution or developer productivity metrics
- Downstream fix success after another agent or developer implements a review
  comment
- End-to-end repair loops that require implementer, tester, and lifecycle trace
  evidence

These signals may become report-only inputs for L3 trajectory or L4 outcome
evals. They must not be used as L1 blocking criteria until the product telemetry,
role attribution, and human-label calibration are defined.

## Skill Evaluation Profiles

Each mature skill gets a dedicated profile before it can become a stable eval
target. The profile records the skill boundary, the observable signals available
today, the graders trusted at each maturity level, and the signals intentionally
deferred to later layers. Add new skill profiles as sibling sections so each
skill can evolve its own evaluation contract without forcing one generic score
across unrelated skill types.

### Code Review Skill Evaluation Profile

#### Skill Boundary

The `code-review` skill reviews changed code and reports correctness, security,
performance, maintainability, and testing findings. L1 evaluates the standalone
skill output. It does not evaluate whether another agent later implements the
feedback correctly, whether a developer accepts a suggestion, or whether the PR
eventually merges.

#### In-Scope Signals

The initial profile separates routing, artifact quality, and bounded review
behavior:

| Boundary | Observable signal | Initial grader | Blocking status |
| --- | --- | --- | --- |
| `skill-trigger` | Skill-selection telemetry, command route, or stable proxy artifact | Expected skill equals observed skill; report true positives, false positives, true negatives, and false negatives | Report-only until observation is stable |
| `skill-artifact` | Structured review artifact with `skill_id`, findings, severities, evidence, recommendations, and summary counts | Schema, required fields, severity enum, summary consistency, and redaction checks | Candidate for blocking after schema stabilizes |
| `skill-behavior` | Structured findings against seeded bug fixtures | Narrow fixture grader for expected issue type, severity band, evidence specificity, actionability, and false positives | Report-only until fixture labels and any judge are calibrated |

#### Artifact Contract

A structured `code-review` artifact should include:

- `skill_id` set to `code-review`
- Findings with severity, category, file path, evidence, and recommendation
- Summary counts that match the finding list
- Redaction status for secrets, local-only paths, tenant IDs, subscription IDs,
  and private URLs
- Assumptions or context gaps when the review cannot verify a claim

The artifact grader can become deterministic once the schema is stable. It does
not prove review quality; it proves the review output is inspectable, safe to
store, and ready for behavior grading.

#### Seeded Behavior Fixtures

Behavior fixtures should use small diffs with known issues and reviewed labels.
Initial fixture categories can include:

- Missing authorization or access checks
- SQL injection or unsanitized input
- N+1 query or obvious performance regression
- Off-by-one or incorrect boolean logic
- Swallowed exception or missing error propagation
- Missing regression test for changed behavior
- Harness lifecycle mistakes such as stale review approval or weak sensors

For each fixture, labels should identify the expected issue type, acceptable
severity band, required evidence, and whether false positives are allowed. The
first behavior evals should remain report-only until labels and graders are
stable.

#### Out-of-Scope Signals

For `code-review`, do not use these signals in the L1 score:

- Suggestion acceptance or one-click fix adoption
- Developer reactions, comment dismissal, or comment resolution
- Time-to-resolution or review-time savings
- Downstream fix success after an implementer acts on a finding
- End-to-end repair loops that require implementer, tester, or trajectory
  evidence

Those signals measure workflow adoption or multi-agent repair effectiveness.
They belong in future L3 trajectory or L4 outcome evals, not in the standalone
L1 skill boundary.

#### Promotion Rules

The `code-review` profile can promote individual eval categories independently:

- Trigger evals can become blocking only after skill-selection observation is
  stable and the positive, negative, contextual, and ambiguous strata are
  reviewed.
- Artifact evals can become blocking only after the structured schema and
  redaction checks are stable.
- Behavior evals remain report-only until seeded fixture labels are reviewed,
  false-positive and false-negative thresholds are explicit, and any rubric or
  LLM judge is calibrated against human labels.

## Dataset Shape

Use a small prompt dataset per skill:

```csv
id,should_trigger,prompt,expected_artifact,expected_behavior
code-review-001,true,"Review this diff for bugs",,blocks_major_bug
code-review-002,false,"Summarize this README",,no_review_mode
```

For artifact-producing skills, pair prompts with fixture repositories and an
expected output schema. Curate and version these prompt sets per
[dataset-governance.md](dataset-governance.md), and never embed customer or
secret material in fixtures.

## Public Dataset Seeds

There is no single public dataset for Copilot skill routing, so trigger evals
should remain harness-specific. Public datasets can still seed behavior and
artifact fixtures:

- [CodeSearchNet](https://github.com/github/CodeSearchNet) provides code,
  docstring, and human relevance judgment examples that can seed prompt-routing
  and code-review relevance cases.
- [HumanEval](https://github.com/openai/human-eval),
  [MBPP](https://github.com/google-research/google-research/tree/master/mbpp),
  and [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench)
  provide code tasks with executable tests; adapt them into reviewer/tester
  behavior fixtures for missing tests, weak sensors, or incorrect artifacts.
- [AgentDojo](https://github.com/ethz-spylab/agentdojo) and
  [InjecAgent](https://github.com/uiuc-kang-lab/InjecAgent) provide adversarial
  tool-agent prompt-injection cases for `security-audit` behavior evals.

Use public cases as seeds only. The final trigger prompt set must include local
positive and negative examples for this repo's actual skill descriptions.

## Graders

Use deterministic graders first:

- Skill was invoked or not invoked, when the tool surface exposes this.
- Required output file exists.
- Output matches JSON or Markdown schema.
- Expected section headers exist.
- Forbidden files are untouched.

Use rubric graders for:

- Review quality.
- Severity classification.
- Whether the skill followed repo-specific instructions.

## The security-audit Skill Is Special

The `security-audit` skill is both a target and a tool. Its behavior evals
should reuse the adversarial fixtures in [security-evals.md](security-evals.md)
so the skill is measured against real injection, secret-leakage, and
least-privilege cases rather than only happy-path prompts.

## Initial Issues To Create Later

1. Define a skill eval dataset format.
2. Add prompt-trigger evals for `code-review`.
3. Add artifact evals for `create-pr`.
4. Add negative-control prompt sets for all high-risk skills.
5. Add structured rubric schema for review-skill outputs.

## Acceptance Criteria

- Each mature skill has positive and negative trigger cases.
- Skill evals produce stable, comparable results across runs.
- Review-skill evals include false-negative cases for missing tests and weak
  sensors.
