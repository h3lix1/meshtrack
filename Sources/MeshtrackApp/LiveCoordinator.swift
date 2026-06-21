// LiveCoordinator — the GUI composition root for LIVE operation.
//
// This is where the live wiring lives so the `App` library stays snapshot-pure
// (App must NOT import Ingest/Transport/Crypto, phase7-gui §4). The coordinator
// connects MQTT (broker + credentials from the environment, never the repo) → the
// validated `IngestPipeline` (decode + AES-CTR decrypt + persist) → the
// `NetworkViewModel`, so `swift run MeshtrackApp` animates real fleet traffic:
//
//   - the pipeline persists every reception (positions / telemetry / messages)
//     AND records `observation.ingest_time = frame.receivedAt` (the latency source);
//   - its `onDecoded` tap feeds each decoded packet into the view model so traces
//     animate the moment a packet arrives, even before a position fix lands;
//   - a slow refresh loop calls `loadNodes()` to surface newly-positioned nodes.
//
// With no broker configured the app falls back to sample data (the coordinator is
// simply not started). Thin composition over already-tested pieces.
//
//   env: MESHTRACK_MQTT_HOST / PORT / USER / PASS / TLS(=1) / TOPIC

import App
import Crypto
import Domain
import Foundation
import Ingest
import Persistence
import Transport

/// Drives the live network composition: owns the store, the `NetworkViewModel`,
/// and the long-running ingest + refresh tasks. `@MainActor` because it mutates
/// the view model the SwiftUI shell observes.
@MainActor
final class LiveCoordinator {
    /// The live network view model the shell renders (nodes + animated traces).
    let viewModel: NetworkViewModel
    /// The broker host, for the "connecting…" affordance (never logs credentials).
    let brokerHost: String

    private let store: MeshStore
    private let settings: LiveBrokerSettings
    private let refreshInterval: Duration
    private var tasks: [Task<Void, Never>] = []

    /// The well-known Meshtastic default channel key (PSK index 1, "AQ=="), shared
    /// by the public MediumFast/LongFast channels and applied to every channel
    /// hash — mirrors the proven `meshtrackd replay` wiring.
    private static let defaultKey = ChannelKey(psk: [
        0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
        0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01
    ])

    /// Build a coordinator over a fresh in-memory store. `refreshInterval` is the
    /// cadence of the slow `loadNodes()` loop that surfaces newly-positioned nodes.
    init(settings: LiveBrokerSettings, refreshInterval: Duration = .seconds(3)) throws {
        self.settings = settings
        self.refreshInterval = refreshInterval
        brokerHost = settings.host
        store = try MeshStore(DatabaseConnection.inMemory())
        viewModel = NetworkViewModel(store: store)
    }

    /// Connect and begin streaming live packets into the visualization. The
    /// pipeline persists + extracts while `onDecoded` feeds traces; a slow loop
    /// refreshes node positions from the store. Idempotent: a second call is a
    /// no-op while tasks are running.
    func start() {
        guard tasks.isEmpty else { return }

        let adapter = MQTTAdapter(config: settings.makeMQTTConfig(), clock: SystemWallClock())
        let decoder = PacketDecoder(
            keyStore: DefaultChannelKeyStore(key: Self.defaultKey),
            decryptor: AESCTRPacketDecryptor()
        )
        let pipeline = IngestPipeline(store: store, decoder: decoder)
        let model = viewModel

        // Ingest: decode + decrypt + persist, tapping each decoded packet into the
        // live trace animation. `ingest` hops to the main actor (the VM is
        // @MainActor); the tap is awaited per packet, so it stays in order.
        tasks.append(Task {
            _ = try? await pipeline.run(adapter) { packet in
                await model.ingest(packet)
            }
        })

        // Slow refresh: surface nodes as soon as they report a position.
        tasks.append(Task { [refreshInterval] in
            while !Task.isCancelled {
                try? await model.loadNodes()
                try? await Task.sleep(for: refreshInterval)
            }
        })
    }

    /// Cancel the live tasks (disconnects the MQTT stream via its termination
    /// handler). Safe to call more than once.
    func stop() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }
}

/// Returns the default channel key for every channel hash (the public Meshtastic
/// channels all share the default PSK). The single live-app key store; the durable
/// per-channel keys live in Keychain for managed channels (future work).
private struct DefaultChannelKeyStore: KeyStore {
    let key: ChannelKey
    func key(forChannelHash _: UInt32) -> ChannelKey? {
        key
    }
}

/// The real wall-clock adapter for the `Clock` port, confined to this composition
/// root (Domain never reads `Date()`). Stamps each inbound frame's `receivedAt`,
/// which becomes `observation.ingest_time` — the receive→publish latency source.
private struct SystemWallClock: Domain.Clock {
    func now() -> Instant {
        Instant(nanosecondsSinceEpoch: Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded()))
    }
}
