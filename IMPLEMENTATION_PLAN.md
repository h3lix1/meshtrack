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

- [ ] `ServiceEnvelope`/`MeshPacket` decode → DecodedPacket → persist observations  *(→ lead / Ingest+Domain)*
- [ ] Provenance + dedup window (10 min, `(packet_id, from_num)`); telemetry taxonomy persisted  *(→ lead / Ingest+Domain)*
- [ ] MQTT adapter (TLS) → frames  *(→ lead / Transport, after decode)*
- [x] PSK decryption (AES-CTR) for `/e/` topics; Keychain-backed `KeyStore` (up to 20 MQTT / 7 local channels)
- [ ] Serial + BLE adapters for the local node  *(→ Agent C / Transport)*
- [ ] Packet inspector (debug view) + structured logging (secret-redacting wrapper)  *(→ Agent D / Logging)*

Seams committed by the lead for the parallel agents: `KeyStore` / `PacketDecryptor`
/ `ChannelKey` ports (Domain), and the `Crypto` + `Logging` module targets.

**Done when:** live nodes + typed telemetry appear from MQTT and from a USB node;
dedup proven by replay test.

## Phase 2 — Liveness, battery & graphs

- [ ] RuleEngine core + config hierarchy (node → class → global)
- [ ] `stale`, `battery_below`, `voltage_below` rules
- [ ] Alert state machine + cooldown/snooze/ack + storm suppression on reconnect
- [ ] Notification Center delivery (+ delivery port stub for ntfy/webhook)
- [ ] Swift Charts telemetry history; retention + rollups

**Done when:** stale/battery scenarios fire exactly the expected alerts; reconnect
avalanche test passes.

## Phase 3 — Map, arming & movement

- [ ] MapKit view: nodes, clustering, track polylines, geofence overlays
- [ ] Arming: anchor capture; `MovementDetector` (confirmation + accuracy margin + hysteresis)
- [ ] Node classification + class-based movement semantics (geofence-exit for mobile)
- [ ] `moved` / `returned` / `geofence_exit` rules

**Done when:** jitter scenarios produce **zero** false movement alerts; real-move
scenarios produce exactly one.

## Phase 4 — Provisioning & on-the-fly updates

- [ ] Template model + naming DSL renderer with byte-limit validation
- [ ] Render → diff → confirm → apply via AdminMessage/ConfigModule (local admin)
- [ ] Remote admin path — both PKI admin key and legacy admin channel; read-back verification; idempotency

**Done when:** a node is provisioned from a template and a live config edit
round-trips with a confirmed diff.

## Phase 5 — Firmware onboarding (extra credit, feature-flagged)

- [ ] `Flasher` port; chip-family detection
- [ ] esptool adapter (ESP32 family, correct offsets)
- [ ] UF2/DFU adapter (nRF52 / RP2040)
- [ ] firmware-variant↔hardware verification; binary pinning + checksums; confirm-before-write
- [ ] HIL test tier (real board + Docker Mosquitto)

**Done when:** guided flash of a known board succeeds behind confirmation; HIL gate
green; flag off by default.

## Phase 6 — Hardening & distribution

- [ ] Observability dashboard (ingestion lag, transport health)
- [ ] App sandbox + entitlements (serial/BLE/network/notifications); code signing + notarization
- [ ] Export/backup; DocC docs; ADRs in `/docs/adr`
- [ ] Performance budgets finalized; scoreboard ratcheted

**Done when:** signed/notarized build; all budgets met; docs complete.
