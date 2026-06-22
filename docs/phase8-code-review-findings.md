# Phase 8 Code Review - Findings Worklist

**Scope:** `git diff main...phase8` on branch `phase8`
(`9d51c9efbf16984cb58455572ab82084a3fa8551` as merge base; 236 files,
about 28.4k insertions).
**Method:** 10 parallel review lanes plus lead consolidation, focused on
phase8 settings/onboarding, live composition, ingest/persistence, alerts,
fleet/provisioning, visualization, and gates.
**Generated:** 2026-06-22.
**Verification:** `git diff --check main...phase8` clean. `make verify` passed
731 tests with coverage above floor, protobuf reproducibility, perf, and secret
scan green. The mutation gate skipped locally because `muter` or
`muter.conf.yml` is absent.

Work top-down. Every behavioral fix should ship with a test, and process/gate
fixes should update the relevant check so `make verify` or CI catches the
regression next time.

---

## P1 - Live Behavior And Data Correctness

### [x] 1. Settings save does not trigger the claimed live reconnect
- **Where:** `Sources/MeshtrackApp/MeshtrackApp.swift:222`,
  `Sources/App/Settings/ConnectionSettingsView.swift:204`,
  `Sources/App/Settings/ConnectionSettingsViewModel.swift:183`
- **Bug:** `ContentView` resolves and applies the saved source once from
  `.task { await resolveAndApply() }`. The Settings save path persists broker,
  password, and data-source edits, but nothing notifies `ContentView` to call
  `resolveAndApply()` again.
- **Failure:** A first-run user can save a connectable broker and remain on
  onboarding until relaunch. Changing broker/topic/source while live also does
  not restart the coordinator even though the plan/progress claim
  reconnect-on-change.
- **Fix/test:** Add a config-change callback, revision token, notification, or
  shared observable state that triggers `resolveAndApply()` after save. Test that
  saving a broker from onboarding starts `LiveCoordinator` without relaunch, and
  that changing the active source restarts the stream.

### [x] 2. `autoConnect` and refresh interval settings are ignored by runtime startup
- **Where:** `Sources/Domain/AppConfig.swift:53`, `Sources/Domain/AppConfig.swift:65`,
  `Sources/App/Settings/GeneralSettingsView.swift:151`,
  `Sources/MeshtrackApp/MeshtrackApp.swift:251`, `Sources/MeshtrackApp/MeshtrackApp.swift:261`
- **Bug:** The UI persists `AppSettings.autoConnect` and
  `refreshIntervalSeconds`, but startup only reads broker/data-source config.
  `LiveCoordinator` is always created with its default 3-second refresh cadence.
- **Failure:** `autoConnect = false` still connects on launch, and changing the
  refresh interval has no effect on the live loop.
- **Fix/test:** Load `AppSettings` during `resolveAndApply()`. If auto-connect is
  disabled, leave the app offline until an explicit connect action. Pass the saved
  refresh interval into `LiveCoordinator`. Add tests for disabled auto-connect and
  custom refresh cadence.

### [x] 3. General and Alerts settings views can overwrite persisted values with defaults
- **Where:** `Sources/MeshtrackApp/MeshtrackApp.swift:167`,
  `Sources/MeshtrackApp/MeshtrackApp.swift:173`,
  `Sources/App/Settings/GeneralSettingsView.swift:20`,
  `Sources/App/Settings/AlertsConfigView.swift:19`
- **Bug:** The production settings registration creates fresh General and Alerts
  view models, but those views do not call `load()` in their body. Connection and
  Channels views do self-load, so this is inconsistent.
- **Failure:** Opening General or Alert rules can show defaults/empty state even
  when values exist in the store. Pressing Save can overwrite persisted settings
  or alert rules with default model state.
- **Fix/test:** Load these view models in `.task`, or pre-load them at
  registration. Add integration tests that seed non-default `AppSettings` and
  alert rules, open the production settings tab, and verify the rendered model is
  populated before Save.

