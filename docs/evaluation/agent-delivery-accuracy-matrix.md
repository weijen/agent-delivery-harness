# Agent Delivery Accuracy Matrix

Agent-delivery accuracy asks whether an agent delivered the requested issue correctly. It is distinct from merge completion, test pass, trajectory quality, and cost efficiency: a run can be merged, fast, cheap, or well ordered while still shipping the wrong behavior. In this matrix, `merged` means delivery completed, not correct; PR merged or a higher merge rate is never an accuracy label by itself.

The machine-readable companion is `agent-delivery-accuracy-matrix.v1.json`. This human document explains the same four layers, metric ids, denominators, absence semantics, and policy posture. It also ties the matrix to the existing evaluation contracts: `trace-summary.v1.json`, `trace-scorecard.v1.json`, `evaluation-matrix.md`, `outcome-evals.md`, `product-quality-rubric.md`, `trajectory-evals.md`, and `cost-efficiency-evals.md`.

## Source contracts and boundaries

- `product-quality-rubric.md` defines functionality product quality: spec fidelity, executable verification, main workflow success, and no critical breakage. These are the correctness gates the matrix protects.
- `outcome-evals.md` covers complete issue delivery from worktree start through sensors, review, PR text, and finish cleanup. Outcome completion is useful evidence, not a correctness label by itself.
- `trajectory-evals.md` covers the path: required ordering, pauses, handbacks, and least-privilege boundaries. Good trajectory can support accuracy but does not replace product-quality evidence.
- `cost-efficiency-evals.md` says cost, token, latency, and useful-action metrics are interpreted only after quality, security, and lifecycle gates pass.
- `evaluation-matrix.md` supplies the eval-case vocabulary: ids, targets, capabilities, fixtures, expected outcomes, grader, blocking policy, trials, thresholds, and contract refs.
- `trace-summary.v1.json` is the per-run source for `finished`, `final_outcome`, `bounded`, `closed_by`, `wall_clock`, `stages`, `tools`, `tokens`, `loop_indicators`, `red_reentry`, and `deviations`. Its absence semantics are honest: `null` means no data, `0` means measured zero, and `[]` means the detector ran and found nothing.
- `trace-scorecard.v1.json` aggregates trace-summary v1 into version buckets with explicit denominators such as `runs`, `red_reentry_free_rate.of`, `token_coverage`, `tool_coverage`, `inputs.missing_summaries`, and `inputs.skipped`.

## Anti-Goodhart rules

Goodhart pressure is expected, so the matrix is quality-gated. Lower `cost`, shorter time, fewer tool calls, or a higher `merge` rate cannot offset correctness, review, security, trace, or lifecycle regressions. Cost and efficiency metrics are interpreted only after the relevant quality gates pass. A metric cannot improve by skipping sensors, suppressing traces, narrowing acceptance criteria, bypassing review, hiding security findings, or treating absent data as zero.

Every rate must carry an explicit denominator and coverage statement. Never fabricate zeros: absence is `null` with an explicit denominator/coverage note, while measured zero remains `0` only when the detector or collector actually ran.

## Attribution windows: finish vs pr_merge

`trace-report` currently treats `finished` as a literal `finish` lifecycle span: `final_outcome` and `main_workflow_pass_rate` use that finish window. After #165, attribution windows can also be bounded by `pr_merge` through `bounded` and `closed_by`; that PR merge window is appropriate for merge/completion and post-merge observation boundaries, not for inferring correctness. Rates that judge agent work use the finish window unless they explicitly name a GitHub PR review source, a PR merge source, or a post-merge defect source.

## Policy posture

Metrics are either blocking or diagnostic. Blocking metrics may fail the quality gate once their denominator and coverage are mature. Diagnostic metrics explain risk and trends but do not block by themselves. Immature metrics start diagnostic, not blocking; deferred metrics are not charted or enforced until the required source fields exist.

## Layer 1: direct labels

Direct labels are closest to human or post-delivery correctness judgment. They ask whether the delivered artifact satisfied the issue, review, and post-merge expectations.

