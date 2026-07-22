# Evaluation Matrix

## Purpose

The evaluation matrix is the shared schema for future harness evals. It makes
each eval attributable: when a check fails, the failure should point to a
specific harness boundary rather than a vague whole-system concern.

## Matrix Fields

Each eval should define:

```json
{
  "id": "subagent-review-001",
  "target": "code-review-subagent",
  "capability": "blocks_missing_behavioral_sensor",
  "boundary": "subagent-role",
  "fixture": {
    "type": "static",
    "path": "tests/evals/fixtures/subagents/code-review/missing-sensor/"
  },
  "expected_outcome": "blocking_finding",
  "grader": {
    "deterministic": [
      "output_schema_valid",
      "verdict_is_blocking"
    ],
    "rubric": [
      "finding_is_specific",
      "finding_is_actionable",
      "cites_relevant_behavior"
    ]
  },
  "blocking": false,
  "trials": 3,
  "threshold": {
    "pass_rate": 1.0,
    "critical_false_negative_rate": 0.0
  }
}
```

The `trials` field is `1` for deterministic checks and higher for any eval whose
target is nondeterministic; see [statistical-methodology.md](statistical-methodology.md)
for how to set it and how to read `pass@k` versus `pass^k`.

The core manifest stays intentionally small for L0 and L1. It declares the case
identity, target, capability, fixture, expected outcome, grader, and blocking
policy. Runner-specific output policy, ownership metadata, runtime selection,
and trace expectations belong in suite configuration or scorecards unless a
specific L1 grader needs them as fixture data.

### Field Reference

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | Yes | Stable case identifier. Keep it unique and do not reuse it when the capability changes meaning. |
| `schema_version` | Yes | Manifest schema version. Increment only when the manifest format changes. |
| `target` | Yes | The script, skill, subagent, prompt, or schema being evaluated. Use paths for repo files and prefixes such as `skill:` when the target is logical. |
| `capability` | Yes | The single behavior this case proves. Phrase it as one observable obligation, not a broad quality area. |
| `boundary` | Yes | The harness responsibility area the case protects, such as `script-lifecycle`, `skill-behavior`, or `subagent-role`. |
| `fixture` | Yes | Reproducible input for the case. Use `type: static` with a checked-in `path`, or `type: generated` with a deterministic builder. |
| `expected_outcome` | Yes | Ground truth the grader should prove, such as `reject`, `allow`, `blocking_finding`, or `valid_artifact`. Actual predictions belong in scorecards. |
| `grader` | Yes | The deterministic command, schema check, rubric, or hybrid grader that turns fixture output into pass/fail evidence. |
| `blocking` | Yes | Whether failure should fail the local or CI run. Use `false` for report-only L1 capability tracking until the case is stable. |
| `trials` | No | Number of repeated runs for nondeterministic targets. Omit for deterministic L0 cases, which default to `1`. |
| `threshold` | No | Metric thresholds for nondeterministic or hybrid graders, such as pass rate or critical false-negative rate. |
| `source_dataset` | No | Provenance for public benchmark fixtures adapted into local, versioned cases. Blocking applies to the local fixture. |
| `contract_refs` | No | References to harness lifecycle or role-boundary obligations when the case claims coverage of a specific contract item. |

## Required Dimensions

### Target

The thing being evaluated. Examples:

- `scripts/start-issue.sh`
- `scripts/review-gate.sh`
- `code-review-subagent`
- `generator-subagent`
- `skill:code-review`
- `skill:create-pr`
- `feature_list.json schema`

### Capability

The behavior the target must demonstrate. Examples:

- Refuses dirty worktree closeout unless `FORCE=1`.
- Blocks stale review approval after HEAD changes.
- Detects missing behavioral tests.
- Decomposes an issue into one-sensor features with no bundled concerns (see
  [feature-breakdown-evals.md](feature-breakdown-evals.md)).
- Does not trigger a skill for adjacent but wrong requests.
- Logs subagent handbacks in the Action Log.

### Boundary

The category of harness responsibility:

