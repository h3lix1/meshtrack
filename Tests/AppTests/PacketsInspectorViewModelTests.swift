@testable import App
import Domain
import Testing

@Suite("PacketInspectorViewModel (window, selection, filters)")
@MainActor
struct PacketsInspectorViewModelTests {
    private func packet(
        packetID: UInt32,
        from: UInt32 = 0xAA,
        port: MeshPort = .telemetry
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: 0xFFFF_FFFF, packetID: packetID, channel: 0, port: port,
            payload: [], rxTime: .epoch, gatewayID: 0xFF
        )
    }

    @Test
    func `ingest grows the window newest-first`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        vm.ingest(packet(packetID: 1))
        vm.ingest(packet(packetID: 2))
        #expect(vm.packets.map(\.packetID) == [2, 1])
    }

    @Test
    func `sliding window evicts the oldest past the cap`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 2)
        vm.ingest(packet(packetID: 1))
        vm.ingest(packet(packetID: 2))
        vm.ingest(packet(packetID: 3))
        #expect(vm.packets.map(\.packetID) == [3, 2])
    }

    @Test
    func `selection defaults to the newest visible packet`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        vm.ingest(packet(packetID: 1))
        vm.ingest(packet(packetID: 2))
        #expect(vm.selected?.packetID == 2)
    }

    @Test
    func `explicit selection is honoured while visible`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        vm.ingest(packet(packetID: 1))
        vm.ingest(packet(packetID: 2))
        vm.selectedID = 1 // pin packet id 1
        #expect(vm.selected?.packetID == 1)
    }

    @Test
    func `selection falls back when filtered out`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        vm.ingest(packet(packetID: 1, port: .position))
        vm.ingest(packet(packetID: 2, port: .telemetry))
        vm.selectedID = 1 // select the position packet by id
        vm.filter = PacketFilter(port: .telemetry) // hides it
        #expect(vm.selected?.packetID == 2)
    }

    @Test
    func `visiblePackets respects the active filter`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        vm.ingest(packet(packetID: 1, from: 0xAA))
        vm.ingest(packet(packetID: 2, from: 0xBB))
        vm.filter = PacketFilter(fromNode: 0xBB)
        #expect(vm.visiblePackets.map(\.packetID) == [2])
    }

    @Test
    func `knownSources and knownPorts dedupe in arrival order`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        vm.ingest(packet(packetID: 1, from: 0xAA, port: .telemetry))
        vm.ingest(packet(packetID: 2, from: 0xBB, port: .telemetry))
        vm.ingest(packet(packetID: 3, from: 0xAA, port: .position))
        #expect(Set(vm.knownSources) == [0xAA, 0xBB])
        #expect(vm.knownSources.count == 2) // 0xAA not repeated
        #expect(vm.knownPorts.map(\.portNumRawValue).sorted() == [3, 67])
    }

    @Test
    func `duplicated packet id keeps distinct receptions in the raw window`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        vm.ingest(packet(packetID: 0x77)) // relay reception 1
        vm.ingest(packet(packetID: 0x77)) // relay reception 2
        #expect(vm.packets.count == 2)
        #expect(Set(vm.packets.map(\.id)).count == 2) // unique sequences
    }

    @Test
    func `duplicated packet id collapses to a single aggregated row`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        vm.ingest(packet(packetID: 0x77)) // relay reception 1
        vm.ingest(packet(packetID: 0x77)) // relay reception 2
        #expect(vm.visiblePackets.count == 1) // one row per id
        #expect(vm.visiblePackets.first?.receptionCount == 2)
    }
}
