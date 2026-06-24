# Product-Quality Rubric for Coding-Agent Work

## Purpose

This rubric defines **functionality product quality** for coding-agent work in the harness: whether implemented features are usable, correct, and safe to merge. It covers both blocking gates (binary pass/fail) and a six-dimension scorecard (0/1/2) to guide revision handbacks.

Functionality product quality is distinct from trajectory quality (tool path, ordering) and cost-efficiency (tokens, latency). This rubric focuses on the final implemented artifact.

## Blocking Gates

Every implemented feature must clear all four blocking gates before scoring. If any gate fails, evaluation stops immediately with a FAIL verdict and a handback to the appropriate subagent or conductor.

### 1. Spec Fidelity

**What it checks**: The implementation satisfies the feature's explicit steps and acceptance criteria from the issue and `feature_list.json` without adding unapproved scope.

**Failure modes**:
- Missing required behavior from the feature steps
- Adding functionality outside the feature scope
- Ignoring explicit constraints or out-of-scope notes
- Implementing a different feature than selected

**Verification**: Compare production changes against the selected feature's `steps` field and the issue's acceptance criteria. Every step must be addressed; no unrelated changes may appear.

### 2. Executable Verification

**What it checks**: Quality claims about the implementation are backed by runnable sensors where feasible. For behavioral claims (correctness, edge handling, integration), executable verification means the claim can be tested; for executability claims (syntax validity, import resolution), it means the artifact runs without errors.

**Failure modes**:
- Behavioral claims with no corresponding test or sensor
- Untestable design (no clear inputs/outputs, hidden side effects)
- Syntax errors, undefined symbols, or import failures that prevent execution
- Dependency loops or circular imports

**Verification**: Check that behavioral changes have associated sensors (unit tests, integration tests, script smoke tests). As supporting evidence, verify syntax/lint/import health using language parsers, linters, and import resolvers. Full functional testing is not required at this gate—only that verification hooks exist.

### 3. Main Workflow Works

**What it checks**: The primary user/system workflow for the selected feature succeeds end to end. For harness infrastructure features, this means lifecycle scripts (e.g., `scripts/init.sh`, `scripts/start-issue.sh`) execute successfully. For application features, this means the main build/run/test commands or user-facing operations complete without critical errors.

**Failure modes**:
- Core workflow step exits with non-zero status when it should succeed
- User-facing operation fails or hangs
- Breaking changes to shared APIs or configs without updating callers

**Verification**: Smoke-test the primary workflow entry point for the feature. For harness script changes, run the relevant lifecycle script; for application features, run the main build/test/run command. This is a shallow check—deep integration testing is later.

### 4. No Known Critical Breakage

**What it checks**: The implementation does not introduce security holes, data loss risks, or credential leaks discoverable through static inspection.

**Failure modes**:
- Hardcoded secrets, tokens, or API keys in code
- Credential leakage via logs, prompts, or error messages
- Unsafe file operations (deleting user data without confirmation, writing to absolute paths outside the worktree)
- Privilege escalation or missing auth checks

**Verification**: Scan changed files for common security anti-patterns. Use the `public-exposure-audit` skill or equivalent static checks. Deep threat modeling is not required—only catching obvious risks.

## Scorecard Dimensions

After clearing all blocking gates, grade the implementation on six dimensions using a 0/1/2 scale. These scores guide revision priority and handback routing.

### 1. Workflow Completeness

**What it measures**: Whether the implementation handles the full intended user workflow, not just the happy path.

- **2 (Strong)**: All user-facing steps work end-to-end; clear error messages for invalid inputs; edge cases handled or documented as out-of-scope.
- **1 (Adequate)**: Happy path works; some edge cases missing but the feature is usable for its primary purpose.
- **0 (Weak)**: Significant gaps in the main workflow; missing required steps or broken user flow.

### 2. Failure and Edge Handling

**What it measures**: How the implementation responds to invalid input, missing dependencies, or unexpected states.

