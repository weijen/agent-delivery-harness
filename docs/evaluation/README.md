# Harness Evaluation

This directory collects the evaluation strategy for the agent delivery harness:
what we should measure, why, and how each measurement maps to a concrete harness
boundary. It is written so that each page can become its own GitHub issue.

The harness is an agentic system. Like any agentic system it needs evaluation
that goes beyond unit tests: deterministic checks for its scripts, behavioral
checks for its skills and subagents, and regression tripwires for the failures
we never want to see again.

## How To Read This Directory

Start with the roadmap below, then read
[evaluation-matrix.md](../archive/evaluation/evaluation-matrix.md) for the
shared eval schema and [research-notes.md](../archive/evaluation/research-notes.md)
for the external grounding behind these choices — both archived by #337 (epic
#331); see [the archive index](../archive/evaluation/README.md) for the full
set.

For the first executable slice, read
[l0-solution/README.md](l0-solution/README.md). It narrows the broad strategy in
this directory into an L0 architecture and specification — plus the shared eval
framework (manifest schema, runner, scorecard, and the determinism-based Tier A /
Tier B runtime split) that later layers reuse. The skills layer builds on that
framework in [l1-solution/README.md](l1-solution/README.md), which is kept
separate because it is less settled than L0.

## Layer Map

Evaluation is organized by how attributable and how expensive each layer is.
Lower layers are cheaper, more deterministic, and run more often.

| Layer | Name | What it protects | Cost | Determinism |
| --- | --- | --- | --- | --- |
| L0 | Script lifecycle | Shell scripts and lifecycle contract | Low | High |
| L1 | Skills | Skill trigger, artifact, behavior | Medium | Medium |
| L2 | Agent topology | Delivering agent / independent reviewer | Medium | Medium |
| L3 | Trajectory + trace | Path, ordering, audit evidence | Medium | Medium |
| L4 | Outcome | End-to-end issue fixtures | High | Low |
| L5 | Mutation | Regression tripwires for known-bad changes | Low–Medium | High |

Current lifecycle evaluation follows contract v2: `gate_start`, `gate_sensors`, `gate_review`, and
`gate_merge_closeout`. L2 evaluates one delivering agent followed by one independent reviewer; legacy role spans are
historical reader-compatibility fixtures, not the live execution topology.

Cross-cutting concerns (security, cost/efficiency, judge calibration, dataset
governance, observability schema, statistical method) apply across every layer
and have their own pages below.

## Evaluation Areas

| Page | Layer | Focus |
| --- | --- | --- |
| [cost-efficiency-evals.md](cost-efficiency-evals.md) | Cross-cutting | Tokens, turns, latency, thrash |
| [observability-and-trace-schema.md](observability-and-trace-schema.md) | Cross-cutting | OpenTelemetry GenAI-aligned trace schema |
| [product-quality-rubric.md](product-quality-rubric.md) | Cross-cutting | Coding-agent functionality product-quality rubric |
| [l0-solution/](l0-solution/) | L0 solution | Runnable architecture, spec, and shared eval framework for the foundation layer |
| [l1-solution/](l1-solution/) | L1 solution | Skills-layer architecture and spec, building on the L0 framework |
| [archived prose set](../archive/evaluation/README.md) | — | Archived L1+ strategy prose with zero runtime/doctrine reference (decision 3a, epic #331): script/skill/subagent-role/feature-breakdown/trajectory/trace-action-log/outcome/mutation evals, judge evaluation, security evals, azure runtime, dataset governance, statistical methodology, evaluation matrix, research notes, telemetry retention, and the accuracy matrix |

## Scorecard Model

Every eval, regardless of layer, is described by the same core fields: a target,
a capability, a boundary, a fixture, an expected outcome, one or more graders,
and a blocking policy. Trials, thresholds, source-dataset metadata, and contract
references are optional fields for cases that need them. The canonical schema lives in
[evaluation-matrix.md](../archive/evaluation/evaluation-matrix.md) (archived by
#337); the dataset lifecycle behind it lives in
[dataset-governance.md](../archive/evaluation/dataset-governance.md) (archived
by #337); the trial and threshold math lives in
[statistical-methodology.md](../archive/evaluation/statistical-methodology.md)
(archived by #337). The
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

Each page lists either an "Initial Issues To Create Later" section or, once its
issues exist, a pointer to the created workstream issues. When turning a page
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
