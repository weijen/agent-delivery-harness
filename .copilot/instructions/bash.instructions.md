---
description: 'Bash conventions for the harness scripts and shell tests.'
applyTo: 'scripts/**/*.sh, tests/**/*.sh'
---

# Bash Conventions (harness scripts & shell tests)

The harness lifecycle is implemented in Bash under `scripts/`, with regression
sensors under `tests/scripts/`. These conventions keep those scripts safe,
portable, and behaviorally testable. They are project-specific — not a general
Bash tutorial. When project-specific guidance is silent, fall back to the
harness contract and the AGENTS.md conventions.

## Style & safety

- Start every script with `#!/usr/bin/env bash` and `set -euo pipefail`. Never
  weaken strict mode to dodge an error — fix the cause.
- **Quote every expansion**: `"$var"`, `"${arr[@]}"`, `"$(cmd)"`. Unquoted
  expansions are bugs, not shortcuts.
- Use **arrays** for argument lists; never build commands by string-splitting.
  Expand optional arrays safely: `${args[@]+"${args[@]}"}`.
- Declare function-local state with `local`. Don't leak loop/temp variables into
  global scope.
- Prefer Bash builtins and POSIX tools that exist on both macOS and Linux. Avoid
  GNU-only flags (e.g. `sed -i` without a backup arg differs across platforms);
  when in doubt, read into a variable and rewrite the file.
- Canonicalize paths before comparing them (`(cd "$p" && pwd -P)`); a linked
  worktree can report a physical path where the main checkout reports a logical
  one (macOS `/var` → `/private/var`).

## Temp files, traps & cleanup

- Create scratch space with `mktemp -d` and remove it on exit:
  `trap 'rm -rf "${TMP_DIR}"' EXIT`. Never hardcode `/tmp/<name>` paths —
  concurrent runs collide and leak.
- Keep all of a test's artifacts under its own `${TMP_DIR}`; nothing should
  escape the temp dir the trap cleans.

## Non-interactive usage

- Scripts run unattended. Pass explicit flags; never rely on prompts. Use
  `gh ... --json`/`-q`, `git ... --no-pager`, and provide `--body-file` rather
  than heredocs when a body contains backticks or `${...}` (heredocs trigger
  shell substitution and "bad substitution" failures).
- Read configuration and secrets from the environment — never hardcode them, and
  never call privileged provider APIs with privileged credentials from a script.

## Exit semantics: hard-fail vs warning

- A **hard** failure (a violated precondition) prints to stderr and exits
  non-zero (e.g. preflight auth missing, a failed quality gate). A **warning** is
  advisory: print the note and continue with exit 0 (e.g. commit signing off, an
  optional surface tool absent). Keep the two paths distinct and intentional;
  match the `kind: hard|warn` declarations in `docs/harness-contract.yml`.

## Harness script tests (`tests/scripts/test_*.sh`)

- Tests are discovered by the `tests/scripts/test_*.sh` glob — there is **no
  aggregator or runner**. Each test is a standalone `set -euo pipefail` script
  with `fail()`/`note()` helpers.
- Build a throwaway repo per test with `mktemp -d` + `git init`; never touch the
  developer's real checkout or network.
- **Fake every external CLI.** Provide fake `gh`/tool binaries on an isolated
  `PATH` (symlink the real coreutils/git/jq you need, drop in fakes for the
  rest) so results never depend on the developer's login or ambient toolchain.
- Keep tests **deterministic and isolated**: pin `PATH`, set `git config
  user.name/email` in the temp repo, and don't depend on ordering between tests.
- Assert **behavior**, not byte-for-byte snapshots. Prove an ordering or
  contract by observing side effects (a worktree that does/doesn't exist, a
  branch that was/wasn't pushed), and **mutation-test** each guard: confirm the
  test fails when the guarded behavior is removed.
- When committing inside a temp repo without a working `git commit`, use the
  `git write-tree` + `git commit-tree` + `git update-ref` pattern.

## Meta-test rubric (`tests/meta/test_*.sh`)

`tests/meta/` guards the harness's own docs, agents, skills, and schemas.
A meta-test earns its keep only if it does one of these — this is the
**deletion criterion**, and new meta-tests must be born structural:

- **KEEP — machine-parsed structure**: validates a format a script actually
  parses (handback payload line, TAP rows, agent/skill frontmatter, schema
  single-source/key-coverage, L0 gate driver behaviour, the teeth_proof
  kind-set).
- **KEEP — cross-file consistency**: asserts two artifacts agree (a routing map
  vs the language files on disk, a doc vs the script/workflow that is its
  authority). Cheap, and it catches drift a human review misses.
- **CONVERT — doctrine-critical prose**: guards core doctrine but pins it with
  sentence-level greps. Rewrite to assert the guarded **section/anchor exists**
  (a `^#` heading pattern) and its **closed vocabulary** is present; wording
  inside the section becomes free to edit. Mutating a guarded section title
  still fails the test; rewording a sentence does not.
- **DELETE — phrase-pinning with no parser and no consumer**: greps prose no
  script parses. Its failure mode is "someone rephrased a sentence", not
  "someone broke behaviour". Doc drift is caught by the `sync-docs` review
  skill and the fresh-context reviewer — never by these.

The point-in-time triage that applied this rubric lives at
[`docs/evaluation/meta-test-triage.md`](../../docs/evaluation/meta-test-triage.md).

## Validation before declaring work done

- `bash -n scripts/*.sh` — syntax check (CI runs this).
- `shellcheck scripts/*.sh tests/scripts/*.sh` — lint; touched shell must be
  shellcheck-clean. Suppress a finding only with a justified, scoped directive
  (e.g. `# shellcheck source=/dev/null` for a dynamically sourced file).
- Run the **targeted** `tests/scripts/test_*.sh` covering the behavior you
  touched, then the full suite before closeout. Confirm `git diff --quiet
  scripts/` when a change should be tests-only.
