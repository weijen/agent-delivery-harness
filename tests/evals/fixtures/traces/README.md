# Trace Replay Fixtures

Sanitized, commit-safe replay fixtures derived from real harness traces
(issue #99, feature `trace-sanitize-fixture`). Real traces are local-only by
contract (`.copilot-tracking/issues/issue-*/` is gitignored); these fixtures
are the only trace data that may live in the repo, and every one must pass
through `scripts/sanitize-trace.sh` and a human review before commit
(governance: [failure-mode-taxonomy.md](../../../../docs/evaluation/failure-mode-taxonomy.md),
provenance rules: [dataset-governance.md](../../../../docs/archive/evaluation/dataset-governance.md)).

Consumers: the existing validator in path mode
(`./scripts/check-trace-consistency.sh <fixture>`), exercised by
`tests/scripts/test_sanitize_trace.sh`.

## issue-97-deviation.trace.jsonl

- **Source:** the real issue #97 run trace
  (`.copilot-tracking/issues/issue-97/trace.jsonl` at the main checkout
  root) — a finished 37-span run containing one real `deviation` span.
- **Sanitized:** 2026-07-04 with `scripts/sanitize-trace.sh` at harness
  revision `eff283d` (no `--head` trim; all 37 spans kept).
- **Sanitization steps:** `trace_redact` (trace-lib policy) on every line;
  home-rooted absolute paths rewritten to `<SCRUBBED_PATH>`; fail-closed
  leak audit (redaction fixed point, path grep, secret-shape backstop,
  valid-JSONL check) passed with zero findings.
- **Verification:** `./scripts/check-trace-consistency.sh` path mode — 0 violations
  (the `unexpected trace location` WARNING is expected for a fixture path);
  no `/Users/` or `/home/` substring; fixed point of `trace_redact`.
- **Human review:** completed 2026-07-04, before commit — all 37 spans
  inspected line by line: zero home-rooted paths, zero secret shapes, zero
  personal identifiers. Reviewer: repo owner (via the conductor-run
  session). Committing a fixture remains a human act; any regeneration
  requires a fresh review.
- **Provenance caveat:** spans 18–27 (the `pr_merge` bursts carrying
  `harness.pr_number` `123` with millisecond-scale durations) originate
  from dogfood/test runs appended into the real issue-97 trace during
  development — genuine emitter output, but not part of the issue's own
  lifecycle. Replay consumers (trajectory/completeness evals) should treat
  the span-sequence fidelity of that window accordingly.
