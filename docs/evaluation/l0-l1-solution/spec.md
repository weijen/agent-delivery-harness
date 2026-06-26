# L0/L1 Evaluation Specification

## Scope

This specification defines the first runnable evaluation slice for the harness:

- **L0 script lifecycle**: unit-test-like execution, contract-test-like
  purpose. L0 protects deterministic harness mechanics such as script behavior,
  lifecycle order, hard/warn semantics, review-gate freshness, and safe cleanup.
- **L1 skills**: prompt-trigger, artifact, and structured behavior checks for
  `.copilot/skills/*` assets. L1 measures skill behavior only when the predicted
  outcome can be observed and scored.

L2 subagent roles, L3 trace trajectories, L4 outcome fixtures, L5 mutation
campaigns, and blocking LLM-as-judge gates are out of scope for this slice.

## Measurement Model

Every eval case must define the same measurement chain:

| Concept | Meaning | Required for L0 | Required for L1 |
| --- | --- | --- | --- |
| Label | Expected result, such as pass/fail, should-trigger, expected artifact, or expected refusal. | Yes | Yes |
| Prediction | The observed output from the target under test. | Yes | Yes |
| Observable signal | The concrete evidence used as prediction: exit code, git state, file state, artifact schema, skill-selection event, or structured output. | Yes | Yes |
| Grader | Deterministic or calibrated logic that compares prediction to label. | Yes | Yes |
| Decision rule | How grader output becomes pass, fail, report-only, or block. | Yes | Yes |

An eval without an observable prediction is not an eval. It is a dataset draft.
This is especially important for L1 skill trigger cases: `should_trigger=true`
is only useful if the runner can observe the selected skill, command route, or a
stable proxy artifact.

## Repository Layout

The implementation should use this layout when eval code is added:

```text
tests/evals/
  bin/
    run-evals.sh
    validate-manifest.sh
  manifests/
    scripts/
      harness-contract.json
      lifecycle-order.json
      review-gate.json
      feature-list.json
      issue-scaffold.json
    skills/
      create-pr/
        trigger.json
        artifact.json
        behavior.json
  fixtures/
    scripts/
      harness-contract/
      lifecycle-order/
      review-gate/
      feature-list/
      issue-scaffold/
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
  baselines/
    README.md
  scorecards/
    .gitkeep
```

Manifests are JSON (`*.json`), validated with `jq`. Eval tooling (the runner and
the manifest validator) lives under `tests/evals/bin/`, keeping `scripts/` for
harness lifecycle entrypoints.

The layout is target-first. Harness script evals live under `scripts/`; skill
evals live under `skills/<skill-id>/`. Keep L0 and L1 in the manifest path or
suite selection, and use the manifest `boundary` field for classifications such
as `script-lifecycle`, `skill-trigger`, `skill-artifact`, and `skill-behavior`.
This keeps each manifest small and avoids duplicating layer metadata that the
runner can infer from where the case is selected.

Small, public-safe, PR-blocking fixtures live in this tree. Large, sensitive, or
model-driven datasets may live in an external registry and be referenced by
logical dataset name, version, and hash.

Generated scorecards are local artifacts and should not be committed. Approved
baselines, when introduced, must live under `tests/evals/baselines/` with
dataset version, fixture hash, runner version, and approval rationale.

## Manifest Schema

Each eval case is declared by a manifest. Manifests are the source of truth for
target, capability, fixture, expected outcome, grader, and blocking policy.

```json
{
  "id": "l0-review-gate-freshness",
  "schema_version": 1,
  "target": "scripts/review-gate.sh",
  "capability": "blocks_stale_review_approval",
  "boundary": "script-lifecycle",
  "fixture": {
    "type": "generated",
    "builder": "tests/scripts/test_review_gate.sh",
    "builder_version": 1
  },
  "expected_outcome": "reject",
  "grader": {
    "type": "shell",
    "command": "tests/scripts/test_review_gate.sh"
  },
  "blocking": true
}
```

Field reference:

