# Research Notes

This page records the external grounding behind the harness evaluation strategy:
the frameworks we drew from, what each contributed, and the open questions that
remain. It is a reference, not a contract; the per-page docs are authoritative.

## Frameworks Surveyed

### OpenAI — Skill / Capability Evals

- Frames evals around discrete capabilities with explicit pass criteria.
- Distinguishes graders that are deterministic from graders that require a model.
- Reinforces one-capability-per-eval for attribution.
- Applied in [skill-evals.md](skill-evals.md) and the matrix capability field.

### Anthropic — Agent Evaluation

- Separates **capability** evals (can the agent do this at all?) from
  **regression** evals (does a fixed behavior stay fixed?).
- Popularized **pass@k** (succeeds at least once) versus **pass^k** (succeeds
  every time) as distinct questions of capability versus reliability.
- Stresses that agent evals must look at the path and tool use, not only the
  final answer.
- Applied in [statistical-methodology.md](statistical-methodology.md),
  [evaluation-matrix.md](evaluation-matrix.md), and the mode field.

### DeepEval — Component And Span Evals

- Component-level and span-level evaluation: score individual steps, not just
  end-to-end output.
- Supports targeted graders attached to specific parts of a trace.
- Motivates the span-aware approach in
  [observability-and-trace-schema.md](../../evaluation/observability-and-trace-schema.md).

### LangSmith AgentEvals — Trajectory Match Modes

- Provides trajectory match modes: strict, unordered, subset, superset.
- Maps cleanly onto the harness need for both exact safety-gate ordering and
  flexible implementation paths.
- Applied directly in [trajectory-evals.md](trajectory-evals.md).

### Microsoft Foundry — System / Process / Quality Evals

- Separates system-level, process-level, and output-quality evaluation.
- Emphasizes continuous evaluation and monitoring over one-off scoring.
- Informs the cadence model in [evaluation-matrix.md](evaluation-matrix.md).

## Judge Calibration And Bias

- Practitioner guidance (notably Hamel Husain's writing on LLM-as-judge)
  recommends **binary pass/fail with written critiques** over 1–5 scales, and
  warns about **critique shadowing**, where showing the judge a prior score
  anchors its verdict.
- The LLM-as-judge bias literature documents **position bias**, **verbosity
  bias**, **self-preference**, and **sycophancy** as systematic failure modes.
- Agreement should be reported with chance-corrected metrics such as **Cohen's
  κ**, not raw agreement alone.
- Applied in [judge-evaluation.md](judge-evaluation.md).

## Agent Security And Prompt Injection

- Indirect prompt injection is the central agent security threat: untrusted
  content (web pages, issues, tool output) carries instructions the agent may
  obey. OWASP lists prompt injection as a top LLM risk.
- Research benchmarks such as **InjecAgent**, **WASP** (web agent prompt
  injection), and **AgentDojo**-style harnesses evaluate whether agents resist
  injected instructions while still completing tasks.
- This grounds [security-evals.md](security-evals.md), whose threat model maps
  directly onto the harness's ingest surfaces (issues, PR comments, web fetches,
  tool output) and privileged actions (git, `gh`, cloud CLIs).

## Observability Standards

- The **OpenTelemetry GenAI semantic conventions** define span names and
  attributes for model calls, agent invocations, and tool calls
  (`gen_ai.operation.name`, `gen_ai.agent.name`, `gen_ai.usage.*`,
  `gen_ai.tool.name`).
- Aligning the harness trace with these conventions gives shared tooling across
  trajectory, trace, and cost evals.
- Applied in [observability-and-trace-schema.md](../../evaluation/observability-and-trace-schema.md).

## Dataset Quality And Contamination

- Eval validity is bounded by dataset quality: benchmark **contamination** and
  **leakage** make memorized answers look like capability.
- Guidance favors small, versioned, intent-labeled datasets, multi-rater gold
  labels, and growing the corpus from real failures (error analysis).
- Applied in [dataset-governance.md](dataset-governance.md).

## Public Benchmarks (Context, Not Gates)

- SWE-bench / SWE-bench Verified, Terminal-Bench, and similar suites measure
  end-to-end software-agent capability.
- They are useful as external reference points and for capability framing, but
  are unsuitable as harness gates: they may be contaminated, they measure a
  different system, and they do not exercise this harness's lifecycle.
- The harness gates on its own fixtures instead.

## Public Dataset Map

