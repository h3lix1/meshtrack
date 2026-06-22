@testable import App
import Domain
import Foundation
import Persistence
import Testing

@Suite("NetworkViewModel (live network composition)")
@MainActor
struct NetworkViewModelTests {
    private func seededStore() async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // gateway (positioned), a source node (positioned), and an unpositioned node.
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_00FF, hexid: "!000000ff", short_name: "GW",
            node_class: .gateway, first_seen_at: 0, last_heard_at: 0
        ))
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_0001, hexid: "!00000001", short_name: "SRC",
            node_class: .mobile, first_seen_at: 0, last_heard_at: 0
        ))
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_0002, hexid: "!00000002", short_name: "NOFIX",
            node_class: .mobile, first_seen_at: 0, last_heard_at: 0
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x0000_00FF,
            t: 1,
            lat: 37.5,
            lon: -122.0
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x0000_0001,
            t: 1,
            lat: 37.0,
            lon: -122.0
        ))
        return store
    }

    @Test
    func `loadNodes builds positioned nodes and ignores those without a fix`() async throws {
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()
        #expect(model.nodes.count == 2) // NOFIX is ignored
        #expect(model.nodes.contains { $0.name == "GW" && $0.isGateway })
        #expect(!model.nodes.contains { $0.name == "NOFIX" })
    }

    @Test
    func `ingesting a decoded packet produces a live trace`() async throws {
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()
        #expect(model.traces.isEmpty)
        model.ingest(DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: 0xABCD, channel: 0,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 2, hopLimit: 1, gatewayID: 0x0000_00FF
        ))
        // The trace rebuild is coalesced; settle it before asserting (Phase 10).
        await model.flushPendingTraces()
        #expect(model.traces.count == 1)
        #expect(model.traces.first?.id == 0xABCD)
    }

    @Test
    func `ingesting records the source node's channel preset`() async throws {
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()
        // The preset stamp on the source node is SYNCHRONOUS (no flush needed); only the
        // trace rebuild is coalesced.
        model.ingest(DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: 0xABCD,
            channel: ChannelPreset.longFast.channelHash,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 2, hopLimit: 1, gatewayID: 0x0000_00FF
        ))
        #expect(model.presetByNode[0x0000_0001] == .longFast)
        #expect(model.nodes.first { $0.id == 0x0000_0001 }?.preset == .longFast)
        #expect(model.availablePresets == [.longFast])
    }

    @Test
    func `a trace keeps its original channel after the source retransmits elsewhere (Finding 20)`(
    ) async throws {
        // Finding 20: traces must filter on the channel they ARRIVED on, not the source
        // node's *current* preset. Two packets from node 1 — first on LongFast, then on
        // MediumFast — so the node's live preset flips to MediumFast. The first trace must
        // still belong to the LongFast filter, not move to MediumFast with the node.
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()

        model.ingest(DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: 0x1111,
            channel: ChannelPreset.longFast.channelHash,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 2, hopLimit: 1, gatewayID: 0x0000_00FF
        ))
        model.ingest(DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: 0x2222,
            channel: ChannelPreset.mediumFast.channelHash,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 2, hopLimit: 1, gatewayID: 0x0000_00FF
        ))
        await model.flushPendingTraces()

        // The source node's LIVE preset is now MediumFast (latest transmission)…
        #expect(model.presetByNode[0x0000_0001] == .mediumFast)
        // …but each trace carries its OWN immutable arrival channel.
        let longTrace = model.traces.first { $0.id == 0x1111 }
        let mediumTrace = model.traces.first { $0.id == 0x2222 }
        #expect(longTrace?.preset == .longFast)
        #expect(mediumTrace?.preset == .mediumFast)

        // Filtering proves the old trace did NOT migrate to the node's new channel.
        let onLong = ChannelFilter.filterTraces(model.traces, nodes: model.nodes, selection: .longFast)
        let onMedium = ChannelFilter.filterTraces(model.traces, nodes: model.nodes, selection: .mediumFast)
        #expect(onLong.map(\.id) == [0x1111])
        #expect(onMedium.map(\.id) == [0x2222])
    }

    // MARK: Coalesced rebuild (Phase 10)

    private func packet(id: UInt32) -> DecodedPacket {
        DecodedPacket(
            from: 0x0000_0001, to: 0xFFFF_FFFF, packetID: id, channel: 0,
            port: .telemetry, payload: [], rxTime: .epoch,
            hopStart: 2, hopLimit: 1, gatewayID: 0x0000_00FF
        )
    }

    @Test
    func `a burst of packets coalesces to one rebuild but yields every trace`() async throws {
        // Phase 10: ingest no longer rebuilds traces inline. A burst of packets inside the
        // coalesce window must collapse to a single rebuild, yet once it settles the
        // published traces must be EXACTLY what eager per-packet rebuilding produced —
        // one trace per distinct packet id.
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()

        let ids: [UInt32] = [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]
        for id in ids {
            model.ingest(packet(id: id))
        }
        await model.flushPendingTraces()

        #expect(model.traces.map(\.id).sorted() == ids.sorted())
    }

    @Test
    func `flushPendingTraces is idempotent and settles to the same traces`() async throws {
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()
        model.ingest(packet(id: 0xABCD))

        await model.flushPendingTraces()
        let first = model.traces.map(\.id)
        await model.flushPendingTraces() // second flush with nothing pending — a no-op
        #expect(model.traces.map(\.id) == first)
        #expect(first == [0xABCD])
    }

    @Test
    func `coalesced ingest matches eager rebuilds packet-for-packet`() async throws {
        // Equivalence guard: feeding the same packets one-at-a-time (flushing between
        // each, i.e. the old eager behaviour) and as a single burst (one coalesced flush)
        // must produce identical published traces — order, ids, and edge counts.
        let ids: [UInt32] = [0x01, 0x02, 0x03, 0x04, 0x05]

        let eager = try await NetworkViewModel(store: seededStore())
        try await eager.loadNodes()
        for id in ids {
            eager.ingest(packet(id: id))
            await eager.flushPendingTraces()
        }

        let coalesced = try await NetworkViewModel(store: seededStore())
        try await coalesced.loadNodes()
        for id in ids {
            coalesced.ingest(packet(id: id))
        }
        await coalesced.flushPendingTraces()

        #expect(eager.traces.map(\.id) == coalesced.traces.map(\.id))
        #expect(eager.traces.map(\.edges.count) == coalesced.traces.map(\.edges.count))
    }

    @Test
    func `ingest microbenchmark stays within budget (catches gross regressions)`() async throws {
        // Mirrors DecodePerfTests: a generous floor so a per-packet O(n) regression (the
        // old `nodes.map` on every packet + inline full rebuild) trips the wire. We time
        // the SYNCHRONOUS ingest cost — the expensive rebuild is coalesced out of it.
        let model = try await NetworkViewModel(store: seededStore())
        try await model.loadNodes()
        let iterations = 20000

        let elapsed = ContinuousClock().measure {
            for i in 0 ..< iterations {
                model.ingest(packet(id: UInt32(i)))
            }
        }
        await model.flushPendingTraces()

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let perSecond = Double(iterations) / max(seconds, 1e-9)
        #expect(
            perSecond > 20000,
            "ingest throughput \(Int(perSecond)) packets/sec is below the 20000 budget"
        )
    }
}
