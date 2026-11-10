# GitHub Copilot

## Instruction discovery

The shared entry point is
[.github/copilot-instructions.md](../.github/copilot-instructions.md), a standard
repository instruction source for Copilot CLI and VS Code. It routes issue
delivery to the canonical lifecycle under `.copilot/instructions/`; the detailed
lifecycle and workflow guide are deliberately not blanket `applyTo: '**'` rules.
Questions and read-only reviews do not enter the delivery pipeline.

The `.copilot/` directory is the harness asset location, not a guarantee of
automatic discovery in every host. CLI also reads root `AGENTS.md`; adopters
retain their own map rather than receiving this source repository's map.
Use `copilot instruction list --json` from the checkout to inspect what that CLI
process discovers (host-projected instructions are excluded). Follow the entry
point's links to load the relevant details; they are not all automatically loaded.

Both installer profiles ship the entry point, lifecycle, workflow guide and
session prompt. Normal installer reconciliation preserves differing adopter
instructions and reports conflicts; resolve those by incorporating the routing
links into the project's existing instructions rather than overwriting them.

## Running the task prompts

| Host | Invocation |
| --- | --- |
| VS Code **Local** session | Open `.copilot/prompts/session-ritual.prompt.md` and use the editor play button. Supply the issue input. The source checkout also has `audit-sweep.prompt.md`. |
| Copilot CLI | Explicitly request the file and supply its input, e.g. `copilot -p 'Follow .copilot/prompts/session-ritual.prompt.md for issue 568; use 568 for the issue input.'` |

Prompt files use the current `agent: agent` frontmatter. VS Code's default
workspace prompt directory is `.github/prompts`, so do not assume slash-command
discovery for these `.copilot/prompts` paths. Opening the file avoids changing
workspace settings or maintaining duplicate prompt copies.
CLI `-p` sends a request to read the file; it does not claim native prompt-file
slash commands or automatic `${input:...}` substitution. To reuse a workflow as
a native CLI skill, follow that host's skill documentation separately.

The session prompt delivers one feature, then stops if work remains. When all
features pass, it completes the lifecycle's review, repair, validation and
authorised closeout. The audit prompt only invokes the source-only driver and
reports findings; it never authorises remediation.

See the [VS Code prompt-file reference](https://code.visualstudio.com/docs/agent-customization/prompt-files)
for Local-session behaviour, and use the CLI's built-in help/documentation for
the installed build. Static frontmatter/link checks and fake-CLI boundary tests
protect structure and script behaviour; they do not establish model adherence or
cross-host reliability through a model execution benchmark.

## Runtime records

No runtime adapter setup is required. The harness emits its kept semantic spine
directly from lifecycle scripts, `scripts/lib/trace-lib.sh`, and
`scripts/log-handback.sh`.

Copilot tool, model, skill, and subagent analysis reads the runtime's native
records through
[`copilot-log-review`](../.copilot/skills/copilot-log-review/SKILL.md);
the harness no longer reconstructs those records into trace spans. The
authoritative boundary and schema are documented in
[observability-and-trace-schema.md](observability-and-trace-schema.md).
