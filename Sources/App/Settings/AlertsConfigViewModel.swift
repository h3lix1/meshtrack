// AlertsConfigViewModel — presentation logic for the Alert-rules configuration
// screen (SPEC §2.6). A testable `@MainActor @Observable` view model over the
// injected `AlertRuleStore` port: it loads the threshold rules across the
// node → class → global hierarchy, groups them for the editor, edits thresholds and
// enabled flags, upserts/deletes records, and manages the global default snooze.
//
// All hierarchy resolution + grouping is pure and unit-tested; the view is a thin
// dark editor over this model.

import Domain
import Observation

@Observable
@MainActor
public final class AlertsConfigViewModel {
    /// The loaded rules, grouped by scope and ordered global → class → node for the
    /// editor. Rebuilt after every load / upsert / delete.
    public private(set) var groups: [ScopeGroup] = []

    /// The global default snooze duration (seconds).
    public private(set) var defaultSnoozeSeconds: Double = 3600

    /// Set after a failed effect, surfaced inline. Cleared on the next success.
    public private(set) var errorMessage: String?

    @ObservationIgnored private let rules: any AlertRuleStore

    public init(rules: any AlertRuleStore) {
        self.rules = rules
    }

    /// One scope's rules, for a grouped editor section.
    public struct ScopeGroup: Sendable, Equatable, Identifiable {
        public let scope: AlertRuleScope
        public var records: [AlertRuleRecord]

        public var id: String {
            switch scope {
            case .global: "global"
            case let .nodeClass(nodeClass): "class:\(nodeClass.rawValue)"
            case let .node(num): "node:\(num)"
            }
        }

        public var title: String {
            scope.title
        }
    }

    // MARK: Snooze bounds

    /// Allowed default snooze (seconds): 1 minute … 24 hours, stepped by 5 minutes.
    public static let snoozeRange: ClosedRange<Double> = 60 ... 86400
    public static let snoozeStep: Double = 300

    /// The snooze formatted compactly (e.g. "1h 0m", "45m").
    public var snoozeLabel: String {
        Self.formatDuration(defaultSnoozeSeconds)
    }

    nonisolated static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: Loading + grouping

    public func load() async {
        do {
            let all = try await rules.allRules()
            groups = Self.group(all)
            defaultSnoozeSeconds = try await rules.loadDefaultSnoozeSeconds()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load alert rules: \(error)"
        }
    }

    /// The groups to render, with a Global group guaranteed to exist (and ordered
    /// first) even when no global rules are configured yet — so a fresh store is never
    /// a dead end: the user can always add global defaults. The synthesized global
    /// group has no records and is not persisted until a rule is added to it.
    public var displayGroups: [ScopeGroup] {
        if groups.contains(where: { $0.scope == .global }) {
            return groups
        }
        return [ScopeGroup(scope: .global, records: [])] + groups
    }

    /// Group records by scope, ordered global → class → node, with class scopes in
    /// `NodeClass.allCases` order and node scopes by ascending node number. Within a
    /// group, rules are ordered by `AlertRuleType.allCases`.
    nonisolated static func group(_ records: [AlertRuleRecord]) -> [ScopeGroup] {
        let byScope = Dictionary(grouping: records, by: \.scope)
        return byScope.keys
            .sorted(by: scopeOrder)
            .map { scope in
                let sorted = (byScope[scope] ?? []).sorted { lhs, rhs in
                    typeOrder(lhs.type) < typeOrder(rhs.type)
                }
                return ScopeGroup(scope: scope, records: sorted)
            }
    }

    /// Total ordering over scopes for stable display.
    nonisolated static func scopeOrder(_ lhs: AlertRuleScope, _ rhs: AlertRuleScope) -> Bool {
        if lhs.precedence != rhs.precedence { return lhs.precedence < rhs.precedence }
        switch (lhs, rhs) {
        case let (.nodeClass(lhsClass), .nodeClass(rhsClass)):
            return classOrder(lhsClass) < classOrder(rhsClass)
        case let (.node(lhsNum), .node(rhsNum)):
            return lhsNum < rhsNum
        default:
            return false
        }
    }

    nonisolated static func classOrder(_ nodeClass: NodeClass) -> Int {
        NodeClass.allCases.firstIndex(of: nodeClass) ?? NodeClass.allCases.count
    }

    nonisolated static func typeOrder(_ type: AlertRuleType) -> Int {
        AlertRuleType.allCases.firstIndex(of: type) ?? AlertRuleType.allCases.count
    }

    // MARK: Hierarchy precedence (display)

    /// The effective rule for `type` for a node, by precedence node → class → global,
    /// ignoring disabled rules — mirrors `RuleEngine.RuleSet.effectiveRule` so the UI
    /// can show "what actually applies". Pure; unit-tested against the engine's rule.
    nonisolated static func effectiveRule(
        in records: [AlertRuleRecord],
        type: AlertRuleType,
        nodeNum: UInt32,
        nodeClass: NodeClass
    ) -> AlertRuleRecord? {
        let candidates = records.filter { $0.type == type && $0.enabled }
        return candidates.first { $0.scope == .node(nodeNum) }
            ?? candidates.first { $0.scope == .nodeClass(nodeClass) }
            ?? candidates.first { $0.scope == .global }
    }

