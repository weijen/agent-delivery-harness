# GitHub Copilot runtime records

No runtime adapter setup is required. The harness emits its kept semantic spine
directly from lifecycle scripts, `scripts/trace-lib.sh`, and
`scripts/log-handback.sh`.

Copilot tool, model, skill, and subagent analysis reads the runtime's native
records through
[`copilot-log-review`](../../.copilot/skills/copilot-log-review/SKILL.md);
the harness no longer reconstructs those records into trace spans. The
authoritative boundary and schema are documented in
[observability-and-trace-schema.md](../evaluation/observability-and-trace-schema.md).
