# Meshtrack — Specification (source of truth)

A fast, native macOS app + headless collector that monitors a Meshtastic fleet
over MQTT and a locally-attached node (USB/BLE), stores rich per-node history,
renders nodes on a map, lets you *arm* nodes for movement, and provisions/updates
nodes from reusable templates — with an alerting engine for movement, silence,
and battery.

This file is the contract the build loop optimizes against. Behavior is defined
here; the plan (`IMPLEMENTATION_PLAN.md`) sequences it; `AGENTS.md` constrains how
it is built. When code and SPEC disagree, SPEC wins (or SPEC is wrong — fix it in
the same change with an ADR).

---

## 1. Vision & non-goals

**Vision.** Native macOS monitoring + control for Meshtastic fleets: first-class
notifications, MapKit, Swift Charts, Keychain, LaunchAgent background execution,
code-signed distribution.

**Non-goals (v1).** Cross-platform builds; a public/multi-user server;
chat/messaging UX (we monitor; we do not replace the official client for
conversations); routing/topology optimization. Keep the surface small and correct.

---

## 2. Domain decisions (testable contracts)

### 2.1 Node identity & classification
- A node is keyed by numeric `node_num`; `!hexid` and short/long names are
  attributes, not the key.
- Every node has a **class**: `fixed | mobile | gateway | unknown`. Class drives
  default alert behavior, is user-overridable, and may be inferred (position
  unchanged for K days → suggest `fixed`).
- **Naming DSL byte limits (hard):** short name ≤ **4 bytes**, long name ≤ **39
  bytes**. The template renderer MUST validate and reject overflow before apply.

### 2.2 "Heard" & staleness (liveness)
- A node is **heard** when *any* packet is attributed to it (not only position).
- `last_heard_at` is wall-clock, persisted, computed by the **collector** (not the
  UI), so staleness is correct even if the app was never opened.
- **Stale** = `now - last_heard_at > expected_interval`, per-node configurable with
  a global default. Optionally learn a baseline and alert on deviation.
- On collector startup / broker reconnect, **backfill** from retained messages,
  then mark events older than `backfill_horizon` as *historical* (no alert) — see
  §2.6 storm suppression.

### 2.3 Position & movement (signal processing, not subtraction)
- Arming a node **captures an anchor**: `(lat, lon, h_accuracy, captured_at)`.
- A **candidate movement** is a fix whose Haversine distance from the anchor
  exceeds `threshold + position_accuracy_margin`.
- Movement is **confirmed** only when `N_consecutive` candidate fixes agree
  (default `N=3`) OR a single fix exceeds `threshold + accuracy` by `escape_factor`
  (default 3×). This kills GPS-jitter false positives.
- **Hysteresis:** once "moved", a node is "returned" only when back inside
  `threshold * return_ratio` (default 0.6) for `N_consecutive` fixes. No flapping.
- Respect Meshtastic **position precision**: widen accuracy margin for
  imprecise/obfuscated positions; never confirm movement on a fix coarser than the
  threshold.
