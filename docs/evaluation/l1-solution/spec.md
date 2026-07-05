# L1 Evaluation Specification

## Scope

This specification defines the skills evaluation layer:

- **L1 skills**: prompt-trigger, artifact, and structured behavior checks for
  `.copilot/skills/*` assets. L1 measures skill behavior only when the predicted
  outcome can be observed and scored.

L1 reuses the framework contract owned by the L0 solution — the measurement
model, repository layout, manifest schema, scorecard schema, runtime profiles,
Azure config contract, and promotion rules. Read
[../l0-solution/spec.md](../l0-solution/spec.md) for those. This document
specifies only what is L1-specific. L2 subagent roles, L3 trace trajectories, L4
outcome fixtures, L5 mutation campaigns, and blocking LLM-as-judge gates are out
of scope.

## Measurement Model

L1 uses the same measurement chain as the framework (label, prediction,
observable signal, grader, decision rule; see
[../l0-solution/spec.md](../l0-solution/spec.md)). The L1-specific requirement is
the prediction:

An eval without an observable prediction is not an eval. It is a dataset draft.
This is especially important for L1 skill trigger cases: `should_trigger=true`
is only useful if the runner can observe the selected skill, command route, or a
stable proxy artifact.

## Repository Layout

L1 cases live under the target-first layout defined in
[../l0-solution/spec.md](../l0-solution/spec.md). Skill evals live under
`skills/<skill-id>/`:

```text
tests/evals/
  manifests/
    skills/
      create-pr/
        trigger.json
        artifact.json
        behavior.json
  fixtures/
    skills/
      create-pr/
        trigger/
          prompts.csv
          README.md
        artifact/
          expected-schema.yml
          README.md
        behavior/
          repo-state.json
          expected-actions.json
          README.md
```

Small, public-safe, PR-blocking fixtures live in this tree. Large, sensitive, or
model-driven datasets may live in an external registry and be referenced by
logical dataset name, version, and hash.

## L1 Specification

### L1 Definition

L1 evaluates observable skill outcomes. It is only valid when the runner can
observe the skill outcome. A prompt label without observable selection,
artifact, or structured output is not sufficient.

### L1 Boundaries

L1 boundaries describe what the eval observes. They are not manifest fields and
do not imply that every skill must implement every boundary before L1 can run.
The boundary model follows a common eval pattern: check routing or tool
selection, check the produced output artifact, then check the traced workflow or
tool trajectory when the runner can observe it.

| Boundary | What is measured | Blocking status |
| --- | --- | --- |
| `skill-trigger` | Expected skill selection vs observed selection or stable proxy artifact. | Report-only until observation is stable and dataset is reviewed. |
| `skill-artifact` | Expected artifact schema and safety vs produced artifact. | Blocking only after schema stabilizes. |
| `skill-behavior` | Expected action sequence, guardrail decision, or repository-state transition vs observed trajectory/action log. | Blocking only when the fixture and trajectory/action log are deterministic. |

### L1 Observable Signals

Allowed L1 signals, in order of preference:

1. Direct skill-selection telemetry from the runner or host environment.
2. A stable command/tool invocation record that uniquely identifies the skill.
3. A deterministic artifact produced only by the intended skill.
4. A structured response with declared `skill_id` emitted by a test harness.

If none of these exists, the case remains `experimental` and cannot block.

### L1 Trigger Dataset Design

This section applies to `skill-trigger` cases. `skill-artifact` and
`skill-behavior` cases use fixture schemas and action-log fixtures instead of
prompt-stratified trigger datasets.

Each mature trigger dataset must be stratified. The minimum first-pass dataset
for one skill is:

| Stratum | Minimum cases | Purpose |
| --- | --- | --- |
| Explicit positive | 5 | User directly names the skill or task. |
| Implicit positive | 5 | User describes the skill domain without naming it. |
| Contextual positive | 5 | Prompt includes realistic noise and still should trigger. |
| Negative control | 10 | Adjacent request must not trigger the skill. |
| Ambiguous | 5 | Should ask clarification or remain report-only. |

Trigger dataset rules:

- Every row has `id`, `skill`, `stratum`, `prompt`, `label`, `expected_signal`,
  `source`, `version`, and `sensitivity`.
- LLM-generated prompts are acceptable as candidate rows for each stratum, but
  labels and safety classification must be human-reviewed before the dataset
  can support blocking decisions.
- Prompt text must not include real customer data, secrets, tenant IDs,
  subscription IDs, private URLs, or local-only paths.
- Keep a holdout subset once the dataset exceeds 50 cases for a skill.
- Record false positives and false negatives by stratum.

CSV is acceptable for simple trigger datasets:

```csv
id,skill,stratum,prompt,label,expected_signal,source,version,sensitivity
create-pr-001,skill:create-pr,explicit_positive,"Create a pull request for this branch",trigger,skill_selection,local,1,public_synthetic
create-pr-002,skill:create-pr,negative_control,"Summarize this README",no_trigger,skill_selection,local,1,public_synthetic
```

