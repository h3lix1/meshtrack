// Integration — the composition-root glue that connects the App-layer Settings
// screens (which program to ports) to the real adapters that need Transport /
// Crypto / Persistence. Lives in the executable because only it imports those
// outer-ring modules; the `App` library stays snapshot-pure.

import App
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
/// is the `params_json` payload). Default-snooze persistence is a follow-up (the port
/// supplies a 3600s default).
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
