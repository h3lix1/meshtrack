# Meshtrack — Implementation Plan (Ralph task queue)

Each phase ships something **verifiable**. Tasks are molecular (one PR-sized unit
per loop iteration). Mark `[x]` only when `make verify` is green *and* the relevant
acceptance snapshot passes. Ownership tags `(→ Agent X)` mark tasks currently
dispatched to a worktree agent.

---

## Phase 0 — Foundations & harness  ← in progress

- [x] SPM workspace with empty modules + dependency rules (Domain depends on nothing)
- [x] `Clock` port + `InjectedClock`/`SystemClock`; lint rule + purity check banning `Date()` in Domain
- [x] `MeshTransport` port + `InboundFrame` provenance type
- [x] `make verify` wired with all gates (purity, format, lint, build, test, coverage, mutation, protos, perf, secrets) + CI workflow
- [x] Ralph loop wiring: `SPEC.md`, `IMPLEMENTATION_PLAN.md`, `AGENTS.md`, `scripts/loop.sh`, stuck-detector
- [x] GRDB store + migration framework + schema v1 (§5)
- [x] Pinned, vendored `meshtastic/protobufs` + reproducible SwiftProtobuf codegen (`scripts/gen-protos.sh`)
- [x] `ReplayAdapter` + golden-corpus format + 3 recordings (synthetic; real captures deferred to Phase 1)
- [x] Scenario DSL parser + runner
- [x] Replay → persist integration (`Ingest` module): a replayed corpus produces persisted nodes

**Done when:** a replayed corpus produces persisted nodes; full gate suite green
from a cold checkout. ✅ **Phase 0 complete (2026-06-20).**

## Phase 1 — Ingestion & node store  ← in progress

- [x] `ServiceEnvelope`/`MeshPacket` decode → DecodedPacket → persist observations
- [x] Provenance + dedup window (10 min, `(packet_id, from_num)`); telemetry taxonomy persisted
- [x] MQTT adapter (TLS) → frames (CocoaMQTT; topic parser tested, connection best-effort)
- [x] PSK decryption (AES-CTR) for `/e/` topics; Keychain-backed `KeyStore` (up to 20 MQTT / 7 local channels)
- [x] Serial + BLE adapters for the local node (SerialFramer tested; port/radio I/O best-effort, HIL-gated)
- [x] Structured logging (secret-redacting wrapper)
- [x] Packet inspector (debug-view data layer) over decoded packets

Seams committed by the lead for the parallel agents: `KeyStore` / `PacketDecryptor`
/ `ChannelKey` ports (Domain), and the `Crypto` + `Logging` module targets.

**Done when:** live nodes + typed telemetry appear from MQTT and from a USB node;
dedup proven by replay test. ✅ **Phase 1 complete (2026-06-20)** — validated on
live bayme.sh MediumFast (decode+decrypt+dedup); serial framer built, USB-node
hardware validation deferred to the Phase 5 HIL tier.

## Phase 2 — Liveness, battery & graphs

- [x] RuleEngine core + config hierarchy (node → class → global)
- [x] `stale`, `battery_below`, `voltage_below` rules
- [x] Alert state machine + cooldown/snooze/ack + storm suppression on reconnect
- [x] Notification Center delivery (+ delivery port stub for ntfy/webhook)
- [x] Telemetry retention + rollups (hourly/daily downsample, prune-keeps-rollups) — Swift Charts history deferred to the App layer (Phase 3)

**Done when:** stale/battery scenarios fire exactly the expected alerts; reconnect
avalanche test passes. ✅ **Phase 2 complete (2026-06-20)** — RuleEvaluator +
AlertEngine (storm suppression = no reconnect avalanche); LivenessScenarioEvaluator
fires stale exactly once through the acceptance harness. Swift Charts UI lands with
the App.

## Phase 3 — Map, arming & movement

- [ ] MapKit view: nodes, clustering, track polylines, geofence overlays  *(→ App layer)*
- [x] Arming: anchor capture (arming table) + `MovementDetector` (confirmation + accuracy margin + hysteresis + escape factor)
- [x] Node classification + class-based movement semantics (geofence-exit for mobile)
- [x] `moved` / `returned` / `geofence_exit` rules

**Done when:** jitter scenarios produce **zero** false movement alerts; real-move
scenarios produce exactly one. ✅ **Phase 3 logic complete (2026-06-20)** —
MovementScenarioEvaluator proves jitter→0, 600m move→1 moved, mobile→geofence_exit
through the harness. MapKit view lands with the App.

## Phase 4 — Provisioning & on-the-fly updates

- [x] Template model + naming DSL renderer with byte-limit validation (+ pure render→diff)
- [x] Render → diff → confirm → apply flow + read-back verification + idempotency (AdminApplier over the AdminChannel port)
- [x] Remote admin abstracted by AdminChannel (PKI admin key / legacy admin channel) — real transport is the effect adapter, validated on hardware (HIL)

