# Phase 7 Code Review — Findings Worklist

**Scope:** `git diff main...HEAD` on branch `phase7` (213 files, ~26.7k insertions).
**Method:** max-effort local review — 10 finder angles + gap sweep, each surviving
candidate verified against source.
**Generated:** 2026-06-21

Work top-down: 🔴 High → 🟠 Medium → 🟡 Low → 🧹 Cleanup. Every behavioral fix
should ship with a test (per `AGENTS.md`), since the recurring theme below is that
in-memory fakes mask divergence from real behavior.

---

## 🔴 High

### [x] 1. Ownership-based alert suppression is inert in the running app
- **Where:** `Sources/RuleEngine/RuleEvaluator.swift:67`; caller `Sources/Scenario/LivenessScenarioEvaluator.swift:30`
- **Bug:** The new `management` gate (ADR 0008 — "never raise battery/silence
  alerts for strangers' nodes") defaults to `NodeManagement(isManaged: true)`, and
  the only production caller omits the argument, taking the managed default.
  `AlertsConsoleViewModel.deriveSuppressed` only renders a *label*.
- **Failure:** Stale/battery/voltage alerts still fire for unmanaged nodes — the
  exact behavior the ADR forbids. `ManagedSuppressionTests` passes but the gate is
  never wired into the live alert path.
- **Fix:** Thread each node's real `is_managed` classification (already in the store
  via `MeshStore.isManaged`/`managedNodeNums`) through `LivenessScenarioEvaluator`
  into `RuleEvaluator.conditions(…, management:)`. Add a test that an unmanaged node
  with a low battery produces no condition through the *production* path.

### [x] 2. Extraction "count-once" doesn't survive a reconnect → duplicate messages & double-counted telemetry
- **Where:** `Sources/Ingest/IngestPipeline.swift:53` (per-run `DedupWindow`);
  schema `Sources/Persistence/Migrations.swift:78` (message), `:194` (telemetry),
  `:175` (position_fix); gateway-scoped observation index `:162`
- **Bug:** `DedupWindow` is in-memory and recreated on every `run()`, and
  `LiveCoordinator` starts a fresh pipeline per reconnect/config change. The
  message/telemetry/position tables have **no unique index**, while observation
  dedup is gateway-scoped. A packet re-delivered via a *different gateway* after a
  reconnect passes observation dedup, the fresh window admits it, and the row is
  inserted again.
- **Failure:** Duplicate chat lines in the Channels view; double-counted telemetry
  points and position fixes in analytics/charts. Multi-gateway bridging is the norm
  on Meshtastic MQTT and reconnect-on-change is a headline feature.
- **Fix:** Make extraction idempotent at the store layer — e.g. a unique index on
  `message(packet_id, from_num)` and on telemetry/position natural keys with
  `INSERT OR IGNORE` — rather than relying on the volatile in-memory window. Add a
  reconnect-then-redeliver test.

---

## 🟠 Medium

### [x] 3. `position_precision` is mis-encoded into the `positionFlags` bitfield
- **Where:** `Sources/Provisioning/AdminMessageMapping.swift:182` (encode), `:91` (read-back)
- **Bug:** `position.positionFlags = UInt32(precision.value) ?? 0` writes the
  operator's precision *bit count* as the entire `positionFlags` value, and
  `snapshot` reads it back the same way. `positionFlags` is a boolean bitfield
  (altitude/DOP/sats/…), not a precision scalar.
- **Failure:** Round-trips only against the echo fake transport. Against real
  firmware the value is applied as the wrong flags AND read-back ≠ entered
  precision, so `AdminApplier` verification fails. Latent until OTA `AdminTransport`
  is wired, but the mapping is wrong now and tests only pass because the fake echoes.
- **Fix:** Map precision to the correct firmware field (channel module
  `position_precision`, or the precision sub-field of `positionFlags`), and make the
  fake transport stop echoing verbatim so the test exercises the real codec.

### [x] 4. Analytics histogram traps on a non-finite SNR/RSSI
- **Where:** `Sources/App/Analytics/NodeAnalyticsAggregations.swift:83`
- **Bug:** `Int((value - low) / width)` — `Int(NaN)`/`Int(.infinity)` is a runtime
  trap, and NaN defeats the `index < 0` / `index >= binCount` clamps (both compare
  false).