### [x] 4. Live ingest records receive latency as zero
- **Where:** `Sources/Ingest/PacketDecoder.swift:70`,
  `Sources/Ingest/IngestPipeline.swift:125`, `Sources/Ingest/IngestPipeline.swift:131`,
  `Sources/MeshProtos/mesh.pb.swift:2718`
- **Bug:** `DecodedPacket.rxTime` is set to the frame receipt time instead of the
  protobuf `MeshPacket.rxTime`. The pipeline then stores `observation.rx_time`
  from `packet.rxTime` and `ingest_time` from `frame.receivedAt`, which are the
  same value in live decode.
- **Failure:** SPEC latency metrics and packet inspector latency are effectively
  zero for live traffic, hiding gateway/broker delay.
- **Fix/test:** Decode nonzero `MeshPacket.rxTime` into `DecodedPacket.rxTime`
  and keep `frame.receivedAt` for `ingest_time`. Add an ingest test with packet
  rx time at 100s and frame receipt at 105s asserting 5s latency.

### [x] 5. Permanent extraction unique indexes violate the sliding-window dedup contract
- **Where:** `Sources/Persistence/Migrations.swift:282`,
  `Sources/Persistence/Migrations.swift:306`,
  `Sources/Persistence/Store.swift:184`, `Sources/Persistence/Store.swift:224`,
  `Sources/Persistence/Store.swift:236`
- **Bug:** Schema v5 dedupes and then permanently unique-indexes
  `message(packet_id, from_num)`, `telemetry(node_num, t, kind, key)`, and
  `position_fix(node_num, t)`. `insert(onConflict: .ignore)` then silently drops
  every future row with the same coarse key.
- **Failure:** SPEC says packet dedup is `(packet_id, from_num)` within a sliding
  10-minute window. Legitimate packet-id reuse after the window, or two distinct
  fixes/samples sharing the coarse natural key, can be lost forever. Migration v5
  can also delete historical rows that are distinct outside the intended window.
- **Fix/test:** Persist a bounded dedup ledger with expiry, or make extraction
  uniqueness include enough payload/time/provenance to identify exact duplicates.
  Add tests that same `(packet_id, from_num)` inside 600s dedups across reconnect,
  but the same key after 601s records a new extraction.

### [x] 6. Ownership-sensitive alert defaults still treat unknown nodes as managed
- **Where:** `Sources/Domain/NodeManagement.swift:17`,
  `Sources/RuleEngine/RuleEvaluator.swift:67`,
  `Sources/Scenario/ScenarioModel.swift:113`,
  `Sources/Scenario/ScenarioParser.swift:57`
- **Bug:** Domain defaults new nodes to unmanaged, but `RuleEvaluator.conditions`
  defaults omitted management to managed, and scenarios default omitted `managed`
  to true.
- **Failure:** Any production or scenario caller that omits management can fire
  stale/battery/voltage alerts for unclassified stranger nodes, contrary to SPEC
  section 2.10 and ADR 0008.
- **Fix/test:** Remove the managed default or default to `.unowned`. Update
  scenarios that intentionally represent owned nodes to state `managed: true`.
  Add a scenario test where omitted `managed` and `silence_hours` produce no stale
  alert.

### [x] 7. Alert rules are configurable, but no live rule-generation loop exists
- **Where:** `Sources/RuleEngine/RuleEvaluator.swift:63`,
  `Sources/Scenario/LivenessScenarioEvaluator.swift:47`,
  `Sources/App/Alerts/AlertsConsoleViewModel.swift:104`,
  `Sources/App/Alerts/AlertsStore.swift:36`
- **Bug:** `RuleEvaluator.conditions` is only called by tests/scenario code.
  The running app rehydrates and mutates persisted `alert` rows, but no live path
  evaluates telemetry/liveness snapshots through `RuleEvaluator -> AlertEngine`
  and saves resulting alerts.
- **Failure:** Operators can configure alert rules and view the console, but live
  battery/stale/voltage alerts are never generated from incoming traffic.