- Nodes reporting **no GPS** are never movement-alerted (surface "no position
  source").
- `mobile` nodes default to **geofence-exit** semantics (left anchor radius)
  rather than "moved at all".

### 2.4 Transport, dedup & provenance
- The same `MeshPacket` may arrive via local node, MQTT, and multiple gateways.
- Dedup key = `(packet_id, from_num)` within a sliding window (default 10 min).
- Record **provenance per observation** (transport, gateway/USERID, rx_rssi,
  rx_snr, hop_start/hop_limit, rx_time); count telemetry/position **once**.

### 2.5 Decryption & keys
- MQTT `msh/REGION/2/e/CHANNEL/USERID` carries a `ServiceEnvelope` → (possibly)
  encrypted `MeshPacket`. **Decryption requires the channel PSK.** With encryption
  on, decoded messages are not republished — without the PSK you get nothing useful.
- JSON topic `msh/REGION/2/json/...` is convenience only and may be disabled; do
  not depend on it.
- All secrets (channel PSKs, admin keys, MQTT creds) live in **Keychain**. The DB
  never stores plaintext secrets.

### 2.6 Alert engine (data-driven)
- Rules are typed records, not code branches: `moved`, `returned`, `geofence_exit`,
  `stale`, `battery_below`, `voltage_below`, `channel_util_high`, `new_node_seen`,
  `back_online`.
- **Config hierarchy:** per-node override → node-class default → global default.
- Each alert has a **state machine**: `firing → acknowledged → resolved` with
  `cooldown` and `snooze`.
- **Storm suppression:** events from backfilled/historical packets do not fire live
  alerts; reconnect must not produce an avalanche.
- **Delivery** is a port: macOS Notification Center (default) + pluggable `ntfy` /
  webhook / email. Acks round-trip back into the state machine.

### 2.7 Provisioning & remote updates
- A **template** = region (always set — legal), role, channel(s)+PSK, position
  config, MQTT config, naming DSL, optional firmware variant.
- Naming DSL example: `{shortName}-{id[-4:]}` → `baymesh-A123`. Renderer validates
  byte limits (§2.1).
- Apply via **admin messages** (`AdminMessage`/`ConfigModule` protobufs), local or
  remote. **Remote admin requires an installed admin key** (PKI admin pubkey or
  legacy admin channel).
- Every apply is **dry-run first**: render → diff vs. current config → explicit
  confirm → apply → verify read-back → mark idempotent. Some changes require a
  reboot; surface that.

### 2.8 Firmware onboarding (extra credit — gated, late)
- **Flash method branches by chip family** (critical correctness point):
  - ESP32 / S3 / S2 / C3 (T-Beam, Heltec…) → **esptool** at chip-specific offsets.
  - nRF52840 (RAK4631, Nano G2 Ultra) → **UF2 bootloader (drag-drop) or DFU;
    esptool does NOT apply.**
  - RP2040 → **UF2**.
- Verify firmware **variant matches detected hardware** before writing (wrong
  binary bricks the board).
- Pin + checksum every binary. **Never auto-flash**; always explicit, single-board,
  confirmed. Behind a feature flag and a hardware-in-the-loop gate (§6 Phase 5).

### 2.9 Regulatory note (light)
- Region must be set on every provisioned node. Be deliberate about uplinking to
  the public broker (zero-hop policy). Encryption choices on amateur allocations
  are the operator's responsibility — surface settings, don't make legal decisions.

---

## 3. Architecture

Hexagonal / ports-and-adapters. **Non-negotiable** — it is what makes the verify
suite deterministic and the loop convergent.

- **Domain is pure**: deterministic, no clock/network/disk. All time via a `Clock`
  port. Domain imports nothing but the standard library.
- **Collector vs. UI split**: `meshtrackd` runs as a `launchd` LaunchAgent so
  liveness/battery alerting works 24/7. The SwiftUI app is a viewer/controller over
  a shared GRDB store (WAL) and/or XPC. The split also makes the core CI-testable
  headlessly.
- **Actors** own the ingestion pipeline and per-node mutable state; everything
  `Sendable`; no shared mutable state.

Ports: `Clock`, `MeshTransport`, `Store`, `Notifier`, `Flasher`, `KeyStore`,
`AdminChannel`. Adapters live in the outer ring (e.g. `MQTTAdapter`, `SerialAdapter`,
`BLEAdapter`, `ReplayAdapter`, `GRDBStore`, `UNNotifier`, `EsptoolFlasher`,
`UF2Flasher`, `KeychainKeyStore`).

---

## 4. Tech stack (pinned)

| Concern | Choice |
|---|---|
| Language | Swift 6, strict concurrency |
| Build | SwiftPM, multi-module |
| Modules | `Domain`, `Persistence`, `Transport`, `RuleEngine`, `Provisioning`, `Scenario`, `App`, `meshtrackd`, `MeshProtos` |
| DB | GRDB.swift (SQLite, WAL) |
| Protobuf | SwiftProtobuf, codegen pinned to a specific `meshtastic/protobufs` commit, vendored |
| MQTT | CocoaMQTT / swift-mqtt (TLS) |
| Serial | IOKit / ORSSerialPort |
| BLE | CoreBluetooth |
| Charts | Swift Charts |
| Map | MapKit |
| Notifications | UserNotifications (+ ntfy/webhook/email behind a port) |
| Flashing | esptool (ESP32) + UF2/DFU (nRF52/RP2040), behind `Flasher`, feature-flagged |
| Background | launchd LaunchAgent (`meshtrackd`) |
| Secrets | Keychain |

---

## 5. Data model (own it in migrations from commit #1)

- `node(node_num PK, hexid, short_name, long_name, class, hw_model, role, first_seen_at, last_heard_at, …)`
- `node_config(node_num FK, region, channels_json, position_precision, mqtt_json, …)`
- `observation(id, node_num, packet_id, transport, gateway_id, rx_time, rx_rssi, rx_snr, hop_start, hop_limit)` — provenance, append-only
- `position_fix(node_num, t, lat, lon, alt, sats, h_accuracy, precision_bits)`
- `telemetry(node_num, t, kind, key, value)` — typed time-series: device
  (battery_pct, voltage, channel_util, air_util_tx, uptime), environment
  (temp/humidity/pressure/lux), power
- `arming(node_num, armed, threshold_m, anchor_lat, anchor_lon, anchor_accuracy, captured_at, state)`
- `alert_rule(id, scope, scope_id, type, params_json, enabled)`
- `alert(id, rule_id, node_num, type, state, fired_at, acked_at, resolved_at, payload_json)`
- `template(id, name, dsl, region, role, config_json, firmware_variant?)`

Retention: raw telemetry kept `retention_raw` (default 30d), then downsampled
rollups (`telemetry_hourly`, `telemetry_daily`) kept longer. Retention is config.

---

## 6. Test & validation harness (the fitness function)

"Done" must be externally checkable. Built in Phase 0, before features.

**Tiers.** (1) Unit (pure Domain). (2) Property-based: geo math (jitter inside
`h_accuracy` never confirms movement; Haversine symmetry & bounds; hysteresis never
flaps), template byte-limit invariants. (3) Decoder fuzzing: malformed
`ServiceEnvelope`/`MeshPacket` bytes never crash, only error. (4) Integration via
`ReplayAdapter` over a golden corpus + a scenario DSL. (5) Snapshot/approval:
`scenario → exact alert sequence` (executable acceptance criteria). (6)
Hardware-in-the-loop (gated, nightly/manual): real T-Beam + Mosquitto-in-Docker.

**Scenario DSL (illustrative).**
```yaml
- node: A123
  class: fixed
  arm: { threshold_m: 100 }
  fixes:                         # jitter within accuracy → MUST NOT alert
    - { dlat: 0.0003, dlon: 0.0002, h_accuracy: 60 } x5
  expect_alerts: []
- node: B456
  class: fixed
  arm: { threshold_m: 100 }
  fixes:                         # confirmed 600m move → exactly one 'moved'
    - { meters_from_anchor: 600 } x3
  expect_alerts: [ { type: moved, count: 1 } ]
- node: C789
  silence_hours: 26
  expect_alerts: [ { type: stale, count: 1 } ]
```

**`make verify` (single external validator).** swiftformat --lint + swiftlint
--strict (custom rule: ban `Date()` in Domain) · build warnings-as-errors, Swift 6
strict concurrency · unit + property + fuzz + replay + snapshot tests · coverage
floor (start 70%, ratchet up — never down) · mutation testing (min score) ·
reproducible protobuf-codegen check (git diff empty) · performance budgets · secret
scan + dependency/license audit.

**Scoreboard.** Track and ratchet in `scoreboard.json`: coverage %, mutation score,
ingestion msgs/sec, p95 query latency, open TODO/FIXME count, doc coverage. CI fails
on regression.

---

## 10. Resolved decisions (was: open questions)

1. **Broker:** Public broker (`mqtt.meshtastic.org`). Honor zero-hop uplink policy.
2. **Channels/PSKs:** Configurable in-app; up to **20** channels for MQTT, **7** for
   the local device. Entered/rotated in-app; stored in Keychain.
3. **Remote admin:** Support **both** PKI admin key (per node) and legacy admin
   channel.
4. **Deployment:** **Single-Mac.** Shared GRDB store (WAL) + XPC between
   `meshtrackd` and the app; no multi-machine access.
5. **macOS floor:** **macOS 26.6** (latest).
