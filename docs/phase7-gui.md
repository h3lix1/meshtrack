# Phase 7 — The App: award-grade MapKit GUI + live fleet control

> **Status:** planning → build (parallel worktrees).
> **Goal:** turn the proven core (Phases 0–6) into *the* Meshtastic fleet
> visualizer & controller for macOS — a real MapKit map with real-time packet
> tracing, click-to-configure nodes, safe fleet-wide rollout, and a viewer worthy
> of an award.

This document is the design contract for Phase 7. `SPEC.md` is amended alongside
it (§1 messaging, §2.10 managed/unmanaged, §2.11 latency, §3 MapKit/snapshot).
`IMPLEMENTATION_PLAN.md` carries the molecular task queue. `AGENTS.md` constrains
*how*. Reference UX studied: **CoreScope** (MeshCore web analyzer) — we re-imagine
its feature set natively for Meshtastic with the macOS toolkit.

---

## 0. What already exists (do not rebuild)

A surprising amount of the "ultimate visualization" engine landed in Phase 6 and
survived the two reverts. Build *on* it:

| Capability | Where | State |
|---|---|---|
| Distinct colour per packet id (Knuth hash → hue) | `App/Visualization/NetworkModels.swift` `PacketColor` | ✅ done |
| Previous-hop **guess from the relay byte** (`MeshPacket.relay_node`, last byte → nearest node to the gateway) | `App/Visualization/PacketTraceBuilder.swift` | ✅ done, pure, tested |
| Ignore position-less nodes | `PacketTraceBuilder` / `NetworkViewModel.loadNodes` | ✅ done |
| Live decoded-stream → animated traces (sliding window) | `App/Visualization/LivePacketTraceCollector.swift` | ✅ done, tested |
| Hop-count badge + per-edge timed draw + guessed/observed styling | `App/Visualization/NetworkMapView.swift` | ✅ done (abstract Canvas) |
| Store → positioned nodes + traces seam | `App/NetworkViewModel.swift` | ✅ done, tested |
| Safe rolling fleet rollout (verify each node before the next, halt on failure) | `Provisioning/FleetApplier.swift` | ✅ done, tested |
| Click-to-configure node detail w/ arming safety gate | `App/NodeDetailView.swift` | ✅ done |
| Packet inspector / observability / telemetry / alerts views (sample-fed) | `App/*View.swift` | ✅ scaffolded |
| Headless snapshot harness (`ImageRenderer`) | `MeshtrackSnapshot` | ✅ done |
| Live MQTT ingest in-app (validated 77 pkts/2 nodes on bayme.sh) | reverted `LiveCoordinator` | ⏪ reverted — re-land cleanly |

**The gap = MapKit.** Everything renders on an abstract `Canvas` projection
(`GeoProjection` → rect). Phase 7's spine is porting the visualization onto a real
`MKMapView` with geographic tiles, then wiring every section to the live store.

---

## 1. The headline: real-time packet tracing on a real map

Requirements (verbatim asks → design):

1. **Real MapKit map.** `MKMapView` via `NSViewRepresentable`, dark `.mutedStandard`
   / hybrid style, fit-to-fleet, clustering for dense areas. Nodes are
   `MKAnnotation`s at real lat/lon; position-less nodes are omitted (SPEC §2.3).
2. **Trace packets between nodes in real time from MQTT.** The decoded stream folds
   into `LivePacketTraceCollector`; traces animate over the map.
3. **Educated previous-hop guess.** `MeshPacket.relay_node` is the *last byte* of the
   prior hop. `PacketTraceBuilder.guessRelay` already matches nodes whose id ends in
   that byte and picks the one **nearest the receiving gateway**. Guessed edges are
   drawn dashed/thin + labelled "≈" (uncertain); observed edges solid. Surface a
   confidence hint (how many candidates shared that byte).
4. **A colour per packet id.** `PacketColor` (stable hue) — already done; expose a
   legend.
5. **Hop count at each point.** Hop badge rides the animation head (already in
   `NetworkMapView`); also annotate each edge with cumulative hop index.
6. **Timed line draw, configurable, equal finish.** Each hop edge animates over a
   configurable `hopDuration`; *shorter hops draw slower* (distance ÷ time) so every
   edge of a journey **finishes together**. Expose `hopDuration` + an "equalise
   finish across a journey" toggle in a viz settings panel.
7. **Record receive→publish latency.** For each reception, store our ingest wall-clock
   (`observation.ingest_time`) alongside the mesh `rx_time`; latency = ingest − rx.
   Surface it: map edge tooltips, packet inspector, and a latency analytics tab.

### MapKit ⇄ snapshot strategy (ADR 0007)