| Public source | What it contributes | Applied pages |
| --- | --- | --- |
| [SWE-bench](https://github.com/SWE-bench/SWE-bench), SWE-bench Lite, SWE-bench Verified | Real GitHub issue-to-patch tasks and human-filtered solvable subsets | [outcome-evals.md](outcome-evals.md), [subagent-role-evals.md](subagent-role-evals.md), [cost-efficiency-evals.md](../../evaluation/cost-efficiency-evals.md), [statistical-methodology.md](statistical-methodology.md) |
| [Terminal-Bench](https://www.tbench.ai/) | Terminal-native software, security, system, and data tasks with verifiers | [script-lifecycle-evals.md](script-lifecycle-evals.md), [trajectory-evals.md](trajectory-evals.md), [outcome-evals.md](outcome-evals.md), [cost-efficiency-evals.md](../../evaluation/cost-efficiency-evals.md) |
| [tau-bench](https://github.com/sierra-research/tau-bench) and [tau2/tau3-bench](https://github.com/sierra-research/tau2-bench) | Tool-agent-user interactions, historical trajectories, and fault labels | [trajectory-evals.md](trajectory-evals.md), [trace-action-log-evals.md](trace-action-log-evals.md), [observability-and-trace-schema.md](../../evaluation/observability-and-trace-schema.md) |
| [AgentDojo](https://github.com/ethz-spylab/agentdojo) and [InjecAgent](https://github.com/uiuc-kang-lab/InjecAgent) | Prompt-injection and tool-integrated-agent attack cases | [security-evals.md](security-evals.md), [skill-evals.md](skill-evals.md), [trajectory-evals.md](trajectory-evals.md) |
| [HumanEval](https://github.com/openai/human-eval), [MBPP](https://github.com/google-research/google-research/tree/master/mbpp), [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench) | Executable code-generation tasks with tests | [skill-evals.md](skill-evals.md), [subagent-role-evals.md](subagent-role-evals.md), [mutation-evals.md](mutation-evals.md), [outcome-evals.md](outcome-evals.md) |
| [CodeSearchNet](https://github.com/github/CodeSearchNet) | Code/docstring pairs and human relevance judgments | [skill-evals.md](skill-evals.md), [judge-evaluation.md](judge-evaluation.md), [dataset-governance.md](dataset-governance.md) |
| [CodeBLEU](https://github.com/salesforce/CodeT5/tree/main/CodeT5/evaluator/CodeBLEU) | Open code-output metric implementation, not a fixture dataset | [evaluation-matrix.md](evaluation-matrix.md), [judge-evaluation.md](judge-evaluation.md) |

## Recommended Eval Shape For This Harness

| Layer | Primary grader style | Trials | Blocks? |
| --- | --- | --- | --- |
| L0 script lifecycle | Deterministic | 1 | Yes |
| L1 skills | Deterministic + rubric | small k | Mature skills only |
| L2 subagent roles | Rubric (calibrated) + deterministic | small k | When stable |
| L3 trajectory + trace | Deterministic ordering | 1–small k | Safety gates yes |
| L4 outcome | Mixed + cost | k | Periodic |
| L5 mutation | Deterministic detection | 1 | Yes |
| Security | Deterministic + trajectory | k | Yes |
| Cost/efficiency | Deterministic counters | k | On regression |

## Design Rules

- Prefer deterministic graders; reach for an LLM judge only when necessary, and
  calibrate it when you do.
- One capability per eval; name the target and boundary for attribution.
- Reliability (pass^k) gates; capability (pass@k) explores.
- Turn every real failure into a dataset item and, where possible, a mutation.
- Keep all datasets, traces, and logs free of secrets and customer data.
- Re-baseline and re-calibrate on every model or tool upgrade.

## Open Questions And Current Resolutions

- **How many trials for nondeterministic gates?** Resolved direction: fix a small
  `k` per eval, larger for high-stakes gates; report pass^k. See
  [statistical-methodology.md](statistical-methodology.md).
- **How to keep LLM graders trustworthy?** Resolved direction: calibrate against
  multi-rater gold labels, report κ and critical false-negative rate, re-calibrate
  on model change. See [judge-evaluation.md](judge-evaluation.md).
- **One trace format or many?** Resolved direction: a single GenAI-aligned trace
  consumed by trajectory, trace, and cost evals. See
  [observability-and-trace-schema.md](../../evaluation/observability-and-trace-schema.md).
- **Use public benchmarks as gates?** Resolved: no; use them as context only and
  gate on harness fixtures.
- **Does the language surface (Bash vs Python vs Node) change the strategy?**
  Open: the L0 lifecycle is shell today; per-language sensors may need
  language-specific graders as code lands.

## Maintenance

When a new external source materially changes the strategy, add it here with a
one-line statement of what it changed and which page it affected, so the grounding
stays auditable.
