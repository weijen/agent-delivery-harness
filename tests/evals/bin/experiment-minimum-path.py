"""Opt-in, six-session #541 experiment; not a CI gate or general evaluation runner."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import TextIO, TypedDict

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "tests/evals/fixtures/skills/minimum-path"
BASELINE = "7009f8048b938a4b14f72fdc3c045a62a15844a8"
GUIDES = [
    "AGENTS.md",
    ".copilot/instructions/harness.instructions.md",
    ".copilot/instructions/workflow-tiers.instructions.md",
    ".copilot/agents/code-review-subagent.agent.md",
    "docs/product-quality-rubric.md",
]


class Run(TypedDict):
    arm: str
    trial: int
    session_id: str
    directory: Path
    work: Path
    process: subprocess.Popen[bytes]
    stdout: TextIO
    stderr: TextIO
    start: float
    first_correct_seconds: float | None
    last_digest: str | None


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=False)
    candidate = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    controls = [
        "--no-auto-update",
        "--no-custom-instructions",
        "--disable-builtin-mcps",
        "--no-ask-user",
        "--model",
        "gpt-6-astra",
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
    guide_hashes: dict[str, str] = {}
    manifest = {
        "baseline": BASELINE,
        "candidate": candidate,
        "controls": controls,
        "cli": subprocess.check_output(["copilot", "--version"], text=True).strip(),
        "fixture": {p.name: digest(p) for p in FIXTURE.iterdir() if p.is_file()},
        "guides": guide_hashes,
    }
    framing = (
        "This is a synthetic, already-authorized local implementation-phase experiment. "
        "Issue hosting, review approval, commits and publication are handled externally. "
        "Do not call GitHub, create issues, run harness lifecycle scripts or use subagents. "
        "Use the supplied guidance for design, testing and sufficient-quality judgment. "
        "Work only in the current directory, offline; source.py is immutable. "
        "Do not inspect parent directories or other sessions. Complete the task autonomously.\n\n"
    )
    prompts = {}
    for arm, ref in [("old", BASELINE), ("new", candidate)]:
        guide = "\n\n".join(
            f"### {name}\n"
            + subprocess.check_output(
                ["git", "show", f"{ref}:{name}"], cwd=ROOT, text=True
            )
            for name in GUIDES
        )
        prompts[arm] = (
            framing + guide + "\n\n## TASK\n" + (FIXTURE / "task.md").read_text()
        )
        (output / f"{arm}-prompt.txt").write_text(prompts[arm])
        guide_hashes[arm] = hashlib.sha256(guide.encode()).hexdigest()
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    runs: list[Run] = []
    for number in range(1, 4):
        for arm in ("old", "new"):
            directory = output / f"{arm}-{number}"
            work = directory / "work"
            work.mkdir(parents=True)
            for name in ("source.py", "report.py", "task.md"):
                shutil.copyfile(FIXTURE / name, work / name)
            home = directory / "home"
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
            session_id = str(uuid.uuid4())
            stdout = (directory / "events.jsonl").open("w")
            stderr = (directory / "stderr.log").open("w")
            start = time.monotonic()
            process = subprocess.Popen(
                [
                    "copilot",
                    *controls,
                    "--session-id",
                    session_id,
                    "--usage-output-file",
                    str(directory / "usage.json"),
                    "-p",
                    prompts[arm],
                ],
                cwd=work,
                env=env,
                stdout=stdout,
                stderr=stderr,
            )
            runs.append(
                {
                    "arm": arm,
                    "trial": number,
                    "session_id": session_id,
                    "directory": directory,
                    "work": work,
                    "process": process,
                    "stdout": stdout,
                    "stderr": stderr,
                    "start": start,
                    "first_correct_seconds": None,
                    "last_digest": None,
                }
            )
    results = []
    while runs:
        for run in runs[:]:
            work = run["work"]
            process = run["process"]
            current = (
                digest(work / "report.py") if (work / "report.py").exists() else None
            )
            finished = process.poll() is not None
            if current != run["last_digest"] or finished:
                command = [sys.executable, str(FIXTURE / "acceptance.py"), str(work)]
                try:
                    check = subprocess.run(
                        command,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                except subprocess.TimeoutExpired:
                    check = subprocess.CompletedProcess(
                        command,
                        124,
                        "",
                        "Acceptance oracle timed out after 10 seconds.\n",
                    )
                intact = (work / "source.py").is_file() and digest(
                    work / "source.py"
                ) == digest(FIXTURE / "source.py")
                passed = check.returncode == 0 and intact
                if passed and run["first_correct_seconds"] is None:
                    run["first_correct_seconds"] = round(
                        time.monotonic() - run["start"], 3
                    )
                run["last_digest"] = current
                if finished:
                    result: dict[str, str | int | float | None] = {
                        "arm": run["arm"],
                        "trial": run["trial"],
                        "session_id": run["session_id"],
                        "first_correct_seconds": run["first_correct_seconds"],
                    }
                    result.update(
                        elapsed_seconds=round(time.monotonic() - run["start"], 3),
                        exit_code=process.returncode,
                        acceptance_passed=passed,
                        source_unchanged=intact,
                        human_interventions=0,
                    )
                    (run["directory"] / "acceptance.log").write_text(
                        check.stdout + check.stderr
                    )
                    (run["directory"] / "result.json").write_text(
                        json.dumps(result, indent=2)
                    )
                    run["stdout"].close()
                    run["stderr"].close()
                    results.append(result)
                    (output / "results.json").write_text(
                        json.dumps(results, indent=2) + "\n"
                    )
                    print(json.dumps(result), flush=True)
                    runs.remove(run)
        time.sleep(1)
    if not all(row["exit_code"] == 0 and row["acceptance_passed"] for row in results):
        raise SystemExit(
            "Experiment retained failed outcomes; inspect results before drawing conclusions."
        )


if __name__ == "__main__":
    main()