- **Fix/test:** Add a live alert evaluator job wired to store snapshots,
  `AlertRuleStore`, node management classification, `RuleEvaluator`, and
  `AlertEngine`, then persist `AlertRecord`s. Add a live-composition test that
  seeded stale telemetry plus an enabled rule creates a console alert.

### [x] 8. Fleet/provision apply paths are store-backed, not over-the-air admin
- **Where:** `Sources/App/AppComposition.swift:59`,
  `Sources/App/AppComposition.swift:62`,
  `Sources/App/Provisioning/ProvisioningWorkflowFactory.swift:29`,
  `Sources/App/Fleet/StoreBackedAdminChannel.swift:8`
- **Bug:** The live Fleet and Provision sections wire `StoreBackedAdminChannel`.
  Its comments acknowledge the authoritative radio admin adapter is still the
  remaining HIL step, but the UI labels these paths as apply/verify flows.
- **Failure:** "Apply" can update Meshtrack's database and verify against the same
  database without sending a remote admin message or reading back a real node
  config. Remote admin support required by SPEC section 10 is not exercised.
- **Fix/test:** Wire an `AdminTransport`/`MeshAdminChannel` for live apply, or
  disable/label the current UI as local-record-only. Add a spy transport test that
  the production composition sends admin messages and verifies read-back.

### [x] 9. Rollout abort does not cooperatively stop later node applies
- **Where:** `Sources/App/Fleet/FleetRolloutViewModel.swift:212`,
  `Sources/App/Fleet/FleetRolloutViewModel.swift:232`,
  `Sources/Provisioning/FleetApplier.swift:73`
- **Bug:** `abort()` cancels the wrapper task and updates UI state, but
  `FleetApplier.rollOut` never checks cancellation before or after each member,
  and `advance(after:)` still mutates rows regardless of the view model phase.
- **Failure:** If the underlying apply path does not observe cancellation, an
  aborted rollout can continue to apply later nodes and then update row status
  after the UI says aborted.
- **Fix/test:** Check `Task.isCancelled` or call `Task.checkCancellation()` before
  each node and before progress callbacks. Guard `advance(after:)` on
  `phase == .rolling`. Add a test with a slow fake channel: abort during node 1
  and assert node 2 is never applied.

### [x] 10. Position-precision admin message can wipe the primary channel settings
- **Where:** `Sources/Provisioning/AdminMessageMapping.swift:205`,
  `Sources/Provisioning/AdminMessageMapping.swift:211`,
  `Sources/Provisioning/AdminMessageMapping.swift:216`
- **Bug:** A precision-only update builds a fresh `ChannelSettings` containing only
  `moduleSettings.positionPrecision`, then sends it as `setChannel` for the primary
  channel.
- **Failure:** If firmware treats `setChannel` as replacement rather than merge,
  the update can clear channel name, PSK/index settings, uplink/downlink flags, or
  other primary-channel fields while verification only checks precision.
- **Fix/test:** Perform a read-modify-write that preserves existing
  `ChannelSettings`, or prove via a transport-level fake that firmware merges this
  message. Add a test with a seeded primary channel where precision changes and
  existing settings survive.

---

## P2 - Settings, Alerts, And UI Composition

### [x] 11. Stale alert thresholds are edited as hours but evaluated as seconds
- **Where:** `Sources/App/Settings/AlertsConfigStore.swift:32`,
  `Sources/App/Settings/AlertsConfigStore.swift:41`,
  `Sources/MeshtrackApp/Integration.swift:75`,
  `Sources/MeshtrackApp/Integration.swift:115`,
  `Sources/RuleEngine/RuleEvaluator.swift:92`
- **Bug:** The Alerts settings UI displays stale thresholds in hours and defaults
  to 24, but `MeshStoreAlertRuleStore` persists that raw value. The rule engine
  compares silence seconds directly to the threshold.
- **Failure:** A user-entered 24-hour stale rule fires after 24 seconds.
- **Fix/test:** Convert hours to seconds at the App/Persistence boundary, or store
  canonical seconds and convert only for display. Add a test that the 24h UI value
  evaluates as 86,400 seconds and round-trips back to 24h in the editor.

