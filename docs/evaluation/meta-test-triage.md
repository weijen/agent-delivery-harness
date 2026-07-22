# Meta-test triage — prose-pinning cleanup (issue #273)

Point-in-time decision record, dated **2026-07-10** batch (delivered under
issue #273). This table is an auditable snapshot, **not** a live inventory —
new meta-tests are governed by the rubric recorded in
[`.copilot/instructions/bash.instructions.md`](../../.copilot/instructions/bash.instructions.md),
not by keeping this file in sync.

## Rubric (the deletion criterion)

A meta-test earns its keep only if it does one of these:

- **KEEP — machine-parsed structure**: validates a format a script actually
  parses (handback payload line, TAP rows, skill/agent frontmatter, schema
  single-source/key-coverage, L0 gate driver behaviour, teeth_proof kind-set).
- **KEEP — cross-file consistency**: asserts two artifacts agree (routing map
  vs language files on disk, doc vs the script/workflow that is its authority,
  schema vs its consumers). Cheap, and catches drift a human review misses.
- **CONVERT — doctrine-critical prose**: guards core doctrine but pins it with
  sentence-level greps. Rewrite to assert the named section/anchor EXISTS and
  its **closed vocabulary** is present; wording becomes free to edit.
- **DELETE — phrase-pinning with no parser and no consumer**: greps prose no
  script parses. Its failure mode is "someone rephrased a sentence", not
  "someone broke behaviour". Doc drift is caught by the `sync-docs` review
  skill and the fresh-context reviewer — never by these.

## Honest line-count note (supersedes the issue's `<1,500` estimate)

The issue estimated `tests/meta` at 41 files / ~3,980 lines and targeted
"under ~1,500 lines". At delivery `tests/meta` is 47 files / 4,196 lines, and
the **structural/behavioural KEEP floor alone exceeds ~1,700 lines** (TAP
helper 160, L0 CI gate 196, L0 sensors TAP 129, trace-schema single-source
137, trace↔action-log consistency 145, teeth-proof doctrine 124, handback
payload 89, log-schema single-source 94, and the extraction/drift sensors).
Cutting below 1,500 would require deleting genuinely structural tests — the
exact Goodhart failure this batch fights. The `<1,500` number is therefore
**superseded by the rubric**: DELETE the phrase-pinning set, CONVERT the five
doctrine tests, KEEP the rest. Net effect below.

## `tests/meta/*.sh` verdicts

| File | Verdict | Justification |
| --- | --- | --- |
| test_agent_delivery_accuracy_matrix_doc.sh | DELETE | Prose sibling of the contract test; pins doc sentences (`actual failing output`, `detail stream`) the contract already guarantees structurally. |
| test_agent_model_pins.sh | KEEP-structural | Parses agent frontmatter `model:` pins against the known lineup (drift sensor). |
| test_agent_span_doctrine.sh | CONVERT | Doctrine-critical (agent-span emission), but pins ordering prose with long fragment greps. |
| test_audit_conventions_shared.sh | KEEP-cross-file | Asserts the four audit skills reference the single extracted `_audit-conventions.md` (dedup consistency). |
| test_blocking_criteria.sh | CONVERT | Doctrine-critical (strict blocking behaviour), pins sentence fragments. |
| test_code_review_public_exposure.sh | KEEP-structural | Token/anchor presence (skill path, review targets, `BLOCKING`); not sentence prose. |
| test_code_review_trace_evidence.sh | KEEP-structural | Already section-scoped (`Trace / Process Evidence`) + closed vocabulary; structural. |
| test_copilot_spike_doc_measured_v1_0_70.sh | DELETE | Version-pinned snapshot of a spike doc paragraph; no parser, no consumer. |
| test_create_pr_conventions.sh | KEEP-structural | Token presence of repo scripts/commit style + anti-regression guards; not prose. |
| test_devcontainer_optional.sh | DELETE | Phrase-pinning a devcontainer stance; no parser/consumer. |
| test_docs_harness_economics.sh | KEEP-cross-file | Section-scoped: HARNESS.md must document the finish-issue economics block/span (doc vs script behaviour). |
| test_docs_health_check_superseded.sh | DELETE | Doc-snapshot pin of a superseded historical file's prose. |
| test_docs_installer_assets_sync.sh | KEEP-cross-file | Doc vs `install-harness.sh HARNESS_ASSETS` (authority) consistency. |
| test_docs_smoke_coverage_sync.sh | KEEP-cross-file | Doc vs `harness-smoke.yml` (authority) consistency. |
| test_failure_review_template.sh | DELETE | Doc-template snapshot (columns/sections prose); no parser/consumer. |
| test_finish_lib_extracted.sh | KEEP-structural | Extraction/dedup sensor (finish-issue helpers single-homed). |
| test_impl_usefulness_grading.sh | CONVERT | Doctrine-critical (usefulness ≠ severity), pins sentence fragments. |
| test_imported_skills_repo_scoped.sh | KEEP-structural | Frontmatter + token guards against re-importing generic originals; not prose. |
| test_instructions_no_stale_repetition.sh | DELETE | Phrase-pinning residue-absence; no parser/consumer. |
| test_instructions_product_generic.sh | DELETE | Phrase-pinning extraction-residue absence; no parser/consumer. |
| test_l0_ci_gate.sh | KEEP-structural | Runs the L0 driver and asserts blocking exit behaviour. |
| test_l0_sensors_tap.sh | KEEP-structural | Asserts per-scenario TAP emission behaviour. |
| test_lifecycle_trap_no_inline_copy.sh | KEEP-structural | Drift sensor: forbids re-inlining the single-homed lifecycle trap. |
| test_log_schema_single_source.sh | KEEP-cross-file | log-schema authority vs its consumers (key coverage). |
| test_no_antiderailment_scaffolding.sh | DELETE | Phrase-pinning absence of old scaffolding; no parser/consumer. |
| test_no_deleted_export_refs.sh | KEEP-structural | Machine guard: no test references deleted export scripts (#272). |
| test_planner_web_fallback.sh | DELETE | Phrase-pinning per-depth prose; no parser/consumer. |
| test_product_quality_rubric.sh | KEEP-structural | Vocabulary/anchor presence of the rubric's blocking gates + scorecard dimensions (already structural). |
| test_public_exposure_audit_skill.sh | KEEP-structural | Section/vocabulary presence of the exposure-audit skill workflow. |
| test_reconcile_lib_extracted.sh | KEEP-structural | Extraction/dedup sensor (reconcile skeleton single-homed). |
| test_review_execute_before_critical.sh | KEEP-structural | Token/anchor presence of the #265 execute-before-CRITICAL rule. |
| test_review_known_false_positives.sh | KEEP-structural | Asserts the FP registry file exists/seeded (machine artifact). |
| test_review_registry_feedback_loop.sh | KEEP-structural | Token/anchor presence of the #265 feedback-loop rule. |
| test_revision_loops.sh | CONVERT | Doctrine-critical (Loop 1/Loop 2), pins sentence fragments. |
| test_role_separation.sh | CONVERT | Doctrine-critical (non-delegable role separation), pins sentence fragments. |
| test_routing_map_drift.sh | KEEP-cross-file | Routing map vs language-instruction files on disk. |
| test_scripts_language_policy_doc.sh | DELETE | Doc-snapshot of the scripts language-policy page; already trimmed in #272. |
| test_skill_references_resolve.sh | KEEP-structural | Machine check: skill references resolve on disk. |
| test_subagent_handback_payload.sh | KEEP-structural | Pins the machine-parsed handback payload line. |
| test_subagent_profile_instructions.sh | KEEP-cross-file | Routing map single-source vs agent prompts. |
| test_subagent_prompt_dedup.sh | KEEP-structural | Structural dedup (heading absence, line budget, phrase-count ≤ 1). |
| test_tap_helper.sh | KEEP-structural | Behaviour test of the TAP helper library. |
| test_teeth_proof_doctrine.sh | KEEP-structural | Pins the closed teeth_proof kind-set + evaluator binding (#263). |
| test_trace_action_log_consistency.sh | RETIRE (issue #332) | Behaviour test of the retired log_without_span / span_without_log reconciliation; deleted with that check. |
| test_trace_schema_key_coverage.sh | KEEP-structural | Schema vocabulary authority vs trace-lib output. |
| test_trace_schema_single_source.sh | KEEP-structural | Byte-for-byte schema-enum single-source drift sensor. |

## `tests/scripts/` doc-grep siblings named for DELETE

| File | Verdict | Justification |
| --- | --- | --- |
| test_trace_scorecard_docs.sh | DELETE | Doc-prose pin of the scorecard contract page; no parser/consumer. |
| test_claude_adapter_docs.sh | DELETE | Doc-prose pin of the Claude adapter template guide. |
| test_copilot_adapter_docs.sh | DELETE | Doc-prose pin of the Copilot adapter guide. |
| test_ci_coverage_docs.sh | DELETE | Doc-prose pin of the CI-coverage operator doc. |
| test_docs_profile_boundaries.sh | DELETE | Doc-prose pin of the harness-layers distinction. |

Other `tests/scripts/*_docs.sh` doc tests are **out of scope** — the issue
names only these five siblings, and its "Out of scope" section excludes
behaviour tests for living components.

## Net effect

- **DELETE**: 10 `tests/meta` files (646 lines) + 5 `tests/scripts` doc-grep
  siblings.
- **CONVERT**: 5 `tests/meta` files (497 lines) shrunk to structure-level
  assertions.
- **KEEP**: the remaining 32 `tests/meta` files (structural / cross-file /
  behavioural).
- New harness-behaviour sensors for this issue live under `tests/scripts/`
  (not `tests/meta`) so the meta line count stays honest.
