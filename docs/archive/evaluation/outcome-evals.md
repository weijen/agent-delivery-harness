# Outcome Evals

## Purpose

Outcome evals test whether the harness can deliver a complete small issue from
start to finish. They are intentionally slower and should come after lower-level
script, skill, subagent, and trajectory evals exist.

## What Outcome Evals Should Prove

- A small issue can be started in an isolated worktree.
- A feature list can be created and completed.
- Required sensors are added and run.
- Review approval is tied to the final HEAD.
- PR creation includes the expected issue closeout text.
- Finish cleanup removes the worktree only when safe.

## Fixture Shape

Use tiny repositories or generated temporary repos. Avoid relying on the actual
main checkout as the mutable fixture.

Example fixture:

```json
{
  "id": "outcome-docs-001",
  "description": "Add a docs page and validate links",
  "initial_repo": {
    "files": {
      "README.md": "# Demo"
    }
  },
  "issue": {
    "title": "Add usage notes",
    "acceptance_criteria": [
      "docs/usage.md exists",
      "README links to docs/usage.md"
    ]
  },
  "expected": {
    "files": [
      "docs/usage.md"
    ],
    "sensors": [
      "link check",
      "shell parse check if scripts touched"
    ]
  }
}
```

## Public Dataset Seeds

Public software-engineering benchmarks can seed outcome fixtures, especially for
capability evals and shadow comparisons:

- [SWE-bench](https://github.com/SWE-bench/SWE-bench),
  [SWE-bench Lite](https://www.swebench.com/lite.html), and
  [SWE-bench Verified](https://www.swebench.com/verified.html) provide real
  GitHub issue-to-patch tasks. Use small tasks as inspiration for local issue
  fixtures, not as direct blocking gates.
- [Terminal-Bench](https://www.tbench.ai/) provides terminal-native tasks across
  software engineering, security, data, and system administration. These are
  useful for shell-heavy outcome fixtures and end-to-end latency/cost baselines.
- [BigCodeBench](https://huggingface.co/datasets/bigcode/bigcodebench),
  [HumanEval](https://github.com/openai/human-eval), and
  [MBPP](https://github.com/google-research/google-research/tree/master/mbpp)
  provide smaller executable programming tasks that can be wrapped in generated
  temporary repos for cheap local outcome checks.

Before promoting any public task into a harness eval, reduce it to a tiny,
versioned fixture with explicit acceptance criteria and sensors. Public benchmark
scores are useful context, but this harness should gate on fixtures it owns.

## Graders

- Final file state.
- Git branch and worktree state.
- Feature list completion.
- Verification text presence.
- Review-gate approval freshness.
- No unrelated files changed.
- Cleanup behavior after finish.

## Avoid At First

Do not start with a full real GitHub issue + PR + merge loop as the first
outcome eval. It will be slow and hard to debug. Start with local temporary repos
and fake `gh`, then add real GitHub integration only after the local outcome
suite is stable.

## Candidate Issues

- Add first local outcome fixture for docs-only issue work.
- Add fake `gh` outcome fixture for PR body generation.
- Add outcome fixture for stale review-gate rejection.
- Add outcome fixture for clean finish cleanup.
- Add nightly outcome eval command.
