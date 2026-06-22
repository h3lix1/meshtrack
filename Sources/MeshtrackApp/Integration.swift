// Integration — the composition-root glue that connects the App-layer Settings
// screens (which program to ports) to the real adapters that need Transport /
// Crypto / Persistence. Lives in the executable because only it imports those
// outer-ring modules; the `App` library stays snapshot-pure.

import App
import Crypto
import Domain
import Foundation
import Persistence
import Transport

/// Live MQTT "Test Connection" probe injected into the Connection settings screen.
///
/// `MQTTAdapter` surfaces no CONNACK callback (it exposes only `frames()`), so this
/// is a frame-arrival heuristic: open the stream and report success when the broker
/// delivers traffic within `timeout`, else a diagnostic failure. Good for the busy
/// public broker; a precise CONNACK status hook on the adapter is a follow-up.
@Sendable
func probeBrokerConnection(
    _ config: BrokerConfig,
    password: String?,
    timeout: Duration = .seconds(6)
) async -> ConnectionTestResult {
    let mqtt = MQTTConfig(
        host: config.host,
        port: config.port,
        username: config.username,
        password: password,
        useTLS: config.useTLS,
        allowUntrustedCert: config.allowUntrustedCert,
        topics: config.topics,
        clientID: config.clientID
    )
    let adapter = MQTTAdapter(config: mqtt, clock: SystemWallClock())
    let seconds = max(1, Int(timeout.components.seconds))

    return await withTaskGroup(of: ConnectionTestResult.self) { group in
        group.addTask {
            for await _ in adapter.frames() {
                return .success(detail: "receiving traffic from \(config.host)")
            }
            return .failure(reason: "the broker stream closed before any data arrived")
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return .failure(
                reason: "no traffic within \(seconds)s — check host/port/TLS, credentials, and topic"
            )
        }
        let result = await group.next() ?? .failure(reason: "connection probe failed")
        group.cancelAll()
        return result
    }
}

/// Adapts the GRDB `alert_rule` table to the App-layer `AlertRuleStore` port the
/// Alerts settings screen programs to. Maps the screen's local rule types onto the
/// persisted `(scope, scope_id, type, params_json, enabled)` columns (the threshold
/// is the `params_json` payload). The operator's default-snooze setting persists in
/// `app_config` via `AlertDefaultSnoozeStore`, so it survives relaunch (Finding 10).
struct MeshStoreAlertRuleStore: App.AlertRuleStore {
    let store: MeshStore

    func allRules() async throws -> [App.AlertRuleRecord] {
        try await store.allAlertRules().compactMap(Self.toApp)
    }

    func upsertRule(_ record: App.AlertRuleRecord) async throws {
        let (scope, scopeID) = Self.columns(for: record.scope)
        try await store.upsertAlertRule(
            scope: scope,
            scopeID: scopeID,
            type: record.type.rawValue,
            paramsJSON: Self.encodeThreshold(record.threshold),
            enabled: record.enabled
        )
    }

    func deleteRule(scope: App.AlertRuleScope, type: App.AlertRuleType) async throws {
        let (scopeColumn, scopeID) = Self.columns(for: scope)
        try await store.deleteAlertRule(scope: scopeColumn, scopeID: scopeID, type: type.rawValue)
    }

    // MARK: Default snooze (persisted in app_config, Finding 10)

    func loadDefaultSnoozeSeconds() async throws -> Double {
        try await AlertDefaultSnoozeStore.load(from: store)
    }

    func saveDefaultSnoozeSeconds(_ seconds: Double) async throws {
        try await AlertDefaultSnoozeStore.save(seconds, to: store)
    }

    // MARK: Mapping

    private struct Params: Codable { let threshold: Double }

    private static func encodeThreshold(_ threshold: Double) -> String {
        (try? String(data: JSONEncoder().encode(Params(threshold: threshold)), encoding: .utf8))
            .flatMap(\.self) ?? "{\"threshold\":\(threshold)}"
    }

    private static func columns(for scope: App.AlertRuleScope) -> (String, String?) {
        switch scope {
        case .global: ("global", nil)
        case let .nodeClass(nodeClass): ("class", nodeClass.rawValue)
        case let .node(num): ("node", String(num))
        }
    }

    private static func toApp(_ record: Persistence.AlertRuleRecord) -> App.AlertRuleRecord? {
        guard let type = App.AlertRuleType(rawValue: record.type),
              let scope = scope(from: record) else { return nil }
        let threshold = decodeThreshold(record.params_json) ?? type.defaultThreshold
        return App.AlertRuleRecord(scope: scope, type: type, threshold: threshold, enabled: record.enabled)
    }

