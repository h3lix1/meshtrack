@testable import App
import Domain
import Testing

@Suite("ChannelPreset — Meshtastic channel-hash resolution")
struct ChannelPresetTests {
    @Test
    func `LongFast hashes to the well-known value 8`() {
        // The public/default LongFast channel transmits channel hash 8 — the canonical
        // sanity check that our XOR-fold + default-PSK matches real firmware.
        #expect(ChannelPreset.longFast.channelHash == 8)
    }

    @Test
    func `MediumFast hashes to 0x1F`() {
        #expect(ChannelPreset.mediumFast.channelHash == 0x1F)
    }

    @Test
    func `every preset hash resolves back to that preset`() {
        for preset in ChannelPreset.allCases {
            #expect(ChannelPreset.preset(forHash: preset.channelHash) == preset)
        }
    }

    @Test
    func `an unknown hash resolves to nil`() {
        // 0xAB collides with none of the eight presets' hashes.
        #expect(ChannelPreset.preset(forHash: 0xAB) == nil)
    }

    @Test
    func `the hash fold is name XOR psk`() {
        // Independent re-derivation of the algorithm pins the contract.
        let psk = ChannelPreset.defaultPSK
        let expected = UInt32(
            Array("MediumFast".utf8).reduce(UInt8(0)) { $0 ^ $1 }
                ^ psk.reduce(UInt8(0)) { $0 ^ $1 }
        )
        #expect(ChannelPreset.hash(name: "MediumFast", psk: psk) == expected)
    }
}

@Suite("ChannelFilter — per-channel map filtering")
@MainActor
struct ChannelFilterTests {
    private func node(_ id: Int64, _ preset: ChannelPreset?) -> NetworkNode {
        NetworkNode(
            id: id, name: "n\(id)",
            position: GeoPoint(latitude: 0, longitude: 0),
            hopsFromGateway: 0, preset: preset
        )
    }

    private let trace = PacketTrace(
        id: 1, sourceNode: 10,
        edges: [TraceEdge(
            from: GeoPoint(latitude: 0, longitude: 0),
            to: GeoPoint(latitude: 1, longitude: 1), kind: .observed
        )],
        hops: 1, startedAt: 0
    )

    @Test
    func `nil selection passes everything through`() {
        let nodes = [node(10, .longFast), node(11, .mediumFast)]
        #expect(ChannelFilter.filterNodes(nodes, selection: nil).count == 2)
        #expect(ChannelFilter.filterTraces([trace], nodes: nodes, selection: nil).count == 1)
    }

    @Test
    func `selecting a channel keeps only nodes on it`() {
        let nodes = [node(10, .longFast), node(11, .mediumFast), node(12, nil)]
        let kept = ChannelFilter.filterNodes(nodes, selection: .longFast)
        #expect(kept.map(\.id) == [10])
    }

    @Test
    func `a trace is hidden when its source node is off the selected channel`() {
        // source node 10 is on MediumFast, so a LongFast filter hides the trace.
        let nodes = [node(10, .mediumFast)]
        #expect(ChannelFilter.filterTraces([trace], nodes: nodes, selection: .longFast).isEmpty)
        #expect(ChannelFilter.filterTraces([trace], nodes: nodes, selection: .mediumFast).count == 1)
    }
}
