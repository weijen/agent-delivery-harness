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
| `feat!:` / `BREAKING CHANGE:` | major |

## The 1.0.0 policy — a manual decision

Promotion from `0.x` to **1.0.0 is a deliberate human decision, not a mechanical
bump.** Under SemVer, `1.0.0` is a stability promise about the harness's public
surface (its lifecycle scripts, sensor contract, and profile interface), so it is
cut on purpose — the planned trigger is the skill-eval milestone — never as an
accidental side effect of a `BREAKING CHANGE` footer slipping into a routine commit.

Until that decision is made, keep breaking changes on the `0.x` track (they bump the
minor while `0.x`). When the maintainer decides the surface is stable, cut `1.0.0`
manually, for example:

```sh
# From a checkout of main, with python-semantic-release available:
semantic-release version --major
```

or by landing a commit that carries an explicit `BREAKING CHANGE:` footer once the
maintainer has agreed it is time. Out of scope for automation: PyPI publishing and
backfilling historical tags.

## Operational notes

- **Branch protection.** `release.yml` pushes the `chore(release): X.Y.Z` commit and
  the tag with the default `GITHUB_TOKEN`. This works only while `main` accepts direct
  pushes from Actions. If you later protect `main` with "require a pull request" or
  "require status checks", that push is rejected and the release step fails with no tag
  or Release — wire in a PAT / GitHub App token with bypass and pass it to both
  `actions/checkout` and the PSR action. (A `GITHUB_TOKEN` push does **not** retrigger
  workflows, which is what stops `release.yml` from looping on its own release commit.)
- **`uv.lock`.** The virtual-root package version pinned in `uv.lock` is **not** on the
  release path — PSR only rewrites `pyproject.toml` + `VERSION`. After a release it lags
  by one version until the next unlocked `uv sync`; this is harmless because
  `[tool.uv].package = false` (nothing is built from the pin) and both CI workflows run
  plain `uv sync --all-groups`, which self-heals it.
