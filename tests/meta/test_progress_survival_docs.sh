#!/usr/bin/env bash
# Regression sensor: Local Tracking progress.md survival doctrine (issue #290,
# docs-progress-md-survives-teardown).
#
# `.copilot-tracking/issues/issue-NN/progress.md` is authoritative in the
# WORKTREE while an issue is open. `git worktree remove` deletes the worktree,
# so `finish-issue.sh` must migrate that file to the MAIN checkout root before
# the delivery-economics stamp and teardown run — otherwise the flagship
# Action Log is destroyed instead of surviving for the post-hoc consistency
# audit. docs/HARNESS.md's Local Tracking section must state this contract,
# and must tie it to the SAME survival rationale already documented for
# trace.jsonl (issue #285) rather than inventing an unrelated one.
#
# This is deliberately structural, not phrase-pinning: it anchors the
# '## Local Tracking' heading, bounds extraction to the next '## ' heading, and
# asserts a closed vocabulary of concepts/relationships rather than any exact
# sentence. Relationship checks (authoritative worktree copy, migrate-before-
# economics, migrate-before-teardown, trace.jsonl-shared-rationale) run
# against a normalized single-line stream of the section so a mid-sentence
# hard-wrap in docs/HARNESS.md cannot false-negative a claim that is actually
# present. The two ordering claims (before the economics stamp; before
# teardown/worktree removal) are proven by INDEPENDENT guards, not a single
# any-of-economics-or-teardown regex — a doc proving only one ordering must
# not pass on the other's coincidental match. It also cross-checks that
# scripts/finish-lib.sh and scripts/finish-issue.sh actually EXPOSE the
# migration function/stage the docs would be describing, so the doc claim
# cannot describe a behavior that does not exist in production. The production
# cross-check verifies the COMPOSED contract: (1) finish-lib.sh defines
# best_effort_progress_migrate() and finish_closeout_orchestrate(); (2) within
# the bounded orchestrator body, the progress_migrate stage precedes the
# economics_stamp stage numerically; (3) finish-issue.sh delegates to the
# orchestrator before its own TRACE_STAGE="worktree_remove" line — proving
# migrate < economics (in the orchestrator) < teardown (post-orchestrator in
# the entrypoint). This composed proof survives behavior-preserving extractions
# that move logic from the entrypoint into a library function.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { echo "✗ $*"; fail=1; }
ok() { echo "· $*"; }

harness_doc="docs/HARNESS.md"
finish_lib="scripts/finish-lib.sh"
finish_issue="scripts/finish-issue.sh"

[ -f "$harness_doc" ] || note "missing $harness_doc"
[ -f "$finish_lib" ] || note "missing $finish_lib"
[ -f "$finish_issue" ] || note "missing $finish_issue"