### [x] 12. Alert console ignores the persisted default snooze
- **Where:** `Sources/MeshtrackApp/Integration.swift:87`,
  `Sources/App/AppComposition.swift:118`
- **Bug:** Phase8 now persists the default snooze in `app_config`, but the live
  alert console still hardcodes `alerts.snooze(item, forSeconds: 3600)`.
- **Failure:** Changing the default snooze in Settings has no effect on the
  console's Snooze action.
- **Fix/test:** Load/inject the default snooze duration into `AlertsSectionView` or
  `AlertsConsoleViewModel`. Test that a saved 900-second default snoozes an alert
  to now plus 900 seconds.

### [x] 13. Alert cooldown is lost when persisted alerts are rehydrated
- **Where:** `Sources/App/Alerts/AlertsConsoleViewModel.swift:223`,
  `Sources/App/Alerts/AlertsConsoleViewModel.swift:232`,
  `Sources/RuleEngine/AlertEngine.swift:112`,
  `Sources/Persistence/Records.swift:271`
- **Bug:** Rehydration rebuilds every `AlertCondition` with `cooldownSeconds: 0`,
  and `AlertRecord` has no cooldown column or payload field.
- **Failure:** After relaunch/reload, a resolved alert can refire immediately even
  if its original rule had a cooldown.
- **Fix/test:** Persist cooldown in `payload_json` or rehydrate from the matching
  rule definition. Add a test where a resolved alert with a 1-hour cooldown remains
  suppressed after reload.

### [x] 14. MQTT channel capacity contradicts the project decision
- **Where:** `SPEC.md:263`, `Sources/App/Settings/ChannelsSettingsViewModel.swift:25`,
  `Sources/App/Settings/ChannelsSettingsViewModel.swift:30`,
  `Tests/AppTests/ChannelsSettingsViewModelTests.swift:157`
- **Bug:** SPEC and AGENTS say up to 20 MQTT channels and 7 local channels, but the
  view model treats MQTT as uncapped and the test suite asserts that the 21st MQTT
  channel is allowed.
- **Failure:** The UI and tests lock in behavior contrary to the source-of-truth
  product decision.
- **Fix/test:** Cap MQTT at 20, show a finite capacity label, and update tests so
  the 21st MQTT channel is rejected. If the product decision changed, update SPEC
  and add an ADR first.

### [x] 15. Normal custom-PSK channel flow stores the key under the wrong hash
- **Where:** `Sources/App/Settings/ChannelsSettingsViewModel.swift:254`,
  `Sources/App/Settings/ChannelsSettingsViewModel.swift:269`,
  `Sources/App/Settings/ChannelsSettingsViewModel.swift:302`,
  `Sources/App/MeshtasticChannelHash.swift:33`
- **Bug:** Adding a channel by name derives the hash with the default PSK. Setting
  a custom PSK later stores that PSK under the already-created default-PSK hash.
- **Failure:** For a real custom-PSK channel, the on-wire hash is derived from the
  custom PSK, so live decrypt lookup misses unless the user manually supplies the
  observed hash.
- **Fix/test:** Either require/derive the hash from the entered PSK in the normal
  custom-key flow, or make the UI explicit that custom PSKs require an observed
  hash. Add a test for "add named custom channel, set PSK, decode packet with
  custom-derived hash".

### [x] 16. Removing the default channel does not stop default-key decoding
- **Where:** `Sources/App/ChannelKeyResolver.swift:38`,
  `Sources/MeshtrackApp/Integration.swift:170`,
  `Sources/MeshtrackApp/Integration.swift:199`
- **Bug:** `ChannelKeyResolver` returns the default PSK for any channel hash absent
  from the registry. Removing or clearing the default channel deletes the stored
  key/registry row, but the live decoder still falls back to the default key.
- **Failure:** The operator can remove a channel from Settings and still decode
  default-key traffic for that hash. Across a new manager/app launch, an empty
  registry can also be seeded again as the default channel.
