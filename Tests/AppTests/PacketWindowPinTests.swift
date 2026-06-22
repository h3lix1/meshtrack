// PacketWindowPinTests — the selection-pin eviction rule (item 6) and the live
// configurable window cap (item 7) of PacketInspectorViewModel. Pure VM behaviour
// (no SwiftUI): selecting a packet id pins ALL its receptions in the window even as
// newer traffic pushes it past the cap, the pin releases on deselection/selection
// change, and resizing the window grows/shrinks the cap live while still honouring
// the pin.

@testable import App
import Domain
import Foundation
import Testing

@Suite("PacketInspectorViewModel — selection pin + window resize")
@MainActor
struct PacketWindowPinTests {
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

    // MARK: Item 6 — selection pin

    @Test
    func `a selected packet is not evicted when newer traffic exceeds the cap`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 2)
        vm.ingest(packet(packetID: 1))
        vm.selectedID = 1 // pin id 1
        vm.ingest(packet(packetID: 2))
        vm.ingest(packet(packetID: 3)) // would normally evict id 1
        // The cap is 2, but the pinned id 1 survives alongside the newest unpinned one.
        #expect(vm.packets.map(\.packetID).contains(1))
        #expect(vm.visiblePackets.contains { $0.packetID == 1 })
        #expect(vm.selected?.packetID == 1) // its detail aggregate stays intact
    }

    @Test
    func `every reception of the pinned packet survives eviction`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 2)
        vm.ingest(packet(packetID: 1)) // reception A of id 1
        vm.ingest(packet(packetID: 1)) // reception B of id 1
        vm.selectedID = 1
        vm.ingest(packet(packetID: 2))
        vm.ingest(packet(packetID: 3))
        // Both receptions of the pinned id remain, so the aggregate's count is intact.
        let pinnedReceptions = vm.packets.filter { $0.packetID == 1 }
        #expect(pinnedReceptions.count == 2)
        #expect(vm.visiblePackets.first { $0.packetID == 1 }?.receptionCount == 2)
    }

    @Test
    func `the pinned packet ages out once deselected`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 2)
        vm.ingest(packet(packetID: 1))
        vm.selectedID = 1
        vm.ingest(packet(packetID: 2))
        vm.ingest(packet(packetID: 3))
        #expect(vm.packets.map(\.packetID).contains(1)) // pinned, still here
        vm.selectedID = nil // deselect — pin releases, eviction re-runs
        #expect(vm.packets.map(\.packetID) == [3, 2]) // id 1 finally drops
    }

    @Test
    func `changing the selection re-pins the new id and frees the old`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 2)
        vm.ingest(packet(packetID: 1))
        vm.selectedID = 1
        vm.ingest(packet(packetID: 2))
        vm.ingest(packet(packetID: 3)) // id 1 pinned, survives
        #expect(vm.packets.map(\.packetID).contains(1))
        vm.selectedID = 3 // move the pin to id 3
        vm.ingest(packet(packetID: 4)) // push id 1 past the (now-unpinned) cap
        // id 1 is unpinned and over the cap — it drops; id 3 stays protected.
        #expect(!vm.packets.map(\.packetID).contains(1))
        #expect(vm.packets.map(\.packetID).contains(3))
    }

    @Test
    func `an unselected window still evicts oldest-first as before`() {
        // Item-6 must not change the no-selection behaviour (back-compat).
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 2)
        vm.ingest(packet(packetID: 1))
        vm.ingest(packet(packetID: 2))
        vm.ingest(packet(packetID: 3))
        #expect(vm.packets.map(\.packetID) == [3, 2])
    }

    // MARK: Item 7 — live window resize

    @Test
    func `growing the window lets more history accumulate`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 2)
        for id: UInt32 in 1 ... 4 {
            vm.ingest(packet(packetID: id))
        }
        #expect(vm.packets.count == 2) // capped at 2
        vm.windowSize = 10 // grow
        for id: UInt32 in 5 ... 8 {
            vm.ingest(packet(packetID: id))
        }
        #expect(vm.packets.count == 6) // 2 retained + 4 new, all under the new cap
    }

    @Test
    func `shrinking the window evicts oldest immediately`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 10)
        for id: UInt32 in 1 ... 6 {
            vm.ingest(packet(packetID: id))
        }
        #expect(vm.packets.count == 6)
        vm.windowSize = 3 // shrink — evict on the spot
        #expect(vm.packets.map(\.packetID) == [6, 5, 4]) // newest 3 kept
    }

    @Test
    func `shrinking honours the selection pin`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 10)
        for id: UInt32 in 1 ... 6 {
            vm.ingest(packet(packetID: id))
        }
        vm.selectedID = 1 // pin the oldest
        vm.windowSize = 2 // shrink hard
        // The 2 newest unpinned (6, 5) survive AND the pinned id 1 is preserved.
        #expect(vm.packets.map(\.packetID).contains(1))
        #expect(vm.packets.map(\.packetID).contains(6))
        #expect(vm.packets.map(\.packetID).contains(5))
        #expect(vm.selected?.packetID == 1)
    }

    @Test
    func `windowSize floors at one`() {
        let vm = PacketInspectorViewModel(clock: InjectedClock(), maxPackets: 5)
        for id: UInt32 in 1 ... 5 {
            vm.ingest(packet(packetID: id))
        }
        vm.windowSize = 0 // clamped to 1
        #expect(vm.packets.map(\.packetID) == [5])
    }

    @Test
    func `default window size stays 200`() {
        // Reset the persisted choice so the default-restoring init yields the literal
        // default regardless of any value a dev machine has saved (item 7).
        UserDefaults.standard.removeObject(forKey: "packetInspector.windowSize")
        let vm = PacketInspectorViewModel(clock: InjectedClock())
        #expect(vm.windowSize == 200)
    }
}
