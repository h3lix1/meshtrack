// LiveCoordinator — the GUI composition root for LIVE operation. Connects MQTT
// (broker + creds from the environment, never the repo) → the validated
// IngestPipeline (decode + AES-CTR decrypt + persist) → NetworkViewModel, so
// `swift run MeshtrackApp` shows real fleet traffic. With no broker configured the
// app falls back to sample data. Thin composition over already-tested pieces.
//
//   env: MESHTRACK_MQTT_HOST / PORT / USER / PASS / TLS(=1) / TOPIC

import Crypto
import Domain
import Foundation
import Ingest
import Persistence
import SwiftUI
import Transport

@MainActor
public final class LiveCoordinator {
    public let viewModel: NetworkViewModel
    public let brokerHost: String
    private let store: MeshStore
    private let config: MQTTConfig
    private var tasks: [Task<Void, Never>] = []

    /// Well-known Meshtastic default channel PSK (the public MediumFast/LongFast
    /// channels share it); applied to every channel hash.
    private static let defaultKey = ChannelKey(psk: [
        0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
        0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01
    ])

    public init(config: MQTTConfig) throws {
        self.config = config
        brokerHost = config.host
        store = try MeshStore(DatabaseConnection.inMemory())
        viewModel = NetworkViewModel(store: store)
    }

    /// Build a broker config from the environment, or nil if none is configured.
    public static func environmentConfig() -> MQTTConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MESHTRACK_MQTT_HOST"] else { return nil }
        return MQTTConfig(
            host: host,
            port: UInt16(env["MESHTRACK_MQTT_PORT"] ?? "") ?? 1883,
            username: env["MESHTRACK_MQTT_USER"],
            password: env["MESHTRACK_MQTT_PASS"],
            useTLS: env["MESHTRACK_MQTT_TLS"] == "1",
            topics: [env["MESHTRACK_MQTT_TOPIC"] ?? "msh/US/bayarea/2/e/#"]
        )
    }

    /// Connect and begin streaming live packets into the visualization: the
    /// pipeline persists + extracts positions while `onDecoded` feeds traces; a
    /// slow loop refreshes node positions from the store.
    public func start() {
        let adapter = MQTTAdapter(config: config, clock: WallClock())
        let decoder = PacketDecoder(
            keyStore: SingleKeyStore(key: Self.defaultKey),
            decryptor: AESCTRPacketDecryptor()
        )
        let pipeline = IngestPipeline(store: store, decoder: decoder)
        let model = viewModel

        tasks.append(Task {
            _ = try? await pipeline.run(adapter) { packet, _ in
                await model.ingest(packet)
            }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                try? await model.loadNodes()
                try? await Task.sleep(for: .seconds(3))
            }
        })
    }

    public func stop() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }
}

/// The live shell: RootView bound to the coordinator's view model. Reading the
/// @Observable nodes/traces here re-renders as live packets arrive.
public struct LiveRootView: View {
    public let coordinator: LiveCoordinator
    public init(coordinator: LiveCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ZStack {
            RootView(nodes: coordinator.viewModel.nodes, traces: coordinator.viewModel.traces)
            if coordinator.viewModel.nodes.isEmpty {
                connecting
            }
        }
    }

    private var connecting: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(.cyan)
            Text("Connecting to \(coordinator.brokerHost)…").font(.headline).foregroundStyle(.white)
            Text("Waiting for nodes to report a position").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SingleKeyStore: KeyStore {
    let key: ChannelKey
    func key(forChannelHash _: UInt32) -> ChannelKey? {
        key
    }
}

private struct WallClock: Domain.Clock {
    func now() -> Instant {
        Instant(nanosecondsSinceEpoch: Int64((Date().timeIntervalSince1970 * 1_000_000_000).rounded()))
    }
}
