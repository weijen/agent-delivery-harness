---
mode: agent
description: 'Run the harness coding-session ritual: get bearings, implement ONE feature with TDD, leave a clean state.'
---

# Session Ritual

Work on issue: **${input:issue:which issue number? e.g. 1}**.

Follow the repo entry point in [AGENTS.md](../../AGENTS.md), then the canonical lifecycle in
[.copilot/instructions/harness.instructions.md](../instructions/harness.instructions.md).

Use the repo's own issue state to pick the next `feature_list` item. Implement one feature,
verify its declared completion sensors, leave a clean state, and report the feature, commit
SHA, and next feature/blocker.
