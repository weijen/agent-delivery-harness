# Minimum-path guidance experiment (#541)

Run date: 2026-11-01. Report-only maintainer experiment, not an adopter gate.

## Result and decision

**All six outputs passed the same independent acceptance checks. No simpler
implementation behavior was demonstrated:** both guidance variants immediately
used source-side aggregation, added focused tests and stopped. Neither added
pagination, retries, configuration, exception wrappers or speculative features.
All used seven model requests and zero human interventions.

Mean reported AI credits fell from 75.975 to 70.046 (7.8%). Mean completion time
was 53.139s versus 52.111s; mean first-correct time was 44.866s versus 44.555s.
These small timing differences are inconclusive. Lower context cost is useful,
but is **not** evidence that the new prose improves design decisions.

Keep the concrete policy simplifications, whose gate behavior has separate
regression coverage; do not claim this experiment proves behavioral superiority
or universally lossless quality. It provides bounded non-regression evidence on
this task. In particular, a stronger coding engine already found the simple path
under old instructions. Do not add more prompt rules or rerun until favorable
results appear. Any future behavioral claim needs a more discriminating,
independently chosen real-project case and fresh retained trials.

## Individual outcomes

Seconds are monotonic elapsed time from CLI launch. First-correct is the first
observed candidate passing the entire external oracle, polled on report changes
at approximately one-second resolution; it is not the agent's self-report.
Input includes cache-read/cache-write tokens. Credits are CLI `totalNanoAiu / 1e9`,
not dollars or an inferred billing rate.

| Trial | First correct | Complete | Input tokens | Output tokens | AI credits | Independent quality |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| old-1 | 41.769 | 49.987 | 252482 | 1758 | 74.23810 | pass |
| new-1 | 38.693 | 44.916 | 230221 | 1814 | 68.74195 | pass |
| old-2 | 50.024 | 57.266 | 254777 | 2247 | 78.24775 | pass |
| new-2 | 52.131 | 61.366 | 231771 | 2224 | 72.07165 | pass |
| old-3 | 42.806 | 52.165 | 253223 | 1924 | 75.44005 | pass |
| new-3 | 42.842 | 50.050 | 230617 | 1898 | 69.32345 | pass |

Each trial changed only `report.py` and its own `test_report.py`. Source hashes
were unchanged. All six production implementations reduce to:

```python
rows = source.top_totals(3)
output.write_text(json.dumps(rows), encoding="utf-8")
```

The independent oracle checks full-source totals beyond the result window,
descending ranking and alphabetical ties, fewer than three groups, empty source,
and source outage propagation without overwriting a previous output. The oracle
rejects the starting example and a success-shaped outage fallback, and accepts
the minimal implementation. Generated tests were executed red then green in all
six sessions; they do not substitute for the independent oracle.

## Frozen controls and retained evidence

- CLI: GitHub Copilot CLI **1.0.105**, auto-update disabled.
- Model: **gpt-6-astra**, reasoning **high**, context **default**; every usage
  record confirms the same resolved model. Backend weights are not exposed or
  independently pinnable; this is a same-session engine configuration control.
- Baseline: `7009f8048b938a4b14f72fdc3c045a62a15844a8`.
- Candidate guidance: `b881ea14b9efdd1c56e450236aed54b13828de69`.
- Guidance: complete AGENTS, harness instructions, workflow tiers, reviewer and
  quality rubric, extracted from those commits with identical prompt framing.
- Each session has a fresh work directory, HOME, COPILOT_HOME and UUID. Automatic
  custom instructions and built-in MCPs are disabled. Available tools are bash,
  view, rg, glob and apply_patch; no reviewer/delivery subagent is spawned.
- Six sessions launched in interleaved old/new order and ran concurrently under
  one shared 600-second wall-time-union budget. No per-arm budget resets.
- The task supplies output/constraint requirements, not an algorithm. Neither
  agent receives the oracle, a completed solution or another session's history.
- Local implementation only: hosting, issue decomposition artifacts, independent
  review and publication are explicitly out of scope in **both** arms. This
  measures design/testing behavior, not the full live SDLC.

The output directory retains prompts, manifest, all six source/test outputs,
JSONL events, usage, oracle logs and individual results. The following identities
allow matching the original retained run without publishing raw CLI environment
metadata:

| Trial | CLI session UUID | Output `report.py` SHA-256 |
| --- | --- | --- |
| old-1 | 3a0c34d5-0e2e-44a6-8fd9-4d0fc3884561 | 3579d1c52d9be1c59d46ecfd7054b9842cee35ca25913cfcbd011b0a9a6de1c0 |
| new-1 | 22e26247-95c6-43e4-a586-8ef4665f17e1 | eae3a99942dfd39e3f62c59ae8872ece8e0c2146855bbb7df6789a48bc5cb4c1 |
| old-2 | 696b5afb-5133-4563-91e1-6a7b06742d1b | 94fcfbf352484763ee813cfcfb37ede74f061ffb5b7a037bf99efda4834b575e |
| new-2 | 8e38c548-1f8f-4696-a960-262b93306a28 | c33a74d86578abea9c5ddf82c370528f894414365c8208615b93e59e78d8a32b |
| old-3 | e6e90a00-f3f7-41eb-8886-3c71a293ecd5 | bede87a8d592b9dc9e0036fda8d4ac8a443ca21905134efb95cea48105cefde7 |
| new-3 | ff2046a9-34c5-4684-b66c-4f72f938b9ff | 94fcfbf352484763ee813cfcfb37ede74f061ffb5b7a037bf99efda4834b575e |

Original guidance SHA-256: old
`fcf2b76e61f1ee3d66ec7fbc8e0e9b7e2bb9a1317806a02de35a97cee1f59f12`;
new `afaa95434c4beeceb08b95813f946def65aef3e56c770f406b7cf450da950cb9`.
Original oracle SHA-256:
`7580d69ecf5b50ebadbce9a7ade6ea40758ac569c2911f0fbd8a9055cccebd6f`.
After the run, candidate-local helper imports were enabled in the oracle; all six
retained outputs were rechecked. No task, source constraint or assertion changed.

## Reproduce

From the source checkout, authenticate using the repository identity helper.
Choose a new, private absolute output path outside tracked files. This opt-in
experiment makes six billable model sessions; it is never run by routine CI.

```bash
source scripts/lib/github-identity-lib.sh
harness_identity_activate
export COPILOT_GITHUB_TOKEN="$(gh auth token)"
source scripts/lib/test-budget-lib.sh
budget_session budget_run minimum-path-experiment \
  python3 tests/evals/bin/experiment-minimum-path.py "$RESULTS_DIR"
unset COPILOT_GITHUB_TOKEN
```

The fixed-purpose launcher snapshots guidance from the starting baseline and
current HEAD. It writes exact controls and fixture hashes before launching.
Reproducing the original comparison requires candidate guidance equal to the
commit above; later HEADs are new treatments, not replications. This launcher
does not introduce a model judge, scorecard gate or evaluation framework.

Three trials per arm on one deliberately small task cannot establish statistical
equivalence or a causal timing improvement. Concurrent provider scheduling and
cache state affect cost/time. The fixture exposes an obvious aggregation API,
so it may be too easy to reproduce real-project pagination thrash. Necessary
safety assertions pass here; broader security and delivery quality are not
proven by this fixture.