- **Failure:** A single NaN/Inf sample reaching `distribution(of:)` crashes the
  analytics view. DB likely coerces NaN→NULL, so the live-ingest seam feeding a raw
  decoded SNR is the realistic trigger.
- **Fix:** Filter `value.isFinite` at the top of `distribution(of:)` (or in the
  `compactMap` feeders). Add a NaN-sample test.

### [x] 5. `StoreBackedAdminChannel.apply` skips the validation its sibling runs
- **Where:** `Sources/App/Fleet/StoreBackedAdminChannel.swift:43` vs `Sources/Provisioning/MeshAdminChannel.swift:56`
- **Bug:** The GUI-wired admin channel persists changes without
  `AdminMessageMapping.validate(_:)`; `MeshAdminChannel.apply` validates first.
- **Failure:** A typo'd template region/role (e.g. `"UX"`) is written to the node
  record unchecked, then read back and "verified" as success.
- **Fix (altitude):** Move `validate` into the shared `AdminApplier` orchestration so
  every `AdminChannel` adapter inherits it, rather than duplicating it in one sibling.

### [x] 6. `Dictionary(uniqueKeysWithValues:)` traps on a duplicate config field
- **Where:** `Sources/App/Fleet/StoreBackedAdminChannel.swift:45`
- **Bug/Failure:** Two `ConfigChange` entries with the same `field` → fatal trap
  mid-apply.
- **Fix:** `Dictionary(changes.map { ($0.field, $0.to) }, uniquingKeysWith: { $1 })`
  (last-wins), unless field-uniqueness is guaranteed upstream (then assert it).

### [x] 7. `Dictionary(uniqueKeysWithValues:)` traps on a duplicate node id
- **Where:** `Sources/App/Fleet/FleetConfigViewModel.swift:267`
- **Bug/Failure:** `buildRollout()` keys `names` by `nodeNum`; a duplicate `nodeNum`
  in `candidates` (a discovered node also present as a stored row) crashes the app on
  rollout preview/start.
- **Fix:** De-dup candidates by `nodeNum`, or use `uniquingKeysWith:`.

### [x] 8. Live decryption ignores per-channel custom PSKs
- **Where:** `Sources/MeshtrackApp/LiveCoordinator.swift:201` (`DefaultChannelKeyStore`)
- **Bug:** `key(forChannelHash:)` returns the hardcoded default PSK for *every*
  channel hash; ingest never consults the per-channel keys held by
  `KeychainChannelManager`/`InMemoryChannelKeyManager`.
- **Failure:** Any non-default-PSK channel entered in Channels & Keys silently fails
  to decrypt in the live app, though the settings UI implies it works.
- **Fix:** Back the live `KeyStore` with the Keychain channel registry so custom
  PSKs are resolved by hash. (Comments mark this "future work" — at minimum gate the
  UI or surface the limitation.)

### [x] 9. `extractNodeInfo` read-modify-write is not atomic
- **Where:** `Sources/Ingest/IngestPipeline.swift:209`
- **Bug:** `fetchNode` (read txn) then `upsertNode`/`node.save` (write txn) are two
  separate transactions. The comment promises ownership flags are never clobbered,
  but a concurrent `setOwnership`/`StoreBackedAdminChannel` write landing between the
  two is overwritten by the stale full-row snapshot.
- **Failure:** Lost ownership update when a provisioning/ownership edit races a
  NODEINFO ingest for the same node.
- **Fix:** Perform the fetch-merge-upsert inside a single `writer.write` transaction.

### [x] 10. Default-snooze setting is silently dropped in production
- **Where:** `Sources/MeshtrackApp/Integration.swift:62` (`MeshStoreAlertRuleStore`)
- **Bug:** Doesn't implement `save/loadDefaultSnoozeSeconds`, so it falls through to
  the port's no-op/3600s default; the fake (`AlertRuleStoreFake.swift:41`) *does*
  persist it, so tests pass while production fails.
- **Failure:** Operator's snooze edit is lost on relaunch.
- **Fix:** Persist default-snooze in `app_config` (or the alert-rule table) in the
  real adapter; documented as a follow-up but it's a real "fake diverges from real".

---

## 🟡 Low

### [x] 11. "Play" from live is a no-op bounce
- **Where:** `Sources/App/Timeline/TimelineViewModel.swift:100` (with `:137`, `:149`)
- **Bug/Failure:** `play()` from live sets `mode = .review` but leaves `playhead`
  pinned at `window.end`; the first `tick(delta>0)` sees `advanced >= window.end` and
  calls `goLive()`, snapping straight back. Review playback never starts from the
  live edge.