    /// Instance convenience over the currently-loaded groups.
    public func effectiveRule(
        type: AlertRuleType,
        nodeNum: UInt32,
        nodeClass: NodeClass
    ) -> AlertRuleRecord? {
        Self.effectiveRule(
            in: groups.flatMap(\.records),
            type: type,
            nodeNum: nodeNum,
            nodeClass: nodeClass
        )
    }

    // MARK: Editing

    /// Clamp a threshold to the type's sensible bounds.
    nonisolated static func clampThreshold(_ value: Double, for type: AlertRuleType) -> Double {
        switch type {
        case .batteryBelow:
            min(100, max(0, value.rounded()))
        case .voltageBelow:
            min(20, max(0, (value * 10).rounded() / 10))
        case .stale:
            min(720, max(1, value.rounded()))
        }
    }

    /// Step amount per −/+ tap for a type.
    nonisolated static func step(for type: AlertRuleType) -> Double {
        switch type {
        case .batteryBelow: 5
        case .voltageBelow: 0.1
        case .stale: 1
        }
    }

    /// Upsert a rule with `threshold` (clamped) for `(scope, type)`, then reload-group.
    public func setThreshold(_ value: Double, scope: AlertRuleScope, type: AlertRuleType) async {
        let existing = record(scope: scope, type: type)
        let clamped = Self.clampThreshold(value, for: type)
        let updated = AlertRuleRecord(
            scope: scope,
            type: type,
            threshold: clamped,
            enabled: existing?.enabled ?? true
        )
        await upsert(updated)
    }

    /// Nudge a rule's threshold by `steps` of its natural step.
    public func stepThreshold(by steps: Int, scope: AlertRuleScope, type: AlertRuleType) async {
        let current = record(scope: scope, type: type)?.threshold ?? type.defaultThreshold
        await setThreshold(current + Double(steps) * Self.step(for: type), scope: scope, type: type)
    }

    /// Toggle a rule's enabled flag (creating it at the default threshold if absent).
    public func setEnabled(_ enabled: Bool, scope: AlertRuleScope, type: AlertRuleType) async {
        let existing = record(scope: scope, type: type)
        let updated = AlertRuleRecord(
            scope: scope,
            type: type,
            threshold: existing?.threshold ?? type.defaultThreshold,
            enabled: enabled
        )
        await upsert(updated)
    }

    /// Add a default rule of `type` to `scope` (no-op if it already exists).
    public func addRule(type: AlertRuleType, scope: AlertRuleScope) async {
        guard record(scope: scope, type: type) == nil else { return }
        await upsert(AlertRuleRecord(scope: scope, type: type, threshold: type.defaultThreshold))
    }

    /// The rule type a freshly-added scope is seeded with so the new group
    /// materializes (and persists) immediately with one editable rule.
    public static let defaultScopeRuleType: AlertRuleType = .batteryBelow

    /// Materialize a new scope group by adding its first default rule, so a class- or
    /// node-scoped group appears immediately and persists. If the scope already has
    /// any rule, seed nothing (it is already present); the group simply stays.
    public func addScope(_ scope: AlertRuleScope) async {
        let hasAnyRule = groups.first { $0.scope == scope }?.records.isEmpty == false
        guard !hasAnyRule else { return }
        await addRule(type: Self.defaultScopeRuleType, scope: scope)
    }

    // MARK: Node-id parsing

    /// Parse a user-entered node identifier into a node number, accepting either a
    /// Meshtastic `!aabbccdd` hex id or a plain decimal number. Returns `nil` for
    /// empty/invalid input. Pure; unit-tested.
    nonisolated static func parseNodeID(_ raw: String) -> UInt32? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Meshtastic `!aabbccdd` hex id.
        if trimmed.hasPrefix("!") {
            return UInt32(trimmed.dropFirst(), radix: 16)
        }
        // A bare hex id (e.g. "aabbccdd") containing a hex letter is read as hex…
        if trimmed.allSatisfy(\.isHexDigit), trimmed.contains(where: { !$0.isNumber }) {
            return UInt32(trimmed, radix: 16)
        }
        // …otherwise a plain decimal node number.
        return UInt32(trimmed)
    }

    /// Delete the rule for `(scope, type)`.
    public func deleteRule(scope: AlertRuleScope, type: AlertRuleType) async {
        do {
            try await rules.deleteRule(scope: scope, type: type)
            await load()
        } catch {
            errorMessage = "Couldn't delete rule: \(error)"
        }
    }

    /// Nudge the default snooze by `steps` of `snoozeStep`, clamped, and persist.
    public func stepSnooze(by steps: Int) async {
        let next = defaultSnoozeSeconds + Double(steps) * Self.snoozeStep
        let clamped = min(Self.snoozeRange.upperBound, max(Self.snoozeRange.lowerBound, next))
        defaultSnoozeSeconds = clamped
        do {
            try await rules.saveDefaultSnoozeSeconds(clamped)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't save snooze: \(error)"
        }
    }

    // MARK: Lookup helpers

    /// The currently-loaded record for `(scope, type)`, if any.
    public func record(scope: AlertRuleScope, type: AlertRuleType) -> AlertRuleRecord? {
        groups.first { $0.scope == scope }?.records.first { $0.type == type }
    }

    private func upsert(_ record: AlertRuleRecord) async {
        do {
            try await rules.upsertRule(record)
            await load()
        } catch {
            errorMessage = "Couldn't save rule: \(error)"
        }
    }
}