if [ -f "$harness_doc" ]; then
	# Anchor the section and bound extraction to the next top-level heading —
	# never grep the whole doc, or drift elsewhere in the file could produce a
	# false GREEN unrelated to the Local Tracking contract.
	local_tracking="$(sed -n '/^## Local Tracking/,/^## /p' "$harness_doc")"
	[ -n "$local_tracking" ] || note "$harness_doc must retain a '## Local Tracking' section"

	# Relationship regexes below must not be line-wrap-sensitive: prose in
	# docs/HARNESS.md is hard-wrapped at ~120 cols, so two clauses that read as
	# ONE claim to a human can land on different physical lines. grep matches
	# per line by default, so a `.{0,N}` span that straddles a wrap would
	# false-negative even though the doc still states the relationship.
	# Collapse the bounded section to a single whitespace-separated stream
	# (portable tr/awk, no GNU-only flags) before running any relationship
	# check. The heading-bound extraction above and the closed-vocabulary
	# checks below still operate on the un-collapsed section/line-based grep.
	local_tracking_flat="$(printf '%s\n' "$local_tracking" | tr '\n' ' ' | awk '{$1=$1; print}')"

	if [ -n "$local_tracking" ]; then
		# Closed vocabulary: each concept in the survival contract must be
		# present. Absence of ANY one of these means the contract is not
		# documented, regardless of exact wording used for the rest.
		if ! printf '%s\n' "$local_tracking" | grep -qi 'progress\.md'; then
			note "$harness_doc Local Tracking section must name progress.md"
		fi
		if ! printf '%s\n' "$local_tracking" | grep -qi 'worktree'; then
			note "$harness_doc Local Tracking section must state progress.md's worktree-relative authority"
		fi
		# Independent guard: mentioning "worktree" alone (e.g. in an unrelated
		# teardown clause) is not the same claim as the worktree copy being
		# authoritative/the source of truth. Require the relationship, not
		# just co-occurrence of the two words anywhere in the section.
		if ! printf '%s\n' "$local_tracking_flat" |
			grep -Eqi 'worktree.{0,80}progress\.md.{0,80}(authoritative|source of truth)|(authoritative|source of truth).{0,80}(worktree.{0,80}progress\.md|progress\.md.{0,80}worktree)'; then
			note "$harness_doc Local Tracking section must identify the worktree copy of progress.md as authoritative/the source of truth, not just mention 'worktree' in passing"
		fi
		if ! printf '%s\n' "$local_tracking" | grep -Eqi 'main (root|checkout)'; then
			note "$harness_doc Local Tracking section must name the main root/main checkout as the migration destination"
		fi
		if ! printf '%s\n' "$local_tracking" | grep -Eqi 'migrat|copie[sd]|copy(ing)?'; then
			note "$harness_doc Local Tracking section must describe migrating/copying progress.md to the main root"
		fi
		if ! printf '%s\n' "$local_tracking" | grep -Eqi 'closeout|teardown'; then
			note "$harness_doc Local Tracking section must tie the migration to closeout/teardown timing"
		fi
		if ! printf '%s\n' "$local_tracking" | grep -Eqi 'surviv|post-hoc|consisten'; then
			note "$harness_doc Local Tracking section must state the survive-for-post-hoc-consistency-audit rationale"
		fi
		if ! printf '%s\n' "$local_tracking" | grep -q 'trace\.jsonl'; then
			note "$harness_doc Local Tracking section must cross-reference trace.jsonl's survival rationale"
		fi

		# Relationship, not just co-occurrence: 'migrate' and 'before ...
		# economics stamp' must sit close enough together to be describing ONE
		# ordering claim (migration happens BEFORE the economics stamp), not
		# two unrelated mentions anywhere in the section. Checked
		# independently of the teardown-ordering guard below — a doc that
		# proves only one of the two orderings must not pass on the other's
		# coincidental match.
		# `[^,.;]{0,N}` (rather than `.{0,N}`) after 'before'/'after'/'once' is
		# deliberate: it requires 'before' to actually GOVERN the keyword
		# clause with nothing else in between, not merely appear somewhere
		# earlier in the same multi-clause sentence. A sentence like "migrate
		# before X, and separately do Y at teardown" must NOT satisfy the
		# teardown guard just because 'teardown' sits within N characters of
		# an unrelated 'before' — the comma/period boundary blocks the match.
		if ! printf '%s\n' "$local_tracking_flat" |
			grep -Eqi 'migrat.{0,200}before[^,.;]{0,30}(economics|stamp)|(economics|stamp)[^,.;]{0,80}(after|once)[^,.;]{0,30}migrat'; then
			note "$harness_doc Local Tracking section must state migration happens BEFORE the economics stamp, not just mention both independently"
		fi

		# Independent guard: migration must also be ordered before teardown
		# (worktree removal). This is a distinct ordering claim from the
		# economics-stamp ordering above — a doc could state one without the
		# other — so it is proven by its own check rather than folded into an
		# any-of-economics-or-teardown regex that a doc proving only the
		# economics ordering could satisfy by accident.
		if ! printf '%s\n' "$local_tracking_flat" |
			grep -Eqi 'migrat.{0,200}before[^,.;]{0,30}(teardown|worktree remove)|(teardown|worktree remove)[^,.;]{0,80}(after|once)[^,.;]{0,30}migrat'; then
			note "$harness_doc Local Tracking section must state migration happens BEFORE teardown/worktree removal, not just mention both independently"
		fi

		# Relationship: the trace.jsonl cross-reference must sit next to the
		# survival/rationale language, not be an unrelated stray mention of
		# trace.jsonl elsewhere in the section (e.g. an unrelated table row).
		if ! printf '%s\n' "$local_tracking_flat" |
			grep -Eqi 'trace\.jsonl.{0,200}(surviv|same|mirror|like|rationale)|(surviv|same|mirror|like|rationale).{0,200}trace\.jsonl'; then
			note "$harness_doc Local Tracking section must tie the trace.jsonl reference to the shared survival rationale, not mention it in isolation"
		fi
	fi