| Field | Required | Meaning |
| --- | --- |
| `id` | Yes | Stable case identifier. Keep it unique and do not reuse it when the capability changes meaning. |
| `schema_version` | Yes | Manifest schema version. Increment only when the manifest format changes. |
| `target` | Yes | The script, skill, subagent, prompt, or schema being evaluated. Use repo paths for files and logical ids such as `skill:code-review` for non-file targets. |
| `capability` | Yes | The single behavior this case proves. Phrase it as one observable obligation, not a broad quality area. |
| `boundary` | Yes | The harness responsibility area the case protects, such as `script-lifecycle`, `skill-behavior`, or `subagent-role`. |
| `fixture` | Yes | Reproducible input for the case. Use `type: generated` with a deterministic builder, or `type: static` with a checked-in path. |
| `expected_outcome` | Yes | Ground truth the grader should prove, such as `reject`, `allow`, `blocking_finding`, or `valid_artifact`. Actual predictions belong in scorecards. |
| `grader` | Yes | The deterministic command, schema check, rubric, or hybrid grader that turns fixture output into pass/fail evidence. |
| `blocking` | Yes | Whether failure should fail the local or CI run. Use `false` for report-only L1 capability tracking until the case is stable. |
| `trials` | No | Number of repeated runs for nondeterministic L1 targets. Omit for deterministic L0 cases, which default to `1`. |
| `threshold` | No | Metric thresholds for nondeterministic or hybrid graders, such as pass rate or critical false-negative rate. |
| `source_dataset` | No | Provenance for public benchmark fixtures adapted into local, versioned cases. Blocking applies to the local fixture. |
| `contract_refs` | No | References to harness lifecycle or role-boundary obligations when the case claims coverage of a specific contract item. |

The `fixture` field is a `oneOf`: a generated fixture declares `type:
generated` and `builder`, while a static fixture declares `type: static` and
`path`. Declaring neither shape, or both, is invalid. Static fixture `hash`
values become required only for approved baselines.

## L0 Specification

### L0 Definition

L0 is the deterministic foundation layer. It is not a broad agent capability
eval. It is a contract regression layer for harness mechanics.

L0 tests are unit-test-like in execution but lifecycle-contract tests in
purpose. They should run quickly, use local temporary fixtures, and block PRs.

### L0 Targets

- `scripts/init.sh`
- `scripts/issue-lib.sh`
- `scripts/start-issue.sh`
- `scripts/check-feature-list.sh`
- `scripts/review-gate.sh`
- `scripts/create-pr.sh`
- `scripts/finish-issue.sh`
- `docs/harness-contract.yml`

### Required L0 Capabilities

| Eval id | Existing bootstrap command | Capability | Required observable signal |
| --- | --- | --- | --- |
| `l0-harness-contract` | `tests/scripts/test_harness_contract.sh` | Contract obligations remain declared and present. | Contract parse result, owner pattern checks, script parse status. |
| `l0-lifecycle-order` | `tests/scripts/test_lifecycle_order.sh` | Critical lifecycle ordering is preserved. | Temporary repo state, worktree/branch presence, push/PR side effects. |
| `l0-review-gate` | `tests/scripts/test_review_gate.sh` | Review approval is bound to current HEAD. | HEAD SHA, marker file content, create-pr exit behavior. |
| `l0-feature-list` | `tests/scripts/test_feature_list_check.sh` | Feature completion schema and hard/warn semantics hold. | JSON parse status, exit code, warning/hard failure evidence. |
| `l0-issue-scaffold` | `tests/scripts/test_issue_scaffold.sh` | Tracking and Action Log scaffold are created. | File existence, Markdown heading presence, issue directory state. |

The existing shell tests are bootstrap inputs. The runner should eventually emit
case-level scorecard rows for each scenario inside those scripts, not only one
coarse pass/fail row per shell file.

### L0 Rules

- L0 manifests use `blocking: true` and default to `trials: 1`.
- L0 graders must be deterministic: shell, schema, filesystem, or git-state.
- L0 does not use Azure, live GitHub auth, live web calls, or LLM calls.
- L0 fixtures must isolate external state so results do not depend on the
  developer machine.
- Expected results must include observable state, not only text presence.
- A flaky L0 result is an eval bug and must be fixed, not averaged.

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

Every runner emits a scorecard with case-level rows. The scorecard is the
machine-readable contract; summaries are secondary human artifacts.