Use JSONL when fixture metadata becomes nested.

### L1 Decision Metrics

L1 metrics should follow the boundary under test. Trigger metrics summarize
routing quality across a prompt dataset. Artifact and behavior metrics summarize
deterministic fixture failures by failure type so regressions point to the
broken obligation.

#### Trigger Metrics

For L1 trigger evals, report confusion-matrix counts:

- True positives.
- False positives.
- True negatives.
- False negatives.
- Ambiguous cases separated from binary trigger/no-trigger metrics.

Promotion thresholds should be explicit per skill. A reasonable initial blocking
candidate threshold for a mature deterministic trigger dataset is:

- False negative rate <= 5% on positive strata.
- False positive rate <= 2% on negative controls.
- No critical false positives on high-risk adjacent prompts.
- Zero secret or environment-identifier leakage.
- At least three consecutive clean scheduled runs after dataset review.

These thresholds are starting policy, not universal truth. Each skill can set a
stricter threshold in its manifest.

#### Artifact Metrics

For L1 artifact evals, report deterministic artifact quality counts:

- Schema passes and schema failures.
- Missing required sections or fields.
- Diff-grounding failures.
- Hallucinated files, tests, issues, reviewers, or commands absent from the
  fixture.
- Redaction failures for secrets or environment-specific identifiers.

Promotion thresholds should be explicit per artifact type. A reasonable initial
blocking candidate threshold for a mature deterministic artifact fixture is:

- 100% schema pass rate on blocking fixtures.
- Zero redaction failures.
- Zero hallucinated claims about fixture state.
- No critical diff-grounding failures.
- At least three consecutive clean scheduled runs after fixture review.

#### Behavior Metrics

For L1 behavior evals, report deterministic workflow counts:

- Expected action-log matches.
- Missing required actions.
- Unexpected or forbidden actions.
- Guardrail decision mismatches.
- Mocked command argument mismatches.
- Repository-state mismatches after the run.

Promotion thresholds should be explicit per behavior fixture. A reasonable
initial blocking candidate threshold for a mature deterministic behavior fixture
is:

- 100% required-action match rate on blocking fixtures.
- Zero forbidden actions.
- Zero live external side effects in dry-run fixtures.
- Zero guardrail decision mismatches.
- At least three consecutive clean scheduled runs after fixture review.

### Nondeterministic L1

If any L1 boundary is nondeterministic:

- Use fixed `trials: k`.
- Use `pass_hat_k` for reliability gates and `pass_at_k` only for capability
  exploration.
- Record per-trial outputs.
- Compare against a recorded baseline and variance band before calling a change
  a regression.
- Do not block on LLM-graded output until judge calibration exists.

This rule applies to `skill-trigger`, `skill-artifact`, and `skill-behavior`
cases. A nondeterministic trigger may vary in selected skill, a nondeterministic
artifact may vary in generated structure or grounding, and a nondeterministic
behavior run may vary in action sequence or guardrail decision.

## Create PR L1 Specification

### Create PR Target

The first L1 version intentionally starts with one skill:

- `skill:create-pr`

`skill:create-pr` is the lowest-friction target because its PR title/body
artifact can be checked with deterministic schema and text rules before any
live GitHub PR creation is required.

Future L1 targets can expand after the `create-pr` artifact and behavior evals
are stable:

- `skill:code-review`
- `skill:security-audit`
- `skill:sync-docs`
- `skill:find-brute-force`
- `skill:find-duplicates`
- `skill:find-over-design`
- `skill:dead-code-detection`

### Create PR Boundary Mapping

`skill:create-pr` uses the generic L1 boundaries as follows:

| Boundary | Create PR question | Observable signal |
| --- | --- | --- |
| `skill-trigger` | Should this request invoke the PR creation skill? | Selected skill, command route, or stable proxy artifact. |
| `skill-artifact` | Did the skill produce a valid PR title and body payload? | Generated PR payload checked against schema and text rules. |
| `skill-behavior` | Did the skill follow the required PR workflow before creating or refusing the PR? | Trajectory/action log, mocked `gh` call, git state, exit code, and PR creation payload. |

### Create PR Observable Signals

`skill:create-pr` should expose these signals before a case can become
blocking:

| Boundary | Observable signal | Blocking use |
| --- | --- | --- |
| `skill-artifact` | PR title, PR body, linked issue reference, testing section, and quality-check summary. | Validate the generated PR payload against schema and text rules. |
| `skill-artifact` | Redaction result for secrets, local paths, tenant IDs, subscription IDs, private URLs, and other environment-specific identifiers. | Fail the case when the PR payload would expose private or local-only data. |
| `skill-behavior` | Mocked `gh pr create` invocation with recorded title, body, base branch, head branch, draft flag, labels, and linked issue. | Prove the skill would call GitHub with the expected arguments without creating a live PR. |
| `skill-behavior` | Git state snapshot: branch name, base branch, HEAD SHA, working-tree cleanliness, and available commits. | Prove the skill made the PR decision from the expected repository state. |
| `skill-behavior` | Guardrail decision: create, refuse, or ask for clarification. | Prove the skill stops when required inputs or safety conditions are missing. |
| `skill-trigger` | Selected skill, command route, or stable proxy artifact. | Report-only until the runner can observe skill selection reliably. |

