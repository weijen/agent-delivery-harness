# CHANGELOG

<!-- version list -->

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