`MKMapView` needs tiles/GPU and **will not render** under the headless
`ImageRenderer` gate the project relies on (cf. memory: stock controls render badly
headless). Therefore:

- **Live app:** `MeshMapView` (real `MKMapView`) is the substrate; the animated
  traces + node glows render in a transparent SwiftUI `Canvas` *overlay* whose
  coordinate transform is driven by `MKMapView.convert(_:toPointTo:)` (a
  `MapProjection` adapter mirroring `GeoProjection`'s interface).
- **Snapshot/CI:** the section renders the existing self-contained Canvas map
  (`DashboardView`, `live: false`) — fully deterministic, already snapshot-clean.
- The trace-drawing math is shared and **unit-tested** independent of MapKit; the
  `MKMapView` substrate is excluded from coverage like the other I/O adapters and
  verified live (manual / env-gated smoke).

---

## 2. Managed vs unmanaged & "my" nodes (ADR 0008)

CoreScope's "My Nodes" plus the explicit ask to *"not get false alerts for batteries
and the such"* for nodes we don't run:

- `node.is_mine` — part of my fleet; drives the **"My Nodes"** filter everywhere.
- `node.is_managed` — we administer it (admin key / we own the battery). **Only
  managed nodes evaluate ownership-sensitive rules** (`battery_below`,
  `voltage_below`, `stale`). Unmanaged nodes are observed read-only — they still
  appear, chart, and trace, but never raise battery/silence alerts (no false alarms
  for strangers' nodes). Movement/geofence and `new_node_seen` remain global.
- Rule scoping: `RuleEvaluator` gains a `management` predicate; the config hierarchy
  (node → class → global) is unchanged, but the engine skips ownership-sensitive
  rule types for `is_managed == false`.
- Bulk-classify UI: multi-select nodes → mark mine / managed; inference hint
  (e.g. nodes we successfully admin become managed).

---

## 3. Messaging — monitor-only (ADR 0006, SPEC §1 amended)

SPEC §1 listed chat as a non-goal ("we monitor; we do not replace the client").
Amended to **monitor-only**: decode `TEXT_MESSAGE_APP` (port 1) payloads into a
`message` table and show a read-only **Channels** view (sender short-name, channel,
@mentions highlighted, timestamps, DMs vs broadcast). **No send path** in Phase 7
(keeps the TX/admin surface small; revisit later). Encrypted channels decode only
with the PSK already in `KeyStore`.

---

## 4. Architecture & seam rules (read before dispatch)

- `App` library stays **snapshot-pure**: imports `Domain`, `Persistence`,
  `RuleEngine`, **+ `Provisioning`** (new, for fleet/admin VMs). It must **not**
  import `Ingest`/`Transport`/`Crypto` — the live wiring lives in the
  **`MeshtrackApp` executable** composition root.
- Every section is driven by a **testable `@MainActor @Observable` view model** over
  the store (pattern: `NodeListViewModel`, `NetworkViewModel`). View models are
  unit-tested over an in-memory `MeshStore`; SwiftUI views are snapshot-verified and
  excluded from the coverage metric (like the hardware adapters).
- **Strict-concurrency, warnings-as-errors, no force-unwrap/`try!`/`as!`.** Typed
  errors. `make verify` is the only judge.
- **Parallel-worktree contract (AGENTS.md):** feature agents add **new files only**
  and must **not** edit shared files — `Package.swift`, `Persistence/Migrations.swift`,
  `Persistence/Schema.swift`, `App/AppShell.swift`, `App/Visualization/SampleNetwork.swift`.
  The **Foundation** stream (G0) owns all shared seams; the lead integrates each
  feature's section into the shell at merge.

### Shared seams owned by G0 (Foundation)

1. **Migration v3** (`Persistence/Migrations.swift` + `Schema.swift` + `Records.swift`):
   - `node` += `is_mine BOOL NOT NULL DEFAULT 0`, `is_managed BOOL NOT NULL DEFAULT 0`.
   - new `message(id, packet_id, from_num, to_num, channel, channel_name, body,
     rx_time, is_dm)` + indexes on `(channel, rx_time)` and `rx_time`.
   - `observation` += `ingest_time INTEGER` (our clock at frame receipt; nullable for
     back-compat) — the receive→publish latency source.
2. **Domain types:** `MeshMessage`, `NodeManagement` (mine/managed), latency helpers.
3. **Ingest:** `IngestPipeline` records `ingest_time = frame.receivedAt`; decodes
   `TEXT_MESSAGE_APP` → `message`. (`onDecoded` tap re-added for the live trace feed.)
4. **RuleEngine:** ownership-sensitive rule gating by `is_managed`.
5. **`Package.swift`:** `App` += `Provisioning`; `MeshtrackApp` += `Ingest, Transport,
   Persistence, Crypto, RuleEngine, Provisioning, Domain, MeshProtos`.
6. **AppShell registry refactor:** `RootView` takes an `AppModel` (env object holding
   the section VMs); each section delegates to its own view so feature agents never
   touch `AppShell.swift`. Snapshot harness updated to build `AppModel` from sample
   data.

---

## 5. Work breakdown — defined goals (the batch)

Each goal is a worktree stream; "✦" marks the headline asks. Acceptance = `make
verify` green + the stated check.

| ID | Goal | Owns (new files) | Depends |
|----|------|------------------|---------|
| **G0** | **Foundation seams** (migration v3, Domain types, Ingest taps, RuleEngine gating, Package.swift, AppShell→AppModel registry, Snapshot harness) | shared files (lead-only) | — |
| **G1** ✦ | **MapKit substrate**: `MeshMapView` (`MKMapView` repr.), dark style, clustering, fit-to-fleet, `MapProjection` adapter, transparent trace **overlay** reusing `PacketTraceBuilder`/`PacketColor`/hop badges, viz-settings panel (`hopDuration`, equalise-finish, legend) | `App/Map/*` | — (uses existing viz types) |
| **G2** | **Live ingest re-land**: `MeshtrackApp/LiveCoordinator` (MQTT→IngestPipeline→store→VMs), `onDecoded` trace tap, latency capture, env-gated live smoke test, sample-fallback | `MeshtrackApp/*`, `AppTests/Live*` | G0 |
| **G3** | **Node directory + detail**: role tabs, search, **My Nodes** filter, managed/unmanaged segmentation + bulk-classify, QR code, click-through to detail/analytics, arming gate | `App/Nodes/*` | G0 |
| **G4** | **Telemetry (Swift Charts) + node analytics deep-dive**: real charts over telemetry/rollups; tabs — SNR/RSSI dist, hop histogram, peer/topology graph, hourly heatmap, packet-type breakdown | `App/Analytics/*` | — (existing records) |
| **G5** | **Alerts + arming UI + managed-aware suppression**: alert list/ack/snooze/cooldown over `AlertEngine`; unmanaged → no battery/stale; arming flow | `App/Alerts/*`, `RuleEngine` gating tests | G0 |
| **G6** | **Packet inspector + latency analytics**: byte-level breakdown, filters, detail pane, per-gateway receive→publish latency surfaced (inspector + map tooltips + analytics) | `App/Packets/*` | G0 |
| **G7** | **Fleet config rollout UI**: wire `FleetApplier` → live verify-each-then-next, halt-on-failure, diff preview, fleet-wide edit, progress + abort | `App/Fleet/*` | G0 |
| **G8** | **Messaging (monitor-only)**: decode text → `message` store → Channels view (sender, mentions, timestamps, DMs) | `App/Messages/*` | G0 |
| **G9** | **VCR / time-travel**: 24h timeline scrubber + variable-speed (≤4×) replay (over `ReplayAdapter`) driving the map animation | `App/Timeline/*` | — (existing replay) |
| **G10** | **Observability + ⌘K search + theme + collision matrix**: finish ingestion-lag/transport-health dashboard, global search palette, theme customizer, node-id 4-byte hash-collision matrix | `App/Observe/*`, `App/Search/*` | partly G0 |

### Dispatch waves (dependency-correct)

- **Wave 1 (parallel now):** G0 (Foundation), G1 (MapKit), G4 (Analytics), G9 (VCR).
  G1/G4/G9 are schema-independent (new files over existing types); G0 lands the seams.
- **Wave 2 (after G0 merges):** G2, G3, G5, G6, G7, G8, G10 — all compile against the
  new schema/types G0 introduces.
- **Integration:** lead merges each worktree, wires the section into the `AppModel`
  registry, runs full `make verify`, and updates `progress.txt` + plan checkboxes.

Per the "background agents don't survive process cycling" learning: every agent
**commits per molecular task** (conventional message) so a cycled worktree is
salvageable, never one big end-of-run commit.

---

## 6. Definition of done (Phase 7)

- `swift run MeshtrackApp` shows a **real MapKit map** animating **live** MQTT
  traffic: per-id coloured traces, guessed vs observed hops, hop badges, latency.
- Click a node → detail → edit config (arming-gated); select many → fleet rollout
  that verifies each node before the next and halts on failure.
- My-Nodes filter + managed/unmanaged segmentation suppress false battery/stale
  alerts for unmanaged nodes (RuleEngine test proves it).
- Channels view shows decoded messages; telemetry/analytics/packet-inspector/
  observability are live; VCR replays history; ⌘K search jumps anywhere.
- `make verify` green throughout; coverage floor held (≥80%, never lowered); every
  view model tested; snapshots deterministic (Canvas fallback for the map).
