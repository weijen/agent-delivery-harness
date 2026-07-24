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

Before the final gate result, `code-review-subagent` performs an independent adversarial test-quality pass. It maps
criteria to sensors, checks assertion strength, boundaries, negative or mutation cases, and implementation-fitting
tests, then adds and executes the smallest independent test, fixture, smoke, or validation asset when needed.
Production remains read-only: the reviewer must not edit production, and ambiguous paths or required production hooks
route through the conductor. The review records changed tests, commands, and observed pass/fail evidence.

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

A failing reviewer-authored adversarial sensor produces `NEEDS_REVISION`. When it exposes a production defect, route
the failure back to the delivering agent; the reviewer never repairs production. After the repair,
`code-review-subagent` reruns the adversarial sensor before issuing a new adequacy verdict.

### To the delivering agent for implementation repair

- Missing required workflow steps (dimension 1)
- Incomplete integration with existing conventions (dimension 4)
- Missing verification hooks or sensor boundaries (dimension 6)
- Any spec fidelity failure (blocking gate 1)

### To the delivering agent for verification repair

- Insufficient verification coverage (dimension 6)
- Missing regression or e2e sensors for new behavior
- Verification that exists but doesn't exercise edge cases (dimension 2)

### To conductor / human gate

- Blocking gate failures that require issue clarification (unclear spec, ambiguous acceptance criteria)
- Security or safety concerns (blocking gate 4)
- Architectural mismatches that need higher-level design decisions (dimension 4, when conventions conflict)
- Main workflow breakage that implicates infrastructure or environment (blocking gate 3)

Include the failing dimension(s), the specific evidence (file, line, or behavior), and the recommended fix in every handback. For FAIL verdicts, cite the blocking gate by name.

## Calibration Examples

These examples show how to apply the rubric consistently. Each demonstrates scoring at different quality levels and illustrates boundary decisions.

### Example 1: Strong Pass (Score: 11)

**Feature Context**: Issue #45 F3 — "Add `--skip-azure` flag to `scripts/init.sh` to bypass optional Azure login check when working on non-cloud features."

**Steps**:
1. Add `--skip-azure` flag parsing to `scripts/init.sh`
2. Skip `az login` verification when flag is present
3. Retain existing behavior when flag is omitted
4. Update help text

**Acceptance**: `./scripts/init.sh --skip-azure` completes without requiring Azure CLI or credentials; default behavior unchanged.

**Sensors**:
- `regression_sensor`: `./tests/scripts/test_init_preflight.sh skip-azure`
- `e2e_sensor`: `./tests/scripts/test_init_preflight.sh e2e`

**Blocking Gate Results**:
1. **Spec Fidelity**: ✅ PASS — all four steps implemented; no scope creep
2. **Executable Verification**: ✅ PASS — regression sensor exercises flag; e2e sensor covers default path
3. **Main Workflow Works**: ✅ PASS — `./scripts/init.sh --skip-azure` exits 0; `./scripts/init.sh` (default) exits 0
4. **No Known Critical Breakage**: ✅ PASS — no credentials exposed; flag documented in help text

**Scorecard**:
1. Workflow Completeness: **2** — both flag and default paths work; edge case (invalid flag) handled with usage message
2. Failure and Edge Handling: **2** — validates flag syntax; clear error for unknown flags
3. State and Data Coherence: **2** — no state changes; idempotent check
4. Integration Depth: **2** — follows existing `scripts/` flag conventions; reuses `show_usage` function
5. Recoverability and Operability: **2** — flag logged when active; help text updated
6. Verification Adequacy: **1** — sensor covers both paths but doesn't exercise concurrent-session edge case (acceptable for this scope)

**Total**: 11 / 12 → **STRONG_PASS**

**Handback**: None (merge-eligible).

---

### Example 2: Fail (Score: 3)

**Feature Context**: Issue #67 F1 — "Add Python formatter to `profiles/python.profile.sh` quality gates."

**Steps**:
1. Add `ruff format --check` to quality gate definition
2. Update `docs/multi-language-profiles.md` to document formatter gate
3. Ensure gate fails on unformatted code

**Acceptance**: `profile_quality_gate` function exits non-zero when Python files fail `ruff format --check`.

**Sensors**:
- `regression_sensor`: `./tests/scripts/test_python_profile.sh formatter`
- `e2e_sensor`: null

**Implementation Evidence**: Implementer edited `profiles/python.profile.sh` to add `ruff format --check` inside `profile_quality_gate`, but did not update `docs/multi-language-profiles.md`. Sensor run output: "Expected formatter command in docs/multi-language-profiles.md, not found."

**Blocking Gate Results**:
1. **Spec Fidelity**: ❌ FAIL — step 2 (documentation update) not completed
2. **Executable Verification**: ⏭️ SKIPPED (stopped at gate 1)
3. **Main Workflow Works**: ⏭️ SKIPPED
4. **No Known Critical Breakage**: ⏭️ SKIPPED

**Scorecard**: Not scored (blocked at gate 1).

**Verdict**: **FAIL** (blocking gate 1: Spec Fidelity)

**Handback to the delivering agent**:
- **Finding**: Step 2 missing — `docs/multi-language-profiles.md` not updated to document formatter gate.
- **Evidence**: `./tests/scripts/test_python_profile.sh formatter` exits 1 with "Expected formatter command in docs/multi-language-profiles.md, not found."
- **Required Fix**: Add formatter gate description to the Python profile section in `docs/multi-language-profiles.md`, following the existing quality gate documentation pattern.

---

### Example 3: Edge Case — Waivable Weakness (Score: 8)

**Feature Context**: Issue #58 F2 — "Add `scripts/archive-issue.sh` to move completed issue worktrees to `../<repo>-archive/` for offline storage."