- **2 (Strong)**: Validates inputs; fails fast with actionable error messages; no silent failures; recovers or reports clearly.
- **1 (Adequate)**: Basic error handling; some failure modes may produce unclear errors or require manual recovery.
- **0 (Weak)**: Crashes on invalid input; silent failures; or confusing/missing error messages.

### 3. State and Data Coherence

**What it measures**: Whether the implementation maintains consistent state and data contracts across its boundaries.

- **2 (Strong)**: All state transitions are atomic or recoverable; data contracts match expectations; no partial-update bugs.
- **1 (Adequate)**: State mostly consistent; minor transient inconsistencies that self-correct or are low-impact.
- **0 (Weak)**: Leaves stale or inconsistent state; partial updates; data contract violations.

### 4. Integration Depth

**What it measures**: Whether the implementation integrates cleanly with existing harness conventions, language profiles, and surrounding code.

- **2 (Strong)**: Follows established patterns; reuses existing utilities; respects profile/language conventions; fits naturally.
- **1 (Adequate)**: Works but introduces minor inconsistencies (different naming, duplicated logic, or deviations from conventions).
- **0 (Weak)**: Duplicates existing logic; ignores conventions; breaks abstraction boundaries; or introduces tight coupling.

### 5. Recoverability and Operability

**What it measures**: Whether a human or automation can observe, debug, or fix the implementation when something goes wrong.

- **2 (Strong)**: Clear logs or trace output; actionable error messages with suggested fixes; easy to diagnose failures.
- **1 (Adequate)**: Basic observability; failures are diagnosable with some manual inspection.
- **0 (Weak)**: Silent failures; opaque errors; hard to debug; no logs or trace breadcrumbs.

### 6. Verification Adequacy

**What it measures**: Whether the implementation is designed to be testable and whether required verification hooks are in place.

- **2 (Strong)**: Sensor-addressable boundaries; clear regression and e2e verification points; no hidden side effects.
- **1 (Adequate)**: Testable but may require complex setup or indirect verification; some boundaries unclear.
- **0 (Weak)**: Opaque implementation; hard to verify without invasive mocking; missing sensor hooks.

## Scoring and Interpretation

Sum the six dimension scores to produce a total score from 0 to 12, then map to one of four verdicts:

| Total Score | Verdict | Meaning |
| --- | --- | --- |
| 0–5 | **FAIL** | Critical quality gaps; implementation needs major revision. |
| 6–8 | **NEEDS_REVISION** | Adequate for basic functionality but has notable weaknesses; should be revised before merging. |
| 9–10 | **PASS** | Good quality; minor improvements possible but not blocking. |
| 11–12 | **STRONG_PASS** | Excellent quality; exemplar implementation. |

**Thresholds**:
- **FAIL** blocks merge and requires handback with detailed findings.
- **NEEDS_REVISION** may proceed to next feature or be revised at conductor discretion; should not merge as-is.
- **PASS** is merge-eligible after test verification.
- **STRONG_PASS** is merge-eligible and may serve as a reference example.

## Handback Routing

When a dimension scores 0 or 1, include specific findings in the handback. Route based on the root cause:

### To implementation-subagent

- Missing required workflow steps (dimension 1)
- Incomplete integration with existing conventions (dimension 4)
- Missing verification hooks or sensor boundaries (dimension 6)
- Any spec fidelity failure (blocking gate 1)

### To test-subagent

- Insufficient verification coverage (dimension 6)
- Missing regression or e2e sensors for new behavior
- Verification that exists but doesn't exercise edge cases (dimension 2)

### To conductor / human gate

- Blocking gate failures that require issue clarification (unclear spec, ambiguous acceptance criteria)
- Security or safety concerns (blocking gate 4)
- Architectural mismatches that need higher-level design decisions (dimension 4, when conventions conflict)
- Main workflow breakage that implicates infrastructure or environment (blocking gate 3)

Include the failing dimension(s), the specific evidence (file, line, or behavior), and the recommended fix in every handback. For FAIL verdicts, cite the blocking gate by name.
