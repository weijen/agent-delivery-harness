# Product-Quality Rubric for Coding-Agent Work

## Purpose

Judge whether the requested result is usable, correct and safe to deliver.
Adequate in-scope work is sufficient. There is no numeric score, total, or
exemplar-quality threshold: optional robustness is not an independent reason
to block. Process completion and passing isolated tests alone do not prove
the user's workflow works.

## Using this reference

The [fresh-context reviewer](../.copilot/agents/code-review-subagent.agent.md#four-review-verdicts)
owns the four verdicts and its edit authority; the lifecycle owns
[acceptance and dispositions](../.copilot/instructions/harness.instructions.md#review-acceptance-policy)
and [minimum sufficient verification](../.copilot/instructions/harness.instructions.md#minimum-sufficient-verification).
This page supplies calibration, not another gate checklist or score threshold.

The actual entrypoint produces the requested result through the intended
components. A collection of merged components or unit-test successes is not
integrated delivery. Confirm the artifact survives the workflow where applicable.

## Quality Questions

Use these questions only where the change makes them relevant, not as a quota:

| Concern | Sufficient evidence |
| --- | --- |
| Workflow completeness | The requested input-to-result path works. |
| Failure handling | Required failures surface at the boundary; internal helpers need no speculative validation. |
| State coherence | Necessary invariants hold; no material partial-update or data-loss defect. |
| Integration | Existing capabilities are actually reused through the intended path. |
| Operability | Material failures are diagnosable; optional logs or automated recovery are not mandatory. |
| Verification | Assertions discriminate required behavior and credible failures, without duplicate cases. |

Also ask whether the implementation creates problems the task does not require.
Could eliminating an unnecessary step replace pagination, retry, configuration
or another abstraction? Do not demand a refactor merely to match reviewer taste.

## Handback Routing

Use the reviewer's [findings and completion](../.copilot/agents/code-review-subagent.agent.md#findings-and-completion)
and [handback](../.copilot/agents/code-review-subagent.agent.md#modes-and-output).
A required failure cannot be compensated by strengths elsewhere; optional
polish needs neither a waiver ceremony nor a stronger score.

## Calibration Examples

- **Approve:** A report returns the required ranked summary with correct totals,
  source failure reporting and a real entrypoint test. It does not implement
  configurable page sizes or retries because the chosen source query needs neither.
- **Request revision:** Individual calculation tests pass, but the report entrypoint
  still invokes an old path and produces the wrong result. Fix integration and
  prove the actual artifact, not another isolated helper.
- **Request revision:** An archive operation overwrites existing user data.
  Infrequent use does not make destructive data loss an optional improvement.
- **Approve with an optional note:** A rare recoverable failure reports a clear
  error and permits documented manual recovery. Automatic rollback was not
  required and no critical state is lost; do not build it to improve a score.

## Validation of This Rubric

Review meaning and real outcomes, not sentence spelling. Controlled coding-engine
experiments belong to maintainer evaluation, not every adopter's PR gate.
Retain unfavorable results and distinguish correctness from efficiency.