- **Fix/test:** Make default fallback registry-aware, or add a persisted tombstone
  for deleted defaults. Test clear/delete in the same session and after
  reconstructing `KeychainChannelManager`.

### [x] 17. Packet inspector, analytics, VCR, and command palette are not live-wired
- **Where:** `Sources/App/AppComposition.swift:37`,
  `Sources/App/AppComposition.swift:45`,
  `Sources/App/Analytics/NodeAnalyticsView.swift:31`,
  `Sources/App/Analytics/NodeAnalyticsViewModel.swift:97`,
  `Sources/App/Timeline/VCRControlView.swift:64`,
  `Sources/App/Search/SearchPaletteView.swift:124`,
  `Sources/MeshtrackApp/MeshtrackApp.swift:298`
- **Bug:** The live Packet Inspector still uses `PacketInspectorSample.viewModel()`.
  Analytics views load only headers; their observation/packet seams are not fed by
  production composition. VCR controls and the command palette exist but are not
  attached to `RootView` in `LiveRootView`.
- **Failure:** Several phase8-visible app sections are either sample data, empty,
  or unreachable in the real app.
- **Fix/test:** Create shared live packet/observation/search/timeline models and
  feed them from `LiveCoordinator` or store-backed polling. Add a composition test
  that live sections do not use sample models and that VCR/search controls are
  reachable from the root.

### [x] 18. Messages view loads once and channel names can stay stale
- **Where:** `Sources/App/Messages/ChannelsView.swift:27`,
  `Sources/App/Messages/ChannelsViewModel.swift:182`,
  `Sources/App/Messages/ChannelsViewModel.swift:186`,
  `Sources/Ingest/IngestPipeline.swift:282`
- **Bug:** `ChannelsView` calls `load()` only once. Live ingest persists new
  messages, but no stream, notification, or polling path refreshes the view. The
  channel label is also derived from `rows.first` after sorting oldest-first.
- **Failure:** Messages decoded while the view is open may not appear until the
  view is recreated. If an old row lacked a channel name but a newer row has one,
  the sidebar can keep the stale unnamed/hash label.
- **Fix/test:** Add live refresh or store observation for messages. Derive channel
  labels from the newest non-empty name. Test that a loaded `ChannelsViewModel`
  updates after `recordMessage` and prefers the newer channel name.

### [x] 19. Node directory detail actions are exposed but default to no-op callbacks
- **Where:** `Sources/App/AppComposition.swift:34`,
  `Sources/App/Nodes/NodeDirectoryView.swift:26`,
  `Sources/App/Nodes/NodeDirectoryDetailView.swift:107`,
  `Sources/App/Nodes/NodeDirectoryDetailView.swift:238`
- **Bug:** The live composition constructs `NodeDirectoryView(viewModel:)` without
  `onApply` or `onOpenAnalytics` callbacks. The detail view still renders "Open
  analytics" and "Apply via verified rolling update" buttons.
- **Failure:** Users can click visible actions that do nothing.
- **Fix/test:** Wire the callbacks to app navigation and verified rollout, or hide
  the buttons until callbacks are supplied. Add a composition test that each
  visible action has a non-default handler.

### [x] 20. Channel filter assigns old traces to the source node's latest channel
- **Where:** `Sources/App/NetworkViewModel.swift:78`,
  `Sources/App/Map/ChannelFilter.swift:42`,
  `Sources/App/Visualization/NetworkModels.swift:71`
- **Bug:** Packet traces do not store their own channel or preset. Filtering traces
  by channel uses the source node's current preset, which is overwritten whenever
  that node later sends on a different preset.
- **Failure:** Historical traces can move between filters when the source node
  transmits on another channel.
- **Fix/test:** Add immutable channel/preset metadata to `PacketTrace` at ingest
  time and filter on that. Test two packets from the same source on different
  channels and verify each remains under its original filter.

---

## P3 - Process, Packaging, And Contract Drift

