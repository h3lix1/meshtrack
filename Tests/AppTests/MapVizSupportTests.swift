@testable import App
import CoreGraphics
import Domain
import Testing

#if canImport(AppKit)
    import AppKit
    import SwiftUI
#endif

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

@Suite("PacketFocus")
struct PacketFocusTests {
    private let nodes = SampleNetwork.nodes
    private let traces = SampleNetwork.traces

    /// The 3-hop San Jose trace: source 0x5A1B_0303, touching Palo Alto, Oakland, SF.
    private let focusID: UInt32 = 0x2A3B_4C5D
    private let touchedByFocus: Set<Int64> = [
        0x5A1B_0303, // source: San Jose
        0x9A10_0404, // Palo Alto (guessed relay endpoint)
        0x0AC1_5511, // Oakland
        0xA1B2_C3D4 // SF gateway
    ]

    @Test
    func `nil focus is the identity for nodes and traces`() {
        let outNodes = PacketFocus.focusNodes(nodes, traces: traces, selectedPacketID: nil)
        let outTraces = PacketFocus.focusTraces(traces, selectedPacketID: nil)
        #expect(outNodes == nodes)
        #expect(outTraces == traces)
    }

    @Test
    func `focusing a packet yields only that trace`() {
        let outTraces = PacketFocus.focusTraces(traces, selectedPacketID: focusID)
        #expect(outTraces.count == 1)
        #expect(outTraces.first?.id == focusID)
    }

    @Test
    func `focusing a packet yields only the nodes it touches`() {
        let outNodes = PacketFocus.focusNodes(nodes, traces: traces, selectedPacketID: focusID)
        #expect(Set(outNodes.map(\.id)) == touchedByFocus)
        // Nodes on other traces are hidden (e.g. Fremont, the source of another packet).
        #expect(!outNodes.contains { $0.id == 0xF1B8_0606 })
    }

    @Test
    func `focused nodes keep their input order`() {
        let outNodes = PacketFocus.focusNodes(nodes, traces: traces, selectedPacketID: focusID)
        let expected = nodes.filter { touchedByFocus.contains($0.id) }.map(\.id)
        #expect(outNodes.map(\.id) == expected)
    }

    @Test
    func `focusing an unknown packet hides everything`() {
        let outNodes = PacketFocus.focusNodes(nodes, traces: traces, selectedPacketID: 0xDEAD_0000)
        let outTraces = PacketFocus.focusTraces(traces, selectedPacketID: 0xDEAD_0000)
        #expect(outNodes.isEmpty)
        #expect(outTraces.isEmpty)
    }

