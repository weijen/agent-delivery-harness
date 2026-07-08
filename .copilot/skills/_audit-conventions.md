# Shared Audit Conventions

This file is the canonical shared convention source for audit skills. It is not a skill: do not add YAML frontmatter, and do not move it into a skill folder.

## Exclusions

Exclude generated files, vendored dependencies, virtual environments, package caches, build output, lockfiles, minified bundles, coverage output, dependency directories, and VCS internals, including `.venv/`, `venv/`, `node_modules/`, `dist/`, `build/`, `target/`, `.terraform/`, `.next/`, `.nuxt/`, `coverage/`, and `.git/`.

## Search broadly, judge narrowly

Search broadly, judge narrowly. Suspicious patterns are clues, not verdicts. A good audit distinguishes harmful shortcuts from intentional compatibility code, tests, documented fallbacks, local development helpers, generated files, operational scripts, and other correct-in-context patterns.

## Implementation-Usefulness Grading

After classifying a finding by severity, grade its remediation priority: **Fix now** (strong evidence, high payoff, contained blast radius), **Plan first** (worthwhile but needs sequencing or has wide blast radius), or **Defer-accept** (low payoff or acceptable as-is). The priority decision never overrides or downgrades the severity classification.

## Report Shape

Use this shared report structure: lead with a Findings table for confirmed actionable findings, follow with Details for each finding, include Accepted Patterns for suspicious hits reviewed and accepted, and add an optional remediation plan only when the user asks for one or the confirmed work is broad enough to require phased tracking.

## Remediation Plans

When the user asks for a remediation plan, follow repository-local planning conventions; include test impact and a verification step per change.