| Metric id | Numerator | Denominator | Source fields | Coverage / absence | Policy |
| --- | --- | --- | --- | --- | --- |
| `spec_compliance_pass_rate` | Issues whose final review verdict records spec compliance as pass against issue acceptance criteria. | Issues with a completed final review verdict in the evaluation window. | Review verdict plus GitHub issue acceptance criteria; aligns with `product-quality-rubric.md`. | Missing review verdict is `null`/no label, not failed or passed; report review coverage separately. | blocking once final review verdict coverage is complete. |
| `human_approval_first_pass_rate` | PRs approved by a human reviewer without a prior requested-changes or blocking-comment round. | PRs with at least one human review decision before merge or closure. | GitHub PR review events. | No human review is `null`, not first-pass approval. | diagnostic until review data is complete. |
| `post_merge_bug_rate` | Merged issues later linked to a confirmed post-merge bug, regression, revert, or incident attributable to that delivery. | Merged issues whose post-merge observation window has elapsed. | Deferred post-merge issue labels, linked incidents, or revert records. | `deferred`: missing post-merge triage is `null`, never zero defects; needs a maintained post-merge source and closed observation window. | deferred. |
| `review_blocking_finding_rate` | Review findings marked blocking, major, or must-fix for an issue. | Reviewed issues with a structured final review verdict. | Review verdict; `trace-summary.v1.json` has no per-verdict finding field yet. | `deferred`: missing finding counts are `null`, not zero blocking findings; needs additive trace-summary v1.x or structured review verdict fields. | deferred. |

## Layer 2: proxy labels

Proxy labels are machine-checkable evidence correlated with correctness, but they are not substitutes for direct acceptance labels.

| Metric id | Numerator | Denominator | Source fields | Coverage / absence | Policy |
| --- | --- | --- | --- | --- | --- |
| `feature_pass_rate` | Feature-list items that reached a verified green handback or equivalent passing feature sensor result. | Feature-list items selected and attempted in evaluated issues. | Feature list plus trace-summary `final_outcome` and lifecycle handback spans. | Missing feature status is `null`/uncovered; implementation handbacks are not verification. | blocking. |
| `first_pass_feature_green_rate` | Features whose first evaluator verdict was green without an earlier red handback for the same feature. | Features with at least one evaluator verdict. | Ordered trace lifecycle handback spans. | Missing ordered handbacks are `null`; `red_reentry_free_rate` must not be relabeled as first-pass green because v1 only detects red after green. | diagnostic. |
| `sensor_adequacy_pass_rate` | Features whose declared regression/e2e sensors directly cover the acceptance criterion and were judged adequate. | Features with declared sensors in the feature list. | `feature_list` `regression_sensor` / `e2e_sensor` plus review-verdict adequacy checks. | No adequacy review is `null`; skipped or trivial sensors are not adequate by default. | blocking. |
| `main_workflow_pass_rate` | Runs whose trace-summary has `finished` true and `final_outcome` equal to `pass`. | Runs aggregated in `trace-scorecard.v1.json` `by_version[].runs` or trace-summary files in the evaluation window. | `trace-summary.v1.json` `finished` / `final_outcome`; `trace-scorecard.v1.json` `by_version[].passed` / `runs`. | Unfinished runs have `final_outcome` `null`; missing summaries are listed as missing/skipped and never counted as pass. Uses the finish window. | blocking. |
| `red_first_evidence_rate` | Features whose verification evidence includes a red result before the first green result for that feature. | Features with ordered evaluator evidence in trace or progress records. | Lifecycle handback spans and feature progress evidence. | Missing ordered evidence is `null`, not a measured absence of red-first proof. | diagnostic. |

## Layer 3: degradation signals

Degradation signals catch ways an apparently green delivery may be fragile, non-compliant, or poorly instrumented.

