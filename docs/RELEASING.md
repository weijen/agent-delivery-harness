# Releasing

The harness version is released automatically by
[python-semantic-release](https://python-semantic-release.readthedocs.io/) (PSR).
You do not bump version numbers by hand — the version is **decided at commit time**
by the [Conventional Commits](https://www.conventionalcommits.org/) type on each
change, and cut in CI by [`.github/workflows/release.yml`](../.github/workflows/release.yml)
on every push to `main`.

See [AGENTS.md](../AGENTS.md#commit-message-convention-conventional-commits) for the
required commit format.

## How an automatic release happens

1. A `fix:` or `feat:` (or `BREAKING CHANGE`) commit lands on `main`.
2. `release.yml` runs `semantic-release version`, which:
   - computes the next SemVer from the commits since the last tag,
   - writes `pyproject.toml` `[project].version` (the single source of truth) and
     mirrors it into the root `VERSION` file via `scripts/sync-version.sh`,
   - updates `CHANGELOG.md`, commits, and tags `vX.Y.Z`,
   - creates the matching GitHub Release.
3. Pushes that carry only non-releasing types (`chore:`, `docs:`, `test:`,
   `refactor:`, `ci:`, `build:`, `style:`) are a **no-op** — no bump, tag, or release.

| Commit type | Bump |
|---|---|
| `fix:` | patch |
| `feat:` | minor |
| `feat!:` / `BREAKING CHANGE:` | minor on `0.x`; major after `1.0.0` |

## The 1.0.0 policy — a manual decision

Promotion from `0.x` to **1.0.0 is a deliberate human decision, not a mechanical
bump.** Under SemVer, `1.0.0` is a stability promise about the harness's public
surface (its lifecycle scripts, sensor contract, and profile interface), so it is
cut on purpose — the planned trigger is the skill-eval milestone — never as an
accidental side effect of a `BREAKING CHANGE` footer slipping into a routine commit.

The configuration in `pyproject.toml` sets `allow_zero_version=true` and
`major_on_zero=false`: breaking changes bump the minor while on `0.x`.
A `BREAKING CHANGE:` footer does not override that policy. When the maintainer
decides the surface is stable, cut `1.0.0`
manually, for example:

```sh
# From a checkout of main, with python-semantic-release available:
semantic-release version --major
```

This explicit major override requires the maintainer's approval. Out of scope
for automation: PyPI publishing and backfilling historical tags.

## Lock integrity

[`scripts/sync-version.sh`](../scripts/sync-version.sh) mirrors the bumped
project version into `VERSION`. When `uv.lock` exists and `uv` is available,
it also runs `uv lock`; both files are PSR release assets. If `uv` is absent
(notably inside the PSR Docker action), it warns that the lock was not refreshed.

The post-release safety net in
[`release.yml`](../.github/workflows/release.yml) runs only when a release was
made. It pulls the released branch, checks `uv lock --check`, and refreshes and
commits `uv.lock` only if necessary. That follow-up commit may therefore appear
after the release tag; it is not another version bump.

[`python-ci.yml`](../.github/workflows/python-ci.yml) enforces
`uv lock --check` without repairing the lock. Its pinned `uv` version matches
the release safety net. A stale lock blocks PR validation: fix the release
refresh or commit a lock refresh with that same tool version, rather than
relying on an unlocked environment sync to hide the inconsistency.

## Operational notes

- **Branch protection.** `release.yml` pushes the `chore(release): X.Y.Z` commit and
  the tag with the default `GITHUB_TOKEN`. This works only while `main` accepts direct
  pushes from Actions. If you later protect `main` with "require a pull request" or
  "require status checks", that push is rejected and the release step fails with no tag
  or Release — wire in a PAT / GitHub App token with bypass and pass it to both
  `actions/checkout` and the PSR action. (A `GITHUB_TOKEN` push does **not** retrigger
  workflows, which is what stops `release.yml` from looping on its own release commit.)
