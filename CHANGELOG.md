# CHANGELOG

<!-- version list -->

## v0.11.1 (2026-07-11)

### Bug Fixes

- **#285**: Close batch-review residue in sensors and artifacts
  ([#289](https://github.com/weijen/agent-delivery-harness/pull/289),
  [`f5157f6`](https://github.com/weijen/agent-delivery-harness/commit/f5157f620916dbe40b0c817a9f10ea0d615b6ae8))

- **#285**: Group cd && pwd -P to satisfy newer shellcheck (SC2015)
  ([#289](https://github.com/weijen/agent-delivery-harness/pull/289),
  [`f5157f6`](https://github.com/weijen/agent-delivery-harness/commit/f5157f620916dbe40b0c817a9f10ea0d615b6ae8))


## v0.11.0 (2026-07-10)

### Features

- **#88**: Document Loop 3 plan-correction escape hatch
  ([#288](https://github.com/weijen/agent-delivery-harness/pull/288),
  [`86cddf7`](https://github.com/weijen/agent-delivery-harness/commit/86cddf7f68a01f4e6ba19b5aeb6dffe8cf225406))


## v0.10.2 (2026-07-10)

### Bug Fixes

- **#91**: Surface git worktree remove errors instead of suppressing stderr
  ([#287](https://github.com/weijen/agent-delivery-harness/pull/287),
  [`eef49ec`](https://github.com/weijen/agent-delivery-harness/commit/eef49ec225068540a04774daee69c4643fd64e33))


## v0.10.1 (2026-07-10)

### Bug Fixes

- **#90**: Fail loudly when gh pr create fails or PR number is missing
  ([#286](https://github.com/weijen/agent-delivery-harness/pull/286),
  [`d034ee7`](https://github.com/weijen/agent-delivery-harness/commit/d034ee777bcd182bf55667a976fe917b1ab029a3))


## v0.10.0 (2026-07-10)

### Features

- **#274**: Demote go/java/ruby profiles to generator-supported
  ([#284](https://github.com/weijen/agent-delivery-harness/pull/284),
  [`cba3aec`](https://github.com/weijen/agent-delivery-harness/commit/cba3aec2b6cc9d64c6f5f0f6446d6dfda6343c7f))

### Refactoring

- **#273**: Triage prose-pinning meta-tests
  ([#283](https://github.com/weijen/agent-delivery-harness/pull/283),
  [`79d14c2`](https://github.com/weijen/agent-delivery-harness/commit/79d14c2ed50982909d5d0913732597053753f18c))


## v0.9.0 (2026-07-10)

### Features

- **#272**: Remove the cloud trace/log export leg
  ([#282](https://github.com/weijen/agent-delivery-harness/pull/282),
  [`5091efd`](https://github.com/weijen/agent-delivery-harness/commit/5091efd0cc7be1f6789eaf81693072161cc735ca))


## v0.8.1 (2026-07-10)

### Bug Fixes

- **#270**: Harden issue-resolution, title escaping, degraded redaction
  ([#281](https://github.com/weijen/agent-delivery-harness/pull/281),
  [`b2c0ada`](https://github.com/weijen/agent-delivery-harness/commit/b2c0ada8ddd7c55cf868af57a811280cd47855a7))

### Documentation

- **#269**: Sync installer/CI docs with shipped harness; retire stale health-check
  ([#280](https://github.com/weijen/agent-delivery-harness/pull/280),
  [`b37d42e`](https://github.com/weijen/agent-delivery-harness/commit/b37d42eb7fdd228d528d85deab68ba72bf22ad29))


## v0.8.0 (2026-07-10)

### Documentation

- **#267**: Document delivery economics block and finish-issue.economics span
  ([#279](https://github.com/weijen/agent-delivery-harness/pull/279),
  [`aa8be84`](https://github.com/weijen/agent-delivery-harness/commit/aa8be84f447b7aab720d7932c1a52aa516d12a96))

- **#267**: Record delivery-economics issue in PROGRESS.md
  ([#279](https://github.com/weijen/agent-delivery-harness/pull/279),
  [`aa8be84`](https://github.com/weijen/agent-delivery-harness/commit/aa8be84f447b7aab720d7932c1a52aa516d12a96))

### Features

- **#267**: Auto-stamp trace-derived delivery economics at closeout
  ([#279](https://github.com/weijen/agent-delivery-harness/pull/279),
  [`aa8be84`](https://github.com/weijen/agent-delivery-harness/commit/aa8be84f447b7aab720d7932c1a52aa516d12a96))

- **#267**: Compute_delivery_economics trace-derived summary helper
  ([#279](https://github.com/weijen/agent-delivery-harness/pull/279),
  [`aa8be84`](https://github.com/weijen/agent-delivery-harness/commit/aa8be84f447b7aab720d7932c1a52aa516d12a96))

- **#267**: Emit finish-issue.economics span with numeric aggregates
  ([#279](https://github.com/weijen/agent-delivery-harness/pull/279),
  [`aa8be84`](https://github.com/weijen/agent-delivery-harness/commit/aa8be84f447b7aab720d7932c1a52aa516d12a96))

- **#267**: Stamp delivery-economics block into progress.md at finish
  ([#279](https://github.com/weijen/agent-delivery-harness/pull/279),
  [`aa8be84`](https://github.com/weijen/agent-delivery-harness/commit/aa8be84f447b7aab720d7932c1a52aa516d12a96))


## v0.7.0 (2026-07-10)

### Bug Fixes

- **#266**: Reconcile log-completeness span with frozen trace contract
  ([#278](https://github.com/weijen/agent-delivery-harness/pull/278),
  [`54ae2d4`](https://github.com/weijen/agent-delivery-harness/commit/54ae2d4f2ca67b3921202ca6024d154de4cbfd6d))

### Documentation

- **#266**: Record log-completeness gate in PROGRESS.md
  ([#278](https://github.com/weijen/agent-delivery-harness/pull/278),
  [`54ae2d4`](https://github.com/weijen/agent-delivery-harness/commit/54ae2d4f2ca67b3921202ca6024d154de4cbfd6d))

### Features

- **#266**: Add review-gate log-completeness placeholder gate
  ([#278](https://github.com/weijen/agent-delivery-harness/pull/278),
  [`54ae2d4`](https://github.com/weijen/agent-delivery-harness/commit/54ae2d4f2ca67b3921202ca6024d154de4cbfd6d))

- **#266**: Configurable LOG_COMPLETENESS_PATHS scan list
  ([#278](https://github.com/weijen/agent-delivery-harness/pull/278),
  [`54ae2d4`](https://github.com/weijen/agent-delivery-harness/commit/54ae2d4f2ca67b3921202ca6024d154de4cbfd6d))

- **#266**: Emit numeric log-completeness trace span + docs
  ([#278](https://github.com/weijen/agent-delivery-harness/pull/278),
  [`54ae2d4`](https://github.com/weijen/agent-delivery-harness/commit/54ae2d4f2ca67b3921202ca6024d154de4cbfd6d))

- **#266**: Log-completeness gate — refuse closeout on unfilled Action Log placeholders
  ([#278](https://github.com/weijen/agent-delivery-harness/pull/278),
  [`54ae2d4`](https://github.com/weijen/agent-delivery-harness/commit/54ae2d4f2ca67b3921202ca6024d154de4cbfd6d))

- **#266**: Wire log-completeness gate into finish-issue and check
  ([#278](https://github.com/weijen/agent-delivery-harness/pull/278),
  [`54ae2d4`](https://github.com/weijen/agent-delivery-harness/commit/54ae2d4f2ca67b3921202ca6024d154de4cbfd6d))


## v0.6.0 (2026-07-10)

### Documentation

- **#265**: Clarify PEP 758 version boundary and Loop 2 actor
  ([#277](https://github.com/weijen/agent-delivery-harness/pull/277),
  [`933787e`](https://github.com/weijen/agent-delivery-harness/commit/933787e7f9b39e98f67e1b77a6632105b4f4fb78))

- **#265**: Record execute-before-CRITICAL + false-positive registry in PROGRESS
  ([#277](https://github.com/weijen/agent-delivery-harness/pull/277),
  [`933787e`](https://github.com/weijen/agent-delivery-harness/commit/933787e7f9b39e98f67e1b77a6632105b4f4fb78))

### Features

- **#265**: Add known-false-positive registry seeded with PEP 758
  ([#277](https://github.com/weijen/agent-delivery-harness/pull/277),
  [`933787e`](https://github.com/weijen/agent-delivery-harness/commit/933787e7f9b39e98f67e1b77a6632105b4f4fb78))

- **#265**: Execute-before-CRITICAL rule + known-false-positive registry (PEP 758)
  ([#277](https://github.com/weijen/agent-delivery-harness/pull/277),
  [`933787e`](https://github.com/weijen/agent-delivery-harness/commit/933787e7f9b39e98f67e1b77a6632105b4f4fb78))

- **#265**: Execute-before-CRITICAL rule in code-review-subagent contract
  ([#277](https://github.com/weijen/agent-delivery-harness/pull/277),
  [`933787e`](https://github.com/weijen/agent-delivery-harness/commit/933787e7f9b39e98f67e1b77a6632105b4f4fb78))

- **#265**: Review-loop appends refuted findings to registry
  ([#277](https://github.com/weijen/agent-delivery-harness/pull/277),
  [`933787e`](https://github.com/weijen/agent-delivery-harness/commit/933787e7f9b39e98f67e1b77a6632105b4f4fb78))


## v0.5.0 (2026-07-10)

### Chores

- **#264**: Sync uv.lock virtual project version to 0.5.0
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))

### Documentation

- **#264**: Record sensor teeth-proof gate delivery in PROGRESS
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))

### Features

- **#264**: Accept teeth_proof as red-first evidence in trace checker
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))

- **#264**: Block PR-path red-first gate on teeth_proof_missing
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))

- **#264**: Enforce sensor teeth-proof on the PR path, not handback ordering
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))

- **#264**: Rename docs to sensor teeth-proof obligation
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))

- **#264**: Rescope waivers to teeth-proof with teeth_proof_waiver
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))

- **#264**: Update contract to teeth-proof gate boundary and bump 0.5.0
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))

### Refactoring

- **#264**: Tidy waiver jq per review
  ([#275](https://github.com/weijen/agent-delivery-harness/pull/275),
  [`700a80d`](https://github.com/weijen/agent-delivery-harness/commit/700a80d52b46e96d1c18f241eb5556497b2f0014))


## v0.4.1 (2026-07-10)

### Bug Fixes

- **ci**: Pin Python workflow actions
  ([#276](https://github.com/weijen/agent-delivery-harness/pull/276),
  [`7d15639`](https://github.com/weijen/agent-delivery-harness/commit/7d156394522ebd88978dffd5a85f2b80f0ac8a62))

- **ci**: Pin release workflow actions
  ([#276](https://github.com/weijen/agent-delivery-harness/pull/276),
  [`7d15639`](https://github.com/weijen/agent-delivery-harness/commit/7d156394522ebd88978dffd5a85f2b80f0ac8a62))

- **ci**: Pin workflow actions and permissions
  ([#276](https://github.com/weijen/agent-delivery-harness/pull/276),
  [`7d15639`](https://github.com/weijen/agent-delivery-harness/commit/7d156394522ebd88978dffd5a85f2b80f0ac8a62))

### Documentation

- **progress**: Note CI workflow hardening
  ([#276](https://github.com/weijen/agent-delivery-harness/pull/276),
  [`7d15639`](https://github.com/weijen/agent-delivery-harness/commit/7d156394522ebd88978dffd5a85f2b80f0ac8a62))

- **progress**: Refresh update metadata
  ([#276](https://github.com/weijen/agent-delivery-harness/pull/276),
  [`7d15639`](https://github.com/weijen/agent-delivery-harness/commit/7d156394522ebd88978dffd5a85f2b80f0ac8a62))


## v0.4.0 (2026-07-10)

### Bug Fixes

- **#263**: Add teeth_proof_missing_count to trace-schema numeric backstop
  ([#271](https://github.com/weijen/agent-delivery-harness/pull/271),
  [`b4b5446`](https://github.com/weijen/agent-delivery-harness/commit/b4b5446122dc34551c80f1ea92c121434c5ec512))

- **#263**: Type harness.teeth_proof_missing_count as a JSON number
  ([#271](https://github.com/weijen/agent-delivery-harness/pull/271),
  [`b4b5446`](https://github.com/weijen/agent-delivery-harness/commit/b4b5446122dc34551c80f1ea92c121434c5ec512))

### Documentation

- **#263**: Document teeth_proof evidence doctrine
  ([#271](https://github.com/weijen/agent-delivery-harness/pull/271),
  [`b4b5446`](https://github.com/weijen/agent-delivery-harness/commit/b4b5446122dc34551c80f1ea92c121434c5ec512))

- **#263**: Record teeth-proof evidence delivery in PROGRESS
  ([#271](https://github.com/weijen/agent-delivery-harness/pull/271),
  [`b4b5446`](https://github.com/weijen/agent-delivery-harness/commit/b4b5446122dc34551c80f1ea92c121434c5ec512))

### Features

- **#263**: Declare teeth-proof-missing warn failure mode in contract
  ([#271](https://github.com/weijen/agent-delivery-harness/pull/271),
  [`b4b5446`](https://github.com/weijen/agent-delivery-harness/commit/b4b5446122dc34551c80f1ea92c121434c5ec512))

- **#263**: First-class teeth-proof evidence for feature_list
  ([#271](https://github.com/weijen/agent-delivery-harness/pull/271),
  [`b4b5446`](https://github.com/weijen/agent-delivery-harness/commit/b4b5446122dc34551c80f1ea92c121434c5ec512))

- **#263**: Validate optional teeth_proof in check-feature-list.sh
  ([#271](https://github.com/weijen/agent-delivery-harness/pull/271),
  [`b4b5446`](https://github.com/weijen/agent-delivery-harness/commit/b4b5446122dc34551c80f1ea92c121434c5ec512))


## v0.3.0 (2026-07-10)

### Features

- **#258**: Add audit-sweep.sh local six-skill driver
  ([#262](https://github.com/weijen/agent-delivery-harness/pull/262),
  [`0137e21`](https://github.com/weijen/agent-delivery-harness/commit/0137e21348c7cde6c8df89e657867f3ef1ef0060))


## v0.2.0 (2026-07-10)

### Bug Fixes

- **#260**: Pin allow_zero_version so PSR stays on 0.x
  ([#261](https://github.com/weijen/agent-delivery-harness/pull/261),
  [`258874b`](https://github.com/weijen/agent-delivery-harness/commit/258874b6b9e29191232547ba7b3f86e8df508fdd))

### Features

- **#257**: Automate SemVer releases with python-semantic-release
  ([#259](https://github.com/weijen/agent-delivery-harness/pull/259),
  [`f1483db`](https://github.com/weijen/agent-delivery-harness/commit/f1483dbde28e5dd56c8fdc70a954ad33cf03f824))


## v0.1.1 (2026-07-10)

- Initial Release
