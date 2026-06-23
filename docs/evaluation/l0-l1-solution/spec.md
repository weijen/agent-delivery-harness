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
  manifests/
    l0/
      harness-contract.yml
      lifecycle-order.yml
      review-gate.yml
    l1/
      code-review-trigger.yml
      create-pr-artifact.yml
  fixtures/
    l0/
      harness-contract/
      lifecycle-order/
      review-gate/
    l1/
      code-review-trigger/
        prompts.csv
        README.md
      create-pr-artifact/
        expected-schema.yml
        README.md
  baselines/
    README.md
  scorecards/
    .gitkeep

scripts/run-evals.sh
```

Generated scorecards are local artifacts and should not be committed. Approved
baselines, when introduced, must live under `tests/evals/baselines/` with
dataset version, fixture hash, runner version, and approval rationale.

## Manifest Schema

Each eval case is declared by a manifest. Manifests are the source of truth for
target, capability, fixture, grader, runtime, and blocking policy.

```yaml
id: l0-review-gate-freshness
schema_version: 1
layer: L0
target: scripts/review-gate.sh
capability: blocks_stale_review_approval
boundary: script-lifecycle
mode: regression
maturity: blocking
fixture:
  path: tests/evals/fixtures/l0/review-gate/
  version: 1
  hash: <sha256>
measurement:
  label: stale approval is rejected
  prediction: exit code, stderr, and git/PR side effects
  observable_signal:
    - exit_code
    - stderr_regex
    - git_remote_state
grader:
  type: shell
  command: tests/scripts/test_review_gate.sh
decision_rule:
  metric: exact_pass
  threshold: 1.0
trials: 1
runtime:
  local: required
  github_actions: required
  azure: not_required
owner: harness-evaluation
```

Required fields:

| Field | Requirement |
| --- | --- |
| `id` | Stable and unique. Do not reuse for a changed capability. |
| `schema_version` | Manifest schema version. |
| `layer` | `L0` or `L1`. |
| `target` | Script path or skill id. |
| `capability` | One behavior under test. |
| `boundary` | `script-lifecycle`, `skill-trigger`, `skill-artifact`, or `skill-behavior`. |
| `mode` | `regression` or `capability`. |
| `maturity` | `blocking`, `report_only`, or `experimental`. |
| `fixture` | Path, version, and hash for reproducibility. |
| `measurement` | Label, prediction, and observable signal. |
| `grader` | Deterministic command/schema check or calibrated rubric. |
| `decision_rule` | Metric and threshold. |
| `trials` | `1` for deterministic; fixed `k` for nondeterministic. |
| `runtime` | Local, GitHub Actions, and optional Azure policy. |
| `owner` | Maintainer group or area. |

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

- L0 manifests use `mode: regression`, `maturity: blocking`, and `trials: 1`.
- L0 graders must be deterministic: shell, schema, filesystem, or git-state.
- L0 does not use Azure, live GitHub auth, live web calls, or LLM calls.
- External tools must be faked on `PATH` where possible.
- Expected results must include observable state, not only text presence.
- A flaky L0 result is an eval bug and must be fixed, not averaged.

## L1 Specification

### L1 Definition

L1 evaluates skill behavior. It is only valid when the runner can observe the
skill outcome. A prompt label without observable selection, artifact, or
structured output is not sufficient.

### L1 Targets

Initial targets:

- `skill:code-review`
- `skill:create-pr`
- `skill:security-audit`
- `skill:sync-docs`

Expansion targets:

- `skill:find-brute-force`
- `skill:find-duplicates`
- `skill:find-over-design`
- `skill:dead-code-detection`

### L1 Maturity Levels

| Level | Boundary | What is measured | Blocking status |
| --- | --- | --- | --- |
| L1a | `skill-trigger` | Expected skill selection vs observed selection or stable proxy artifact. | Report-only until observation is stable and dataset is reviewed. |
| L1b | `skill-artifact` | Expected artifact schema and safety vs produced artifact. | Blocking only after schema stabilizes. |
| L1c | `skill-behavior` | Expected review/audit behavior vs structured output. | Report-only until judge calibration exists. |

### L1 Observable Signals

Allowed L1 signals, in order of preference:

1. Direct skill-selection telemetry from the runner or host environment.
2. A stable command/tool invocation record that uniquely identifies the skill.
3. A deterministic artifact produced only by the intended skill.
4. A structured response with declared `skill_id` emitted by a test harness.

If none of these exists, the case remains `experimental` and cannot block.

### L1 Dataset Design

Each mature skill dataset must be stratified. The minimum first-pass dataset for
one skill is:

| Stratum | Minimum cases | Purpose |
| --- | --- | --- |
| Explicit positive | 5 | User directly names the skill or task. |
| Implicit positive | 5 | User describes the skill domain without naming it. |
| Contextual positive | 5 | Prompt includes realistic noise and still should trigger. |
| Negative control | 10 | Adjacent request must not trigger the skill. |
| Ambiguous | 5 | Should ask clarification or remain report-only. |

Dataset rules:

- Every row has `id`, `skill`, `stratum`, `prompt`, `label`, `expected_signal`,
  `source`, `version`, and `sensitivity`.
- Prompt text must not include real customer data, secrets, tenant IDs,
  subscription IDs, private URLs, or local-only paths.
- Labels require human review before a dataset can support blocking decisions.
- Keep a holdout subset once the dataset exceeds 50 cases for a skill.
- Record false positives and false negatives by stratum.

CSV is acceptable for simple trigger datasets:

```csv
id,skill,stratum,prompt,label,expected_signal,source,version,sensitivity
code-review-001,skill:code-review,explicit_positive,"Review this diff for bugs",trigger,skill_selection,local,1,public_synthetic
code-review-002,skill:code-review,negative_control,"Summarize this README",no_trigger,skill_selection,local,1,public_synthetic
```

Use JSONL when fixture metadata becomes nested.

### L1 Decision Metrics

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

### Nondeterministic L1

If L1 behavior is nondeterministic:

- Use fixed `trials: k`.
- Use `pass_hat_k` for reliability gates and `pass_at_k` only for capability
  exploration.
- Record per-trial outputs.
- Compare against a recorded baseline and variance band before calling a change
  a regression.
- Do not block on LLM-graded output until judge calibration exists.

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
  "manifest_path": "tests/evals/manifests/l0/review-gate.yml",
  "manifest_version": 1,
  "fixture_path": "tests/evals/fixtures/l0/review-gate/",
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
      "layer": "L0",
      "target": "scripts/review-gate.sh",
      "capability": "blocks_stale_review_approval",
      "boundary": "script-lifecycle",
      "mode": "regression",
      "maturity": "blocking",
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
  lifecycle plus the deterministic L1 checks (starting with SKILL.md frontmatter
  validation, which CI already performs).
- One L1 `code-review` trigger dataset exists with explicit positive, negative,
  contextual, and ambiguous strata, declaring the observable signal used to
  detect skill selection.
- The live `code-review` trigger eval runs as Tier B on Azure, report-only, and
  is labeled a pinned-model or Copilot CLI proxy rather than VS Code Copilot
  selection.
- Azure profile names remain logical references; no environment-specific Azure
  identifiers are committed.