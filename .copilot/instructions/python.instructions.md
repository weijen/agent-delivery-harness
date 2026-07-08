---
description: 'Python best practices for uv-managed projects.'
applyTo: '**/*.py'
---

# Python Best Practices

> This file activates once the first `pyproject.toml` lands. While the repo is docs-only it is
> intentionally inert.

## Project & environment
- This project is managed by **uv**. Never call `pip` directly.
  - Add runtime deps: `uv add <pkg>`
  - Add dev deps: `uv add --dev <pkg>`
  - Run anything inside the env: `uv run <cmd>` (e.g. `uv run pytest`, `uv run python -m ...`)
  - Sync the env: `uv sync`
- Target the Python version declared in `.python-version` and `requires-python`.
- Source lives in the repository's importable package under `src/` (src-layout). Tests live in
  `tests/`.
- **Test layout mirrors the source tree.** A new test file goes under
  `tests/<apps|packages>/<unit>/` mirroring the unit under test (using the
  importable package name, e.g. `tests/apps/orchestrator/`,
  `tests/packages/cu_client/`) — never flat in `tests/` root. Cross-cutting
  fitness tests with no single owner go in `tests/meta/`; root-package tests
  in `tests/src/`. Shared constants and path anchors live in
  `tests/_helpers.py`; no test imports another test module. `conftest.py`
  stays at the `tests/` root.

## Style & structure
- Format and lint with **ruff** (`uv run ruff format` / `uv run ruff check --fix`).
- Keep line length ≤ 100.
- Use **full type hints** on all public functions, methods, and module-level constants.
  Type-check with `uv run mypy` (strict mode is on).
- Prefer small, single-responsibility functions and modules.
- Use `pathlib.Path` over `os.path`; use f-strings over `%`/`.format`.
- Prefer `dataclasses` or `pydantic` models over loose dicts for structured data. **All
  external service response parsing goes through a typed model** matching the canonical project
  schemas.
- Raise specific exceptions; never bare `except:`. Only catch what you can handle.
- No mutable default arguments. Use `None` + initialize inside.

## Imports
- Standard lib → third-party → local, separated by blank lines (ruff `I` rules enforce this).
- Use absolute imports within the package.

## Logging & config
- Use the `logging` module, not `print`, in library code.
- Read secrets/config from environment variables, never hard-code them. Service endpoints, keys,
  deployment/model names, storage locations, and resource identifiers all come from env.

## Quality gates (run before declaring work done)
```sh
uv run ruff format
uv run ruff check --fix
uv run mypy
uv run pytest
```

## YAGNI / DRY
- Build only what is asked. No speculative abstractions.
- Extract a helper only after the third repetition, and only if it doesn't add coupling.
