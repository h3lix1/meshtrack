// meshtrackd — the headless, always-on collector (LaunchAgent target, SPEC §3).
//
// Phase 0: prove the composition root wires the real `Clock` adapter. Phase 1+
// opens the GRDB store, attaches transports (MQTT/Serial/BLE), runs the rule
// engine, and serves the SwiftUI app over the shared store / XPC.

import Domain

let clock: any Domain.Clock = SystemClock()

print("meshtrackd — Meshtastic fleet collector")
print("composition root online; clock now (ns since epoch): \(clock.now().nanosecondsSinceEpoch)")
// TODO(Phase 1): open Store, attach MeshTransport adapters, run ingestion actors.
