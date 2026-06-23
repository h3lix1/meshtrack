import Domain
@testable import Persistence
import Testing

@Suite("MeshStore: alert_rule CRUD (Phase 8)")
struct AlertRuleStoreTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `no rules on a fresh store`() async throws {
        let store = try makeStore()
        #expect(try await store.allAlertRules().isEmpty)
    }

    @Test
    func `upsert inserts then round-trips a rule`() async throws {
        let store = try makeStore()
        try await store.upsertAlertRule(
            scope: "global", scopeID: nil, type: "battery_below",
            paramsJSON: "{\"threshold\":20}", enabled: true
        )
        let rules = try await store.allAlertRules()
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(rule.scope == "global")
        #expect(rule.scope_id == nil)
        #expect(rule.type == "battery_below")
        #expect(rule.params_json == "{\"threshold\":20}")
        #expect(rule.enabled)
    }

    @Test
    func `upsert replaces the rule with the same identity in place`() async throws {
        let store = try makeStore()
        try await store.upsertAlertRule(
            scope: "node", scopeID: "42", type: "stale", paramsJSON: "{\"threshold\":24}", enabled: true
        )
        try await store.upsertAlertRule(
            scope: "node", scopeID: "42", type: "stale", paramsJSON: "{\"threshold\":48}", enabled: false
        )
        let rules = try await store.allAlertRules().filter { $0.type == "stale" }
        #expect(rules.count == 1) // replaced, not duplicated
        #expect(rules.first?.params_json == "{\"threshold\":48}")
        #expect(rules.first?.enabled == false)
    }

    @Test
    func `rules with different scope_id coexist`() async throws {
        let store = try makeStore()
        try await store.upsertAlertRule(
            scope: "class", scopeID: "fixed", type: "battery_below", paramsJSON: nil, enabled: true
        )
        try await store.upsertAlertRule(
            scope: "class", scopeID: "mobile", type: "battery_below", paramsJSON: nil, enabled: true
        )
        #expect(try await store.allAlertRules().count == 2)
    }

    @Test
    func `delete removes the matching rule, NULL-safe on scope_id`() async throws {
        let store = try makeStore()
        try await store.upsertAlertRule(
            scope: "global", scopeID: nil, type: "voltage_below", paramsJSON: nil, enabled: true
        )
        try await store.deleteAlertRule(scope: "global", scopeID: nil, type: "voltage_below")
        #expect(try await store.allAlertRules().isEmpty)
    }
}
