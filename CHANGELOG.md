# CHANGELOG

<!-- version list -->

## v0.27.3 (2026-07-22)

### Bug Fixes

- **#352**: Merge-pr local cleanup uses safe branch delete only
  ([`368eb47`](https://github.com/weijen/agent-delivery-harness/commit/368eb47c94ff8c40516e3e4656443d658f7181db))

### Documentation

- **#352**: Align escalation/durable-lesson doctrine with the #327 sensor contract
  ([`1fab790`](https://github.com/weijen/agent-delivery-harness/commit/1fab790bf2464da78b9d12ff21acff9b9194f976))

### Refactoring

- **#334**: Retire red-first/teeth evidence gating — keep TDD, review owns test quality
  ([`10c271f`](https://github.com/weijen/agent-delivery-harness/commit/10c271f77391c5ff818a1169bfcc15964ef51a51))

- **#352**: Absorb #335 remainder — retire copilot capture hook, claude-code hook to optional
  ([`785d952`](https://github.com/weijen/agent-delivery-harness/commit/785d95245ecf0b1d3b6dc0e1586d62cbefc646a8))

- **#352**: Retire role choreography — one agent, one reviewer, four gates
  ([`3d1d8fc`](https://github.com/weijen/agent-delivery-harness/commit/3d1d8fc6af21adb4e8acc575af0736db0a487037))

- **#352**: Sync harness contract and doctrine anchors to the skeleton
  ([`eecad32`](https://github.com/weijen/agent-delivery-harness/commit/eecad3218a19b3636c9155a5b9597b1c841c4482))

### Testing

- **#334**: Retarget economics line and waiver-kind docs
  ([`77769cd`](https://github.com/weijen/agent-delivery-harness/commit/77769cde878410727978c60bdaae805a57d74264))

- **#336**: Remove role-choreography and prose-pinning meta sensors with their subjects
  ([`9b6a52a`](https://github.com/weijen/agent-delivery-harness/commit/9b6a52aae31e0cbf86f1ee7a00af486c0d4ee15d))

- **#336**: Retarget surviving sensors to the skeleton contract
  ([`0563938`](https://github.com/weijen/agent-delivery-harness/commit/056393804f98460240254bb645fd50665c985116))


## v0.27.2 (2026-07-22)

### Bug Fixes

- **#333**: Remove trace_log calls inside the lifecycle trap
  ([`ba847b3`](https://github.com/weijen/agent-delivery-harness/commit/ba847b3c291811d26c1d335e72a239ef28a494f6))

### Chores

- **#335**: Drop generated lockfile delta
  ([`f2b95ee`](https://github.com/weijen/agent-delivery-harness/commit/f2b95ee29abf80f43f66465508648c2115fa53ad))

### Refactoring

- **#333**: Retire the log.jsonl detail stream
  ([`93b6942`](https://github.com/weijen/agent-delivery-harness/commit/93b6942d4b81958cfe5784d9ff0d5a6d78acb8fa))

- **#335**: Fold cross-run trace report
  ([`ddb58c4`](https://github.com/weijen/agent-delivery-harness/commit/ddb58c4c9432df200cb9bed82a85019c275393dd))

- **#335**: Fold trace validation gate
  ([`1c996ef`](https://github.com/weijen/agent-delivery-harness/commit/1c996ef84d84746f8d01e7fc4bc2e142a8bec23d))

### Testing

- **#333**: Remove log.jsonl sensors with their subject
  ([`29fab35`](https://github.com/weijen/agent-delivery-harness/commit/29fab356e249c13d7c33b322665eab085b42c032))

- **#333**: Retire trace_log sensor family; retarget archived log-schema links
  ([`e1fb9cd`](https://github.com/weijen/agent-delivery-harness/commit/e1fb9cd2c7ef610b711dc9465d62a77821f03bbe))

- **#335**: Add consolidated trace sensor
  ([`9d88876`](https://github.com/weijen/agent-delivery-harness/commit/9d88876566ffd999e56dafd2ca9ce345755c8496))

- **#335**: Drop retired trace-scorecard schema from archive keep-list
  ([`3f5592a`](https://github.com/weijen/agent-delivery-harness/commit/3f5592abbff8e9ec5fb0ba0909c4a9ae1adfcca8))


## v0.27.1 (2026-07-22)

### Bug Fixes

- Convert SC2015 patterns in render-action-log sensor
  ([`33a8ca3`](https://github.com/weijen/agent-delivery-harness/commit/33a8ca37e67a670c327c43a5c1da0025dede93cb))

### Documentation

- **#86**: Boundary-gates research — evidence predicates over trace.jsonl
  ([`5a9bec3`](https://github.com/weijen/agent-delivery-harness/commit/5a9bec3bb4dfec8827ba474a26568a6f1fa9f759))


## v0.27.0 (2026-07-22)

### Documentation

- **#332**: Record single-source trace delivery
  ([`9a5837e`](https://github.com/weijen/agent-delivery-harness/commit/9a5837e2808f5963a569876093ebb51b54375d66))

### Features

- **#332**: Render action log from trace
  ([`774854e`](https://github.com/weijen/agent-delivery-harness/commit/774854e3c56054608c7811159c3a43fc5e4252f3))

### Refactoring

- **#332**: Consolidate action log sensor
  ([`e46337d`](https://github.com/weijen/agent-delivery-harness/commit/e46337d451c0ac12e385e7ab62859f25b42840f6))

- **#332**: Make handbacks trace-only
  ([`97c7e16`](https://github.com/weijen/agent-delivery-harness/commit/97c7e1640464a30a9da127e6510d4454a4731954))

- **#332**: Retire action log reconciliation
  ([`8259602`](https://github.com/weijen/agent-delivery-harness/commit/82596028a6079636338d86e51b105d4496b14627))


## v0.26.0 (2026-07-22)

### Features

- **#350**: Review diet — five quality skills run only in audit-sweep
  ([`15e37d4`](https://github.com/weijen/agent-delivery-harness/commit/15e37d4a0d8bafc51470ee22ac1ec8f8a1f8e978))


## v0.25.0 (2026-07-22)

### Documentation

- **#337**: Archive dormant evaluation plans
  ([`0e26d4d`](https://github.com/weijen/agent-delivery-harness/commit/0e26d4defdcaf45dbb5d4805174e2141c056a298))

- **#337**: Record evaluation archive delivery
  ([`fa9eaac`](https://github.com/weijen/agent-delivery-harness/commit/fa9eaacb19a94b64d95f3335e567e9341124cc43))

### Features

- **#347**: Tiered sensor runner — green is scoped by construction, full only at gates
  ([`049d80f`](https://github.com/weijen/agent-delivery-harness/commit/049d80fc01338a8b9a9d3dae33c9543eeeeb319f))

### Testing

- **#337**: Audit archived evaluation contracts
  ([`66ef8c1`](https://github.com/weijen/agent-delivery-harness/commit/66ef8c1bb2469098ec07722b7b2897f4dfedd5e7))

- **#337**: Block live archive references
  ([`b88af8e`](https://github.com/weijen/agent-delivery-harness/commit/b88af8ef64959353854cabbe408f57c603774fcc))

- **#337**: Drop retired installed sensor
  ([`b45bef7`](https://github.com/weijen/agent-delivery-harness/commit/b45bef72e081b2bc9558f21bf6ca99db1eb48789))

- **#337**: Retire archived content gates
  ([`e918e74`](https://github.com/weijen/agent-delivery-harness/commit/e918e74e25125bef5577a1f3405be40e59682293))


## v0.24.1 (2026-07-22)

### Bug Fixes

- Complete installer runtime assets
  ([#345](https://github.com/weijen/agent-delivery-harness/pull/345),
  [`15af67c`](https://github.com/weijen/agent-delivery-harness/commit/15af67c2751dfb929acd117d052fb253013da379))

- **#311**: Complete installer runtime assets
  ([#345](https://github.com/weijen/agent-delivery-harness/pull/345),
  [`15af67c`](https://github.com/weijen/agent-delivery-harness/commit/15af67c2751dfb929acd117d052fb253013da379))

### Documentation

- **#311**: Record installer closure
  ([#345](https://github.com/weijen/agent-delivery-harness/pull/345),
  [`15af67c`](https://github.com/weijen/agent-delivery-harness/commit/15af67c2751dfb929acd117d052fb253013da379))


## v0.24.0 (2026-07-22)

### Features

- **#343**: Register sensor_scope/sensor_count in the trace contract
  ([`1a1b75c`](https://github.com/weijen/agent-delivery-harness/commit/1a1b75cd818e2ace5318543900de53152a4aab68))

- **#343**: Tiered sensor execution — scoped GREEN runs, full suite pre-review/pre-PR
  ([`7b41279`](https://github.com/weijen/agent-delivery-harness/commit/7b412793160f9a174a0b3b2a28e2497c307152ef))


## v0.23.2 (2026-07-22)

### Bug Fixes

- **#329**: Group SC2015 test assertion for shellcheck 0.11.0+
  ([`de02d29`](https://github.com/weijen/agent-delivery-harness/commit/de02d29262e6daee950ab9aea2a92ca79acea077))

- **#329**: Harden closeout local writes
  ([`d068156`](https://github.com/weijen/agent-delivery-harness/commit/d068156cbd4e495417061587e613266f5c166d13))

- **#329**: Join native run economics
  ([`e3ceddd`](https://github.com/weijen/agent-delivery-harness/commit/e3cedddf53459a1b9681449eeddfe0f83d9bca9b))

- **#329**: Regenerate final trace summary
  ([`77535d7`](https://github.com/weijen/agent-delivery-harness/commit/77535d758dcdc6863588fff4bcd25de9f40becf2))

### Testing

- **#329**: Group economics shellcheck assertion
  ([`6d1c3ba`](https://github.com/weijen/agent-delivery-harness/commit/6d1c3bacca5c4ce524336f013398454c2190851b))

- **#329**: Isolate native economics fixtures
  ([`f67a5b1`](https://github.com/weijen/agent-delivery-harness/commit/f67a5b133bbc0054f383e224867a594a9695bd6a))


## v0.23.1 (2026-07-22)

### Bug Fixes

- **#330**: Preserve legacy fail traces
  ([`3352220`](https://github.com/weijen/agent-delivery-harness/commit/3352220bd3d162ad81c9f1b602452fac3aa322cf))


## v0.23.0 (2026-07-22)

### Bug Fixes

- **#310**: Fail closed on unresolved main marker
  ([`0d7eca2`](https://github.com/weijen/agent-delivery-harness/commit/0d7eca2486eb7db7a163c9b2d3e98bdd00478644))

- **#310**: Update both worktree and main-root markers on linked-worktree carry
  ([`4e2db48`](https://github.com/weijen/agent-delivery-harness/commit/4e2db48d01a16457d0b51aa7d096ca94a61316a2))

### Documentation

- **#310**: Record approval carry delivery
  ([`4af9198`](https://github.com/weijen/agent-delivery-harness/commit/4af9198740d1e6289e26ca68ac07c6107687a09d))

### Features

- **#310**: Carry review across stable rebases
  ([`6b95dd0`](https://github.com/weijen/agent-delivery-harness/commit/6b95dd097d329a8d39874b448f100190b2d4d567))

- **#310**: Store stable review patch identity
  ([`f7e1ecd`](https://github.com/weijen/agent-delivery-harness/commit/f7e1ecd5a73b5f7b7be487fa6c2a889513614c86))


## v0.22.0 (2026-07-21)

### Bug Fixes

- **#326**: Group fallback assertions for shellcheck
  ([`7d77c1d`](https://github.com/weijen/agent-delivery-harness/commit/7d77c1d0ff81b1f0d03d0f6029a76d4aeb503283))

- **#326**: Support ruleset force rejections
  ([`378dafc`](https://github.com/weijen/agent-delivery-harness/commit/378dafc9452882415b310f663b2d6f4ae9bceb75))

### Documentation

- **#326**: Define create-pr push contract
  ([`5114597`](https://github.com/weijen/agent-delivery-harness/commit/5114597271cc3ee143ecf652a03c61a71be945bd))

- **#326**: Record non-rewriting PR sync
  ([`aed8f68`](https://github.com/weijen/agent-delivery-harness/commit/aed8f68f6c68c8803457ad62db2344e0cd9e65d2))

### Features

- **#326**: Add non-rewriting PR sync mode
  ([`0ca7d2a`](https://github.com/weijen/agent-delivery-harness/commit/0ca7d2a9ba111e36ab6ebe24db75399c5cc9ea4c))

- **#326**: Recover from blocked force pushes
  ([`dc7a1ae`](https://github.com/weijen/agent-delivery-harness/commit/dc7a1aeb3a4b97014ced74f3f8b68e6e5ffc60e5))


## v0.21.1 (2026-07-21)

### Bug Fixes

- Require authoritative merge evidence
  ([#338](https://github.com/weijen/agent-delivery-harness/pull/338),
  [`17561ac`](https://github.com/weijen/agent-delivery-harness/commit/17561acf9d45ebddd933ab633a7f8e9ae3fa733f))

- **#328**: Make create-pr help side-effect free
  ([#338](https://github.com/weijen/agent-delivery-harness/pull/338),
  [`17561ac`](https://github.com/weijen/agent-delivery-harness/commit/17561acf9d45ebddd933ab633a7f8e9ae3fa733f))

- **#328**: Make merge-pr help side-effect free
  ([#338](https://github.com/weijen/agent-delivery-harness/pull/338),
  [`17561ac`](https://github.com/weijen/agent-delivery-harness/commit/17561acf9d45ebddd933ab633a7f8e9ae3fa733f))

- **#328**: Require merge evidence at closeout
  ([#338](https://github.com/weijen/agent-delivery-harness/pull/338),
  [`17561ac`](https://github.com/weijen/agent-delivery-harness/commit/17561acf9d45ebddd933ab633a7f8e9ae3fa733f))

- **#328**: Verify merge state before success
  ([#338](https://github.com/weijen/agent-delivery-harness/pull/338),
  [`17561ac`](https://github.com/weijen/agent-delivery-harness/commit/17561acf9d45ebddd933ab633a7f8e9ae3fa733f))

### Documentation

- **#328**: Record lifecycle merge hardening
  ([#338](https://github.com/weijen/agent-delivery-harness/pull/338),
  [`17561ac`](https://github.com/weijen/agent-delivery-harness/commit/17561acf9d45ebddd933ab633a7f8e9ae3fa733f))


## v0.21.0 (2026-07-21)

### Bug Fixes

- **#317**: Close provenance route matrix
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Persist transitioned class fixes
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Require generator failure classes
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Require research provenance
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Support jq 1.6 binding precedence
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

### Documentation

- **#317**: Record research escalation delivery
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

### Features

- Escalate repeated generator failure classes
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Bound generator research
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Measure same-class repeats
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Persist generator class fixes
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Record research provenance
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

- **#317**: Stop repeated point fixes
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))

### Testing

- **#317**: Expand provenance route matrix
  ([#327](https://github.com/weijen/agent-delivery-harness/pull/327),
  [`2e7649e`](https://github.com/weijen/agent-delivery-harness/commit/2e7649e4e298f75a5ce1f8a8db3f88519a76ae72))


## v0.20.1 (2026-07-21)

### Bug Fixes

- Sync Copilot adapter with native records
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))

### Documentation

- **#319**: Add CLI cost review recipes
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))

- **#319**: Document safe subagent permissions
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))

- **#319**: Enumerate Copilot record surfaces
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))

- **#319**: Record Copilot adapter delivery
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))

- **#319**: Version-pin Copilot token metrics
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))

### Testing

- **#319**: Cross-check Copilot record contracts
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))

- **#319**: Follow token metrics heading rename
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))

- **#319**: Satisfy newer ShellCheck indexing
  ([#325](https://github.com/weijen/agent-delivery-harness/pull/325),
  [`aeec4fa`](https://github.com/weijen/agent-delivery-harness/commit/aeec4fa7bcc5452f7f18913076caaaecbe6500d7))


## v0.20.0 (2026-07-21)

### Bug Fixes

- Make review failures attributable and actionable
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

### Documentation

- **#318**: Record review trace delivery
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

### Features

- **#318**: Enforce review trace coherence
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Gate rejects on actionable evidence
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Pin repair verdict scope
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Require attributed review failures
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Track review findings across events
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

### Testing

- **#318**: Group actionability prerequisites
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Group attribution prerequisites
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Group integration prerequisites
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Group repair scope prerequisites
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Isolate attribution fixture git config
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Isolate identity fixture git config
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))

- **#318**: Isolate repair fixture git config
  ([#324](https://github.com/weijen/agent-delivery-harness/pull/324),
  [`05477a1`](https://github.com/weijen/agent-delivery-harness/commit/05477a1093ecdf59aea5a6ba8da281ce5272af23))


## v0.19.0 (2026-07-20)

### Bug Fixes

- Finalize closeout records and delivery economics
  ([#323](https://github.com/weijen/agent-delivery-harness/pull/323),
  [`7c85863`](https://github.com/weijen/agent-delivery-harness/commit/7c858635bfbdd5e8d77f4e698aa299472323c832))

- **#320**: Count logical review events
  ([#323](https://github.com/weijen/agent-delivery-harness/pull/323),
  [`7c85863`](https://github.com/weijen/agent-delivery-harness/commit/7c858635bfbdd5e8d77f4e698aa299472323c832))

### Features

- **#320**: Finalize closeout conclusion
  ([#323](https://github.com/weijen/agent-delivery-harness/pull/323),
  [`7c85863`](https://github.com/weijen/agent-delivery-harness/commit/7c858635bfbdd5e8d77f4e698aa299472323c832))

- **#320**: Finalize closeout records
  ([#323](https://github.com/weijen/agent-delivery-harness/pull/323),
  [`7c85863`](https://github.com/weijen/agent-delivery-harness/commit/7c858635bfbdd5e8d77f4e698aa299472323c832))

- **#320**: Report active delivery time
  ([#323](https://github.com/weijen/agent-delivery-harness/pull/323),
  [`7c85863`](https://github.com/weijen/agent-delivery-harness/commit/7c858635bfbdd5e8d77f4e698aa299472323c832))

### Refactoring

- **#320**: Extract closeout orchestration
  ([#323](https://github.com/weijen/agent-delivery-harness/pull/323),
  [`7c85863`](https://github.com/weijen/agent-delivery-harness/commit/7c858635bfbdd5e8d77f4e698aa299472323c832))

### Testing

- Bound init gate sensor runtime ([#322](https://github.com/weijen/agent-delivery-harness/pull/322),
  [`fa446e6`](https://github.com/weijen/agent-delivery-harness/commit/fa446e651484735374dcdf500bd576c9db90d9e7))

- **#315**: Bound init gate sensor
  ([#322](https://github.com/weijen/agent-delivery-harness/pull/322),
  [`fa446e6`](https://github.com/weijen/agent-delivery-harness/commit/fa446e651484735374dcdf500bd576c9db90d9e7))

- **#315**: Isolate init gate controls
  ([#322](https://github.com/weijen/agent-delivery-harness/pull/322),
  [`fa446e6`](https://github.com/weijen/agent-delivery-harness/commit/fa446e651484735374dcdf500bd576c9db90d9e7))

- **#320**: Align lifecycle fixtures with closeout
  ([#323](https://github.com/weijen/agent-delivery-harness/pull/323),
  [`7c85863`](https://github.com/weijen/agent-delivery-harness/commit/7c858635bfbdd5e8d77f4e698aa299472323c832))

- **#320**: Verify composed closeout ordering
  ([#323](https://github.com/weijen/agent-delivery-harness/pull/323),
  [`7c85863`](https://github.com/weijen/agent-delivery-harness/commit/7c858635bfbdd5e8d77f4e698aa299472323c832))


## v0.18.1 (2026-07-20)

### Bug Fixes

- **#316**: Prevent trace-tools debris
  ([#321](https://github.com/weijen/agent-delivery-harness/pull/321),
  [`81f0819`](https://github.com/weijen/agent-delivery-harness/commit/81f0819a6604618e0f3acbbf21453c16c49f5539))


## v0.18.0 (2026-07-18)

### Bug Fixes

- **#305**: Reconcile launch-topology doctrine and retire seeding contract
  ([#309](https://github.com/weijen/agent-delivery-harness/pull/309),
  [`2e1e0cb`](https://github.com/weijen/agent-delivery-harness/commit/2e1e0cb8a1dd3800eb37df3f0df66578ea3151a1))

### Documentation

- **#305**: Finalize PROGRESS delivery entry and sensor count
  ([#309](https://github.com/weijen/agent-delivery-harness/pull/309),
  [`2e1e0cb`](https://github.com/weijen/agent-delivery-harness/commit/2e1e0cb8a1dd3800eb37df3f0df66578ea3151a1))

### Features

- **#305**: Document the capture kept/retired boundary and Phase-2 gate
  ([#309](https://github.com/weijen/agent-delivery-harness/pull/309),
  [`2e1e0cb`](https://github.com/weijen/agent-delivery-harness/commit/2e1e0cb8a1dd3800eb37df3f0df66578ea3151a1))

- **#305**: Mark runtime capture deprecated in adapter docs
  ([#309](https://github.com/weijen/agent-delivery-harness/pull/309),
  [`2e1e0cb`](https://github.com/weijen/agent-delivery-harness/commit/2e1e0cb8a1dd3800eb37df3f0df66578ea3151a1))

- **#305**: Rescope dark_run to a semantic-spine completeness check
  ([#309](https://github.com/weijen/agent-delivery-harness/pull/309),
  [`2e1e0cb`](https://github.com/weijen/agent-delivery-harness/commit/2e1e0cb8a1dd3800eb37df3f0df66578ea3151a1))

- **#305**: Retire the runtime capture layer (Phase 1), keep the semantic spine
  ([#309](https://github.com/weijen/agent-delivery-harness/pull/309),
  [`2e1e0cb`](https://github.com/weijen/agent-delivery-harness/commit/2e1e0cb8a1dd3800eb37df3f0df66578ea3151a1))

- **#305**: Stop seeding the runtime hook config into worktrees
  ([#309](https://github.com/weijen/agent-delivery-harness/pull/309),
  [`2e1e0cb`](https://github.com/weijen/agent-delivery-harness/commit/2e1e0cb8a1dd3800eb37df3f0df66578ea3151a1))


## v0.17.0 (2026-07-18)

### Bug Fixes

- **#306**: Guard Quantify recipes against orphaned tool calls
  ([#308](https://github.com/weijen/agent-delivery-harness/pull/308),
  [`3aecf38`](https://github.com/weijen/agent-delivery-harness/commit/3aecf380374c6a3f4f37317a9a6892f9f08d2b9f))

### Documentation

- **#306**: Finalize PROGRESS delivery entry and sensor count
  ([#308](https://github.com/weijen/agent-delivery-harness/pull/308),
  [`3aecf38`](https://github.com/weijen/agent-delivery-harness/commit/3aecf380374c6a3f4f37317a9a6892f9f08d2b9f))

### Features

- **#306**: Add Locate/Qualify/Report stages and privacy rules
  ([#308](https://github.com/weijen/agent-delivery-harness/pull/308),
  [`3aecf38`](https://github.com/weijen/agent-delivery-harness/commit/3aecf380374c6a3f4f37317a9a6892f9f08d2b9f))

- **#306**: Add Quantify jq recipes with fixture validation
  ([#308](https://github.com/weijen/agent-delivery-harness/pull/308),
  [`3aecf38`](https://github.com/weijen/agent-delivery-harness/commit/3aecf380374c6a3f4f37317a9a6892f9f08d2b9f))

- **#306**: Copilot-log-review skill — workflow review from Copilot native records
  ([#308](https://github.com/weijen/agent-delivery-harness/pull/308),
  [`3aecf38`](https://github.com/weijen/agent-delivery-harness/commit/3aecf380374c6a3f4f37317a9a6892f9f08d2b9f))

- **#306**: Register copilot-log-review skill (non-audit)
  ([#308](https://github.com/weijen/agent-delivery-harness/pull/308),
  [`3aecf38`](https://github.com/weijen/agent-delivery-harness/commit/3aecf380374c6a3f4f37317a9a6892f9f08d2b9f))


## v0.16.0 (2026-07-18)

### Documentation

- **#303**: Finalize PROGRESS delivery entry and sensor count
  ([#307](https://github.com/weijen/agent-delivery-harness/pull/307),
  [`7eece9a`](https://github.com/weijen/agent-delivery-harness/commit/7eece9a2e003e7ebb8133dc5a4045ae21ae93406))

### Features

- **#303**: Detect missing per-feature review verdict at approve
  ([#307](https://github.com/weijen/agent-delivery-harness/pull/307),
  [`7eece9a`](https://github.com/weijen/agent-delivery-harness/commit/7eece9a2e003e7ebb8133dc5a4045ae21ae93406))

- **#303**: Generator owns per-feature verification; single end-of-issue review
  ([#307](https://github.com/weijen/agent-delivery-harness/pull/307),
  [`7eece9a`](https://github.com/weijen/agent-delivery-harness/commit/7eece9a2e003e7ebb8133dc5a4045ae21ae93406))

- **#303**: Generator pre-handback self-check checklist
  ([#307](https://github.com/weijen/agent-delivery-harness/pull/307),
  [`7eece9a`](https://github.com/weijen/agent-delivery-harness/commit/7eece9a2e003e7ebb8133dc5a4045ae21ae93406))

- **#303**: Review-gate blocks approve on missing verdict
  ([#307](https://github.com/weijen/agent-delivery-harness/pull/307),
  [`7eece9a`](https://github.com/weijen/agent-delivery-harness/commit/7eece9a2e003e7ebb8133dc5a4045ae21ae93406))

- **#303**: Reviewer contract for single end-of-issue review
  ([#307](https://github.com/weijen/agent-delivery-harness/pull/307),
  [`7eece9a`](https://github.com/weijen/agent-delivery-harness/commit/7eece9a2e003e7ebb8133dc5a4045ae21ae93406))

- **#303**: Single end-of-issue review, per-feature verdicts
  ([#307](https://github.com/weijen/agent-delivery-harness/pull/307),
  [`7eece9a`](https://github.com/weijen/agent-delivery-harness/commit/7eece9a2e003e7ebb8133dc5a4045ae21ae93406))


## v0.15.0 (2026-07-18)

### Documentation

- **#299**: Finalize PROGRESS delivery entry and sensor count
  ([#304](https://github.com/weijen/agent-delivery-harness/pull/304),
  [`a51e126`](https://github.com/weijen/agent-delivery-harness/commit/a51e12616276a0269e2a135e9677179a4bd9dc5e))

### Features

- **#299**: Record review mode and reviewed sha on review_verdict spans
  ([#304](https://github.com/weijen/agent-delivery-harness/pull/304),
  [`a51e126`](https://github.com/weijen/agent-delivery-harness/commit/a51e12616276a0269e2a135e9677179a4bd9dc5e))

- **#299**: Review provenance, full-review dedup, and irreversibility-based pre-PR sensor list
  ([#304](https://github.com/weijen/agent-delivery-harness/pull/304),
  [`a51e126`](https://github.com/weijen/agent-delivery-harness/commit/a51e12616276a0269e2a135e9677179a4bd9dc5e))

- **#299**: Scope the pre-PR standalone sensor list by irreversibility
  ([#304](https://github.com/weijen/agent-delivery-harness/pull/304),
  [`a51e126`](https://github.com/weijen/agent-delivery-harness/commit/a51e12616276a0269e2a135e9677179a4bd9dc5e))

- **#299**: Warn on duplicate full-mode reviews of the same sha
  ([#304](https://github.com/weijen/agent-delivery-harness/pull/304),
  [`a51e126`](https://github.com/weijen/agent-delivery-harness/commit/a51e12616276a0269e2a135e9677179a4bd9dc5e))

- **#299**: Warn when a review verdict drops instruction-file provenance
  ([#304](https://github.com/weijen/agent-delivery-harness/pull/304),
  [`a51e126`](https://github.com/weijen/agent-delivery-harness/commit/a51e12616276a0269e2a135e9677179a4bd9dc5e))


## v0.14.0 (2026-07-18)

### Documentation

- **#300**: Enumerate repair in the code-review-subagent description
  ([#302](https://github.com/weijen/agent-delivery-harness/pull/302),
  [`09c702c`](https://github.com/weijen/agent-delivery-harness/commit/09c702cb768520eeebeb16ed7654c324ff10fc5f))

- **#300**: Record #300 delivery in PROGRESS.md
  ([#302](https://github.com/weijen/agent-delivery-harness/pull/302),
  [`09c702c`](https://github.com/weijen/agent-delivery-harness/commit/09c702cb768520eeebeb16ed7654c324ff10fc5f))

### Features

- **#300**: Add repair review profile that skips the whole-diff skill battery
  ([#302](https://github.com/weijen/agent-delivery-harness/pull/302),
  [`09c702c`](https://github.com/weijen/agent-delivery-harness/commit/09c702cb768520eeebeb16ed7654c324ff10fc5f))

- **#300**: Detect 3+ review rejections per feature in trace consistency
  ([#302](https://github.com/weijen/agent-delivery-harness/pull/302),
  [`09c702c`](https://github.com/weijen/agent-delivery-harness/commit/09c702cb768520eeebeb16ed7654c324ff10fc5f))

- **#300**: Hard-block the review gate on the 3-rejection cap
  ([#302](https://github.com/weijen/agent-delivery-harness/pull/302),
  [`09c702c`](https://github.com/weijen/agent-delivery-harness/commit/09c702cb768520eeebeb16ed7654c324ff10fc5f))

- **#300**: Record injected instruction files per handback
  ([#302](https://github.com/weijen/agent-delivery-harness/pull/302),
  [`09c702c`](https://github.com/weijen/agent-delivery-harness/commit/09c702cb768520eeebeb16ed7654c324ff10fc5f))

- **#300**: Repair-loop context control + 3-rejection stop rule
  ([#302](https://github.com/weijen/agent-delivery-harness/pull/302),
  [`09c702c`](https://github.com/weijen/agent-delivery-harness/commit/09c702cb768520eeebeb16ed7654c324ff10fc5f))


## v0.13.0 (2026-07-18)

### Bug Fixes

- **#65**: Handle YAML description forms
  ([#301](https://github.com/weijen/agent-delivery-harness/pull/301),
  [`6c98027`](https://github.com/weijen/agent-delivery-harness/commit/6c98027773a976c253e56dbb3f9c47d28bf90f5b))

### Continuous Integration

- **#65**: Share frontmatter validation
  ([#301](https://github.com/weijen/agent-delivery-harness/pull/301),
  [`6c98027`](https://github.com/weijen/agent-delivery-harness/commit/6c98027773a976c253e56dbb3f9c47d28bf90f5b))

### Documentation

- **#65**: Record frontmatter lint delivery
  ([#301](https://github.com/weijen/agent-delivery-harness/pull/301),
  [`6c98027`](https://github.com/weijen/agent-delivery-harness/commit/6c98027773a976c253e56dbb3f9c47d28bf90f5b))

- **#65**: Record pull request number
  ([#301](https://github.com/weijen/agent-delivery-harness/pull/301),
  [`6c98027`](https://github.com/weijen/agent-delivery-harness/commit/6c98027773a976c253e56dbb3f9c47d28bf90f5b))

### Features

- Validate customization frontmatter
  ([#301](https://github.com/weijen/agent-delivery-harness/pull/301),
  [`6c98027`](https://github.com/weijen/agent-delivery-harness/commit/6c98027773a976c253e56dbb3f9c47d28bf90f5b))

- **#65**: Validate customization frontmatter
  ([#301](https://github.com/weijen/agent-delivery-harness/pull/301),
  [`6c98027`](https://github.com/weijen/agent-delivery-harness/commit/6c98027773a976c253e56dbb3f9c47d28bf90f5b))


## v0.12.0 (2026-07-18)

### Bug Fixes

- **#296**: Avoid meta-test SIGPIPE
  ([#297](https://github.com/weijen/agent-delivery-harness/pull/297),
  [`7274d51`](https://github.com/weijen/agent-delivery-harness/commit/7274d51cea4eae5292eabe03e715b025efd06fc7))

### Documentation

- **#296**: Close generator delivery
  ([#297](https://github.com/weijen/agent-delivery-harness/pull/297),
  [`7274d51`](https://github.com/weijen/agent-delivery-harness/commit/7274d51cea4eae5292eabe03e715b025efd06fc7))

### Features

- Unify per-feature generator workflow
  ([#297](https://github.com/weijen/agent-delivery-harness/pull/297),
  [`7274d51`](https://github.com/weijen/agent-delivery-harness/commit/7274d51cea4eae5292eabe03e715b025efd06fc7))

- **#296**: Add adversarial review tests
  ([#297](https://github.com/weijen/agent-delivery-harness/pull/297),
  [`7274d51`](https://github.com/weijen/agent-delivery-harness/commit/7274d51cea4eae5292eabe03e715b025efd06fc7))

- **#296**: Instrument generator experiment
  ([#297](https://github.com/weijen/agent-delivery-harness/pull/297),
  [`7274d51`](https://github.com/weijen/agent-delivery-harness/commit/7274d51cea4eae5292eabe03e715b025efd06fc7))

- **#296**: Merge generator roles
  ([#297](https://github.com/weijen/agent-delivery-harness/pull/297),
  [`7274d51`](https://github.com/weijen/agent-delivery-harness/commit/7274d51cea4eae5292eabe03e715b025efd06fc7))

- **#296**: Support generator traces
  ([#297](https://github.com/weijen/agent-delivery-harness/pull/297),
  [`7274d51`](https://github.com/weijen/agent-delivery-harness/commit/7274d51cea4eae5292eabe03e715b025efd06fc7))


## v0.11.4 (2026-07-17)

### Bug Fixes

- **#294**: Install runtime dependencies
  ([#295](https://github.com/weijen/agent-delivery-harness/pull/295),
  [`4c925f9`](https://github.com/weijen/agent-delivery-harness/commit/4c925f9a774a5a568ba30b854caa3b5ea73502ff))

### Chores

- Sync uv.lock to 0.11.2; add tracing/observability journey docs
  ([`ce852bd`](https://github.com/weijen/agent-delivery-harness/commit/ce852bdf7374f62fe40cc41693a823823ec73835))

- Sync uv.lock to 0.11.3
  ([`1c18673`](https://github.com/weijen/agent-delivery-harness/commit/1c1867349d9766d8e8faaecb1216c59c6b040653))


## v0.11.3 (2026-07-11)

### Bug Fixes

- **#291**: Block missing feature starts
  ([#293](https://github.com/weijen/agent-delivery-harness/pull/293),
  [`c842b9d`](https://github.com/weijen/agent-delivery-harness/commit/c842b9da0942f36eb6f0a05f9bbc80b6f2c308da))

- **#291**: Clarify evidence gate guidance
  ([#293](https://github.com/weijen/agent-delivery-harness/pull/293),
  [`c842b9d`](https://github.com/weijen/agent-delivery-harness/commit/c842b9da0942f36eb6f0a05f9bbc80b6f2c308da))

- **#291**: Enforce feature start evidence
  ([#293](https://github.com/weijen/agent-delivery-harness/pull/293),
  [`c842b9d`](https://github.com/weijen/agent-delivery-harness/commit/c842b9da0942f36eb6f0a05f9bbc80b6f2c308da))

- **#291**: Require feature start evidence
  ([#293](https://github.com/weijen/agent-delivery-harness/pull/293),
  [`c842b9d`](https://github.com/weijen/agent-delivery-harness/commit/c842b9da0942f36eb6f0a05f9bbc80b6f2c308da))

### Documentation

- **#291**: Define feature start contract
  ([#293](https://github.com/weijen/agent-delivery-harness/pull/293),
  [`c842b9d`](https://github.com/weijen/agent-delivery-harness/commit/c842b9da0942f36eb6f0a05f9bbc80b6f2c308da))


## v0.11.2 (2026-07-11)

### Bug Fixes

- **#290**: Preserve action log after teardown
  ([#292](https://github.com/weijen/agent-delivery-harness/pull/292),
  [`01fe591`](https://github.com/weijen/agent-delivery-harness/commit/01fe591e22a8a724ca4780845f407fa24f2fa37c))

### Documentation

- **#290**: Document action log survival
  ([#292](https://github.com/weijen/agent-delivery-harness/pull/292),
  [`01fe591`](https://github.com/weijen/agent-delivery-harness/commit/01fe591e22a8a724ca4780845f407fa24f2fa37c))

- **#290**: Record action log survival delivery
  ([#292](https://github.com/weijen/agent-delivery-harness/pull/292),
  [`01fe591`](https://github.com/weijen/agent-delivery-harness/commit/01fe591e22a8a724ca4780845f407fa24f2fa37c))


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
