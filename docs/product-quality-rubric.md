# Product-Quality Rubric for Coding-Agent Work

## Purpose

Judge whether the requested result is usable, correct and safe to deliver.
Adequate in-scope work is sufficient. There is no numeric score, total, or
exemplar-quality threshold: optional robustness is not an independent reason
to block. Process completion and passing isolated tests alone do not prove
the user's workflow works.

## Blocking Gates

### 1. Spec Fidelity

The change satisfies the issue's acceptance criteria without unapproved scope.
Compare observable results, not the exact implementation steps in a plan.
Missing required behavior and unnecessary features are both relevant.

### 2. Executable Verification

Required behavioral claims have executed, discriminating assertions. Use real
runtime evidence for real boundaries; reuse the same test for regression and
end-to-end coverage when it genuinely proves both. Non-behavioral prose needs
semantic review, not invented tests.

The reviewer identifies a concrete gap before adding the smallest independent
test. Production remains read-only. A new test exposing a material in-scope
defect requires repair; unsupported hypotheticals do not. Preserve necessary
negative and safety cases, and remove duplicate assurance only after identifying
the retained assertion that detects the same failure.

### 3. Main Workflow Works

The actual entrypoint produces the requested result through the intended
components. A collection of merged components or unit-test successes is not
integrated delivery. Confirm the artifact survives the workflow where applicable.

### 4. No Known Critical Breakage

Do not introduce credential leaks, authorization bypasses, destructive data loss
or other concrete critical defects. Apply the existing exposure checks and
inspect affected safety boundaries. This does not require speculative threat
modeling of unrelated systems or production-grade recovery for every helper.

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

`NEEDS_REVISION` needs an unmet acceptance criterion or concrete material
in-scope failure, with evidence and a repair direction. A gate failure cannot
be compensated by strengths elsewhere. Route implementation and test defects
to the delivering agent; unresolved scope or authority decisions to the owner.

`APPROVED` means the gates pass. Mention optional improvements as non-blocking
notes only when useful. There is no waiver ceremony for out-of-scope polish and
no requirement to attain a stronger score.

Preserve the existing four review verdicts and structured finding attribution;
this rubric adds no stage, payload schema or mandatory checklist artifact.

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
