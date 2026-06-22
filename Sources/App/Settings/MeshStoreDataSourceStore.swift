// MeshStoreDataSourceStore — the shared-store `DataSourceStore` (Finding 23).
//
// The data-source selection (MQTT broker vs locally-attached node) is NON-SECRET
// config, and the shared-store contract says non-secret config lives in the GRDB
// `app_config` table alongside the broker config / channel registry — not in
// `UserDefaults`. The original `UserDefaultsDataSourceStore` violated that: the
// selection lived in a separate `UserDefaults` blob, so it didn't travel with the
// store (backup/migration/inspection) and diverged from every other config row.
//
// The `DataSourceStore` PORT is intentionally synchronous (`load()`/`save()` are
// called from non-async UI paths and from `LiveDataSource.resolve`), but `MeshStore`
// is async. This adapter bridges that by keeping a synchronously-readable in-memory
// cache that mirrors the durable `app_config` row:
//
//   • `hydrate()` (async) loads the persisted selection into the cache once at
//     startup, before the composition root resolves the live source;
//   • `load()` returns the cache synchronously;
//   • `save(_:)` updates the cache immediately (so a following `load()` is
//     consistent) and writes through to `app_config` durably in the background.
//
// The DB is the source of truth across launches; the cache is the sync mirror.

import Domain
import Foundation
import Persistence
import Synchronization

/// A `DataSourceStore` backed by the shared `MeshStore` (`app_config`), keeping the
/// non-secret selection in the same durable store as the rest of the config.
public final class MeshStoreDataSourceStore: DataSourceStore {
    private let store: MeshStore
    private let key: String
    /// The synchronously-readable mirror of the persisted selection. Seeded with the
    /// default, replaced by `hydrate()` and every `save(_:)`.
    private let cache: Mutex<DataSourceConfig>

    public init(store: MeshStore, key: String = "data_source") {
        self.store = store
        self.key = key
        cache = Mutex(.default)
    }

    /// Load the persisted selection from `app_config` into the sync cache. Await this
    /// once at startup (before resolving the live source) so `load()` reflects disk.
    /// A missing / unparsable row leaves the default in place.
    public func hydrate() async {
        guard let json = try? await store.appConfigValue(forKey: key),
              let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(DataSourceConfig.self, from: data)
        else { return }
        cache.withLock { $0 = config }
    }

    public func load() -> DataSourceConfig {
        cache.withLock { $0 }
    }

    public func save(_ config: DataSourceConfig) {
        cache.withLock { $0 = config }
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else { return }
        // Write through durably; the cache already reflects the new value so the UI
        // and the live resolver stay consistent even before the write lands.
        Task { [store, key] in
            try? await store.setAppConfigValue(json, forKey: key)
        }
    }
}
