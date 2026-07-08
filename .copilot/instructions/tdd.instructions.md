---
description: 'Test-Driven Development practices for pytest projects.'
applyTo: '**/*.py'
---

# TDD Best Practices

## The cycle (Red → Green → Refactor)
1. **Red** — write the smallest failing test that expresses the next behavior.
   Run it and confirm it fails *for the right reason* (assertion, not import error).
2. **Green** — write the minimal production code to make the test pass. Nothing more.
3. **Refactor** — clean up code and tests with the suite green. Re-run after each change.

Never write production code without a failing test that requires it.

For **prompt assets, analyzer schemas, and other non-code artifacts**, the TDD equivalent is:
1. Define the expected JSON output as a fixture (the assertion).
2. Run the analyzer / prompt on fixed test input.
3. Diff output against fixture; adjust the prompt or schema until the diff is intended-only.
This is the "snapshot test" pattern — the fixture IS the test.

## Running tests
- Full suite: `uv run pytest`
- Single file: `uv run pytest tests/test_foo.py`
- Single test: `uv run pytest tests/test_foo.py::test_name`
- Watch coverage: coverage is on by default (`--cov` in `pyproject.toml`); aim to keep
  meaningful lines covered, but don't chase 100% for trivial code.

## Test structure & naming
- Tests live in `tests/`, mirroring the importable source package layout under `src/`.
- File names: `test_<module>.py`. Function names: `test_<behavior>_<condition>`.
- Follow **Arrange–Act–Assert**; separate the three with blank lines.
- One logical assertion per test where practical. Test behavior, not implementation details.

## Good test design
- Tests must be **deterministic** and **isolated** — no shared mutable state, no order dependence.
- Use `pytest.fixture` for setup; prefer function-scoped fixtures.
- Use `@pytest.mark.parametrize` for table-driven cases instead of copy-pasting tests.
- Use `tmp_path` / `monkeypatch` fixtures instead of touching the real filesystem or env.
- Mock at the **external-service boundary** (the model/service client, any managed session such
  as a code-interpreter session); never mock our own orchestrator/tool logic. The unit under test
  is the boundary parser + the orchestration step, NOT the network.
- Assert on observable behavior and public API, not private internals.

## What to test
- Happy path, edge cases, and error/exception paths.
- Boundary conditions (empty, one, many; min/max).
- Regression: when a bug is found, first write a failing test that reproduces it.

## Discipline
- Keep tests fast. Mark slow/integration tests (`@pytest.mark.slow`) and keep the default
  run quick.
- A failing test blocks "done". Fix the cause, don't delete or skip the test.