    @Test
    func `a pinned focused packet stays in the legend after live-window retirement`() throws {
        let selected = try #require(traces.first { $0.id == focusID })
        let liveAfterRetirement = traces.filter { $0.id != focusID }

        let pinned = PacketFocus.pinSelectedTrace(
            liveAfterRetirement,
            selectedPacketID: focusID,
            pinnedTrace: selected
        )

        #expect(pinned.contains { $0.id == focusID })
        #expect(PacketFocus.focusTraces(pinned, selectedPacketID: focusID) == [selected])
        #expect(VizLegend.entries(for: pinned).contains { entry in
            entry.id == focusID && PacketFocus.isFocused(entry.id, selectedPacketID: focusID)
        })
    }

    @Test
    func `pinning does not duplicate a selected packet still in the live trace window`() throws {
        let selected = try #require(traces.first { $0.id == focusID })
        let pinned = PacketFocus.pinSelectedTrace(
            traces,
            selectedPacketID: focusID,
            pinnedTrace: selected
        )
        #expect(pinned.count(where: { $0.id == focusID }) == 1)
        #expect(pinned == traces)
    }

    @Test
    func `toggling focus selects then resets`() {
        let focused = PacketFocus.toggled(focusID, current: nil)
        #expect(focused == focusID)
        let reset = PacketFocus.toggled(focusID, current: focusID)
        #expect(reset == nil)
        // Toggling a different id while one is focused switches focus.
        let switched = PacketFocus.toggled(0x7788_99AA, current: focusID)
        #expect(switched == 0x7788_99AA)
    }

    @Test
    func `isFocused reflects the current selection`() {
        #expect(PacketFocus.isFocused(focusID, selectedPacketID: focusID))
        #expect(!PacketFocus.isFocused(focusID, selectedPacketID: 0x7788_99AA))
        #expect(!PacketFocus.isFocused(focusID, selectedPacketID: nil))
    }

    @Test
    @MainActor
    func `focus composes after the channel filter, narrowing further`() {
        // Stamp the two SF-trace nodes onto one preset, the rest onto another, so the
        // channel filter and the focus overlap on the same packet.
        let preset = ChannelPreset.mediumFast
        let other = ChannelPreset.longFast
        let stamped = nodes.map { node -> NetworkNode in
            touchedByFocus.contains(node.id) ? node.withPreset(preset) : node.withPreset(other)
        }
        // Channel filter first: keep only the focus packet's nodes/traces' channel.
        let channelled = ChannelFilter.filterNodes(stamped, selection: preset)
        let channelledTraces = ChannelFilter.filterTraces(
            traces, nodes: stamped, selection: preset
        )
        // Then focus narrows to the single packet — composition is stable.
        let focusedNodes = PacketFocus.focusNodes(
            channelled, traces: channelledTraces, selectedPacketID: focusID
        )
        let focusedTraces = PacketFocus.focusTraces(channelledTraces, selectedPacketID: focusID)
        #expect(Set(focusedNodes.map(\.id)) == touchedByFocus)
        #expect(focusedTraces.map(\.id) == [focusID])
    }

    @Test
    @MainActor
    func `channel filter hiding the focused packet leaves nothing`() {
        // Source node on a different channel than the filter → its trace is filtered out,
        // and focusing it can't resurrect a packet the channel filter already removed.
        let preset = ChannelPreset.mediumFast
        let stamped = nodes.map { $0.withPreset(.longFast) }
        let channelledTraces = ChannelFilter.filterTraces(
            traces, nodes: stamped, selection: preset
        )
        let focusedTraces = PacketFocus.focusTraces(channelledTraces, selectedPacketID: focusID)
        #expect(focusedTraces.isEmpty)
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

@Suite("MapDeclutterPolicy")
struct MapDeclutterPolicyTests {
    @Test
    func `broad zoom clusters annotations and uses lightweight trace detail`() {
        let level = MapDeclutterPolicy.level(metersPerPoint: 300, visibleNodeCount: 24)

        #expect(level == .overview)
        #expect(level.clustersAnnotations)
        #expect(!level.allowsSpiderfy)
        let detail = MapDeclutterPolicy.traceDetail(isInteracting: false, declutterLevel: level)
        #expect(detail == .interactive)
    }

    @Test
    func `sparse close zoom restores individual annotations and full overlay detail`() {
        let level = MapDeclutterPolicy.level(metersPerPoint: 30, visibleNodeCount: 24)

        #expect(level == .individual)
        #expect(!level.clustersAnnotations)
        #expect(level.allowsSpiderfy)
        let detail = MapDeclutterPolicy.traceDetail(isInteracting: false, declutterLevel: level)
        #expect(detail == .full)
    }

    @Test
    func `dense maps stay clustered until zoomed closer`() {
        let midZoom = MapDeclutterPolicy.level(metersPerPoint: 30, visibleNodeCount: 600)
        let closeZoom = MapDeclutterPolicy.level(metersPerPoint: 15, visibleNodeCount: 600)

        #expect(midZoom == .clustered)
        #expect(midZoom.clustersAnnotations)
        #expect(closeZoom == .individual)
    }

    @Test
    func `active map interaction always uses lightweight trace detail`() {
        let level = MapDeclutterPolicy.level(metersPerPoint: 10, visibleNodeCount: 12)

        #expect(level == .individual)
        let detail = MapDeclutterPolicy.traceDetail(isInteracting: true, declutterLevel: level)
        #expect(detail == .interactive)
    }

    @Test
    func `invalid zoom input falls back to overview decluttering`() {
        let level = MapDeclutterPolicy.level(metersPerPoint: .nan, visibleNodeCount: 12)

        #expect(level == .overview)
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

    @Test
    func `relay guessing exposes all collisions mode and preserves the old toggle`() {
        let settings = VizSettings(relayGuessingPolicy: .allCandidates)
        #expect(settings.relayGuessingPolicy == .allCandidates)
        #expect(settings.relayGuessingDetail.contains("colliding"))

        settings.ignoreAmbiguousRelayGuesses = true
        #expect(settings.relayGuessingPolicy == .unambiguousOnly)

        settings.ignoreAmbiguousRelayGuesses = false
        #expect(settings.relayGuessingPolicy == .nearestCandidate)
    }
}

#if canImport(AppKit)
    @Suite("VizSettingsPanel headless render")
    @MainActor
    struct VizSettingsPanelRenderTests {
        private func renderedByteCount(_ view: some View, width: CGFloat, height: CGFloat) -> Int {
            let renderer = ImageRenderer(content: view.frame(width: width, height: height))
            renderer.scale = 1
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { return 0 }
            return png.count
        }

        private func traceWithManyReceivers(count: Int = 130) -> PacketTrace {
            let source = GeoPoint(latitude: 37.0, longitude: -122.0)
            let gateway = GeoPoint(latitude: 37.8, longitude: -122.4)
            var receivers: [TraceReceiver] = []
            receivers.reserveCapacity(count)
            for index in 0 ..< count {
                let position = GeoPoint(
                    latitude: 37.1 + Double(index) * 0.001,
                    longitude: -122.1 - Double(index) * 0.001
                )
                let kind: TraceReceiver.Kind = index.isMultiple(of: 5) ? .gateway : .relay
                receivers.append(TraceReceiver(
                    nodeID: Int64(0x0001_0000 + index),
                    position: position,
                    hop: index % 6 + 1,
                    kind: kind
                ))
            }
            return PacketTrace(
                id: 0xCAFE_BABE,
                sourceNode: 0x0000_0001,
                edges: [TraceEdge(from: source, to: gateway, kind: .observed, hopIndex: 1)],
                hops: 6,
                startedAt: 0,
                receivers: receivers
            )
        }

        @Test
        func `panel renders a bounded scrollable roster with one hundred plus receivers`() {
            let trace = traceWithManyReceivers()
            let settings = VizSettings(
                hopDuration: 1.2,
                equaliseFinish: false,
                showAllReceivers: true
            )
            let panel = VizSettingsPanel(
                settings: settings,
                traces: [trace],
                selectedPacketID: trace.id,
                maxHeight: 360
            )
            let bytes = renderedByteCount(panel, width: 280, height: 380)
            #expect(bytes > 1000, "panel rendered only \(bytes) bytes")
        }
    }
#endif
