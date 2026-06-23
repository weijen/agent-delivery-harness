---
name: public-exposure-audit
description: 'Public repository exposure audit. Find private or identifying material accidentally exposed in a public repo — personal identifiers, company/internal references, vendor/account/resource identifiers, local paths, emails, secrets, tokens, cloud IDs, subscription/tenant IDs, URLs/endpoints — across tracked files, reachable Git history, Git metadata (author/committer email), and ignored/untracked local files. Use before making a repo public, or for pre-commit/pre-PR hygiene on an already-public repo.'
argument-hint: 'scope (paths), remote/push status, branches to sweep, risk tolerance, optional already-installed scanners'
---

# Public Repository Exposure Audit

## Goal

Find private, confidential, or personally identifying material that is exposed — or about to be
exposed — in a public repository, and report each finding with enough context for a human to decide
what to do. The audit covers what is committed (tracked files), what is reachable in history (all
branches and commits), what Git itself records (author/committer name and email, tags, notes), and
what sits locally as ignored or untracked files that could be staged by accident later.

This skill is an audit workflow. It gathers evidence, classifies real exposure versus intentional
public content, assigns severity, and recommends remediation. Identifier hits are clues, not
verdicts.

## When to Use

Use this skill when the user asks to:

- Audit a repository before flipping it from private to public.
- Run pre-commit or pre-PR hygiene on a public repo before pushing.
- Review docs, prompts, skills, agents, workflows, fixtures, logs, or generated artifacts for leaked
  private material.
- Check whether customer-supplied material (raw media, screenshots, decks, exports) or environment
  files have crept into tracked or soon-to-be-pushed content.
- Assess residual risk from material that is already pushed to a public remote.

## Core Principle

Search broadly, judge narrowly. A pattern match (an email address, a long hex string, a path) is a
clue, not a finding. A good audit distinguishes real exposure of private material from intentional
public content. Classify the following as **Accept** (not exposure) unless they reveal genuinely
private account details:

- Intentional public documentation — vendor/product names and public URLs the project deliberately
  documents.
- Synthetic fixtures and test data created specifically to be committed.
- Invalid / reserved example emails and domains (`@example.com`, `@example.org`, RFC 2606 reserved
  domains) and obviously fake sample addresses.
- Placeholder environment variable names (`AZURE_TENANT_ID=<your-tenant-id>`, `${API_KEY}`) where no
  real value is present.

## Scope of the Sweep

1. **Tracked files** — everything currently committed on the working branch (`git ls-files`).
2. **All branch tips** — every local and remote branch (`git branch -a`), not just the current one.
3. **Reachable Git history** — content reachable from any commit, since published history cannot be
   un-published by deleting a file in a new commit. Use `git log --all`, `git rev-list --all`, and
   `git grep <pattern> $(git rev-list --all)` to sweep historical blobs.
4. **Git metadata** — author and committer name + email on every commit
   (`git log --all --format='%an <%ae> | %cn <%ce>'`), plus tags and notes. A personal email baked
   into authorship is metadata, not file content.
5. **Ignored files** — local files Git is told to ignore (`git status --ignored`). They are not
   exposed yet, but a future `git add -A` or a loosened `.gitignore` could expose them.
6. **Untracked files** — local files not yet added, which could be staged by accident later.

## Procedure

1. **Define scope and remote/push status.** Establish which remotes exist and whether they are public
   (`git remote -v`, `git branch -r`). For each candidate finding, determine whether it is **already
   pushed** to a public remote or only **soon-to-be-pushed** (local). This drives both severity and
   remediation.
2. **Scan tracked content by category.** Sweep tracked files for each identifier category below using
   built-in `git grep`/`grep`. Treat hits as candidates, then classify.
3. **Scan reachable history.** Repeat the category sweep across `git rev-list --all` so a secret that
   was committed and later deleted is still found.
4. **Scan Git metadata.** Extract author/committer emails and names; flag personal or
   company-internal addresses that the contributor did not intend to publish.
5. **Scan ignored and untracked local files.** List them and check for env files, exports, raw media,
   and credentials that could be staged later.
6. **Classify each hit** as Exposure or Accept using the Classification table.
7. **Assign severity** using the severity ladder.
8. **Determine remediation** and, for anything already pushed, **assess residual risk**.

### Identifier categories to sweep

- **Personal identifiers** — real names, personal emails, phone numbers, home/local paths
  (`/Users/<name>`, `/home/<name>`, `C:\Users\<name>`).
- **Company / internal references** — internal hostnames, project codenames, internal ticket IDs,
  org-private domains.
