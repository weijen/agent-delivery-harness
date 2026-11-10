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
and shares the [900-second hard test budget](HARNESS.md#shared-test-execution-budget);
600 seconds is a performance target.
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

## Representative workflow evaluation (#571)

This bounded record accompanies the runtime, policy and guide deliveries
#572–#574. **No controlled model-adherence evaluations were executed.**
The evidence below separates observed issue delivery, executed deterministic
CLI fixtures and semantic/tabletop walkthroughs. It does not establish prompt
adherence, cross-host reliability, comparative quality, cost or success rates.
There are no controlled model trial results, model comparisons or inferred scores.

| Path | Evidence kind | Observed outcome or walkthrough result | Stop / limitation |
| --- | --- | --- | --- |
| Read-only review | Tabletop of the routing map and guide | A question/review routes directly to an answer, without issue creation, worktree or publication. | No model task executed for this path; the expected stop is the answer. |
| Chat-driven edits | Tabletop of lifecycle authorization | Missing issue-creation authority requires a draft and owner decision before implementation; an approved issue needs no repeat handshake. | Declined/unclear authority stops edits. No controlled authorization prompt run. |
| Resumed feature | Observed #572 delivery, [PR #576](https://github.com/weijen/agent-delivery-harness/pull/576) | Resumed preflight initially hit a tooling download failure; recovery used the existing synced environment without gate skips. The next criterion received scoped evidence before commit/push. | The earlier one-feature session stopped with unfinished work; continuation followed explicit owner authorization. This is a delivery observation, not a benchmark. |
| Final-feature closeout | Observed #573 delivery, [PR #577](https://github.com/weijen/agent-delivery-harness/pull/577) | All three criteria passed; preparation preceded independent full review, exact-candidate approval, shared-budget final validation, publication, green CI, confirmed merge and main-checkout closeout. | Historical trace-field warning was retained and disclosed, not rewritten or presented as a clean trace check. |
| Scoped repair | Executed [currency fixture](../tests/scripts/validation/test_verdict_currency_gate.sh), plus #572 tracking repair | Two originally reviewed features receive a one-feature product repair. Approval accepts justified candidate-bound carry of the unaffected original verdict; missing/stale/mismatched carry and later affected content are rejected. The real tracking-only repair also obtained independent confirmation. | CLI fixtures use synthetic verdicts, not an actual model's independence judgment. Scripts validate attribution/currency, not the truth of a rationale. |
| Optional-only feedback | Tabletop of acceptance policy and recovery diagram | Two optional observations do not create mandatory repair items or debt; an otherwise passing four-verdict review proceeds to approval. | No controlled reviewer prompt executed. Unsupported suspicions remain advisory, not automatic MAJOR findings. |
| Blocked CI/merge | Executed [merge CI fixture](../tests/scripts/lifecycle/test_merge_pr_ci_gate.sh) and [guardrail fixture](../tests/scripts/lifecycle/test_post_pr_guardrails.sh) | Pending, failing and empty checks refuse merge without a merge call; green checks permit it, but unconfirmed merge state blocks cleanup. Guardrails cover round exhaustion, structural-red and green-freeze stops. | Fake GitHub boundaries prove deterministic refusal, not model waiting behavior or live provider reliability. Human releases are not automatically granted. |

### Newcomer walkthrough findings

The normal-path walkthrough starts at README, follows the central guide, enters
the printed issue worktree and selects one criterion from issue body/comments.
It now exposes the previously obscured one-feature stop after commit/push,
all-pass continuation, exact-candidate approval and final **applicable**, not
full-inventory, validation. Onboarding hands off after startup; host invocation
remains in its own guide. The old repo-wide progress advice was replaced with
issue authority and local per-issue tracking.

The repair walkthrough follows a required finding through scoped checks,
one-at-a-time repair items when needed, scoped independent review, explicit
unaffected carry, approval and final validation. It also follows a failed final
gate back through repair/review/approval and pending/red CI or a green merge
failure to the correct wait/stop/human-ruling boundary. Optional-only feedback
has a direct non-remediation path. These are semantic walkthroughs, not model runs.

An initial control-file structural check failed when cleanup removed a consumed
handoff heading. Restoring that compatibility anchor and historical
`feature_start` tolerance made the existing sensor pass; this unfavorable result
was retained in local evidence. No prose-pinning tests were added. Existing
structural/link/contract checks protect references and layout, not instruction
following. The two journey diagrams were reviewed as editable Mermaid source;
no Mermaid renderer/parser was installed, so rendering was not executed.

Operational ownership remains with the
[agent lifecycle](../.copilot/instructions/harness.instructions.md);
the [central human guide](HARNESS.md#lifecycle) explains the journey.
Official [prompting guidance](https://developers.openai.com/api/docs/guides/latest-model/gpt-6-astra.md)
informed conflict auditing, explicit topology and calibrated verification.
It does not replace this harness's single delivering agent plus independent
reviewer or supply missing model-evaluation evidence.

## Blocked-review recovery evaluation (#578)

The following bounded **delivering-agent semantic walkthroughs** evaluate the
recovery rule separately from deterministic gate behavior. They are not isolated
model trials, measured adherence rates or cross-host benchmarks. Fresh-context
review may probe them separately; only its actual recorded results, not this
table, can support claims about that probe.

| Input at blocked review/approval | Walkthrough outcome | Coverage and limit |
| --- | --- | --- |
| Required integration verification is missing; no human replan request | Keep approval blocked, execute the missing verification, repair if needed and return through applicable review. No automatic replan or synthetic failed verdict. | Original requirement stays required. Executed shell fixtures separately prove that missing review/state and a plan edit cannot grant approval; they do not judge natural-language intent. |
| Owner explicitly forbids the planned provider, requests a permitted equivalent, and retains the required outcome | Treat the authorized constraint as authoritative without calling the forbidden provider. Assess alternative feasibility and dependencies; record reason, conditions and old-to-new requirement/item mapping; replan affected work only. | Preserve unaffected completion and applicable carry. Required implementation, tests and actual review remain due; neither an owner constraint nor a new plan is approval. If feasibility is unknown, clarify/check rather than claim success. |
| Human says the current approach is impossible but provides no support for a technical condition | Keep approval blocked; check the claim where feasible or seek clarification. If justification remains insufficient, repair the existing approach; if it is genuinely impossible, resolve the assumption/scope rather than endlessly retry. | No silent requirement removal or weakening. An explicit owner-approved issue change is necessary for changed requirements. This semantic judgment is not shell-enforced. |

Executed regression boundaries are
[strict/default completion](../tests/scripts/validation/test_feature_list_check.sh),
[approval and recovery](../tests/scripts/validation/test_review_gate.sh),
[unchanged-HEAD publication](../tests/scripts/lifecycle/test_create_pr_sensor_gate.sh),
and [supported review currency/carry](../tests/scripts/validation/test_verdict_currency_gate.sh).
They use isolated synthetic state/review records, not fabricated real approvals.
The [central recovery diagram](HARNESS.md#human-requested-replanning-at-blocked-review)
shows the narrow branch. Rendering/parser checks, when executed, validate diagram
syntax and layout only; neither those checks nor prose/link sensors establish
agent judgment.

## CI and retained history

The [source smoke workflow](../.github/workflows/harness-smoke.yml) runs applicable
functional sensors and
[customization frontmatter validation](../tests/evals/bin/validate-customization-frontmatter.sh).
Frontmatter validation protects file structure, not skill selection or behavior.

The active evaluation roadmap and L0/L1 research documents were deleted under
#546. Existing [archived evaluation research](archive/evaluation/README.md)
remains historical; links to deleted proposals pin their last upstream revision.
It is not an additional lifecycle gate or delivery commitment.
