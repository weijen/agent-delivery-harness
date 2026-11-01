"""Opt-in minimum-path experiments (#541/#543), never a routine CI gate."""

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "tests/evals/fixtures/skills/minimum-path"
BASELINE = "7009f8048b938a4b14f72fdc3c045a62a15844a8"
MODEL = "gpt-6-astra"
GUIDES = [
    "AGENTS.md",
    ".copilot/instructions/harness.instructions.md",
    ".copilot/instructions/workflow-tiers.instructions.md",
    ".copilot/agents/code-review-subagent.agent.md",
    "docs/product-quality-rubric.md",
]


@dataclass
class Run:
    directory: Path
    work: Path
    prompt: str
    files: dict[str, str]
    record: dict[str, object]
    process: subprocess.Popen[bytes] | None = None
    stdout: TextIO | None = None
    stderr: TextIO | None = None
    start: float = 0
    last_digest: str | None = None


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files_for(case: str) -> dict[str, str]:
    if case == "quantity":
        return {"quantity.py": "quantity.py", "task.md": "quantity-task.md"}
    return {
        "source.py": "paginated_source.py" if case == "pagination" else "source.py",
        "report.py": "report.py",
        "task.md": "pagination-task.md" if case == "pagination" else "task.md",
    }


def guidance(ref: str, planning: bool) -> str:
    def show(name: str) -> str:
        return subprocess.check_output(
            ["git", "show", f"{ref}:{name}"], cwd=ROOT, text=True
        )

    text = "\n\n".join(f"### {name}\n{show(name)}" for name in GUIDES)
    if planning:
        doc = show("docs/HARNESS.md")
        start = doc.index("### The breakdown flow")
        end = doc.index("#### What counts as one feature", start)
        text += "\n\n### docs/HARNESS.md planning section\n" + doc[start:end]
    return text


def check(run: Run) -> bool:
    case = str(run.record["case"])
    command = [sys.executable, str(FIXTURE / "acceptance.py"), str(run.work), case]
    intact = "source.py" not in run.files or (
        (run.work / "source.py").is_file()
        and digest(run.work / "source.py") == digest(FIXTURE / run.files["source.py"])
    )
    run.record["source_unchanged"] = intact
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=15)
        log = result.stdout + result.stderr
        passed = result.returncode == 0 and intact
    except subprocess.TimeoutExpired:
        log = "Acceptance oracle timed out after 15 seconds.\n"
        passed = False
    if not intact:
        log += "Immutable source changed or disappeared.\n"
    (run.directory / "acceptance.log").write_text(log)
    if passed and run.record["first_correct_seconds"] is None:
        run.record["first_correct_seconds"] = round(time.monotonic() - run.start, 3)
    return passed


def initial_decision(path: Path) -> str | None:
    messages = []
    for line in path.read_text().splitlines():
        event = json.loads(line)
        if event["type"] == "tool.execution_start":
            break
        if event["type"] == "assistant.message" and event["data"].get("content"):
            messages.append(event["data"]["content"])
    return "\n".join(messages) or None


def save(output: Path, runs: list[Run]) -> None:
    records = []
    for run in runs:
        (run.directory / "result.json").write_text(
            json.dumps(run.record, indent=2) + "\n"
        )
        records.append(run.record)
    (output / "results.json").write_text(json.dumps(records, indent=2) + "\n")


def interrupt(signum: int, _frame: object) -> None:
    print(
        f"Experiment interrupted by signal {signum}; retaining incomplete trials.",
        file=sys.stderr,
    )
    raise SystemExit(128 + signum)


