# Harness Evaluation

This directory collects the evaluation strategy for the agent delivery harness:
what we should measure, why, and how each measurement maps to a concrete harness
boundary. It is written so that each page can become its own GitHub issue.

The harness is an agentic system. Like any agentic system it needs evaluation
that goes beyond unit tests: deterministic checks for its scripts, behavioral
checks for its skills and subagents, and regression tripwires for the failures
we never want to see again.

## How To Read This Directory

Start with the roadmap below, then read [evaluation-matrix.md](evaluation-matrix.md)
for the shared eval schema and [research-notes.md](research-notes.md) for the
external grounding behind these choices.

For the first executable slice, read
[l0-l1-solution/README.md](l0-l1-solution/README.md). It narrows the broad
strategy in this directory into an L0/L1 architecture and specification with a
determinism-based runtime split: deterministic Tier A checks in GitHub Actions
CI, and model-driven Tier B checks on Azure.

## Layer Map

Evaluation is organized by how attributable and how expensive each layer is.
Lower layers are cheaper, more deterministic, and run more often.

| Layer | Name | What it protects | Cost | Determinism |
| --- | --- | --- | --- | --- |
| L0 | Script lifecycle | Shell scripts and lifecycle contract | Low | High |
| L1 | Skills | Skill trigger, artifact, behavior | Medium | Medium |
| L2 | Subagent roles | Planner / implementer / tester / reviewer | Medium | Medium |
| L3 | Trajectory + trace | Path, ordering, audit evidence | Medium | Medium |
| L4 | Outcome | End-to-end issue fixtures | High | Low |
| L5 | Mutation | Regression tripwires for known-bad changes | Low–Medium | High |

Cross-cutting concerns (security, cost/efficiency, judge calibration, dataset
governance, observability schema, statistical method) apply across every layer
and have their own pages below.

## Evaluation Areas

| Page | Layer | Focus |
| --- | --- | --- |
| [script-lifecycle-evals.md](script-lifecycle-evals.md) | L0 | Deterministic shell and lifecycle checks |
| [skill-evals.md](skill-evals.md) | L1 | Skill trigger, artifact, and behavior checks |
| [subagent-role-evals.md](subagent-role-evals.md) | L2 | Planner, implementer, tester, reviewer roles |
| [feature-breakdown-evals.md](feature-breakdown-evals.md) | L2 | Feature decomposition granularity and sensor-addressability |
| [trajectory-evals.md](trajectory-evals.md) | L3 | Tool path and lifecycle ordering |
| [trace-action-log-evals.md](trace-action-log-evals.md) | L3 | Audit evidence and role attribution |
| [outcome-evals.md](outcome-evals.md) | L4 | End-to-end issue fixtures |
| [mutation-evals.md](mutation-evals.md) | L5 | Known-bad regression tripwires |
| [judge-evaluation.md](judge-evaluation.md) | Cross-cutting | Calibrating LLM-as-judge graders |
| [security-evals.md](security-evals.md) | Cross-cutting | Prompt injection, secrets, least privilege |
| [cost-efficiency-evals.md](cost-efficiency-evals.md) | Cross-cutting | Tokens, turns, latency, thrash |
| [azure-evaluation-runtime.md](azure-evaluation-runtime.md) | Cross-cutting | Azure ML and Azure AI Foundry runtime strategy |
| [dataset-governance.md](dataset-governance.md) | Cross-cutting | Golden datasets, versioning, contamination |
| [observability-and-trace-schema.md](observability-and-trace-schema.md) | Cross-cutting | OpenTelemetry GenAI-aligned trace schema |
| [statistical-methodology.md](statistical-methodology.md) | Cross-cutting | Trials, pass@k vs pass^k, noise vs regression |
| [evaluation-matrix.md](evaluation-matrix.md) | Cross-cutting | Shared eval schema and grader types |
| [product-quality-rubric.md](product-quality-rubric.md) | Cross-cutting | Coding-agent functionality product-quality rubric |
| [research-notes.md](research-notes.md) | Cross-cutting | External grounding and open questions |
| [l0-l1-solution/](l0-l1-solution/) | L0/L1 solution | Runnable architecture and spec for the first two layers |

## Scorecard Model

