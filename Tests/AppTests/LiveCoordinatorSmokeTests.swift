@testable import App
import Domain
import Foundation
import Persistence
import Testing

/// Env-gated live smoke for the in-app feed. It runs ONLY when a broker is
/// configured (`MESHTRACK_MQTT_HOST`), so the normal offline `make verify` skips
/// it and stays green.
///
/// Scope note: `AppTests` links only `App` + `Persistence` + `Domain` (it cannot
/// import the `MeshtrackApp` executable or the Transport/Ingest/Crypto stack the
/// live MQTT path uses). So this suite verifies the two seams the
/// `LiveCoordinator` is composed from — both reachable from here — under the
/// live-broker gate:
///   1. the broker env is decoded into a coherent connection (host/topic/TLS);
///   2. the `NetworkViewModel` live path (ingest a reception → loadNodes)
///      positions at least one node and animates a trace, exactly as the
///      coordinator drives it per decoded packet.
///
/// The end-to-end MQTT smoke (real packets off the wire) lives in the executable
/// and is verified manually:
///   MESHTRACK_MQTT_HOST=mqtt.bayme.sh MESHTRACK_MQTT_USER=… MESHTRACK_MQTT_PASS=… \
///   MESHTRACK_MQTT_TLS=1 MESHTRACK_MQTT_TOPIC=msh/US/bayarea/2/e/# swift run MeshtrackApp
@Suite("LiveCoordinator (live-broker smoke — env-gated)")
@MainActor
struct LiveCoordinatorSmokeTests {
    // Evaluated by the `.enabled(if:)` trait in a nonisolated context, so it must
    // not touch main-actor state.
    private nonisolated static var brokerConfigured: Bool {
        let host = ProcessInfo.processInfo.environment["MESHTRACK_MQTT_HOST"]
        return host.map { !$0.isEmpty } ?? false
    }

    @Test(.enabled(if: LiveCoordinatorSmokeTests.brokerConfigured))
    func `the broker environment decodes into a coherent connection`() throws {
        let env = ProcessInfo.processInfo.environment
        let host = try #require(env["MESHTRACK_MQTT_HOST"], "broker host must be set")
        #expect(!host.isEmpty)

        // A TLS broker with no explicit port should default to the TLS port; the
        // topic should be a Meshtastic v2 encrypted feed.
        let useTLS = env["MESHTRACK_MQTT_TLS"] == "1"
        if let portText = env["MESHTRACK_MQTT_PORT"] {
            #expect(UInt16(portText) != nil, "MESHTRACK_MQTT_PORT must be a valid port")
        }
        let topic = env["MESHTRACK_MQTT_TOPIC"] ?? "msh/US/bayarea/2/e/#"
        #expect(topic.hasPrefix("msh/"), "topic should be a Meshtastic v2 topic")
        // Credentials, if present, are non-empty (never logged here).
        if let user = env["MESHTRACK_MQTT_USER"] { #expect(!user.isEmpty) }
        print("live smoke: broker \(host) tls=\(useTLS) topic=\(topic)")
    }

    @Test(.enabled(if: LiveCoordinatorSmokeTests.brokerConfigured))
    func `the live composition positions a node and animates a trace from a reception`() async throws {
        // Mirror what the LiveCoordinator drives per decoded packet: ingest a
        // reception, then refresh nodes from the store. A node with a position fix
        // must surface on the map and the reception must animate as a trace.
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_00FF, hexid: "!000000ff", short_name: "GW",
            node_class: .gateway, first_seen_at: 0, last_heard_at: 0
        ))
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_0001, hexid: "!00000001", short_name: "SRC",
            node_class: .mobile, first_seen_at: 0, last_heard_at: 0
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(node_num: 0x0000_00FF, t: 1, lat: 37.5, lon: -122.0))
        _ = try await store.appendPositionFix(PositionFixRecord(node_num: 0x0000_0001, t: 1, lat: 37.0, lon: -122.0))

        let model = NetworkViewModel(store: store)
        model.ingest(DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: 0xABCD, channel: 0,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 2, hopLimit: 1, gatewayID: 0x0000_00FF
        ))
        try await model.loadNodes()

        #expect(!model.nodes.isEmpty, "at least one node should position")
        #expect(!model.traces.isEmpty, "the reception should animate a trace")
        print("live smoke: \(model.nodes.count) positioned nodes, \(model.traces.count) traces")
    }
}
