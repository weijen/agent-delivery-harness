---
name: copilot-log-review
description: 'Report-only review of an agentic workflow reconstructed from GitHub Copilot''s native records (session transcripts and hook logs). Use to review a single issue run, a day''s work, or an L4 batch of runs — surfacing time decomposition, decision points, and workflow-adherence findings. Never edits the repo; emits a Markdown report only.'
argument-hint: 'review window or issue number, workspace/session scope, optional redaction tolerance'
---

# Copilot Log Review

## Purpose

Review how an agentic workflow actually unfolded, reconstructed from GitHub Copilot's own
records — the session transcripts and hook logs it writes locally — rather than from the repo's
committed artifacts. Use it to review a single issue run, a day's worth of work, or an L4 batch,
and to surface where time went, which decisions mattered, and where the run diverged from the
harness workflow.

This skill is **report-only**: it reads Copilot's local records and never edits any file in the
repository. Its Markdown report lands under `logs/audit/<UTC-timestamp>/copilot-log-review.md`.

Later stages of this skill add the Quantify jq recipes and the Locate / Qualify / Report stages;
this skeleton establishes only the report-only contract and output location.