- **Vendor / account / resource identifiers** — account numbers, resource group names, storage
  account names, private resource identifiers.
- **Local paths** — absolute developer machine paths that leak usernames or directory layout.
- **Secrets and tokens** — API keys, access tokens, connection strings, private keys, passwords.
- **Cloud identifiers** — subscription IDs, tenant IDs, project IDs, and private resource endpoints.
- **URLs / endpoints** — private or pre-production endpoints that should not be publicly known.

### Built-in Checks

Prefer built-in `git`/`grep` checks — no third-party tool is required:

```sh
# Tracked + history content sweep (adjust the pattern per category)
git grep -nIE '<pattern>' -- . || true
git grep -nIE '<pattern>' $(git rev-list --all) || true

# Author / committer metadata
git log --all --format='%an <%ae> | %cn <%ce>' | sort -u

# Local exposure surface
git status --ignored --porcelain
git ls-files --others --exclude-standard
```

Dedicated scanners (`gitleaks`, `trufflehog`, `detect-secrets`) are **optional**: if one is already
installed in the environment, run it as an extra signal, but never require installing one — this skill
must work with built-in Git and grep alone.

## Classification

| Pattern observed | Verdict | Why |
|---|---|---|
| Live secret / token / private key / connection string | **Exposure** | Real credential, actionable by anyone |
| Customer-supplied raw media, screenshots, decks, exports | **Exposure** | Confidential third-party material |
| Real tenant / subscription ID or private resource endpoint in pushed content | **Exposure** | Reveals private cloud topology |
| Personal email in Git author metadata the contributor did not intend to publish | **Exposure (residual)** | Already-published metadata; report, do not auto-fix |
| Local `.env`, export, or credential as an ignored/untracked file | **Exposure (latent)** | Not pushed yet, but one `git add` from exposure |
| Vendor/product name in intentional public documentation | **Accept** | Deliberately published |
| Synthetic fixture / committed test data | **Accept** | Created to be public |
| `@example.com` / RFC 2606 reserved or invalid example email | **Accept** | Not a real address |
| Placeholder env var name with no real value | **Accept** | Documents a variable, exposes nothing |

## Severity ladder

- **Critical** — live secret/token/private credential, customer-supplied raw media/exports/decks/
  screenshots, or real tenant/subscription IDs or private resource endpoints in already-pushed
  content.
- **High** — the same classes of material present in soon-to-be-pushed (staged/local-tracked)
  content, or a personal email exposed in pushed Git metadata.
- **Medium** — latent exposure in ignored/untracked local files; private internal references.
- **Low** — borderline identifiers that need human judgement.
- **Accept** — intentional public content, synthetic fixtures, invalid example emails, placeholders.

## Implementation-Usefulness Grading

Grade each finding so a reviewer can act:

- **Fix now** — remove the secret/file, rotate the credential, scrub the soon-to-be-pushed content
  before it lands. Applies to anything not yet pushed.
- **Plan first** — already-pushed exposure that needs a coordinated response (credential rotation,
  access review, and only if the owner chooses, history rewriting — which is out of scope here).
- **Defer / accept** — classified as Accept, or residual risk the owner knowingly accepts.

## Report Template

Produce a findings report:

```
## Public exposure audit — <repo> (<remote: public/private>)

### Findings
| # | Severity | Category | Evidence (file:line / commit) | Pushed? | Remediation |
|---|----------|----------|-------------------------------|---------|-------------|
| 1 | Critical | Secret   | config.json:12                | yes     | Rotate key; remove from history |

### Residual risk (already-published history)
- Author email `<name>@personal.example` appears in commit metadata across N commits. This is
  **already published** and cannot be unpublished by a normal commit. Report it as residual risk:
  recommend a `.mailmap` and future-commit hygiene, optional coordinated history rewrite (owner
  decision, out of scope for this skill), and credential rotation for anything sensitive. This is
  reportable, not auto-fixable.

### Summary
- Counts by severity, and a clear go / no-go recommendation for making the repo public.
```

## Out of Scope

- Rewriting existing Git history to remove previously published personal metadata.
- Installing or requiring third-party scanners (gitleaks, trufflehog, detect-secrets) as mandatory
  dependencies.
- Changing repository visibility or deleting remote branches.
- Removing intentional public vendor/product references unless they expose private account details.

## Completion Criteria

- Every identifier category and the full sweep scope (tracked, history, metadata, ignored, untracked)
  were checked.
- Each candidate hit is classified Exposure or Accept with a reason.
- Findings carry severity, evidence, remote/push status, and remediation.
- Already-pushed exposure is reported as residual risk with guidance, not silently auto-fixed.