**Steps**:
1. Create `scripts/archive-issue.sh` that accepts issue number
2. Validate worktree exists and is clean (no uncommitted changes)
3. Move worktree directory to `../<repo>-archive/issue-<N>/`
4. Update `.copilot-tracking/issues/issue-<N>/progress.md` with archive timestamp

**Acceptance**: `./scripts/archive-issue.sh 42` moves a clean worktree; refuses if worktree has uncommitted changes.

**Sensors**:
- `regression_sensor`: `./tests/scripts/test_archive_issue.sh`
- `e2e_sensor`: `./tests/scripts/test_archive_issue.sh e2e`

**Blocking Gate Results**:
1. **Spec Fidelity**: ✅ PASS — all four steps implemented
2. **Executable Verification**: ✅ PASS — regression sensor covers happy path and dirty-worktree rejection
3. **Main Workflow Works**: ✅ PASS — `./scripts/archive-issue.sh 42` exits 0 for clean worktree
4. **No Known Critical Breakage**: ✅ PASS — validates worktree cleanliness before moving; no data loss risk

**Scorecard**:
1. Workflow Completeness: **1** — happy path works; edge case not handled: what if archive directory already contains `issue-<N>/`? Script overwrites without warning.
2. Failure and Edge Handling: **1** — validates dirty worktree; does not check for existing archive target (low-impact because archive is offline storage, but should warn).
3. State and Data Coherence: **2** — progress.md updated atomically after move
4. Integration Depth: **2** — follows `scripts/` conventions; reuses `issue-lib.sh` functions
5. Recoverability and Operability: **1** — logs archive action; no rollback mechanism if move fails mid-operation (would require manual recovery).
6. Verification Adequacy: **1** — sensor covers main path; does not test existing-archive-target collision.

**Total**: 8 / 12 → **NEEDS_REVISION**

**Evaluation Notes**:
- The existing-archive-target edge case is low-severity because the archive directory is intended for cold storage (user rarely re-archives the same issue).
- The missing rollback for failed moves is a real gap but acceptable for a first iteration (manual recovery is straightforward: move the directory back).

**Handback to the delivering agent** (recommended but waivable):
- **Findings**:
  1. Dimension 1 (Workflow Completeness): Script does not check if `../<repo>-archive/issue-<N>/` already exists; overwrites silently.
  2. Dimension 5 (Recoverability): No rollback if `mv` fails partway (e.g., disk full, permission error).
- **Evidence**:
  - `scripts/archive-issue.sh` line 42: `mv "$worktree_path" "$archive_target"` — no pre-check for existing target.
  - No `trap` or error handler to undo partial moves.
- **Suggested Fix**:
  1. Add `[ -e "$archive_target" ] && { echo "Archive target already exists"; exit 1; }` before the move.
  2. Consider wrapping the move in a `trap 'rollback_on_error' ERR` handler (or document manual recovery in error message).
- **Waiver Rationale**: If the conductor judges that archive-target collision is rare and manual recovery is acceptable for this iteration, dimension 1 and 5 scores (1 each) may be accepted as-is, yielding **NEEDS_REVISION** but not blocking next feature work.

---

## Calibration Guidance: Distinguishing 0 / 1 / 2

The three-point scale for each scorecard dimension is designed to make boundary decisions quick and consistent. Use these anchors:

### Score 2 (Strong)
- The implementation **actively handles** the dimension's concern with clear evidence of design intent.
- For workflow/edge handling: validates inputs, handles known edge cases, provides clear error messages.
- For integration/operability: follows conventions, reuses existing patterns, includes observability hooks.
- **Test**: "Would I cite this as a good example to a new contributor?"

### Score 1 (Adequate)
- The implementation **mostly works** for the dimension's concern but has **identifiable gaps** that don't block basic functionality.
- For workflow/edge handling: happy path works; some edge cases missing but the feature is usable.
- For integration/operability: works but introduces minor inconsistencies (different naming, missing logs, shallow integration).
- **Test**: "Does this work well enough for the primary use case, even if it has rough edges?"

### Score 0 (Weak)
- The implementation **neglects** the dimension's concern or introduces **critical gaps** that undermine functionality.
- For workflow/edge handling: crashes on invalid input; silent failures; or missing required steps.
- For integration/operability: duplicates logic, ignores conventions, or breaks abstraction boundaries.
- **Test**: "Would this cause problems or confusion in real use?"

### Boundary Heuristics

**1 vs 2 (Adequate vs Strong)**:
- If the implementation handles the main case correctly but misses an uncommon edge case → likely **1**.
- If the implementation handles the main case AND anticipated edge cases with clear design → **2**.
- Example: A script that validates required arguments but doesn't check for conflicting flags → **1** (adequate). A script that validates all argument combinations and provides actionable errors → **2** (strong).

**0 vs 1 (Weak vs Adequate)**:
- If the gap **blocks the primary use case** or introduces a **high-impact failure mode** → **0**.
- If the gap is **low-impact** or affects only uncommon paths → **1**.
- Example: A script that crashes on empty input when empty input is a common case → **0** (weak). A script that works for common cases but has unclear errors for rare edge cases → **1** (adequate).

### When to Waive a Weakness

A dimension score of 0 or 1 is not always blocking. Waive when:
- The gap is **out of scope** for the selected feature (e.g., a logging improvement is not part of the feature's acceptance criteria).
- The gap is **low-severity** and fixing it would delay higher-priority work (e.g., missing rollback for a rarely-used script).
- The feature is **experimental** or **internal-only** and production-grade robustness is not required yet.

Document waiver rationale in the handback so future evaluations understand the context. A waived weakness should still appear in the scorecard—waivers affect routing, not scoring.
