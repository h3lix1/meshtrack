import Domain
import Foundation
@testable import Ingest
import MeshProtos
import Persistence
import Testing
import Transport

@Suite("IngestPipeline NODEINFO (User → node identity)")
struct IngestNodeInfoTests {
    // MARK: Fakes

    private struct StubTransport: MeshTransport {
        let queued: [InboundFrame]
        func frames() -> AsyncStream<InboundFrame> {
            AsyncStream { continuation in
                for frame in queued {
                    continuation.yield(frame)
                }
                continuation.finish()
            }
        }
    }

    private struct EmptyKeyStore: KeyStore {
        func key(forChannelHash _: UInt32) -> ChannelKey? {
            nil
        }
    }

    private struct NoopDecryptor: PacketDecryptor {
        func decrypt(_ c: [UInt8], packetID _: UInt32, fromNode _: UInt32, key _: ChannelKey) -> [UInt8] {
            c
        }
    }

    private func pipeline(_ store: MeshStore) -> IngestPipeline {
        IngestPipeline(
            store: store,
            decoder: PacketDecoder(keyStore: EmptyKeyStore(), decryptor: NoopDecryptor())
        )
    }

    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

    /// A plaintext NODEINFO frame carrying `payload`, from `from`.
    private func frame(from: UInt32, packetID: UInt32, payload: Data, at instant: Instant) -> InboundFrame {
        var data = DataMessage()
        data.portnum = .nodeinfoApp
        data.payload = payload
        var packet = MeshPacket()
        packet.from = from
        packet.id = packetID
        packet.channel = 8
        packet.decoded = data
        var env = ServiceEnvelope()
        env.packet = packet
        env.gatewayID = "!gw1"
        // serializedData() can throw only on a malformed message; the fixture above
        // is well-formed, so an empty payload on failure simply fails the assertions.
        let bytes = (try? [UInt8](env.serializedData())) ?? []
        return InboundFrame(
            transport: .mqtt,
            topic: "msh/US/2/e/MediumFast/!gw1",
            payload: bytes,
            receivedAt: instant,
            gatewayID: "!gw1"
        )
    }

    private func nodeInfoPayload(
        id: String,
        longName: String,
        shortName: String,
        hwModel: HardwareModel = .unset,
        role: Config.DeviceConfig.Role = .client
    ) -> Data {
        var user = User()
        user.id = id
        user.longName = longName
        user.shortName = shortName
        user.hwModel = hwModel
        user.role = role
        return (try? user.serializedData()) ?? Data()
    }

    // MARK: Tests