- `script-lifecycle`
- `skill-trigger`
- `skill-artifact`
- `subagent-role`
- `trajectory`
- `mutation-resistance`
- `trace-action-log`
- `security`
- `cost-efficiency`
- `end-to-end-fixture`

### Fixture

The reproducible input for the eval case. Static fixtures point at a checked-in
path. Generated fixtures name the deterministic builder command or script that
creates the temporary case state.

### Expected Outcome

The ground truth the grader must prove, such as `reject`, `allow`,
`blocking_finding`, or `valid_artifact`. Manifests declare expected outcomes;
scorecards record actual predictions after the runner executes the case.

### Blocking

Use `blocking: true` when a failed eval should fail the local or CI run. Use
`blocking: false` for report-only capability tracking until the fixture, grader,
and threshold are stable enough to gate changes.

The older `regression` and `capability` language is still useful for planning,
but the first manifest schema uses the explicit `blocking` field because it is
the decision the runner must enforce.

## Grader Types

### Deterministic Graders

Use these first:

- Exit code checks.
- File-system state checks.
- JSON schema checks.
- Shell output regex checks.
- Git state checks.
- Tool-call presence or absence checks.
- Ordered lifecycle checks.
- Static analysis and shellcheck.

### Rubric Graders

Use only where deterministic checks are insufficient:

- Review finding specificity.
- Plan usefulness.
- Explanation quality.
- Whether a generator produced a meaningful adversarial sensor.
- Whether a reviewer correctly classified severity.

Rubric graders must return structured JSON, not free-form prose. A rubric grader
backed by an LLM is itself a system under test and must be calibrated per
[judge-evaluation.md](judge-evaluation.md).

### Human Calibration

Human review should be used to calibrate LLM-based graders and inspect failures.
It should not be the only way to run routine regression checks.

## Score Reporting

Each eval run should report:

- Pass/fail count.
- Per-capability result.
- False positives and false negatives when known.
- Cost and runtime when LLM calls are involved.
- Links to traces or artifacts.
- The commit SHA and model/tool versions used.

## Blocking Policy

Initial policy:

- Script lifecycle regressions block.
- Review-gate regressions block.
- Security regressions (injection obeyed, secret committed, signing disabled)
  block.
- Known-dangerous subagent false negatives block once test cases are stable.
- Skill trigger regressions block only for mature skills.
- Capability eval score movement does not block until converted to regression.

## Cadence

Match cost to frequency:

| Cadence | What runs | Why |
| --- | --- | --- |
| Every commit / pre-PR | L0 script lifecycle, deterministic mutation, fast security checks | Cheap, deterministic, high attribution |
| Nightly or on demand | Skill, subagent, trajectory, judge-calibration evals | Slower or LLM-backed |
| Before model/tool upgrade | Full suite plus re-baseline and judge re-calibration | Behavior can shift under a new model |
| Periodic review | Outcome fixtures, saturation and gap review | Expensive, broad |

## Issue Template Hint

Future evaluation issues should include:

```markdown
## Target

## Capability

## Fixtures

## Graders

## Trials And Thresholds

## Blocking Policy

## Acceptance Criteria
```

## Public Dataset Field Guidance

When an eval adapts a public benchmark, keep the manifest `fixture.path` pointed
at the local versioned fixture path and add source metadata beside it:

```json
{
  "fixture": {
    "type": "static",
    "path": "tests/evals/fixtures/issues/swebench-lite-sympy-20590/"
  },
  "source_dataset": {
    "name": "SWE-bench Lite",
    "url": "https://github.com/SWE-bench/SWE-bench",
    "source_id": "sympy__sympy-20590",
    "local_modifications": [
      "reduced_to_single_acceptance_criterion",
      "replaced_external_network_with_fake_cli"
    ],
    "use": "seed"
  }
}
```

Use `use: seed` when the public task was adapted into a local fixture,
`use: shadow` when the harness only reports external benchmark scores, and
`use: calibration` when the public labels help calibrate a judge. Blocking
policy should normally apply to the local fixture, not the external benchmark.
