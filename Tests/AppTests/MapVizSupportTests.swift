@testable import App
import CoreGraphics
import Domain
import Testing

@Suite("RelayConfidence")
struct RelayConfidenceTests {
    /// Three nodes whose ids end in 0x11; one ending in 0x22.
    private let positions: [Int64: GeoPoint] = [
        0x0AC1_5511: GeoPoint(latitude: 1, longitude: 1),
        0xBEEF_0011: GeoPoint(latitude: 2, longitude: 2),
        0xF00D_AB11: GeoPoint(latitude: 3, longitude: 3),
        0x1234_5622: GeoPoint(latitude: 4, longitude: 4)
    ]

    @Test
    func `candidate count matches nodes sharing the relay byte`() {
        #expect(RelayConfidence.candidateCount(relayByte: 0x11, positions: positions) == 3)
        #expect(RelayConfidence.candidateCount(relayByte: 0x22, positions: positions) == 1)
        #expect(RelayConfidence.candidateCount(relayByte: 0x99, positions: positions) == 0)
    }

    @Test
    func `excluded nodes are not counted as candidates`() {
        let count = RelayConfidence.candidateCount(
            relayByte: 0x11, excluding: [0x0AC1_5511], positions: positions
        )
        #expect(count == 2)
    }

    @Test
    func `confidence level buckets by candidate count`() {
        #expect(RelayConfidence.level(forCandidateCount: 0) == .none)
        #expect(RelayConfidence.level(forCandidateCount: 1) == .high)
        #expect(RelayConfidence.level(forCandidateCount: 2) == .medium)
        #expect(RelayConfidence.level(forCandidateCount: 3) == .medium)
        #expect(RelayConfidence.level(forCandidateCount: 9) == .low)
    }
}

@Suite("VizLegend")
struct VizLegendTests {
    @Test
    func `entries are sorted by id with stable colours and hex labels`() {
        let entries = VizLegend.entries(for: SampleNetwork.traces)
        #expect(!entries.isEmpty)
        #expect(entries == entries.sorted { $0.id < $1.id })
        for entry in entries {
            #expect(entry.color == PacketColor.color(for: entry.id))
            #expect(entry.label == VizLegend.hexLabel(entry.id))
        }
    }

    @Test
    func `guessed edge count is surfaced per trace`() {
        // SampleNetwork's first trace has exactly one guessed edge.
        let entries = VizLegend.entries(for: SampleNetwork.traces)
        let first = entries.first { $0.id == 0x2A3B_4C5D }
        #expect(first?.guessedEdges == 1)
        #expect(first?.hops == 3)
    }

    @Test
    func `hex label is zero-padded eight digits`() {
        #expect(VizLegend.hexLabel(0x0000_00FF) == "#000000ff")
        #expect(VizLegend.hexLabel(0xA1B2_C3D4) == "#a1b2c3d4")
    }

    @Test
    func `confidence hint reflects the candidate count`() {
        #expect(VizLegend.confidenceHint(candidateCount: 0).contains("no candidate"))
        #expect(VizLegend.confidenceHint(candidateCount: 1).contains("high confidence"))
        #expect(VizLegend.confidenceHint(candidateCount: 4).contains("4"))
    }
}

@Suite("MapProjection adapter")
struct MapProjectionTests {
    @Test
    func `point(for:) forwards to the supplied conversion`() {
        // The adapter must mirror GeoProjection.point(for:) — same shape, different
        // coordinate source. Here we stand in a deterministic conversion.
        let projection = MapProjection { geo in
            CGPoint(x: geo.longitude * 2, y: geo.latitude * 3)
        }
        let point = projection.point(for: GeoPoint(latitude: 5, longitude: 10))
        #expect(point == CGPoint(x: 20, y: 15))
    }

    @Test
    func `MapProjection conforms to TraceProjection like GeoProjection`() {
        // Both must be usable through the shared protocol so the renderer is agnostic.
        let geo: any TraceProjection = GeoProjection(
            points: [GeoPoint(latitude: 0, longitude: 0)],
            in: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let map: any TraceProjection = MapProjection { _ in CGPoint(x: 1, y: 1) }
        #expect(map.point(for: GeoPoint(latitude: 0, longitude: 0)) == CGPoint(x: 1, y: 1))
        #expect(geo.point(for: GeoPoint(latitude: 0, longitude: 0)).x.isFinite)
    }
}

@Suite("VizSettings")
@MainActor
struct VizSettingsTests {
    @Test
    func `hopDuration clamps to the allowed range`() {
        let tooLow = VizSettings(hopDuration: -5)
        #expect(tooLow.hopDuration == VizSettings.minHopDuration)
        let tooHigh = VizSettings(hopDuration: 99)
        #expect(tooHigh.hopDuration == VizSettings.maxHopDuration)
    }

    @Test
    func `mutating hopDuration past a bound clamps`() {
        let settings = VizSettings(hopDuration: 1.0)
        settings.hopDuration = 100
        #expect(settings.hopDuration == VizSettings.maxHopDuration)
    }

    @Test
    func `mode derives from the equaliseFinish toggle`() {
        let settings = VizSettings(equaliseFinish: false)
        #expect(settings.mode == .sequential)
        settings.equaliseFinish = true
        #expect(settings.mode == .equaliseFinish)
    }
}