    @Test
    func `a NODEINFO packet fills in the node's short, long, and hex names plus hw/role`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [frame(
            from: 0xDEAD_BEEF,
            packetID: 11,
            payload: nodeInfoPayload(
                id: "!deadbeef",
                longName: "Summit Repeater",
                shortName: "SMT",
                hwModel: .heltecV3,
                role: .router
            ),
            at: at(20)
        )]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))

        #expect(summary.nodeInfoRecorded == 1)
        let node = try await store.fetchNode(nodeNum: 0xDEAD_BEEF)
        #expect(node?.short_name == "SMT")
        #expect(node?.long_name == "Summit Repeater")
        #expect(node?.hexid == "!deadbeef")
        #expect(node?.hw_model == "HELTEC_V3")
        #expect(node?.role == "ROUTER")
        // markHeard still maintained liveness for the same reception.
        #expect(node?.last_heard_at == at(20).nanosecondsSinceEpoch)
    }

    @Test
    func `a default-role NODEINFO records CLIENT (the proto3-omitted default)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [frame(
            from: 0x1234,
            packetID: 15,
            payload: nodeInfoPayload(id: "!00001234", longName: "Plain Client", shortName: "PLN"),
            at: at(50)
        )]
        _ = try await pipeline(store).run(StubTransport(queued: frames))
        #expect(try await store.fetchNode(nodeNum: 0x1234)?.role == "CLIENT")
    }

    @Test
    func `a NODEINFO packet preserves ownership flags, class, and first_seen_at`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // Pre-existing node the operator already classified as their own + managed.
        try await store.upsertNode(NodeRecord(
            node_num: 0xCAFE,
            hexid: "!0000cafe",
            short_name: "OLD",
            node_class: .gateway,
            first_seen_at: at(1).nanosecondsSinceEpoch,
            last_heard_at: at(1).nanosecondsSinceEpoch,
            is_mine: true,
            is_managed: true
        ))
        let frames = [frame(
            from: 0xCAFE,
            packetID: 12,
            payload: nodeInfoPayload(id: "!0000cafe", longName: "Cafe Node", shortName: "CAF"),
            at: at(30)
        )]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))

        #expect(summary.nodeInfoRecorded == 1)
        let node = try await store.fetchNode(nodeNum: 0xCAFE)
        // Names updated …
        #expect(node?.short_name == "CAF")
        #expect(node?.long_name == "Cafe Node")
        // … while ownership, class, and first_seen_at are preserved (not clobbered).
        #expect(node?.is_mine == true)
        #expect(node?.is_managed == true)
        #expect(node?.node_class == .gateway)
        #expect(node?.first_seen_at == at(1).nanosecondsSinceEpoch)
        #expect(node?.last_heard_at == at(30).nanosecondsSinceEpoch)
    }

    @Test
    func `a sparse NODEINFO does not erase a previously-known name`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(
            node_num: 0xBEE,
            short_name: "KNOWN",
            long_name: "Known Long Name",
            first_seen_at: at(1).nanosecondsSinceEpoch,
            last_heard_at: at(1).nanosecondsSinceEpoch
        ))
        // A NODEINFO advertising only a short name must not blank the long name.
        let frames = [frame(
            from: 0xBEE,
            packetID: 13,
            payload: nodeInfoPayload(id: "", longName: "", shortName: "NEW"),
            at: at(40)
        )]
        _ = try await pipeline(store).run(StubTransport(queued: frames))

        let node = try await store.fetchNode(nodeNum: 0xBEE)
        #expect(node?.short_name == "NEW")
        #expect(node?.long_name == "Known Long Name") // preserved, not erased
    }

    @Test
    func `an ownership write racing a NODEINFO ingest is not lost (Finding 9)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // A pre-existing, operator-classified node.
        try await store.upsertNode(NodeRecord(
            node_num: 0xC0DE,
            short_name: "OLD",
            first_seen_at: at(1).nanosecondsSinceEpoch,
            last_heard_at: at(1).nanosecondsSinceEpoch
        ))

        // Fire the ownership write and the NODEINFO ingest concurrently. Because
        // the ingest now fetch-merges-upserts inside a SINGLE write transaction,
        // neither effect can clobber the other regardless of interleaving: the
        // NODEINFO's name AND the ownership flag must both survive.
        let frames = [frame(
            from: 0xC0DE,
            packetID: 21,
            payload: nodeInfoPayload(id: "!0000c0de", longName: "Concurrent Node", shortName: "CON"),
            at: at(60)
        )]
        async let ownership: Void = store.setOwnership(nodeNum: 0xC0DE, isMine: true, isManaged: true)
        async let ingest = pipeline(store).run(StubTransport(queued: frames))
        _ = try await (ownership, ingest)

        let node = try await store.fetchNode(nodeNum: 0xC0DE)
        // The NODEINFO identity landed …
        #expect(node?.short_name == "CON")
        #expect(node?.long_name == "Concurrent Node")
        // … and the racing ownership write was NOT clobbered by a stale snapshot.
        #expect(node?.is_mine == true)
        #expect(node?.is_managed == true)
    }

    @Test
    func `malformed NODEINFO bytes are skipped, not fatal`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [frame(
            from: 0xF00D,
            packetID: 14,
            payload: Data([0xFF, 0xFF, 0xFF, 0xFF]), // not a valid User protobuf
            at: at(0)
        )]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))
        #expect(summary.packetsDecoded == 1) // the envelope decoded fine
        #expect(summary.nodeInfoRecorded == 0) // but the User payload did not
        // Node still exists from markHeard, just without names.
        let node = try await store.fetchNode(nodeNum: 0xF00D)
        #expect(node != nil)
        #expect(node?.short_name == nil)
    }
}
