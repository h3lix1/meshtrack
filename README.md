# Meshtrack

A macOS-native command-and-monitoring app for Meshtastic fleets: a headless
collector (`meshtrackd`, a LaunchAgent) ingests packets over MQTT and a local
USB/BLE node, stores rich per-node history in SQLite, and a SwiftUI app renders
nodes on a map, arms them for movement, and provisions them from templates — with
an alerting engine for movement, silence, and battery.

Built test-first behind a hexagonal architecture so the core is deterministic and
CI-testable headlessly. See **[SPEC.md](SPEC.md)** for the contract,
**[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)** for the task queue, and
**[AGENTS.md](AGENTS.md)** for the engineering guardrails and build-loop contract.

## Quickstart

```bash
make bootstrap   # install dev tooling (swiftformat, swiftlint, muter)
make verify      # run the full gate suite — the only validator the loop trusts
make run         # run the meshtrackd collector
make loop        # run the autonomous Ralph build loop
```

Requires macOS 26 / Swift 6.2 (Xcode 26).

## Layout

| Path | What |
|---|---|
| `Sources/Domain` | Pure domain logic. No Foundation, no `Date()`, no I/O. |
| `Sources/MeshProtos` | Generated SwiftProtobuf from vendored `meshtastic/protobufs`. |
| `Sources/Persistence` | GRDB (SQLite WAL) store + migrations. |
| `Sources/Transport` | `MeshTransport` port + MQTT/Serial/BLE/Replay adapters. |
| `Sources/RuleEngine` | Typed alert rules + state machine. |
| `Sources/Provisioning` | Templates, naming DSL, admin apply. |
| `Sources/Scenario` | Acceptance harness: scenario DSL parser + runner. |
| `Sources/App` | SwiftUI viewer/controller. |
| `Sources/meshtrackd` | Headless collector (composition root + LaunchAgent). |
| `scripts/` | Gate scripts + the Ralph loop driver. |
| `docs/adr/` | Architecture decision records. |

## Architecture

Hexagonal / ports-and-adapters. `Domain` is pure and deterministic; all time
enters through the `Clock` port. The collector and UI are split so liveness/battery
alerting runs 24/7 over a shared store. See [docs/adr/](docs/adr/).
