---
mode: agent
description: 'Run the harness coding-session ritual: get bearings, implement ONE feature with TDD, leave a clean state.'
---

# Session Ritual

Work on issue: **${input:issue:which issue number? e.g. 1}**.

Follow the repo entry point in [AGENTS.md](../../AGENTS.md), then the canonical lifecycle in
[.copilot/instructions/harness.instructions.md](../instructions/harness.instructions.md).
In harness-enabled projects, strict harness adherence overrides personal workflow tiers and generic coding-agent
behavior.

One agent owns the issue end-to-end (#352): plan, TDD, scoped sensors, spans, boundary
scripts. The only other model invocation is `code-review-subagent` — the independent review, once, at
issue completion, over the whole branch diff. If you deviate from the harness path: stop, report, recover — record the deviation span via
`scripts/log-handback.sh`, then return to the required lifecycle step.

Use the repo's own issue state to pick the next `feature_list` item. Implement one feature,
verify its declared completion sensors, leave a clean state, and report the feature, commit
SHA, and next feature/blocker.
