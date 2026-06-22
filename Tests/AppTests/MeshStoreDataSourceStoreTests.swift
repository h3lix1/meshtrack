@testable import App
import Persistence
import Testing

@Suite("MeshStoreDataSourceStore (app_config-backed data-source selection, Finding 23)")
struct MeshStoreDataSourceStoreTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `defaults to MQTT before anything is saved/hydrated`() throws {
        let adapter = try MeshStoreDataSourceStore(store: makeStore())
        #expect(adapter.load() == .default)
        #expect(adapter.load().kind == .mqtt)
    }

    @Test
    func `save then load reflects the new selection synchronously`() throws {
        let adapter = try MeshStoreDataSourceStore(store: makeStore())
        let serial = DataSourceConfig(kind: .serial, serialDevicePath: "/dev/cu.usbmodem3101")
        adapter.save(serial)
        #expect(adapter.load() == serial)
    }

    @Test
    func `a saved selection round-trips through app_config across a fresh adapter`() async throws {
        let store = try makeStore()
        let writer = MeshStoreDataSourceStore(store: store)
        let ble = DataSourceConfig(kind: .ble, bleDeviceName: "Meshtastic_1234")
        writer.save(ble)
        // Wait for the background write-through to land in app_config.
        try await Task.sleep(for: .milliseconds(50))

        let reader = MeshStoreDataSourceStore(store: store)
        // A fresh adapter starts at the default until hydrated…
        #expect(reader.load() == .default)
        await reader.hydrate()
        // …then reflects the persisted selection.
        #expect(reader.load() == ble)
    }

    @Test
    func `hydrate over an empty store leaves the default in place`() async throws {
        let adapter = try MeshStoreDataSourceStore(store: makeStore())
        await adapter.hydrate()
        #expect(adapter.load() == .default)
    }
}