**Done when:** a node is provisioned from a template and a live config edit
round-trips with a confirmed diff. ✅ **Phase 4 logic complete (2026-06-20)** —
AdminApplier round-trips plan→apply→verify (idempotent; verification failure
detected). Real AdminMessage transport (local USB / remote PKI / legacy) is HIL.

## Phase 5 — Firmware onboarding (extra credit, feature-flagged)

- [x] `Flasher` port; chip-family detection (esptool vs UF2 by family + chip-specific offsets)
- [~] esptool adapter (offsets defined; real esptool process I/O is effect/HIL)  *(→ HIL)*
- [~] UF2/DFU adapter (UF2 method defined; real volume-copy I/O is effect/HIL)  *(→ HIL)*
- [x] firmware-variant↔hardware verification; binary pinning + checksums; confirm-before-write (GuardedFlasher, never auto-flash)
- [~] HIL test tier — read-only chip detection validated on the XIAO; flashing is gated/manual (never auto-flash)  *(→ HIL)*

**Done when:** guided flash of a known board succeeds behind confirmation; HIL gate
green; flag off by default.

## Phase 6 — Hardening & distribution

- [ ] Observability dashboard (ingestion lag, transport health)
- [ ] App sandbox + entitlements (serial/BLE/network/notifications); code signing + notarization
- [ ] Export/backup; DocC docs; ADRs in `/docs/adr`
- [x] Performance budgets: decode-throughput gate (DecodePerfTests, ≥ 5000 msgs/sec) wired into make verify + scoreboard; coverage floor ratcheted 70→80

**Done when:** signed/notarized build; all budgets met; docs complete.

## Phase 7 — The App: award-grade MapKit GUI + live fleet control  ← in progress

Design contract: `docs/phase7-gui.md`. SPEC amended (§1 monitor-only messaging,
§2.10 managed/unmanaged + my-nodes, §2.11 latency, §3 MapKit/snapshot). ADRs 0006–0008.
Built by parallel worktree agents; feature streams add **new files only** and never
touch shared files (`Package.swift`, `Migrations.swift`, `Schema.swift`, `AppShell.swift`,
`SampleNetwork.swift`) — the Foundation stream owns those. Commit per molecular task.

### G0 — Foundation seams (lead-only; unblocks Wave 2) ✅ merged
- [x] Migration v3: `node.is_mine`/`is_managed`; `message` table; `observation.ingest_time` (+ records/queries + tests)
- [x] Domain: `MeshMessage`, `NodeManagement`, latency helpers (pure + tested)
- [x] Ingest: record `ingest_time`; decode `TEXT_MESSAGE_APP` → message; re-add `onDecoded` tap (tested)
- [x] RuleEngine: gate `battery_below`/`voltage_below`/`stale` on `is_managed` (unmanaged+low → no alert; managed+low → 1)
- [x] `Package.swift`: `App` += `Provisioning`; `MeshtrackApp` += `Ingest,Transport,Persistence,Crypto,RuleEngine,Provisioning,Domain,MeshProtos`
- [x] AppShell → `AppModel` registry refactor; Snapshot harness builds `AppModel` from sample data

### G1 — MapKit substrate (Wave 1)  *(→ headline)* ✅ merged
- [x] `MeshMapView` (`NSViewRepresentable` over `MKMapView`): dark style, fit-to-fleet, clustering, real `MKAnnotation` nodes (position-less omitted)
- [x] `MapProjection` adapter (`MKMapView.convert` → `point(for:)`); transparent `Canvas` trace overlay reusing `PacketTraceBuilder`/`PacketColor`/hop badge
- [x] Viz-settings panel: configurable `hopDuration`, equalise-finish toggle, per-id colour legend, guessed-vs-observed key + relay-confidence hint
- [x] Snapshot path renders the Canvas-only fallback (deterministic); overlay geometry unit-tested

### G2 — Live ingest re-land + composition root (Wave 2; needs G0) ✅ merged
- [x] `MeshtrackApp/LiveCoordinator`: MQTT (env creds) → IngestPipeline → store → VMs; sample-fallback when no broker
- [x] `onDecoded` trace tap feeds `NetworkViewModel`; latency (`ingest_time`) captured; env-gated live smoke test

### G3 — Node directory + detail + ownership (Wave 2; needs G0) ✅ merged
- [x] Node directory VM: role tabs, search, **My Nodes** filter, managed/unmanaged segmentation + bulk-classify (tested)
- [x] Node detail: click-to-configure (arming-gated), QR code, drill-through to analytics

### G4 — Telemetry + node analytics deep-dive (Wave 1) ✅ merged
- [x] Swift Charts over telemetry + rollups (battery/voltage/util/env), live VM (tested)
- [x] Analytics tabs: SNR/RSSI distribution, hop-count histogram, peer/topology graph, hourly heatmap, packet-type breakdown

