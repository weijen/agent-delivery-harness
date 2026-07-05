# L0 Evaluation Specification

## Scope

This specification defines the first runnable evaluation slice for the harness
and the shared framework contract every later layer reuses:

- **L0 script lifecycle**: unit-test-like execution, contract-test-like
  purpose. L0 protects deterministic harness mechanics such as script behavior,
  lifecycle order, hard/warn semantics, review-gate freshness, and safe cleanup.
- **Framework contract**: the measurement model, repository layout, manifest
  schema, scorecard schema, and runtime profiles that the L1 layer builds on.

L1 skills, L2 subagent roles, L3 trace trajectories, L4 outcome fixtures, L5
mutation campaigns, and blocking LLM-as-judge gates are out of scope for this
slice. The L1 skills specification lives in
[../l1-solution/spec.md](../l1-solution/spec.md).

## Measurement Model

Every eval case must define the same measurement chain:

| Concept | Meaning | Required |
| --- | --- | --- |
| Label | Expected result, such as pass/fail, should-trigger, expected artifact, or expected refusal. | Yes |
| Prediction | The observed output from the target under test. | Yes |
| Observable signal | The concrete evidence used as prediction: exit code, git state, file state, artifact schema, skill-selection event, or structured output. | Yes |
| Grader | Deterministic or calibrated logic that compares prediction to label. | Yes |
| Decision rule | How grader output becomes pass, fail, report-only, or block. | Yes |

An eval without an observable prediction is not an eval. It is a dataset draft.
For L0 the prediction is always deterministic: an exit code, git state, or file
state.

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
        ...
  baselines/
    README.md
  scorecards/
    .gitkeep
```

Manifests are JSON (`*.json`), validated with `jq`. Eval tooling (the runner and
the manifest validator) lives under `tests/evals/bin/`, keeping `scripts/` for
harness lifecycle entrypoints.

The layout is target-first. Harness script evals live under `scripts/`; skill
evals live under `skills/<skill-id>/` and are specified in the L1 solution. Keep
L0 and L1 in the manifest path or suite selection, and use the manifest
`boundary` field for classifications such as `script-lifecycle`,
`skill-trigger`, `skill-artifact`, and `skill-behavior`. This keeps each manifest
small and avoids duplicating layer metadata that the runner can infer from where
the case is selected.

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
| --- | --- | --- |
| `id` | Yes | Stable case identifier. Keep it unique and do not reuse it when the capability changes meaning. |
| `schema_version` | Yes | Manifest schema version. Increment only when the manifest format changes. |
| `target` | Yes | The script, skill, subagent, prompt, or schema being evaluated. Use repo paths for files and logical ids such as `skill:code-review` for non-file targets. |
| `capability` | Yes | The single behavior this case proves. Phrase it as one observable obligation, not a broad quality area. |
| `boundary` | Yes | The harness responsibility area the case protects, such as `script-lifecycle`, `skill-behavior`, or `subagent-role`. |
| `fixture` | Yes | Reproducible input for the case. Use `type: generated` with a deterministic builder, or `type: static` with a checked-in path. |
| `expected_outcome` | Yes | Ground truth the grader should prove, such as `reject`, `allow`, `blocking_finding`, or `valid_artifact`. Actual predictions belong in scorecards. |
| `grader` | Yes | The deterministic command, schema check, rubric, or hybrid grader that turns fixture output into pass/fail evidence. |
| `blocking` | Yes | Whether failure should fail the local or CI run. Use `false` for report-only capability tracking until the case is stable. |
| `trials` | No | Number of repeated runs for nondeterministic targets. Omit for deterministic L0 cases, which default to `1`. |
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

## Scorecard Schema

Every runner emits a scorecard with case-level rows. The scorecard is the
machine-readable contract; summaries are secondary human artifacts. The L1 layer
reuses this exact schema.

```json
{
  "schema_version": 1,
  "run_id": "local-20260623T120000Z",
  "commit_sha": "<sha>",
  "runtime": "local",
  "runner_version": "0.1.0",
  "suite": "l0",
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
**Tier B** (model-driven, report-only, never a PR gate), first consumed by the
L1 layer.

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
  calibrated LLM-as-judge behavior evals defined in the L1 solution.
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
- Tier A L0 cases block PRs in GitHub Actions without Azure configuration.
- The scorecard schema is stable enough for the L1 layer to reuse unchanged.
- Azure profile names remain logical references; no environment-specific Azure
  identifiers are committed.