Every eval, regardless of layer, is described by the same fields: a target, a
capability, a boundary, a mode (`regression` or `capability`), a dataset, one or
more graders, trials, and thresholds. The canonical schema lives in
[evaluation-matrix.md](evaluation-matrix.md); the dataset lifecycle behind it
lives in [dataset-governance.md](dataset-governance.md); the trial and threshold
math lives in [statistical-methodology.md](statistical-methodology.md). The
coding-agent functionality product quality rubric lives in
[product-quality-rubric.md](product-quality-rubric.md), where it frames useful,
complete, workflow-fit agent behavior; it is not a visual, aesthetic, or
UI-design rubric.

## Public Dataset Seeds

Public software-agent benchmarks are useful seed material for capability
framing, calibration, and fixture design, but they should not replace this
harness's own versioned regression fixtures. Treat them as sources to adapt,
subset, or use for shadow comparisons after checking license, contamination, and
sensitivity constraints.

| Source | Best fit in this directory | Notes |
| --- | --- | --- |
| [SWE-bench](https://github.com/SWE-bench/SWE-bench) and [SWE-bench Verified](https://www.swebench.com/verified.html) | Outcome, subagent-role, cost, statistical methodology | Public real GitHub issue tasks; useful for seed issue fixtures and external capability comparisons. |
| [Terminal-Bench](https://www.tbench.ai/) | Outcome, trajectory, cost | Terminal-task benchmark with software, security, data, and system-admin tasks; useful for tool-path and latency/cost baselines. |
| [tau-bench](https://github.com/sierra-research/tau-bench) and [tau2/tau3-bench](https://github.com/sierra-research/tau2-bench) | Trajectory, trace/action-log, cost | Tool-agent-user interaction tasks and historical trajectories; useful for trajectory schema and fault attribution ideas. |
| [AgentDojo](https://github.com/ethz-spylab/agentdojo) and [InjecAgent](https://github.com/uiuc-kang-lab/InjecAgent) | Security, skill behavior, trajectory | Prompt-injection and tool-integrated-agent attack fixtures; adapt with synthetic secrets only. |
| [HumanEval](https://github.com/openai/human-eval), [MBPP](https://github.com/google-research/google-research/tree/master/mbpp), and [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench) | Skill, subagent-role, mutation, outcome | Code-generation tasks with executable tests; useful for tester/reviewer sensors and missing-test mutations. |
| [CodeSearchNet](https://github.com/github/CodeSearchNet) | Skill, judge calibration, dataset governance | Code/docstring pairs plus human relevance judgments; useful for routing, review relevance, and gold-label examples. |
| [CodeBLEU](https://github.com/salesforce/CodeT5/tree/main/CodeT5/evaluator/CodeBLEU) | Evaluation matrix, judge evaluation | Not a dataset, but an open code-quality metric implementation that can complement execution checks for code-output evals. |

## Implementation Priority

1. **L0 script lifecycle** — cheapest, most deterministic, highest attribution.
2. **L5 mutation** for known past failures — turn every fixed bug into a
   tripwire.
3. **Security** baseline — injection, secret-leakage, signing preservation.
4. **L2 subagent role** separation — the harness's core quality gate.
5. **L1 skill** trigger and artifact checks for mature skills.
6. **L3 trajectory + trace** for safety-critical ordering.
7. **L4 outcome** fixtures last — most expensive, least deterministic.

Cross-cutting pages (judge calibration, dataset governance, observability schema,
statistical method, cost/efficiency, and the coding-agent functionality product
quality rubric in [product-quality-rubric.md](product-quality-rubric.md)) are
prerequisites that the layer work pulls in as needed rather than a separate
phase.

## Issue Creation Guidance

Each page lists an "Initial Issues To Create Later" section. When turning a page
into issues:

- Keep one capability per issue where possible.
- Name the target, the boundary, and the grader type in the issue.
- State whether the eval is `regression` (blocking) or `capability` (tracked).
- Reference the dataset or fixture location.
- Do not bundle multiple boundaries into one issue; that destroys attribution.

## Non-Goals

- This is not a benchmark leaderboard.
- This does not require uploading private issue content to any third party.
- This does not replace human review; it calibrates and focuses it.
