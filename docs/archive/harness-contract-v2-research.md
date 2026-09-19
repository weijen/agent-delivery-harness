> **Historical snapshot (2026-07-23).** Committed 2026-08-16 for provenance (#424): this research
> predates the 0.42-0.44 guardrail wave — design moves it proposes as future work shipped as
> #447-#450/#460, and gates it cites (e.g. `red_first_evidence_gate`) no longer exist. Read as the
> origin of the contract-v2 thinking, not as a description of the current system.

# Harness Contract v2 — research synthesis and design proposal

Date: 2026-07-23. Question: is `docs/harness-contract.yml` still valuable, and how should it
evolve so the SDLC lifecycle stays mechanically stable across model generations
(Fable 5.x, GPT-6/7, …)?

Verdict: **keep it, and promote it** — from a grep-presence freeze of the old harness's
strings to the declared authority for the skeleton's four gates and their evidence rules.
Every mature ecosystem studied (supply-chain security, policy-as-code, workflow engines,
agent-harness practice, and the 2024–26 research literature) converges on the same split:
**prose is advisory and dies with each model generation; deterministic gates + evidence
verification are the durable layer.** The contract is our one machine-readable artifact on
the durable side. Its current implementation, however, has both failure modes of a rotten
contract: false greens (retired behaviors whose strings survive — `red_first_evidence_gate`
is a hollow function, "conductor" outlived role choreography) and false reds (#385: a
benign literal refactor broke a pinned string while behavior was intact).

## Evidence base (three research streams, full citations at bottom)

**Industry practice.** Anthropic draws the line explicitly: CLAUDE.md/skills/rules are
advisory; "a real guardrail needs to be deterministic" (hooks that block with exit codes,
permissions). GitHub runs Copilot's coding agent as an untrusted contributor under the same
mechanical controls as humans: own branch only, initiator cannot approve the PR, CI gated
behind human click, **CODEOWNERS protects the agent's own config files from
self-modification**. Temporal/LangGraph converge on "control flow in deterministic code,
model only inside bounded nodes." The generational-durability consensus (Amp, mini-swe-agent,
harness commentary): *each model generation exposes the previous generation's structure as
overhead — but gates, deterministic regression checks, and evals are the assets that
transfer.* Cursor measured the same model at 46% vs 80% across two harnesses: the harness is
the variable worth engineering.

**Mature non-AI ecosystems.**
- **in-toto**: process = signed layout; each step declares who may perform it and what
  materials/products (by hash) it consumes/produces; step ORDER is enforced by evidence
  chaining (`MATCH … WITH PRODUCTS FROM <prev-step>`), not by a step list. Self-reported
  fields (`command`, byproducts) are explicitly informational, never load-bearing.
- **SLSA**: grades evidence trustworthiness. L1 = self-reported (worthless under
  adversarial/sycophantic failure); L2/L3 = produced by infrastructure the measured actor
  cannot influence. Tekton Chains implements this: the observer that signs the record is a
  different process from the actor being recorded.
- **OPA/Gatekeeper/GitHub rulesets**: three enforcement modes — deny / warn / **dry-run**
  (“evaluate”); policies are themselves unit-tested with coverage; bypasses are named,
  auditable records.
- **Pact**: a hand-maintained third artifact always drifts; bind contract to implementation
  mechanically (generate one side, replay against the other); match by minimum shape, not
  exact content, or benign changes break the contract and it gets loosened wholesale.
- **Argo/Gatekeeper audit**: conformance is a reconciliation loop, not a one-time gate —
  re-verify past runs when the contract changes; provide a declared-tolerance vocabulary so
  drift detection doesn't cry wolf.

**Research literature (2023–26).**
- **Never accept agent completion claims; never use an LLM as the completion judge.** False
  success = 45–76% of failures across settings; best LLM judge over 25 configurations never
  exceeded AUROC 0.65 (arXiv:2606.09863). GPT-5 submits a patch in 100% of runs but resolves
  44% (arXiv:2603.25764). Verification must be a deterministic gate reading environment state.
  (Our #374 catch — nine hand-written green_handbacks exposed by re-render forensics — is
  this literature in miniature.)
- **The oracle itself must be independent and adversarially strengthened.** Weak tests +
  leakage inflated SWE-agent's solve rate 3× (12.47%→3.97%, SWE-Bench+); adversarial test
  augmentation flipped 24–41% of leaderboard rankings (UTBoost).
- **External FSM/runtime rules beat prompts on both reliability and cost**: StateFlow got
  higher success with 3–5× cost reduction; AgentSpec-style runtime rule enforcement blocks
  >90% of unsafe actions at millisecond overhead. Prompt rules degrade up to 12% under
  semantics-preserving perturbation and don't survive long horizons.
- **Scaffold overfit is per model FAMILY, not capability tier** — "more capable ⇒ less
  scaffold-sensitive" was experimentally rejected (Scaffold Effects on GAIA, 28-pt swings).
  A contract must be re-validated per family and on every upgrade.
- **Design the trace schema for conformance checking**: raw AgentOps traces can't be
  conformance-checked without standardized activity semantics; once logs are event logs,
  Declare/LTL conformance runs offline and online (AgentLTL) and is by construction
  model-invariant. Our trace schema v1 + check-trace-consistency is already this shape.

## What we already have (and should keep, verbatim)

