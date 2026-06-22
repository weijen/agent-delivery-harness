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

Keep prompt-path role separation explicit: Conductor selects and coordinates; implementation-subagent edits production assets only; test-subagent owns sensors and pass status; code-review-subagent reviews the completed diff. If a harness
deviation occurs, stop, report it in the issue progress Action Log, recover to the required lifecycle step, and only
then continue. Record substantive Conductor and subagent actions in the issue progress Action Log while preserving
those role boundaries.

Use the repo's own issue state to pick the next `feature_list` item. Implement one feature,
verify its declared completion sensors, leave a clean state, and report the feature, commit
SHA, and next feature/blocker.