| Metric id | Numerator | Denominator | Source fields | Coverage / absence | Policy |
| --- | --- | --- | --- | --- | --- |
| `loop_rate_by_type` | Loop indicator groups by signature/type at or above the trace-summary threshold. | Runs with a valid `loop_indicators` detector result. | `trace-summary.v1.json` `loop_indicators`; `trace-scorecard.v1.json` `by_version[].issues[].loop_indicator_groups`. | `[]` means detector ran and found no repeated groups; missing field is `null`. | diagnostic. |
| `deviation_rate` | Deviation lifecycle events counted across evaluated runs. | Runs aggregated in the same evaluation window. | `trace-summary.v1.json` `deviations {count, feature_ids}` and `trace-scorecard.v1.json` `by_version[].deviations`. | `deviations.count` 0 with `feature_ids []` is measured zero; missing `deviations` is `null`. | diagnostic. |
| `red_reentry_free_rate` | Finished passing runs whose `red_reentry` array is empty. | Runs in the bucket, reported as `trace-scorecard.v1.json` `by_version[].red_reentry_free_rate.of`. | `trace-summary.v1.json` `red_reentry`; `trace-scorecard.v1.json` `red_reentry_free_rate {free, of}`. | `[]` means no red-after-green re-entry detected; missing `red_reentry` is `null`. Not first-pass green. | diagnostic. |
| `role_boundary_violation_rate` | Detected conductor/generator/evaluator/reviewer boundary violations. | Issues or feature phases with role-scoped handbacks/reviews in the window. | Review verdict, diff file classes, and role handback logs. | Missing role or diff classification is `null`, not zero violations. | blocking. |
| `trace_completeness_rate` | Runs with valid summaries, no invalid trace lines, required fields, and expected instrumentation coverage. | Runs discovered by the scorecard input scan, including missing and skipped summaries. | `trace-scorecard.v1.json` `inputs`; `trace-summary.v1.json` `span_counts.invalid_lines` and `coverage`. | Missing or skipped summaries are coverage gaps; `invalid_lines` 0 is measured only when `span_counts` exists. | blocking. |
| `tool_failure_rate` | Failed tool calls summed across runs. | Tool calls summed across the same runs. | `trace-summary.v1.json` `tools[] {calls, fail_calls}` and `trace-scorecard.v1.json` `tool_calls`. | No tool spans with coverage false is `null`, not zero failures; `fail_calls` 0 with `calls > 0` is measured zero. | diagnostic. |
| `thrash_rate` | Repeated-loop groups, repeated failed sensor attempts, or same-step handbacks indicating no progress. | Runs with loop indicators and ordered lifecycle handback data. | `trace-summary.v1.json` `loop_indicators` plus lifecycle handback spans. | `[]` loop indicators means no exact-repeat loops; missing handback ordering is `null` for handback-thrash subsignals. | diagnostic. |

## Layer 4: efficiency after quality

Efficiency after quality is intentionally last. It is useful only after direct labels, proxy labels, and degradation signals show the delivery is correct enough to compare.

| Metric id | Numerator | Denominator | Source fields | Coverage / absence | Policy |
| --- | --- | --- | --- | --- | --- |
| `tokens_per_accepted_issue` | Input plus output tokens for accepted issues when token data is captured. | Accepted issues with token coverage in `trace-scorecard.v1.json` `token_coverage.runs_with_tokens`. | `trace-summary.v1.json` `tokens`; `trace-scorecard.v1.json` `by_version[].tokens` plus `token_coverage`. | `deferred` / coverage-dependent for Copilot-side token capture tracked in #163; `tokens null` means unavailable and is never averaged as zero. | deferred until coverage is comparable. |
| `wall_clock_per_accepted_issue` | `wall_clock.elapsed_seconds` summed for accepted issues with wall-clock data. | Accepted issues with non-null `trace-summary.v1.json` `wall_clock.elapsed_seconds`. | `trace-summary.v1.json` `wall_clock.elapsed_seconds`; `trace-scorecard.v1.json` issue rows. | `wall_clock null` means no timestamp data; not zero seconds. Uses finish-window elapsed time unless a metric explicitly names PR merge or post-merge observation. | diagnostic. |
| `tool_calls_per_accepted_issue` | Tool calls summed for accepted issues. | Accepted issues with tool span coverage, using `tool_coverage.runs_with_tool_spans`. | `trace-summary.v1.json` `tools[]`; `trace-scorecard.v1.json` `tool_calls` and `tool_coverage`. | Coverage-dependent: lifecycle-only runs are not zero-call successes. | diagnostic. |
| `useful_action_ratio` | Tool calls, handbacks, or lifecycle actions that directly advance an accepted feature. | All attributed tool calls, handbacks, and lifecycle actions for accepted issues. | Aggregate v1 trace fields plus future per-feature attribution. | `deferred`: v1 `tools[]` has no feature dimension, so the value is `null` until additive trace-summary v1.x attribution exists. | deferred. |

## Deferred and coverage-dependent metrics

The deferred labels are explicit, not hidden gaps:

- `post_merge_bug_rate` is deferred because v1 has no maintained post-merge defect attribution source. Its window starts after `pr_merge` and only counts merged issues whose observation window has elapsed.
- `review_blocking_finding_rate` is deferred because `trace-summary.v1.json` has no per-verdict or per-finding field yet. It needs an additive v1.x source or structured review-verdict data.
- `tokens_per_accepted_issue` is deferred / coverage-dependent for Copilot-side token and cost capture tracked in #163. Existing model spans may provide token coverage for some adapters, but missing token data remains `null` with `token_coverage`, never zero.
- `useful_action_ratio` is deferred until trace-summary v1.x can attribute tool/action evidence to features.

Deferred metrics start diagnostic or unavailable, not blocking. They become blocking only after the source contract, denominator, and coverage rules are mature enough to prevent fabricated zeros and Goodhart gaming.
