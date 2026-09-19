# Language Profiles: Current Use

## Current profile workflow

Language profiles and the scaffolder are implemented. The descriptor interface
has one current authority: [profiles/README.md](../profiles/README.md).
`scripts/init.sh` uses explicit marker-file detection, then reads the selected
profile's labels, dependency sync and quality gates. Profile metadata does not
replace those detection branches.

Python and Node.js descriptors ship with the harness.
Go, Java and Ruby remain generator-supported scaffold skeletons, not committed production profiles.
Use [`scripts/scaffold-language.sh`](../scripts/scaffold-language.sh)
with a profile name for a dry run, `--write` to create missing assets, or
`--update` for a visible update. It produces the descriptor and matching
instruction file, not a new application or arbitrary version-pin files.

[`docs/harness-contract.yml`](harness-contract.yml) already defines the frozen
lifecycle. [`tests/scripts/test_harness_contract.sh`](../tests/scripts/test_harness_contract.sh)
guards it; `tests/scripts/test_init_gates.sh` covers marker detection and gate
execution. Changes to profiles must preserve those contracts.
Current review approvals live at
`.copilot-tracking/review-gate/issue-NN/approved-head`; the historical unscoped
marker is a read-only fallback, not the place to write new approvals.

## Design history

The original implementation initiative is preserved as
[historical design](archive/multi-language-profiles.md), not current interface authority.
