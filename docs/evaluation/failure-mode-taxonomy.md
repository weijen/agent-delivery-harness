# Failure-Mode Taxonomy

## The Contract Freezes The Vocabulary

The eight failure modes below are frozen as the closed `failure_modes` enum in
[trace-schema.v1.json](trace-schema.v1.json), exactly as `lifecycle_steps`,
span types, roles, and outcomes are frozen. This page is the prose authority
for what each mode *means*; the contract is the authority for the spelling and
the closed membership. When prose and contract disagree, the contract wins.
Changing the taxonomy (adding, renaming, or removing a mode) is a schema
amendment and goes through the normal contract-change ritual — that friction
is deliberate.

## Purpose

Deviation spans already record *that* a run left the scripted path
(`harness.lifecycle_step: "deviation"`), but only in free-text
`harness.summary` prose. Nothing machine-clusterable says *why*. A shared,
closed failure vocabulary lets trace-based evals and periodic failure reviews
cluster deviations across issues ("three `flaky-environment` hits this month,
all shellcheck") instead of grepping prose, and turns observed failures into
evidence for filed harness issues.

## The Eight Modes

### missing-context

The agent lacked information it needed and either guessed or stalled: an
instruction file it was never routed, a decision recorded only in an untracked
local artifact, a contract it did not know existed. The trace signal is a
deviation or failed span whose summary shows the agent discovering late what
it should have been handed up front. Distinct from `weak-sensor`: here the
information existed but never reached the agent; there the check itself was
too weak to produce the information.

### brittle-tool-interface

A tool or script interface invited misuse: ambiguous flags, silently
destructive defaults, output that parses two ways, an interface that behaves
differently in edge conditions than its help text implies. The trace signal is
a tool span sequence where a reasonable invocation produced a surprising state
that a later span had to repair. When an agent misused a *correct* interface
because of who it was acting as, prefer `role-violation`.

### weak-sensor

A test or gate passed while the behavior it guards was broken, or failed for
reasons unrelated to what it claims to check — the sensor exists but does not
bite. This workstream's recurring SC2015 shellcheck reds are partly this mode:
the local pre-push check was weaker than CI's, so "lint clean" locally was a
sensor that did not actually predict a green pipeline. The trace signal is a
green handback followed by a red CI or review verdict on the same feature.

### token-thrash

The run burned model tokens without converging: repeated re-reads of the same
files, retry loops on the same failing command, oversized context assembled
for a small question. The trace signal is in `gen_ai.usage.*` aggregates —
token or span counts far above comparable features — and in tool-span
sequences that revisit the same targets without new outcomes.

### premature-termination

The harness or an agent tore down state or declared completion while work was
still pending. The anchor example is issue #95's worktree teardown on red CI:
the finish path removed the worktree while the pipeline was still red, and the
finish-time trace span only survived because trace-lib pins the trace file to
the main-checkout root. The trace signal is a `finish` (or teardown-adjacent)
span that precedes, or coexists with, unresolved failure evidence.

### permission-friction

Progress stalled on sandboxing, credentials, or approval prompts: a command
that needed an interactive grant mid-run, a token scope too narrow for a `gh`
call, repeated permission prompts fragmenting one logical operation into many
retries. The trace signal is clusters of failed or repeated tool spans around
the same privileged operation.

### flaky-environment

The same inputs produced different outcomes across environments or runs — the
failure is in the substrate, not the change. The anchor example is this
workstream's SC2015 CI-vs-local shellcheck divergence: scripts that passed
shellcheck locally went red in CI twice, because the CI shellcheck version and
severity settings diverged from the local ones. (The same incidents also
exposed a `weak-sensor`; one incident may legitimately carry evidence for a
follow-up under either mode — the human review picks the dominant one, since a
span carries a single `harness.failure_mode`.) The trace signal is
identical-looking spans with divergent outcomes across runs or hosts.

### role-violation

An agent acted outside its role contract: writing when scoped read-only,
mutating shared state that belongs to another role, bypassing a gate it was
supposed to stop at. The anchor example is the reviewer checkout that detached
HEAD (issue #92's deviation): a review step performed a `git checkout` in the
shared checkout, leaving the workspace on a detached HEAD that a later step
had to diagnose and repair. The trace signal is a tool or agent span whose
actor/operation pair contradicts the role doctrine in
`harness.instructions.md`.

## Attaching A Mode To A Trace

The carrier is the optional span attribute `harness.failure_mode`, declared in
the contract's `optional_fields` and constrained to the closed `failure_modes`
enum. Like `span_id`/`parent_span_id` (issue #93), it is additive and
optional: it rides the open-world extra-fields rule, no required-field set
changes, and every existing trace and emitter stays valid.

By convention the field belongs on deviation/failure spans — above all the
`deviation` lifecycle handbacks emitted through `scripts/log-handback.sh`. The
planned emission path (feature `failure-mode-span-plumbing`, a forward
reference — not implemented by this feature) is a `TRACE_FAILURE_MODE`
environment variable on `log-handback.sh`, mirroring the existing
`TRACE_INPUT_TOKENS`/`TRACE_OUTPUT_TOKENS` passthrough: forwarded only when
the value is in the frozen enum, omitted with a warning otherwise — omit,
never fake. The standalone validator (`scripts/check-trace-consistency.sh`) will reject
out-of-enum values as `schema_violation` when the key is present.

## Governance

Classification and everything downstream of it is **human-gated** and
PEV-governed: an agent (or a human) may *propose* a mode on a deviation span,
but clustering failures, diagnosing causes, and deciding that the harness
should change are review acts performed by a human under the normal
plan–execute–verify ritual. Taxonomy evidence is input to judgment, never a
trigger.

### Non-Goals

- **No automated harness mutation.** No script, agent, or eval may modify
  harness scripts, instructions, or contracts because failure-mode counts
  crossed a threshold.
- **No auto-promotion.** A recurring failure mode does not automatically
  become a rule, a gate, or a contract change.
- Any proposed harness change arising from taxonomy evidence is a **normal
  GitHub issue**, citing the relevant traces and mode counts as evidence, and
  travels the same PEV path as every other issue.
