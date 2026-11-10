---
description: 'Task routing for questions, maintenance and issue delivery; read when choosing a workflow.'
---

# Workflow Routing

Choose by the requested outcome, not file count or keywords.

| Task | Path |
| --- | --- |
| Question, explanation or read-only review | Answer directly; no issue, plan, worktree or implementation pipeline |
| Issue delivery in a harness-enabled project | Read [the canonical lifecycle](harness.instructions.md); it owns all delivery gates and proportionality |
| Explicit maintenance audit | Read the requested skill and respect its edit/report policy; an audit does not authorise publication or unrelated fixes |
| Other work in a project without an issue lifecycle | Follow the project's own instructions and the defaults below |

## Defaults outside issue delivery

Use the smallest complete approach. Implement authorised changes directly, with
TDD for behaviour changes and relevant formatting, lint and tests. Stop expanding
verification once the required checks pass unless new failures or uncertainty
justify more. Keep scope, authorisation, signing and publication boundaries intact.

For contained reversible work, an inline approach and targeted checks are enough.
For uncertain cross-component contracts or material trust/data-loss risk, record
the consequential decisions and arrange independent review when required by the
project, risk or user. Ask only for unresolved requirements, consequential choices
or missing authority; continue already-authorised independent work.

When a project requires issues for edits, obtain approval for the issue before
creating it or implementing. A question or read-only review is not an edit request.
Do not introduce a parallel tier system or alternate approval path inside the harness.
