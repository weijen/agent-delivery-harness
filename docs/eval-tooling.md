---
title: Evaluation tooling
description: Maintainer reference for the implemented local evaluation commands and contracts
---

The local evaluation tools wrap deterministic harness sensors in JSON manifests
and emit scorecards. They do not measure runtime agent quality, internal IDE
skill selection, or comparative model cost.

This is a source-only maintainer reference. The developer installation includes
the portable L0 tools and manifests through
[install-harness.dev.assets](../scripts/install-harness.dev.assets); the default
adopter installation does not include those evaluation tools. Current lifecycle
requirements remain in [HARNESS.md](HARNESS.md).

## Commands

Run from the repository or developer installation root with Bash, Git and `jq`
available:

```bash
bash tests/evals/bin/validate-manifest.sh tests/evals/manifests/scripts/l0-feature-list.json
bash tests/evals/bin/run-evals.sh tests/evals/manifests/scripts/l0-feature-list.json
bash tests/evals/bin/run-l0-suite.sh
```

| Command | Input and output | Exit behavior |
| --- | --- | --- |
| [validate-manifest.sh](../tests/evals/bin/validate-manifest.sh) | One JSON manifest; prints `valid_manifest` on success or a diagnostic on failure. | `0` valid, `1` invalid/missing manifest or missing `jq`, `2` usage error. |
| [run-evals.sh](../tests/evals/bin/run-evals.sh) | One manifest; executes `grader.command` and writes one JSON scorecard to stdout. | `1` for a blocking case failure; invalid manifests and unavailable grader executables emit warning rows with `0`. Usage errors return `2`; missing runner dependencies can fail without a scorecard. |
| [run-l0-suite.sh](../tests/evals/bin/run-l0-suite.sh) | Optional manifest directory; runs its sorted `l0-*.json` manifests, defaulting to the shipped scripts directory. Emits each scorecard separately, not a combined JSON array. | `1` for a blocking result, nonzero runner exit, missing scorecard, or malformed/mismatched result; `2` for usage, missing dependencies, or no matching manifests. |

The five shipped manifests cover feature-list validation, the harness contract,
issue scaffolding, lifecycle order, and review gates. Graders own their fixtures
and assertions. The runner does not execute `fixture.builder` separately.
Manifests execute shell commands and must come from trusted repository content.

Ordinary source gates run functional sensors once through discovery. They do
not rerun the full L0 suite to generate reports. Small recording workloads
protect runner/manifest wiring and installed-package behavior without duplicating
functional execution. Explicit suite execution still runs the shipped graders
and shares the [600-second test budget](HARNESS.md#shared-test-execution-budget).
Scorecards go to stdout; saved run-specific output is local evidence, not
committed baseline data.

## Manifest contract

The [validator](../tests/evals/bin/validate-manifest.sh) is the executable
authority. Required, non-null fields are:

```text
id schema_version target capability boundary fixture expected_outcome grader blocking
```

* `boundary` is `script-lifecycle`, `skill-trigger`, `skill-artifact`, or
  `skill-behavior`. Accepted vocabulary does not imply delivered skill evals.
* `blocking` is a JSON boolean.
* `fixture` is an object. `type: generated` requires `builder` and forbids
  a non-null `path`; `type: static` requires `path` and forbids a non-null
  `builder`.
* Optional metadata such as `trials`, `threshold`, `source_dataset`, and
  `contract_refs` is accepted, but is not interpreted by the local runner.
  Validation is not a full type/schema check of every field.

For example, the shipped
[feature-list manifest](../tests/evals/manifests/scripts/l0-feature-list.json)
uses `grader.type: shell` and
`grader.command: bash tests/scripts/validation/test_feature_list_check.sh`.
The runner executes that command once; it does not implement repeated trials,
threshold scoring, or grader-type dispatch.

## Scorecard contract

The [runner](../tests/evals/bin/run-evals.sh) emits schema version `1`, suite
`l0`, and exactly one `results` row per manifest:

| Field group | Emitted content |
| --- | --- |
| Run identity | `schema_version`, `run_id`, `commit_sha`, `runtime`, `runner_version`, `suite`, `manifest_path`, `manifest_version` |
| Provenance | `tool_versions` for Bash, Git and `jq`; `fixture_path`, `fixture_version`, `fixture_hash`, and `dataset_version` are currently null |
| Redaction | `checked`, `secrets_found`, `environment_identifiers_found` |
| Result | `case_id`, `target`, `capability`, `boundary`, `label`, `prediction`, `observable_signal`, `grader`, `status`, `blocking_decision`, `trials`, `duration_ms`, `skip_reason`, `failure_type`, `evidence` |
| Aggregates | `total_cases`, `passed`, `failed`, `skipped`, `false_positive`, `false_negative` |

`label` is the manifest's expected outcome; `prediction` is the runner status,
not an independently classified domain outcome. `observable_signal` is
`["exit_code"]`, `trials` is `1`, and duration has whole-second resolution.
False-positive and false-negative counts are zero placeholders, not measured
classification accuracy.

| Condition | Status / failure type | Blocking decision |
| --- | --- | --- |
| Grader exits `0` | `pass` / null | `pass` |
| Grader exits nonzero | `fail` / `target_failure` | `block` if `blocking: true`, otherwise `warn` |
| Manifest validation fails | `invalid_manifest` / null | `warn` |
| Grader executable is unavailable | `not_run` / `environment_missing` | `warn` |
| Secret-shaped captured evidence | `fail` / `redaction_failure` | `block` if `blocking: true`, otherwise `warn` |

Secret-shaped output is checked before ordinary grader status. It is emitted
only after successful redaction and a clean backstop scan; otherwise evidence
is withheld. `environment_identifiers_found: false` is not proof that arbitrary
environment identifiers have been audited.

The suite accepts `infrastructure_error` rows for compatibility, but the current
runner does not generate them. `RUN_EVALS_RUNTIME` accepts `local`, `github-pr`,
`github-actions`, and `azure-l1-nightly`; unknown values normalize to `local`.
These are output labels, not execution backends. No Azure scheduler, live-model
evaluation, or internal VS Code selector observation is provided by these tools.

## CI and retained history

The [source smoke workflow](../.github/workflows/harness-smoke.yml) runs applicable
functional sensors and
[customization frontmatter validation](../tests/evals/bin/validate-customization-frontmatter.sh).
Frontmatter validation protects file structure, not skill selection or behavior.

The active evaluation roadmap and L0/L1 research documents were deleted under
#546. Existing [archived evaluation research](archive/evaluation/README.md)
remains historical; links to deleted proposals pin their last upstream revision.
It is not an additional lifecycle gate or delivery commitment.