fi

# Production must actually expose the migration function/stage the docs would
# be describing — a doc claim describing a nonexistent behavior is worse than
# no doc claim at all. After the behavior-preserving extraction (issue #320),
# the ordering contract is COMPOSED across two files: best_effort_progress_migrate()
# and finish_closeout_orchestrate() are defined in finish-lib.sh; the orchestrator
# body orders progress_migrate before economics_stamp; and finish-issue.sh delegates
# to the orchestrator before its own worktree_remove stage.
if [ -f "$finish_lib" ]; then
	if grep -Eq '^best_effort_progress_migrate[[:space:]]*\(\)' "$finish_lib"; then
		ok "$finish_lib defines best_effort_progress_migrate()"
	else
		note "$finish_lib does not define a best_effort_progress_migrate() function for docs to describe"
	fi
	if grep -Eq '^finish_closeout_orchestrate[[:space:]]*\(\)' "$finish_lib"; then
		ok "$finish_lib defines finish_closeout_orchestrate() orchestrator"
	else
		note "$finish_lib does not define a finish_closeout_orchestrate() orchestrator"
	fi
fi

# Composed ordering part 1: within the bounded finish_closeout_orchestrate body
# in finish-lib.sh, progress_migrate stage precedes action_log_render stage,
# and both precede economics_stamp stage.
# This proves migrate < render < economics without requiring any to live
# directly in the entrypoint.
if [ -f "$finish_lib" ]; then
	orch_start="$(grep -n '^finish_closeout_orchestrate[[:space:]]*()' "$finish_lib" | head -1 | cut -d: -f1 || true)"
	if [ -z "$orch_start" ]; then
		note "$finish_lib: finish_closeout_orchestrate() not found — cannot check internal ordering"
	else
		# Bound body to the next top-level function definition at col-0, or EOF.
		orch_end="$(awk -v s="$orch_start" \
			'NR > s && /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)/ { print NR; exit }' "$finish_lib")"
		[ -z "$orch_end" ] && orch_end="$(wc -l < "$finish_lib")"

		migrate_stage_in_orch="$(awk -v s="$orch_start" -v e="$orch_end" \
			'NR >= s && NR <= e && /TRACE_STAGE="progress_migrate"/ { print NR; exit }' "$finish_lib")"
		migrate_call_in_orch="$(awk -v s="$orch_start" -v e="$orch_end" \
			'NR >= s && NR <= e && /^[[:space:]]*best_effort_progress_migrate[[:space:]]*$/ { print NR; exit }' "$finish_lib")"
		render_stage_in_orch="$(awk -v s="$orch_start" -v e="$orch_end" \
			'NR >= s && NR <= e && /TRACE_STAGE="action_log_render"/ { print NR; exit }' "$finish_lib")"
		economics_stage_in_orch="$(awk -v s="$orch_start" -v e="$orch_end" \
			'NR >= s && NR <= e && /TRACE_STAGE="economics_stamp"/ { print NR; exit }' "$finish_lib")"

		if [ -z "$migrate_stage_in_orch" ] || [ -z "$migrate_call_in_orch" ] || \
		   [ -z "$render_stage_in_orch" ] || [ -z "$economics_stage_in_orch" ]; then
			note "$finish_lib finish_closeout_orchestrate() body must contain TRACE_STAGE=\"progress_migrate\", a best_effort_progress_migrate call, TRACE_STAGE=\"action_log_render\", and TRACE_STAGE=\"economics_stamp\" — one or more missing"
		elif [ "$migrate_stage_in_orch" -ge "$render_stage_in_orch" ]; then
			note "$finish_lib finish_closeout_orchestrate(): progress_migrate stage (line $migrate_stage_in_orch) must precede action_log_render stage (line $render_stage_in_orch)"
		elif [ "$render_stage_in_orch" -ge "$economics_stage_in_orch" ]; then
			note "$finish_lib finish_closeout_orchestrate(): action_log_render stage (line $render_stage_in_orch) must precede economics_stamp stage (line $economics_stage_in_orch)"
		else
			ok "$finish_lib finish_closeout_orchestrate() orders progress_migrate (line $migrate_stage_in_orch) before action_log_render (line $render_stage_in_orch) before economics_stamp (line $economics_stage_in_orch)"
		fi
	fi
