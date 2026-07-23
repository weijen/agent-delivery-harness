# Issue 374 progress

Status: not started.

- Branch: `feature/issue-374-feat-sensor-diet-3-5-mechanical-merges-2`
- Worktree: `/Users/weijen/Personal/agent-delivery-harness/agent-delivery-harness-public/.worktrees/issue-374`

## Action Log

- [conductor] feature_start install-update pass — Consolidating the six install-update sensors into test_install_harness_three_way.sh.
- [conductor] green_handback install-update pass — Merged six install-update sensors into one passing sensor, reducing the cluster from 396 to 391 lines.
- [conductor] feature_start install-adopter pass — Consolidating adopter install and installed-runtime sensors.
- [conductor] green_handback install-adopter pass — Merged adopter install and installed-runtime coverage into one passing 351-line sensor.
- [conductor] feature_start init pass — Consolidating init preflight, gate, and profile sensors.
- [conductor] green_handback init pass — Merged init gate, preflight, and profile coverage into one passing net-negative sensor.
- [conductor] feature_start merge-pr pass — Consolidating merge PR CI, help, and worktree cleanup sensors.
- [conductor] green_handback merge-pr pass — Merged three merge-PR sensors into one passing sensor, reducing 440 lines to 400.
- [conductor] feature_start economics-unit pass — Consolidating economics calculation, span, review, active-time, and finish-stamp unit coverage.
- [conductor] green_handback economics-unit pass — Consolidated economics unit legs into test_economics_span.sh, retained a slim native E2E sensor, and passed the 130-sensor FULL gate.
- [conductor] feature_start log-completeness pass — Consolidating log completeness gate, path, trace, and finish sensors.
- [conductor] green_handback log-completeness pass — Merged four log-completeness sensors into one passing sensor, reducing 841 lines to 799.
- [conductor] feature_start release pass — Consolidating release workflow, policy, zero-version, convention, and drift sensors.
- [conductor] green_handback release pass — Merged five release sensors into one passing 319-line sensor and updated adopter bookkeeping references.
- [conductor] feature_start copilot-log-review pass — Consolidating Copilot log-review recipe, registry, structure, CLI, and executable smoke coverage.
- [conductor] green_handback copilot-log-review pass — Merged five Copilot log-review sensors into one passing sensor, reducing 1263 lines to 1119.
- [conductor] feature_start create-pr-core pass — Consolidating create-PR failure, force fallback, rewrite, and help sensors.
- [conductor] green_handback create-pr-core pass — Merged four create-PR sensors, retained fixture-helper adoption, and passed the scoped gate.
- [conductor] feature_start review-gate-core pass — Consolidating review gate core issue, verdict, rejection, and docs-carry sensors.
- [conductor] green_handback review-gate-core pass — Merged five review-gate core sensors, retained shared-fixture adoption, and passed eight scoped sensors.
- [conductor] feature_start review-approval-carry pass — Consolidating approval carry into the patch-id sensor with a slim behavioral set.
- [conductor] green_handback review-approval-carry pass — Merged approval carry into patch-id coverage with three representative legs, reducing 1071 lines to 617.
- [conductor] feature_start trace-lib pass — Consolidating trace-lib core, isolation, and main-root sensors.
- [conductor] green_handback trace-lib pass — Merged trace-lib core, isolation, and main-root coverage into one fixture-backed passing sensor.
- [conductor] feature_start log-handback pass — Consolidating log-handback core, sensor scope, and Action Log rendering sensors.
- [conductor] green_handback log-handback pass — Merged log-handback core, scope, and Action Log rendering into one fixture-backed sensor.
- [conductor] feature_start identity pass — Consolidating GitHub, start-issue, and repository identity sensors.
- [conductor] green_handback identity pass — Merged three identity-binding sensors into one passing net-negative sensor.
- [conductor] feature_start start-issue pass — Consolidating issue scaffold, worktree location, no-hook, and title-escape sensors.
- [conductor] green_handback start-issue pass — Merged four start-issue sensors into one passing 370-line sensor.
- [conductor] feature_start eval-manifest pass — Consolidating eval manifest validation, directory, and L0 manifest sensors.
- [conductor] green_handback eval-manifest pass — Merged manifest, directory, and L0 validation into one passing sensor, reducing 196 lines to 167.