```json
{
  "schema_version": 1,
  "run_id": "local-20260623T120000Z",
  "commit_sha": "<sha>",
  "runtime": "local",
  "runner_version": "0.1.0",
  "suite": "l0-l1",
  "manifest_path": "tests/evals/manifests/scripts/review-gate.json",
  "manifest_version": 1,
  "fixture_path": "tests/evals/fixtures/scripts/review-gate/",
  "fixture_version": 1,
  "fixture_hash": "<sha256>",
  "dataset_version": null,
  "tool_versions": {
    "bash": "<version>",
    "git": "<version>"
  },
  "redaction": {
    "checked": true,
    "secrets_found": false,
    "environment_identifiers_found": false
  },
  "results": [
    {
      "case_id": "l0-review-gate-stale-head",
      "target": "scripts/review-gate.sh",
      "capability": "blocks_stale_review_approval",
      "boundary": "script-lifecycle",
      "label": "reject",
      "prediction": "reject",
      "observable_signal": ["exit_code", "stderr_regex", "head_sha"],
      "grader": "shell",
      "status": "pass",
      "blocking_decision": "pass",
      "trials": 1,
      "duration_ms": 1200,
      "skip_reason": null,
      "failure_type": null,
      "evidence": ["current HEAD has not been approved"]
    }
  ],
  "aggregates": {
    "total_cases": 1,
    "passed": 1,
    "failed": 0,
    "skipped": 0,
    "false_positive": 0,
    "false_negative": 0
  }
}
```

Allowed case `status` values:

- `pass`
- `fail`
- `not_run`
- `skipped`
- `invalid_manifest`
- `infrastructure_error`

Allowed `failure_type` values:

- `target_failure`
- `fixture_failure`
- `runner_failure`
- `grader_failure`
- `environment_missing`
- `redaction_failure`

## Runtime Profiles

Profiles map onto two tiers split by determinism. `local-fast` and `github-pr`
are **Tier A** (deterministic, blocking, part of CI). `azure-l1-nightly` is
**Tier B** (model-driven, report-only, never a PR gate).

### `local-fast` (Tier A)

- Runs L0 and deterministic L1 cases (frontmatter lint, description proxy,
  artifact schema).
- Requires no Azure configuration and makes no live model call.
- Writes local scorecards.

### `github-pr` (Tier A)

- Runs blocking L0 and mature deterministic L1 cases as part of the CI pipeline.
- Uses standard GitHub-hosted Linux runners.
- Uploads only sanitized scorecards and summaries with short retention.
- Does not require tenant or subscription IDs and makes no live model call.

### `azure-l1-nightly` (Tier B)

- The committed home for model-driven evals, run nightly or on demand.
- Runs live skill-selection trigger runs, multi-trial `pass^k` datasets, and
  calibrated LLM-as-judge behavior evals.
- Report-only: never a required PR gate, so external contributors' PRs never
  depend on the maintainer's Azure subscription.
- Requires runtime configuration outside the repository.
- Emits the same scorecard schema as local and GitHub Actions runs.
- Measures a pinned-model proxy or a Copilot CLI session, not VS Code Copilot's
  internal selection.
- Missing Azure configuration yields `not_run` with `failure_type:
  environment_missing`, not a Tier A failure.

## Azure Configuration Contract

Tracked files may reference only logical profile names and environment variable
names. They must not contain real tenant IDs, subscription IDs, resource group
names, workspace names, endpoints, keys, tokens, or connection strings.

Allowed environment variable names:

```text
AZURE_TENANT_ID
AZURE_SUBSCRIPTION_ID
AZURE_RESOURCE_GROUP
AZUREML_WORKSPACE_NAME
AZURE_AI_PROJECT_NAME
FOUNDRY_PROJECT_ENDPOINT
```

Real values must stay in local untracked configuration, GitHub secrets, Azure
managed identity configuration, Key Vault, or another approved secret store.

## Promotion Rules

An eval can move from `experimental` to `report_only` when:

- The manifest is valid.
- The fixture is versioned and hashed.
- The measurement model has label, prediction, signal, grader, and decision
  rule.
- The runner can reproduce a scorecard locally.
- Failures identify target, capability, and failure type.

An eval can move from `report_only` to `blocking` when:

- It has a reviewed dataset or deterministic fixture.
- It has stable observable signals.
- It has explicit false-positive and false-negative thresholds where relevant.
- It has no dependency on private credentials or live cloud state.
- For rubric graders, judge calibration exists and reports critical
  false-negative rate.

## First Acceptance Criteria

- L0 manifests exist for current script sensors.
- The runner emits case-level scorecard rows, not only shell-file-level pass/fail.
- Tier A cases block PRs in GitHub Actions without Azure configuration: L0
  lifecycle plus the deterministic `create-pr` artifact schema check.
- One L1 `create-pr` artifact eval exists with a static fixture, expected PR
  body schema, and deterministic grader.
- Any live skill-trigger proxy remains outside first acceptance until the
  deterministic `create-pr` artifact eval is stable.
- Azure profile names remain logical references; no environment-specific Azure
  identifiers are committed.