    private static func scope(from record: Persistence.AlertRuleRecord) -> App.AlertRuleScope? {
        switch record.scope {
        case "global": .global
        case "class": record.scope_id.flatMap(NodeClass.init(rawValue:)).map(App.AlertRuleScope.nodeClass)
        case "node": record.scope_id.flatMap(UInt32.init).map(App.AlertRuleScope.node)
        default: nil
        }
    }

    private static func decodeThreshold(_ json: String?) -> Double? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Params.self, from: data))?.threshold
    }
}

/// Adapts `KeychainKeyStore` (channel PSKs, in the Keychain) + the `app_config`
/// channel registry (names/hashes/kinds, non-secret) to the App-layer async
/// `ChannelKeyManaging` port the Channels & Keys screen programs to. PSKs never
/// enter the registry or any log; `hasKey` is derived from the Keychain.
actor KeychainChannelManager: ChannelKeyManaging {
    private let keys: KeychainKeyStore
    private let store: MeshStore
    private static let registryKey = "channel_registry"

    /// Set once we've seeded (or attempted to seed) the out-of-the-box default
    /// channel, so subsequent reads over an empty registry never re-seed — in
    /// particular after the operator deletes the default channel this run.
    private var didSeedDefault = false

    init(keys: KeychainKeyStore = KeychainKeyStore(), store: MeshStore) {
        self.keys = keys
        self.store = store
    }

    func channels() async throws -> [ChannelEntry] {
        try await seedDefaultChannelIfNeeded()
        return try await registry().map {
            ChannelEntry(
                name: $0.name, hash: $0.hash, kind: $0.kind,
                hasKey: keys.key(forChannelHash: $0.hash) != nil
            )
        }
    }

    func addChannel(name: String, hash: UInt32, kind: ChannelKind) async throws {
        var stored = try await registry()
        guard !stored.contains(where: { $0.hash == hash }) else { return }
        stored.append(StoredChannel(name: name, hash: hash, kind: kind))
        try await save(stored)
    }

    func removeChannel(hash: UInt32) async throws {
        var stored = try await registry()
        stored.removeAll { $0.hash == hash }
        try await save(stored)
        try? keys.removeKey(forChannelHash: hash)
    }

    func hasKey(forChannelHash hash: UInt32) async -> Bool {
        keys.key(forChannelHash: hash) != nil
    }

    func setKey(_ key: ChannelKey, forChannelHash hash: UInt32) async throws {
        try keys.store(key, forChannelHash: hash)
    }

    func clearKey(forChannelHash hash: UInt32) async throws {
        try keys.removeKey(forChannelHash: hash)
    }

    // MARK: First-run seeding (consistent with the Channels tab's in-VM seed)

    /// On first read over an empty registry, register the default **MediumFast**
    /// channel keyed with the well-known `"AQ=="` default PSK so the live app
    /// shows/decodes the public channel out of the box — not only after the
    /// operator opens Settings. Idempotent: guarded by `didSeedDefault` so it
    /// never re-runs (deleting the default this run does not resurrect it), and a
    /// no-op when the operator already has any channels. Reuses the same public
    /// constants + `ChannelKeyMath` as `ChannelsSettingsViewModel`, so the two
    /// seeding paths agree on name/hash/kind/PSK and never collide.
    private func seedDefaultChannelIfNeeded() async throws {
        guard !didSeedDefault else { return }
        didSeedDefault = true
        guard try await registry().isEmpty else { return }

        // The defaults live on the (main-actor) settings VM; read them there so the
        // two seeding paths share one source of truth for name/kind.
        let (name, kind) = await MainActor.run {
            (ChannelsSettingsViewModel.defaultChannelName, ChannelsSettingsViewModel.defaultChannelKind)
        }
        let hash = ChannelKeyMath.channelHash(name: name, psk: ChannelKeyMath.defaultPSK)
        try await save([StoredChannel(name: name, hash: hash, kind: kind)])
        try keys.store(ChannelKey(psk: ChannelKeyMath.defaultPSK), forChannelHash: hash)
    }

    // MARK: Registry (non-secret) persisted as JSON in app_config

    private struct StoredChannel: Codable {
        let name: String
        let hash: UInt32
        let kind: ChannelKind
    }

    private func registry() async throws -> [StoredChannel] {
        guard let json = try await store.appConfigValue(forKey: Self.registryKey),
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([StoredChannel].self, from: data)) ?? []
    }

    private func save(_ stored: [StoredChannel]) async throws {
        let data = try JSONEncoder().encode(stored)
        // JSONEncoder output is always valid UTF-8, so this conversion never fails.
        // swiftlint:disable:next optional_data_string_conversion
        try await store.setAppConfigValue(String(decoding: data, as: UTF8.self), forKey: Self.registryKey)
    }
}
