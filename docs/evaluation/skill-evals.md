# Skill Evals

## Purpose

Skill evals measure whether Copilot skills are selected for the right requests,
avoid false positives, and produce the expected artifacts or review behavior.
They answer whether a skill is useful and reliable in its intended boundary.

## Targets

Skills under `.copilot/skills/`, especially:

- `code-review`
- `create-pr`
- `security-audit`
- `sync-docs`
- `find-brute-force`
- `find-duplicates`
- `find-over-design`
- `dead-code-detection`

## Eval Categories

### Trigger Evals

Use prompt sets with:

- Explicit invocation: the prompt names the skill.
- Implicit invocation: the prompt describes the skill's domain.
- Contextual invocation: realistic prompt with extra noise.
- Negative control: adjacent request that must not invoke the skill.
- Ambiguous prompt: should ask clarification or avoid over-triggering.

### Artifact Evals

For skills that create outputs, check artifacts:

- Expected file exists.
- Expected schema is valid.
- Required sections are present.
- No unrelated files are modified.
- No sensitive or local-only material is included.

### Behavior Evals

For review and audit skills, check verdict quality:

- Findings are severity ordered.
- Blocking defects are not downgraded.
- Missing tests are called out when behavior changed.
- Findings are actionable and tied to concrete code or behavior.
- No invented file paths or unsupported claims.

Behavior evals that depend on an LLM judge must calibrate that judge against
human labels using [judge-evaluation.md](judge-evaluation.md), otherwise the
verdict quality score is itself unverified.

## Dataset Shape

Use a small prompt dataset per skill:

```csv
id,should_trigger,prompt,expected_artifact,expected_behavior
code-review-001,true,"Review this diff for bugs",,blocks_major_bug
code-review-002,false,"Summarize this README",,no_review_mode
```

For artifact-producing skills, pair prompts with fixture repositories and an
expected output schema. Curate and version these prompt sets per
[dataset-governance.md](dataset-governance.md), and never embed customer or
secret material in fixtures.

## Public Dataset Seeds

There is no single public dataset for Copilot skill routing, so trigger evals
should remain harness-specific. Public datasets can still seed behavior and
artifact fixtures:

- [CodeSearchNet](https://github.com/github/CodeSearchNet) provides code,
  docstring, and human relevance judgment examples that can seed prompt-routing
  and code-review relevance cases.
- [HumanEval](https://github.com/openai/human-eval),
  [MBPP](https://github.com/google-research/google-research/tree/master/mbpp),
  and [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench)
  provide code tasks with executable tests; adapt them into reviewer/tester
  behavior fixtures for missing tests, weak sensors, or incorrect artifacts.
- [AgentDojo](https://github.com/ethz-spylab/agentdojo) and
  [InjecAgent](https://github.com/uiuc-kang-lab/InjecAgent) provide adversarial
  tool-agent prompt-injection cases for `security-audit` behavior evals.

Use public cases as seeds only. The final trigger prompt set must include local
positive and negative examples for this repo's actual skill descriptions.

## Graders

Use deterministic graders first:

- Skill was invoked or not invoked, when the tool surface exposes this.
- Required output file exists.
- Output matches JSON or Markdown schema.
- Expected section headers exist.
- Forbidden files are untouched.

Use rubric graders for:

- Review quality.
- Severity classification.
- Whether the skill followed repo-specific instructions.

## The security-audit Skill Is Special

The `security-audit` skill is both a target and a tool. Its behavior evals
should reuse the adversarial fixtures in [security-evals.md](security-evals.md)
so the skill is measured against real injection, secret-leakage, and
least-privilege cases rather than only happy-path prompts.

## Initial Issues To Create Later

1. Define a skill eval dataset format.
2. Add prompt-trigger evals for `code-review`.
3. Add artifact evals for `create-pr`.
4. Add negative-control prompt sets for all high-risk skills.
5. Add structured rubric schema for review-skill outputs.

## Acceptance Criteria

- Each mature skill has positive and negative trigger cases.
- Skill evals produce stable, comparable results across runs.
- Review-skill evals include false-negative cases for missing tests and weak
  sensors.