def stop_active(runs: list[Run]) -> None:
    active = [run for run in runs if run.record["status"] == "running"]
    for run in active:
        assert run.process is not None
        try:
            os.killpg(run.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 0.5
    for run in active:
        assert run.process is not None
        try:
            run.process.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(run.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        run.record.update(status="interrupted", exit_code=run.process.wait())
    for run in runs:
        if run.stdout is not None:
            run.stdout.close()
        if run.stderr is not None:
            run.stderr.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--planning-baseline",
        help="Pre-change commit for the fixed 18-trial #543 matrix",
    )
    args = parser.parse_args()
    planning = args.planning_baseline is not None
    baseline = subprocess.check_output(
        [
            "git",
            "rev-parse",
            "--verify",
            f"{args.planning_baseline or BASELINE}^{{commit}}",
        ],
        cwd=ROOT,
        text=True,
    ).strip()
    candidate = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    controls = [
        "--no-auto-update",
        "--no-custom-instructions",
        "--disable-builtin-mcps",
        "--no-ask-user",
        "--model",
        MODEL,
        "--reasoning-effort",
        "high",
        "--context",
        "default",
        "--output-format",
        "json",
        "--available-tools=bash,view,rg,glob,apply_patch",
        "--allow-all-tools",
        "--secret-env-vars=COPILOT_GITHUB_TOKEN",
    ]
    framing = (
        "This is a synthetic, already-authorized local implementation-phase experiment. "
        "Issue hosting, review approval, commits and publication are handled externally. "
        "Do not call GitHub, create issues, run harness lifecycle scripts or use subagents. "
        "Use the supplied guidance for design, testing and sufficient-quality judgment. "
        "Work only in the current directory, offline; source.py is immutable. "
        "Do not inspect parent directories or other sessions. Complete the task autonomously.\n\n"
    )
    if planning:
        framing = framing.replace("implementation-phase", "planning-and-implementation")
        framing += (
            "Before using tools, briefly state your initial approach in chat, then implement. "
            "No plan file or approval pause is required in this controlled experiment. "
            "Project tests run with `python3 -m unittest discover -v`; use discoverable "
            "unittest regression tests. Do not install dependencies.\n\n"
        )
    bundles = {
        arm: guidance(ref, planning)
        for arm, ref in [("old", baseline), ("new", candidate)]
    }
    for arm, text in bundles.items():
        (output / f"{arm}-guidance.txt").write_text(text)
    cases = ["aggregation", "pagination", "quantity"] if planning else ["legacy"]
    runs = []
    for case in cases:
        files = files_for(case)
        for number in range(1, 4):
            for arm in ("old", "new"):
                directory = (
                    output / case / f"{arm}-{number}"
                    if planning
                    else output / f"{arm}-{number}"
                )
                work = directory / "work"
                work.mkdir(parents=True)
                for destination, source in files.items():
                    shutil.copyfile(FIXTURE / source, work / destination)
                prompt = (
                    framing
                    + bundles[arm]
                    + "\n\n## TASK\n"
                    + (work / "task.md").read_text()
                )
                (directory / "prompt.txt").write_text(prompt)
                runs.append(
                    Run(
                        directory,
                        work,
                        prompt,
                        files,
                        {
                            "case": case,
                            "arm": arm,
                            "trial": number,
                            "session_id": str(uuid.uuid4()),
                            "status": "not_started",
                            "exit_code": None,
                            "acceptance_passed": False,
                            "first_correct_seconds": None,
                            "initial_decision": None,
                            "model_verified": False,
                            "human_interventions": 0,
                        },
                    )
                )
    manifest = {
        "baseline": baseline,
        "candidate": candidate,
        "controls": controls,
        "cli": subprocess.check_output(["copilot", "--version"], text=True).strip(),
        "fixture": {p.name: digest(p) for p in FIXTURE.iterdir() if p.is_file()},
        "runner_sha256": digest(Path(__file__)),
        "guides": {
            arm: hashlib.sha256(text.encode()).hexdigest()
            for arm, text in bundles.items()
        },
        "trials": [dict(run.record) for run in runs],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    save(output, runs)
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, interrupt)
    pending = iter(runs)
    active: list[Run] = []
    exhausted = False
    try:
        while active or not exhausted:
            while len(active) < 6 and not exhausted:
                next_run = next(pending, None)
                if next_run is None:
                    exhausted = True
                    break
                run = next_run
                home = run.directory / "home"
                home.mkdir()
                env = {
                    key: value
                    for key, value in os.environ.items()
                    if not key.startswith(
                        ("COPILOT_", "HARNESS_", "TRACE_", "GH_", "GITHUB_")
                    )
                }
                env.update(
                    HOME=str(home),
                    COPILOT_HOME=str(home / ".copilot"),
                    COPILOT_GITHUB_TOKEN=os.environ["COPILOT_GITHUB_TOKEN"],
                )
                run.stdout = (run.directory / "events.jsonl").open("w")
                run.stderr = (run.directory / "stderr.log").open("w")
                run.start = time.monotonic()
                try:
                    run.process = subprocess.Popen(
                        [
                            "copilot",
                            *controls,
                            "--session-id",
                            str(run.record["session_id"]),
                            "--usage-output-file",
                            str(run.directory / "usage.json"),
                            "-p",
                            run.prompt,
                        ],
                        cwd=run.work,
                        env=env,
                        stdout=run.stdout,
                        stderr=run.stderr,
                        start_new_session=True,
                    )
                except OSError as error:
                    run.record.update(status="launch_failed", error=str(error))
                    raise
                run.record.update(status="running", pid=run.process.pid)
                active.append(run)
                save(output, runs)
            for run in active[:]:
                assert run.process is not None
                finished = run.process.poll() is not None
                try:
                    current = hashlib.sha256(
                        "".join(
                            f"{p.relative_to(run.work)}:{digest(p)}"
                            for p in sorted(run.work.rglob("*.py"))
                        ).encode()
                    ).hexdigest()
                except FileNotFoundError as error:
                    # The agent may replace a file while this observation is reading it.
                    run.record["observation_error"] = str(error)
                    current = None
                if current != run.last_digest or finished:
                    passed = check(run)
                    run.last_digest = current
                    if finished:
                        assert run.stdout is not None and run.stderr is not None
                        run.stdout.close()
                        run.stderr.close()
                        decision = initial_decision(run.directory / "events.jsonl")
                        usage_path = run.directory / "usage.json"
                        verified = False
                        if usage_path.is_file():
                            usage = json.loads(usage_path.read_text())
                            verified = set(usage.get("modelMetrics", {})) == {MODEL}
                        run.record.update(
                            status="completed" if passed else "quality_failed",
                            exit_code=run.process.returncode,
                            acceptance_passed=passed,
                            elapsed_seconds=round(time.monotonic() - run.start, 3),
                            initial_decision=decision,
                            model_verified=verified,
                        )
                        if not verified:
                            run.record["error"] = (
                                "Missing usage evidence or unexpected resolved model."
                            )
                        save(output, runs)
                        print(json.dumps(run.record), flush=True)
                        active.remove(run)
                        if run.process.returncode != 0 or not verified:
                            raise SystemExit(
                                "Trial execution failed; retained unfinished matrix without retry."
                            )
            if active:
                time.sleep(0.1)
    finally:
        stop_active(runs)
        save(output, runs)
    if not all(run.record["acceptance_passed"] for run in runs):
        raise SystemExit(
            "Experiment retained quality failures; inspect outcomes before drawing conclusions."
        )


if __name__ == "__main__":
    main()