### G5 — Alerts + arming UI (Wave 2; needs G0) ✅ merged
- [x] Alert list/ack/snooze/cooldown VM over `AlertEngine` (tested); managed-aware suppression surfaced
- [x] Arming flow UI (capture anchor / disarm) over the arming table

### G6 — Packet inspector + latency analytics (Wave 2; needs G0) ✅ merged
- [x] Inspector: byte-level breakdown, filters, detail pane (live, tested VM)
- [x] Receive→publish latency surfaced (inspector + map-edge tooltip + latency tab)

### G7 — Fleet config rollout UI (Wave 2; needs G0) ✅ merged
- [x] Wire `FleetApplier`: live verify-each-then-next, halt-on-failure, diff preview, fleet-wide edit, progress + abort (tested VM)

### G8 — Messaging (monitor-only) (Wave 2; needs G0) ✅ merged
- [x] Channels view: decoded text grouped by channel — sender, @mentions, timestamps, DM vs broadcast (tested VM)

### G9 — VCR / time-travel (Wave 1) ✅ merged
- [x] Timeline scrubber + variable-speed (≤4×) replay over `ReplayAdapter` driving the map animation (tested VM)

### G10 — Observability + ⌘K search + theme + collision matrix (Wave 2; partly G0) ✅ merged
- [x] Observability dashboard: ingestion lag + transport health (finishes Phase 6 item)
- [x] Global ⌘K search (nodes/packets/channels); in-app theme customizer; node-id 4-byte hash-collision matrix

### Lead integration ✅
- [x] Merged all 11 streams; `AppComposition.registerLiveSections` wires every section into the shell (headline MapKit map live); Analytics + Messages sidebar sections added
- [x] `make verify` green end-to-end: 474 tests, coverage 91.6%
- [ ] *Follow-ups:* live `IngestHealth` push from the coordinator; `relay_node` on observations for guessed-hop replay; per-node picker for telemetry/analytics; surface VCR overlay + ⌘K + theme in the live shell; signing/notarization (Phase 6 carry-over)

## Phase 8 — Configuration & onboarding (no more env vars)  ← in progress

Replace environment-variable config with proper macOS Settings screens (⌘,) and a
first-run onboarding flow. Non-secret config persists in the shared store; secrets
(MQTT password, channel PSKs) live in the Keychain (SPEC §2.5). Env vars remain only
as a headless fallback for `meshtrackd`/CI. Built by a parallel worktree team off the
committed contracts (`Domain/AppConfig.swift`: `BrokerConfig`, `AppSettings`,
`ConfigGateway`, `CredentialStore`; `App/SettingsModel.swift`: `SettingsTab` registry).

- [x] Contracts: Domain config types + `ConfigGateway`/`CredentialStore` ports + `SettingsModel`/`SettingsTab` registry (lead)
- [x] **T-Persist**: `ConfigGateway` on `MeshStore` (migration v4 `app_config`) + Keychain `CredentialStore` adapter (+ tests)
- [x] **T-Compose**: macOS `Settings {}` scene + ⌘, + first-run onboarding wizard; `LiveCoordinator`/`MeshtrackApp` read `BrokerConfig` from the store (env fallback); reconnect-on-change; connection-status indicator
- [x] **T-Connection**: Connection tab — broker host/port/TLS/cert/topics + username + Keychain password + Test Connection + status
- [~] **T-Channels**: Channels & Keys screen built + `KeychainKeyStore` exists; tab wired to a placeholder pending an **async `ChannelKeyManaging`** port (sync port can't persist the registry to GRDB)
- [x] **T-Prefs**: General tab (refresh, units, theme, retention, notifications, start-at-login, auto-connect) + Alerts-rules config tab (battery/voltage/stale thresholds across node→class→global)
- [x] **Lead integration**: on-disk shared `MeshStore` (config persists) + `KeychainCredentialStore` + MQTT Test-Connection probe + `alert_rule` CRUD adapter; Connection/General/Alerts tabs registered; `make verify` green (549 tests, coverage 90.55%)

**Done when:** a fresh launch with no env vars walks the user through onboarding,
connects to a broker entered in the UI (password in Keychain), and every setting is
editable from `Settings` (⌘,) and persists across launches; `make verify` green.
*Follow-ups:* async `ChannelKeyManaging` so the Channels tab persists (then wire it);
CONNACK-based connection status hook on `MQTTAdapter`; persist default-snooze; wire
`startAtLogin`→LaunchAgent and `notificationsEnabled`→`UNNotifier`.

**Done when:** `swift run MeshtrackApp` shows a real MapKit map animating live MQTT
traffic (per-id colours, guessed/observed hops, hop badges, latency); click-to-config
+ safe fleet rollout work; my-nodes/managed segmentation kills false battery/stale
alerts (RuleEngine test proves it); channels/telemetry/analytics/inspector/observability
live; VCR + ⌘K work; `make verify` green; coverage floor held; snapshots deterministic.