Signals based on user adoption, reviewer satisfaction, or later repair success
are outside the first `create-pr` L1 slice. They may be useful for higher-level
outcome or trajectory evals, but they do not help prove whether
`skill:create-pr` produced the right artifact or followed the required workflow
in a deterministic fixture.

### Create PR Fixture Dataset

The `create-pr` dataset is not only a prompt dataset. Each fixture needs enough
repository context for the skill to produce a meaningful PR title/body and to
prove the workflow decisions that led to that payload.

Each static fixture should include:

- User request prompt, such as "create a PR for this branch".
- Base branch, head branch, and HEAD SHA metadata.
- A sanitized `git diff` or equivalent patch between base and head.
- Optional commit list when the PR body should summarize multiple commits.
- Existing issue id or work item reference when linkage is expected.
- Expected PR payload schema, including required sections and forbidden content.
- Expected behavior record, such as required pre-PR checks, expected guardrail
  decision, mocked `gh pr create` arguments, and forbidden actions.

The `git diff` is the primary fixture input because it lets the artifact grader
verify that the generated PR title/body reflects the actual code change instead
of a generic PR template. The same fixture can also drive behavior checks by
comparing the observed action log or mocked command calls against the expected
workflow for that repository state. The diff must be public-safe and
fixture-sized; use small synthetic patches for blocking Tier A cases.

The deterministic artifact grader should check:

- The payload parses into the expected PR title/body shape.
- The title summarizes the dominant change in the diff.
- The body includes required sections such as summary, changes, testing, quality
  checks, and linked issue when provided by the fixture.
- The body does not claim tests, files, issues, or reviewers that are absent from
  the fixture.
- The payload does not expose secrets, local paths, tenant IDs, subscription IDs,
  private URLs, or other environment-specific identifiers.

The deterministic behavior grader should check:

- Required pre-PR checks were run or explicitly reported as unavailable by the
  fixture.
- The guardrail decision matches the fixture state: create, refuse, or ask for
  clarification.
- The mocked `gh pr create` call uses the expected title, body, base branch,
  head branch, draft flag, labels, and linked issue.
- The workflow does not push, open a live PR, skip required checks, or mutate
  files when the fixture expects a dry-run artifact.

### Create PR First Runnable Case

The first runnable L1 case should start with `skill-artifact` for
`skill:create-pr`. It should use a static repo fixture with a sanitized
`git diff`, an expected PR body schema, and a deterministic grader for title,
body, issue linkage, testing evidence, quality-check summary, diff grounding,
and redaction.

Behavior evals should reuse the same deterministic repo fixtures by adding
expected action logs and mocked `gh` calls that record command arguments instead
of creating a live pull request. Trigger evals remain report-only until the
runner can observe skill selection or an equivalent stable proxy.

## Scorecard Schema

L1 emits the same case-level scorecard as the framework; see
[../l0-solution/spec.md](../l0-solution/spec.md) for the full schema, allowed
`status` values, and allowed `failure_type` values. L1 rows populate the
classification-metric fields (`false_positive`, `false_negative`) for
`skill-trigger` cases, which deterministic L0 rows leave at zero.

## Runtime Profiles And Azure Configuration

L1 runs on the framework runtime profiles defined in
[../l0-solution/spec.md](../l0-solution/spec.md): deterministic L1 checks use the
Tier A `local-fast` and `github-pr` profiles; model-driven L1 checks use the
Tier B `azure-l1-nightly` profile. The Azure configuration and secret contract in
the L0 spec applies to all L1 Tier B datasets unchanged.

## Promotion Rules

L1 evals follow the framework promotion rules in
[../l0-solution/spec.md](../l0-solution/spec.md). Two L1-specific reminders:

- A `skill-trigger` case cannot become blocking until it has an observable skill
  selection signal or a stable proxy artifact.
- A rubric-graded `skill-behavior` case cannot become blocking until judge
  calibration exists and reports a critical false-negative rate.

## First Acceptance Criteria

- SKILL.md frontmatter validation runs in Tier A CI and blocks a skill that would
  silently fail to load.
- One L1 `create-pr` artifact eval exists with a static fixture, expected PR body
  schema, and deterministic grader, blocking on schema only.
- Any live skill-trigger proxy remains outside first acceptance until the
  deterministic `create-pr` artifact eval is stable.
- Azure profile names remain logical references; no environment-specific Azure
  identifiers are committed.
