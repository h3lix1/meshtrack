// LiveCoordinator — the GUI composition root for LIVE operation.
//
// This is where the live wiring lives so the `App` library stays snapshot-pure
// (App must NOT import Ingest/Transport/Crypto, phase7-gui §4). The coordinator
// resolves the broker connection from the config store (NOT the environment,
// Phase 8): the non-secret `BrokerConfig` from a `ConfigGateway` + the password
// from a `CredentialStore`. It then connects MQTT → the validated
// `IngestPipeline` (decode + AES-CTR decrypt + persist) → the `NetworkViewModel`,
// so the app animates real fleet traffic:
//
//   - the pipeline persists every reception (positions / telemetry / messages)
//     AND records `observation.ingest_time = frame.receivedAt` (the latency source);
//   - its `onDecoded` tap feeds each decoded packet into the view model so traces
//     animate the moment a packet arrives, even before a position fix lands;
//   - a slow refresh loop calls `loadNodes()` to surface newly-positioned nodes.
//
// Reconnect-on-change: `applyBrokerConfig(_:)` restarts the MQTT stream against a
// new saved config, so saving a broker in Settings goes live without a relaunch.
//
// The legacy `MESHTRACK_MQTT_*` environment path is a FALLBACK only (see
// `LiveBrokerSettings.fromEnvironment`), wired by the composition root when no
// `BrokerConfig` has been saved.

import App
import Crypto
import Domain
import Foundation
import Ingest
import Persistence
import Transport

/// The shell-facing connection state. Carries only the broker host — never any
/// credentials — so the status indicator can show "connecting to mqtt.bayme.sh"
/// without ever surfacing a secret.
enum LiveConnectionStatus: Equatable, Sendable {
    case offline
    case connecting(host: String)
    case connected(host: String)

    /// The broker host, when connecting/connected; `nil` when offline.
    var host: String? {
        switch self {
        case .offline: nil
        case let .connecting(host), let .connected(host): host
        }
    }
}

/// Drives the live network composition: owns the store, the `NetworkViewModel`,
/// and the long-running ingest + refresh tasks. `@MainActor` because it mutates
/// the view model + status the SwiftUI shell observes.
@MainActor
@Observable
final class LiveCoordinator {
    /// The live network view model the shell renders (nodes + animated traces).
    let viewModel: NetworkViewModel
    /// The connection state for the status indicator (host only, never secrets).
    private(set) var status: LiveConnectionStatus = .offline

    /// The broker host, for the "connecting…" affordance (never logs credentials).
    var brokerHost: String { status.host ?? "" }

    /// The shared in-memory store; exposed so the shell can wire the store-backed
    /// section view models (nodes / telemetry / analytics / alerts / messages).
    let store: MeshStore
    private let refreshInterval: Duration
    /// The connection settings of the currently-running stream (incl. resolved
    /// password). `nil` while offline. Never logged.
    private var settings: LiveBrokerSettings?
    private var tasks: [Task<Void, Never>] = []

    /// The well-known Meshtastic default channel key (PSK index 1, "AQ=="), shared
    /// by the public MediumFast/LongFast channels and applied to every channel
    /// hash — mirrors the proven `meshtrackd replay` wiring.
    private static let defaultKey = ChannelKey(psk: [
        0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
        0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01
    ])

    /// Build a coordinator over a fresh in-memory store. The broker connection is
    /// resolved later via `applyBrokerConfig(_:)` / `start(settings:)`, so the
    /// coordinator exists before any broker is configured (first-run/onboarding).
    /// `refreshInterval` is the cadence of the slow `loadNodes()` loop that surfaces
    /// newly-positioned nodes.
    init(refreshInterval: Duration = .seconds(3)) throws {
        self.refreshInterval = refreshInterval
        store = try MeshStore(DatabaseConnection.inMemory())
        viewModel = NetworkViewModel(store: store)
    }

    /// Resolve the broker connection from the config store and, if a connectable
    /// `BrokerConfig` is saved, (re)start the live stream. Reconnect-on-change: if
    /// the resolved settings differ from the running stream's, the stream restarts;
    /// if they are identical it is a no-op. With no connectable config the stream
    /// stops and the status goes offline. The password is read from the
    /// `CredentialStore` and held only in memory.
    func applyConfig(
        gateway: any ConfigGateway,
        credentials: any CredentialStore
    ) async {
        guard let config = try? await gateway.loadBrokerConfig(), config.isConnectable else {
            stop()
            return
        }
        let password = credentials.password(host: config.host, username: config.username)
        apply(settings: LiveBrokerSettings.from(config: config, password: password))
    }

    /// (Re)start the live stream against `newSettings`. Restarts on change, no-ops
    /// when unchanged. Public seam for the env-fallback path and tests.
    func apply(settings newSettings: LiveBrokerSettings) {
        guard settings != newSettings else { return }
        stop()
        start(settings: newSettings)
    }

    /// Connect and begin streaming live packets into the visualization. The
    /// pipeline persists + extracts while `onDecoded` feeds traces; a slow loop
    /// refreshes node positions from the store.
    private func start(settings newSettings: LiveBrokerSettings) {
        settings = newSettings
        status = .connecting(host: newSettings.displayHost)

        let adapter = MQTTAdapter(config: newSettings.makeMQTTConfig(), clock: SystemWallClock())
        let decoder = PacketDecoder(
            keyStore: DefaultChannelKeyStore(key: Self.defaultKey),
            decryptor: AESCTRPacketDecryptor()
        )
        let pipeline = IngestPipeline(store: store, decoder: decoder)
        let model = viewModel
        let host = newSettings.displayHost
        // A @MainActor tap that promotes the status to `.connected`; capturing this
        // closure (rather than `self`) keeps the Sendable ingest closure clean.
        let onFirstPacket: @MainActor @Sendable () -> Void = { [weak self] in
            self?.markConnected(host: host)
        }

        // Ingest: decode + decrypt + persist, tapping each decoded packet into the
        // live trace animation. `ingest` hops to the main actor (the VM is
        // @MainActor); the tap is awaited per packet, so it stays in order. The
        // first decoded packet flips the status to `.connected` (we have a stream).
        tasks.append(Task {
            _ = try? await pipeline.run(adapter) { packet in
                await model.ingest(packet)
                await onFirstPacket()
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
    /// handler) and go offline. Safe to call more than once.
    func stop() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
        settings = nil
        status = .offline
    }

    /// Promote `.connecting` to `.connected` once the stream yields a packet. Only
    /// applies while still pointed at the same host (ignores stale taps from a
    /// stream that was replaced by a reconnect).
    private func markConnected(host: String) {
        if case .connecting(host) = status {
            status = .connected(host: host)
        }
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
struct SystemWallClock: Domain.Clock {
    func now() -> Instant {
        Instant(nanosecondsSinceEpoch: Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded()))
    }
}