- **Fix:** On play-from-live, seek the playhead back (e.g. to `window.start` or a
  small offset) before entering review, or don't switch to review at the end.

### [x] 12. Mixed clocked/clockless trace window saturates instantly
- **Where:** `Sources/App/Visualization/LivePacketTraceCollector.swift:74`
- **Bug/Failure:** `arrivalClockByPacket[packetID] ?? Double(index) * stagger` mixes
  reference-date clocks (~7.9e8) with the legacy per-index stagger (~0.4). A single
  clockless packet beside clocked ones gets `clock − startedAt ≈ 7.9e8` → its hop
  lines draw instantly complete (the bug this change fixed, re-exposed for mixed
  windows).
- **Fix:** Don't mix the two regimes in one window — either always stamp an
  arrival clock in live mode, or fall back uniformly when any packet lacks one.

### [x] 13. Message ordering is unstable on equal `rx_time`
- **Where:** `Sources/Persistence/Store.swift:171` (`messages`), `:179` (`recentMessages`)
- **Bug/Failure:** Orders by `rx_time` only with no tie-break; messages sharing a
  coarse `rx_time` come back in arbitrary order → transcript flickers between loads.
- **Fix:** `.order(Column("rx_time").desc, Column("id").desc)`.

---

## 🧹 Cleanup (highest-value only)

### [x] 14. Node hex-ID format copy-pasted across 15+ files
- **Where:** e.g. `Sources/App/Search/SearchViewModel.swift:102`,
  `Sources/App/Fleet/FleetConfigViewModel.swift:277`,
  `Sources/App/Timeline/TimelineViewModel.swift:203`
- **Cost:** `"!" + String(format: "%08x", UInt32(truncatingIfNeeded: nodeNum))`
  (and a `%04x` short-id variant) is duplicated everywhere; a format change must
  touch ~15 sites or they drift.
- **Fix:** Promote one `NodeID.hex(_:)` / `NodeID.shortHex(_:)` helper to `Domain`
  and call it everywhere.

### [x] 15. Two copies of the Meshtastic channel-hash + default PSK
- **Where:** `Sources/App/Settings/ChannelsSettingsViewModel.swift:132`
  (`ChannelKeyMath`) vs `Sources/App/Map/ChannelPreset.swift`
- **Cost:** Two copies of the firmware XOR-fold hash and the identical 16-byte PSK
  literal; if either changes, map preset resolution and settings channel derivation
  drift (traffic decodes on one screen but not the other).
- **Fix:** Extract one shared channel-hash helper + one PSK constant; have both call it.

---

## Considered and dropped (do not re-file)
- **`markConnected` host "shadowing"** — *refuted*. In Swift `if case .connecting(host) = status`
  with no `let` is an expression pattern that compares via `~=`; the same-host guard
  is correct (`Sources/MeshtrackApp/LiveCoordinator.swift:192`).
- **`InMemoryCredentialStore` NUL-vs-pipe separator** — the in-memory and Keychain
  stores never share a backing, so the key-scheme difference has no runtime effect.
- **Unconditional `role` overwrite in `extractNodeInfo`** — proto3 can't distinguish
  unset from `CLIENT`; the asymmetry is by-design and the code comment acknowledges it.
- **`Package.swift` edit vs AGENTS.md "don't edit Package.swift"** — that rule is
  scoped to parallel worktree agents; integration-branch target wiring is expected.

---

## Follow-ups discovered while fixing (phase 8, not in original review)
- **No live alert-generation loop (surfaced fixing #1).** `RuleEvaluator.conditions`
  is only ever called by `LivenessScenarioEvaluator` (the scenario/acceptance
  harness) — nothing in `MeshtrackApp`/`meshtrackd` runs telemetry through it, and
  `AlertsConsoleViewModel.reconcile` only folds *already-persisted* `alert` rows.
  So the running app never derives liveness/battery/voltage alerts from live
  telemetry at all. #1's fix correctly makes the management gate honored *and*
  builds the production `StoreNodeManagementLookup` adapter, but the gate has no
  live loop to attach to until one exists. Wiring a real ingest→RuleEvaluator→
  AlertEngine→store loop (and injecting `StoreNodeManagementLookup` there) is a
  larger phase-9 task, out of scope for this worklist.
