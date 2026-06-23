# Public Dataset Seeds For L0/L1 Evals

## Purpose

This note records open-source datasets and benchmarks that can seed the first
L0/L1 evaluation implementation. These sources are useful for fixture design,
behavior probes, and shadow comparisons, but they do not replace this repo's own
versioned regression fixtures.

The L0/L1 solution still needs harness-specific manifests, fixtures, labels,
observable signals, graders, and scorecards. Public datasets should be adapted
into local fixtures under `tests/evals/` before they can participate in this
repo's evaluation gates.

## Immediate Finding

- L0 does not need a public dataset. The current `tests/scripts/*.sh` sensors are
  the bootstrap inputs and should be wrapped in manifests first.
- L1 skill-trigger evals, especially `skill:code-review`, do not have a single
  ready-made public dataset. They need a harness-specific prompt dataset because
  the expected routing decision depends on this repo's skill descriptions and
  workflow language.
- Public datasets are most useful for L1 artifact and behavior fixtures, not as
  direct blocking skill-routing datasets.

## Datasets Available From Hugging Face

| Dataset | Access | License / size signal | Best fit | Notes |
| --- | --- | --- | --- | --- |
| `bigcode/bigcodebench` | Hugging Face `datasets` | Apache-2.0; thousands of Python code-generation rows | `code-review`, tester behavior, weak-sensor, missing-test, artifact-quality fixtures | Strong first seed for practical Python tasks with tests. Use small subsets and sandbox execution. |
| `google-research-datasets/mbpp` | Hugging Face `datasets` | CC-BY-4.0; small Python programming tasks | Simple reviewer/tester behavior fixtures | Good for cheap local fixtures; less realistic than repo-level issue datasets. |
| `openai/openai_humaneval` | Hugging Face `datasets` | MIT; 164 Python problems | Small code-correctness and tester fixtures | Useful for smoke-sized behavior seeds, but likely contaminated in model pretraining. Do not use as a sole gate. |
| `princeton-nlp/SWE-bench_Lite` | Hugging Face `datasets` | Small subset of SWE-bench; about 300 issue/PR pairs | Outcome, subagent-role, and review-behavior seeds | Real GitHub issue style, but heavier than L1 trigger evals and not ideal for fast PR gates. |
| `princeton-nlp/SWE-bench_Verified` | Hugging Face `datasets` | 500 human-validated SWE-bench samples | Higher-quality issue fixture seeds | Prefer over full SWE-bench when sampling realistic issue fixtures. Still requires local adaptation. |
| `SWE-bench/SWE-bench` | Hugging Face `datasets` | Larger SWE-bench corpus | External capability comparison and later outcome evals | Too heavy for the first L0/L1 implementation slice. |

Example loading commands:

```python
from datasets import load_dataset

bigcode = load_dataset("bigcode/bigcodebench", split="v0.1.4")
mbpp = load_dataset("google-research-datasets/mbpp", "sanitized", split="test")
humaneval = load_dataset("openai/openai_humaneval", split="test")
swe_lite = load_dataset("princeton-nlp/SWE-bench_Lite", split="test")
swe_verified = load_dataset("princeton-nlp/SWE-bench_Verified", split="test")
```

## GitHub Or Package Benchmarks

| Source | Access | Best fit | Notes |
| --- | --- | --- | --- |
| CodeSearchNet | GitHub repository plus S3 downloads | Routing relevance, code/docstring relevance, judge-calibration seeds | The GitHub repo is archived but the dataset and human relevance judgments are public. The full corpus is large; use targeted subsets. |
| AgentDojo | GitHub and `pip install agentdojo` | `security-audit` behavior, prompt-injection, tool-agent attack fixtures | Useful for adversarial skill behavior. Replace any risky payloads with synthetic markers before committing fixtures. |
| InjecAgent | GitHub repository data files | Indirect prompt injection and data-stealing attack fixtures | Includes attacker cases, user cases, and generated test cases. Adapt only sanitized synthetic variants. |
| Terminal-Bench | GitHub and `pip install terminal-bench` / `uv tool install terminal-bench` | Terminal-task and trajectory seeds | Better suited for later trajectory or outcome evals than the first L0/L1 gate. |
| tau-bench / tau2 / tau3 | GitHub repositories | Tool-agent-user interaction and historical trajectory seeds | The original tau-bench README points users to newer tau2/tau3 tasks. Use for design ideas and later trajectory work. |

## Recommended First Slice

1. Build the first `skill:code-review` trigger dataset manually with the strata
   required by the L0/L1 spec: explicit positive, implicit positive, contextual
   positive, negative control, and ambiguous cases.
2. Sample 5-10 BigCodeBench rows as behavior-fixture seeds for code-review or
   tester-style checks.
3. Sample 3-5 SWE-bench Verified rows as realistic issue-fixture seeds for later
   review or outcome scenarios.
4. Sample a small sanitized InjecAgent or AgentDojo subset for future
   `security-audit` behavior checks.

## Adaptation Requirements

Every imported seed must be converted into a local fixture before it supports a
scorecard. Record at least:

- Source dataset name.
- Source URL.
- Source version, split, commit, or task id.
- Local fixture id and path.
- License.
- Modifications made.
- Contamination risk.
- Sensitivity classification.
- Expected label and observable signal.

For trigger datasets, public cases are only inspiration. The final prompt set
must include local positive and negative examples for this repo's actual skill
descriptions.

## Blocking-Gate Guidance

- Do not make public benchmark rows blocking until they have been adapted,
  versioned, reviewed, and proven reproducible in the local runner.
- Do not make L1 trigger cases blocking until the runner has an observable skill
  selection signal or a stable proxy artifact.
- Do not run heavyweight SWE-bench-style fixtures in every PR gate.
- Do not commit real secrets, customer data, private URLs, tenant IDs,
  subscription IDs, endpoints, or unsanitized benchmark artifacts.