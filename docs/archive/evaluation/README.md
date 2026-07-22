# docs/evaluation archive (decision 3a)

> **Archived by #337 (epic #331).** The 2026-07-21 harness-simplification epic
> found this content to be L1+ eval-platform prose that the current
> harvest-loop strategy forbids building now, with zero execution-time
> reference from runtime scripts, agent doctrine, or `AGENTS.md`. It is
> retained here, unmodified, as design context for anyone who later revisits
> that eval-platform work — it is not deleted history, only moved out of the
> sensed tree. See epic #331 for the full harness-simplification rationale and
> issue #337 for the archival decision (decision 3a, 2026-07-21).

The live, runtime-referenced evaluation docs (roadmap, product-quality rubric,
observability/trace-schema doctrine, L0 solution, and the active `l1-solution/`
contract docs for issues #66-#69/#87) stay in
[docs/evaluation/](../../evaluation/README.md). Nothing below this line is
referenced by any runtime script, agent doctrine file, or `AGENTS.md`.

## Index

| Page | Focus |
| --- | --- |
| [agent-delivery-accuracy-matrix.md](agent-delivery-accuracy-matrix.md) | Layered model distinguishing agent-delivery accuracy from merge completion, trajectory quality, and cost efficiency |
| [agent-delivery-accuracy-matrix.v1.json](agent-delivery-accuracy-matrix.v1.json) | Machine-readable contract for the accuracy matrix, with honest denominator and absence semantics per metric |
| [azure-evaluation-runtime.md](azure-evaluation-runtime.md) | Azure ML and Azure AI Foundry runtime strategy for running evals at scale |
| [dashboards/README.md](dashboards/README.md) | Decommissioned (#272) Harness Quality Workbook pack, retained as a historical panel/field map |
| [dashboards/workbook-redesign.md](dashboards/workbook-redesign.md) | Review and redesign notes for the former Harness Quality Workbook |
| [dataset-governance.md](dataset-governance.md) | Golden dataset lifecycle, versioning, provenance, and contamination controls |
| [evaluation-matrix.md](evaluation-matrix.md) | Shared eval schema and grader types used across evaluation layers |
| [failure-review-template.md](failure-review-template.md) | Recurring human-run failure-review ritual and its failure-mode-taxonomy vocabulary |
| [feature-breakdown-evals.md](feature-breakdown-evals.md) | Feature decomposition granularity and sensor-addressability checks (L2) |
| [judge-evaluation.md](judge-evaluation.md) | Calibrating LLM-as-judge graders against human labels |
| [mutation-evals.md](mutation-evals.md) | Known-bad regression tripwires (L5) |
| [outcome-evals.md](outcome-evals.md) | End-to-end issue fixtures (L4) |
| [research-notes.md](research-notes.md) | External grounding and open questions behind the evaluation strategy |
| [script-lifecycle-evals.md](script-lifecycle-evals.md) | Deterministic shell and lifecycle checks (L0) |
| [security-evals.md](security-evals.md) | Prompt injection, secrets, and least-privilege evals |
| [skill-evals.md](skill-evals.md) | Skill trigger, artifact, and behavior checks (L1) |
| [statistical-methodology.md](statistical-methodology.md) | Trials, pass@k vs pass^k, and noise vs. regression methodology |
| [subagent-role-evals.md](subagent-role-evals.md) | Planner, implementer, tester, reviewer role separation (L2) |
| [telemetry-retention-pii.md](telemetry-retention-pii.md) | Dormant exit-ramp contract for telemetry retention, allowlist, and PII posture (#272 removed the export leg) |
| [trace-action-log-evals.md](trace-action-log-evals.md) | Audit evidence and role attribution checks (L3) |
| [trajectory-evals.md](trajectory-evals.md) | Tool path and lifecycle ordering checks (L3) |