fi

# Composed ordering part 2: finish-issue.sh delegates to finish_closeout_orchestrate
# BEFORE its own TRACE_STAGE="worktree_remove". Combined with part 1, this proves
# the full chain: migrate < economics (in orchestrator) < teardown (in entrypoint).
if [ -f "$finish_issue" ]; then
	# Match the delegation call — exclude the no-op fallback definition (has '()')
	# and comment lines, leaving only the actual invocation site(s).
	orch_call_line="$(grep -n 'finish_closeout_orchestrate' "$finish_issue" \
		| grep -v '()' | head -1 | cut -d: -f1 || true)"
	worktree_remove_stage_line="$(grep -n '^TRACE_STAGE="worktree_remove"$' "$finish_issue" | head -1 | cut -d: -f1 || true)"

	if [ -z "$orch_call_line" ]; then
		note "$finish_issue must delegate to finish_closeout_orchestrate() before teardown (not call best_effort_progress_migrate directly)"
	elif [ -z "$worktree_remove_stage_line" ]; then
		note "$finish_issue must set TRACE_STAGE=\"worktree_remove\" so the composed ordering can be verified"
	elif [ "$orch_call_line" -ge "$worktree_remove_stage_line" ]; then
		note "$finish_issue: finish_closeout_orchestrate delegation (line $orch_call_line) must precede TRACE_STAGE=\"worktree_remove\" (line $worktree_remove_stage_line) — found out of order"
	else
		ok "$finish_issue delegates to finish_closeout_orchestrate (line $orch_call_line) before worktree_remove stage (line $worktree_remove_stage_line)"
		ok "Composed order proven: migrate < economics (finish-lib.sh orchestrator) < teardown (finish-issue.sh post-orchestrator)"
	fi
fi

# Adversarial proof: the structural ordering checks have teeth.
# Verify that synthetic bad content (delegation moved after teardown) is
# correctly detected as an error by the same line-number logic used above.
_adv_fail=0
_adv_bad_order="$(printf 'TRACE_STAGE="worktree_remove"\nif ! finish_closeout_orchestrate; then exit 1; fi\n')"
_adv_orch_line="$(printf '%s\n' "$_adv_bad_order" | grep -n 'finish_closeout_orchestrate' | grep -v '()' | head -1 | cut -d: -f1 || true)"
_adv_wt_line="$(printf '%s\n' "$_adv_bad_order" | grep -n 'TRACE_STAGE="worktree_remove"' | head -1 | cut -d: -f1)"
# In the mutated content: orch=2, wt=1 → orch >= wt → ordering check detects it.
if [ -n "$_adv_orch_line" ] && [ -n "$_adv_wt_line" ] && [ "$_adv_orch_line" -ge "$_adv_wt_line" ]; then
	ok "adversarial proof: out-of-order delegation (orchestrate after worktree_remove) correctly detected by line-number check"
else
	note "adversarial proof FAILED: ordering check did not detect reordered delegation in synthetic content"
	_adv_fail=1
fi
# Also verify: absent delegation produces empty orch line (would trigger the
# 'must delegate' guard above — confirm the pattern is specific enough).
_adv_no_deleg="$(printf 'TRACE_STAGE="worktree_remove"\n')"
_adv_no_orch_line="$(printf '%s\n' "$_adv_no_deleg" | grep -n 'finish_closeout_orchestrate' | grep -v '()' | head -1 | cut -d: -f1 || true)"
if [ -z "$_adv_no_orch_line" ]; then
	ok "adversarial proof: absent delegation correctly produces empty match (would trigger must-delegate guard)"
else
	note "adversarial proof FAILED: absent delegation was spuriously matched — pattern too loose"
	_adv_fail=1
fi

echo
if [ "$fail" -ne 0 ]; then
	echo "FAIL: progress.md survival documentation contract incomplete (RED)"
	exit 1
fi
echo "progress.md survival documentation contract honored"