| Asset | Status |
|---|---|
| Four-gate skeleton (preflight / sensors-green / independent review / merge+closeout evidence) | The durable spine — matches every source's "gates survive generations" |
| Trace schema v1 + `check-trace-consistency.sh` | A working conformance checker over an event log — ahead of most industry practice |
| HEAD-bound review marker (`approved-head`), `reviewed_sha`, #368 claim↔summary reconciliation | Evidence chaining in embryo — exactly in-toto's MATCH pattern |
| Independent fresh-context reviewer + initiator-cannot-self-approve | Matches GitHub's mechanical separation; kill-record: 4 true intercepts today alone |
| TDD rule of engagement ("change the contract first") | Worked live today: #370 had to edit the contract to retire feature_start |
| Kill-record accounting / harvest loop | The re-earn-your-place discipline every durability source recommends |

## Contract v2 — six design moves

1. **Restructure around the four gates.** Each gate declares: trigger, evidence consumed,
   evidence produced, enforcement mode, and allowed producer of each evidence artifact.
   The old sections (scripts/lifecycle/env_flags/…) become supporting inventory.

2. **Evidence provenance tiers (SLSA-style).** Tag every evidence artifact in the contract:
   `provenance: harness-observed` (trace spans emitted by trace-lib inside lifecycle scripts,
   exit codes, `gh pr checks` output, sensor summary lines) vs `provenance: agent-claimed`
   (progress.md text, PR descriptions, chat claims). **Hard gates may only consume
   harness-observed evidence.** Agent-claimed artifacts are logged, never load-bearing.
   (#368 and the #374 forensics both become instances of one declared rule.)

3. **Order-by-chaining, not order-by-list (in-toto MATCH).** Replace the `lifecycle:` list
   with chain declarations: `pr_create requires review_gate_approve span whose
   reviewed_sha == HEAD`; `pr_merge requires CI-green at the same SHA`; `finish requires
   MERGED state observed`. check-trace-consistency verifies the chain; skipping or
   reordering breaks verification mechanically. Much of this logic exists — v2 makes the
   contract the place where the chain is *declared* and the checker the place where it is
   *verified* (single source of truth, two roles).

4. **Behavioral assertions for hard clauses; minimum-shape matching for the rest.** The
   ~15 `kind: hard` failure modes get fixture-based legs (drive the violating condition,
   assert non-zero exit) — this closes the admitted hard↔warn-flip blindness and ends both
   false-green and false-red failure modes. `warn` clauses keep cheap presence checks but
   match on message *shape*, not exact prose. Every clause needs one passing and one
   violating fixture (OPA `opa test` discipline); a clause no fixture exercises is flagged
   as rotted.

5. **Three enforcement modes + expiry + named bypasses.** Add `mode: dry-run` for new
   rules: evaluate against the recent run corpus (`logs/`, traces) and report what *would*
   have failed before promotion to hard — no more #385-style surprise reds. Add a
   `review_by:` date to force periodic re-authorship (in-toto `expires`). Existing escape
   hatches (FORCE, SKIP_CI_GATE, CREATE_PR_NO_REWRITE) become named `bypasses:` entries
   with declared audit obligations — they already exist; the contract should own them.

6. **Self-modification guard (CODEOWNERS pattern).** The contract, the gate scripts, and
   the reviewer prompt are the instrument that measures the agent; the agent must not
   silently modify them mid-issue. Mechanically: a sensor flags any diff touching
   `docs/harness-contract.yml` + gate scripts unless the issue explicitly declares
   harness-surgery scope (as #370 does) — declared in the feature list, visible to the
   independent reviewer.

## Why this survives Fable 5.1 / GPT-6

- The contract constrains the **envelope** (gate order, evidence provenance, chain
  integrity), never the reasoning or task-solving style — the layer research shows is
  model-invariant. Everything model-generation-sensitive stays in prose instructions,
  which remain cheap to rewrite or delete (the Amp lesson).
- Verification reads **environment state** (exit codes, SHAs, CI status, trace chains),
  which no model generation can redefine.
- Per-model-family re-validation is built in: the L0/L1 eval manifests already resolve to
  contract entries; run the conformance eval on every model upgrade and let kill-record
  accounting retire clauses that stop earning their keep.
- The bar for adding a clause is behavioral evidence from real runs (harvest loop), so the
  contract grows by measured need, not speculation — the anti-rot property none of the
  studied ecosystems get for free.

## Sequencing

Queue behind the current lanes per the standing decision (after sensor-diet lanes + the
#378–#384 re-validation). Natural slicing (footprint rule):
1. Prune + restructure around four gates (pure contract + contract-sensor change).
2. Provenance tiers + behavioral legs for hard clauses.
3. Chain declarations + check-trace-consistency wiring.
4. Dry-run mode + bypass registry + self-modification guard.

## Key sources

Industry: anthropic.com/research/building-effective-agents · code.claude.com/docs/en/hooks-guide ·
docs.github.com (Copilot cloud-agent risks-and-mitigations; rulesets) · temporal.io/blog (durable agents) ·
cognition.com/blog/dont-build-multi-agents · github.com/SWE-agent/mini-swe-agent · agents.md
Standards: in-toto spec (github.com/in-toto/docs) · slsa.dev/spec/v1.0 · openpolicyagent.org (policy testing) ·
conftest.dev · docs.pact.io · tekton.dev/docs/chains · argo-cd.readthedocs.io (diffing)
Research: arXiv 2403.11322 (StateFlow) · 2503.18666 (AgentSpec) · 2410.06992 (SWE-Bench+) ·
2506.09289 (UTBoost) · 2606.09863 (False Success) · 2603.25764 (Confident and Wrong) ·
2606.04990 (Agent Traces to Trust) · 2606.08529 (Scaffold Effects on GAIA) · 2603.13285 (BrittleBench) ·
2607.02599 (AgentLTL) · 2606.20669 (Agent Behavior Mining) · 2408.07720 (Re-Thinking Process Mining)
