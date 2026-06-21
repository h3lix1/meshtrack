// AlertRuleStoreFake — in-memory `AlertRuleStore` for the Alert-rules screen, used by
// previews and tests (every effect ships a fake, per AGENTS.md). This is NOT the
// production adapter: the lead adapts the GRDB `alert_rule` table to `AlertRuleStore`
// at integration. Mutable state is actor-isolated for Swift 6 strict concurrency.

/// In-memory `AlertRuleStore` for previews/tests: holds rule records keyed by
/// `(scope, type)` so an upsert replaces the matching rule rather than duplicating
/// it, plus a default snooze.
public actor InMemoryAlertRuleStore: AlertRuleStore {
    private var records: [AlertRuleRecord]
    private var defaultSnoozeSeconds: Double

    public init(_ records: [AlertRuleRecord] = [], defaultSnoozeSeconds: Double = 3600) {
        // De-dupe on construction so seeded data obeys the same identity rule.
        var deduped: [AlertRuleRecord] = []
        for record in records {
            deduped.removeAll { $0.matchesIdentity(of: record) }
            deduped.append(record)
        }
        self.records = deduped
        self.defaultSnoozeSeconds = defaultSnoozeSeconds
    }

    public func allRules() async throws -> [AlertRuleRecord] {
        records
    }

    public func upsertRule(_ record: AlertRuleRecord) async throws {
        records.removeAll { $0.matchesIdentity(of: record) }
        records.append(record)
    }

    public func deleteRule(scope: AlertRuleScope, type: AlertRuleType) async throws {
        records.removeAll { $0.scope == scope && $0.type == type }
    }

    public func loadDefaultSnoozeSeconds() async throws -> Double {
        defaultSnoozeSeconds
    }

    public func saveDefaultSnoozeSeconds(_ seconds: Double) async throws {
        defaultSnoozeSeconds = seconds
    }
}