### [x] 21. Mutation floor is declared, but `make verify` accepts a skipped mutation gate
- **Where:** `scoreboard.json:6`, `scoreboard.json:11`, `Makefile:54`,
  `.github/workflows/verify.yml:31`
- **Bug:** The scoreboard requires `mutation_min_score = 60`, but local metrics
  report `mutation_score: null`. `make mutation` exits successfully when `muter`
  or `muter.conf.yml` is absent, and the CI workflow only says `make verify` will
  enforce all gates.
- **Failure:** A missing Muter config/toolchain can produce "all gates green" while
  the mutation floor is not measured.
- **Fix/test:** Commit `muter.conf.yml`, install/verify Muter in CI, and make the
  mutation target fail under `CI=true` when the tool/config is missing or score is
  below the scoreboard floor. Update the scoreboard metric after a real run.

### [x] 22. App package and generated bundle advertise macOS 26.0, not 26.6
- **Where:** `SPEC.md:270`, `Package.swift:13`, `scripts/make-app.sh:52`
- **Bug:** The source-of-truth platform floor is macOS 26.6, but SwiftPM and the
  generated app bundle both declare 26.0.
- **Failure:** Build/install paths can claim support for 26.0-26.5 even though the
  project decision is latest macOS 26.6.
- **Fix/test:** Set both SwiftPM and generated `LSMinimumSystemVersion` to 26.6.
  Add a lightweight script or test that validates package/platform and generated
  plist values against SPEC section 10.

### [x] 23. Data-source selection is UserDefaults-only despite the shared-store contract
- **Where:** `IMPLEMENTATION_PLAN.md:163`,
  `Sources/App/Settings/DataSourceConfig.swift:12`,
  `Sources/MeshtrackApp/MeshtrackApp.swift:65`
- **Bug:** Phase8 says non-secret config persists in the shared store, but the
  active MQTT/serial/BLE source selection is backed by `UserDefaultsDataSourceStore`.
- **Failure:** The shared GRDB/XPC store is not the single source of truth for local
  node source selection, so the app and daemon can diverge.
- **Fix/test:** Move data-source config behind `ConfigGateway`/`MeshStore`
  `app_config`, or update SPEC/plan to mark it intentionally app-local. Add a
  persistence test for the chosen contract.

---

## Considered And Dropped

- `LiveCoordinator.markConnected(host:)` host shadowing was not re-filed. The
  existing phase7 worklist already refuted this as a Swift pattern-match compare,
  and the current code still matches that form.
- `StoreBackedAdminChannel` duplicate-field trap was not re-filed. Current code
  uses `Dictionary(..., uniquingKeysWith: { $1 })`.
- Message ordering by equal `rx_time` was not re-filed. Current store queries use
  an `id` tie-breaker.

---

## Resolution notes (phase 9)

All 23 findings fixed on branch `phase9` (7 parallel wave-1 agents for the leaf
logic + 1 composition agent for the live wiring + lead docs/integration). Two items
are wired but retain a deliberate, documented seam:

- **#8 (OTA admin).** Per decision, the full OTA path is wired into the live
  composition: Fleet/Provision → `OTAAdminChannelFactory` → `MeshAdminChannel` →
  `LiveAdminTransport` → `AdminLink` (no more same-DB echo; the protocol is
  spy-tested). The single remaining seam is the concrete `LiveAdminLink.exchange`,
  which throws `AdminTransportError.notConnected` because `Transport/MeshTransport`
  is inbound-only — the outbound radio link is genuine hardware-in-the-loop work.
- **#17 (live-wire sections).** Packet inspector, latency overlay, ⌘K palette, and
  the VCR transport (over a live 24h `TimelineViewModel`) are wired to real data.
  *Deferred:* review-mode scrubbing drives the timeline VM but the map still renders
  live nodes — feeding a reconstructed replay frame into `MeshMapSection` needs a new
  map data-source input that doesn't exist yet.

- **#14 (MQTT cap).** Resolved as "keep uncapped" — SPEC §10.2/AGENTS updated and
  ADR 0009 added; the code/tests already matched (uncapped MQTT, 7 local).
