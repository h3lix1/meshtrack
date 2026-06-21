// SettingsFakes — in-memory `ConfigGateway` for the General preferences screen, used
// by previews and tests (every effect ships a fake, per AGENTS.md). This is NOT the
// production adapter: the lead adapts `MeshStore` (Persistence) to `ConfigGateway` at
// integration. Mutable state is actor-isolated so the fake satisfies Swift 6 strict
// concurrency without a lock.

import Domain

/// In-memory `ConfigGateway` for previews/tests: keeps the last saved broker config
/// and app settings in actor-isolated storage. `loadAppSettings` returns the saved
/// value or `AppSettings.default` when nothing has been saved.
public actor InMemoryConfigGateway: ConfigGateway {
    private var broker: BrokerConfig?
    private var appSettings: AppSettings?

    public init(broker: BrokerConfig? = nil, appSettings: AppSettings? = nil) {
        self.broker = broker
        self.appSettings = appSettings
    }

    public func loadBrokerConfig() async throws -> BrokerConfig? {
        broker
    }

    public func saveBrokerConfig(_ config: BrokerConfig) async throws {
        broker = config
    }

    public func loadAppSettings() async throws -> AppSettings {
        appSettings ?? .default
    }

    public func saveAppSettings(_ settings: AppSettings) async throws {
        appSettings = settings
    }
}
