@testable import App
import Domain
import RuleEngine
import Testing

@Suite("AlertsConfigViewModel")
@MainActor
struct AlertsConfigViewModelTests {
    // MARK: CRUD round-trips

    @Test
    func `upsert adds then replaces a rule by (scope, type) identity`() async throws {
        let store = InMemoryAlertRuleStore()
        let viewModel = AlertsConfigViewModel(rules: store)
        await viewModel.load()
        #expect(viewModel.groups.isEmpty)

        await viewModel.addRule(type: .batteryBelow, scope: .global)
        #expect(viewModel.record(scope: .global, type: .batteryBelow)?.threshold == AlertRuleType.batteryBelow
            .defaultThreshold)

        // Same identity → replace, not duplicate.
        await viewModel.setThreshold(35, scope: .global, type: .batteryBelow)
        let all = try await store.allRules()
        #expect(all.count(where: { $0.scope == .global && $0.type == .batteryBelow }) == 1)
        #expect(viewModel.record(scope: .global, type: .batteryBelow)?.threshold == 35)
    }

    @Test
    func `delete removes a rule`() async {
        let store = InMemoryAlertRuleStore([
            AlertRuleRecord(scope: .global, type: .stale, threshold: 24)
        ])
        let viewModel = AlertsConfigViewModel(rules: store)
        await viewModel.load()
        #expect(viewModel.record(scope: .global, type: .stale) != nil)

        await viewModel.deleteRule(scope: .global, type: .stale)
        #expect(viewModel.record(scope: .global, type: .stale) == nil)
        #expect(viewModel.groups.isEmpty)
    }

    @Test
    func `enable flag toggles and persists`() async {
        let store = InMemoryAlertRuleStore([
            AlertRuleRecord(scope: .global, type: .batteryBelow, threshold: 20, enabled: true)
        ])
        let viewModel = AlertsConfigViewModel(rules: store)
        await viewModel.load()

        await viewModel.setEnabled(false, scope: .global, type: .batteryBelow)
        #expect(viewModel.record(scope: .global, type: .batteryBelow)?.enabled == false)
        // Threshold preserved across the toggle.
        #expect(viewModel.record(scope: .global, type: .batteryBelow)?.threshold == 20)

        await viewModel.setEnabled(true, scope: .global, type: .batteryBelow)
        #expect(viewModel.record(scope: .global, type: .batteryBelow)?.enabled == true)
    }

    @Test
    func `threshold steps and clamps per type`() async throws {
        let store = InMemoryAlertRuleStore()
        let viewModel = AlertsConfigViewModel(rules: store)
        await viewModel.load()

        // Battery: step of 5, clamp 0…100.
        await viewModel.addRule(type: .batteryBelow, scope: .global)
        await viewModel.stepThreshold(by: 1, scope: .global, type: .batteryBelow) // 20 → 25
        #expect(viewModel.record(scope: .global, type: .batteryBelow)?.threshold == 25)
        await viewModel.setThreshold(999, scope: .global, type: .batteryBelow)
        #expect(viewModel.record(scope: .global, type: .batteryBelow)?.threshold == 100)

        // Voltage: step of 0.1.
        await viewModel.addRule(type: .voltageBelow, scope: .global)
        await viewModel.stepThreshold(by: 1, scope: .global, type: .voltageBelow) // 3.3 → 3.4
        let v = try #require(viewModel.record(scope: .global, type: .voltageBelow)?.threshold)
        #expect(abs(v - 3.4) < 0.0001)
    }

    // MARK: Grouping + ordering

    @Test
    func `groups are ordered global then class then node`() async {
        let store = InMemoryAlertRuleStore([
            AlertRuleRecord(scope: .node(0xA1B2_C3D4), type: .voltageBelow, threshold: 3.4),
            AlertRuleRecord(scope: .global, type: .batteryBelow, threshold: 20),
            AlertRuleRecord(scope: .nodeClass(.mobile), type: .stale, threshold: 6)
        ])
        let viewModel = AlertsConfigViewModel(rules: store)
        await viewModel.load()

        let scopes = viewModel.groups.map(\.scope)
        #expect(scopes == [.global, .nodeClass(.mobile), .node(0xA1B2_C3D4)])
    }

    // MARK: Hierarchy precedence

    @Test
    func `effective rule resolves node over class over global`() {
        let records = [
            AlertRuleRecord(scope: .global, type: .stale, threshold: 24),
            AlertRuleRecord(scope: .nodeClass(.fixed), type: .stale, threshold: 12),
            AlertRuleRecord(scope: .node(42), type: .stale, threshold: 1)
        ]
        // Node 42 (fixed): node override wins.
        #expect(AlertsConfigViewModel.effectiveRule(
            in: records, type: .stale, nodeNum: 42, nodeClass: .fixed
        )?.threshold == 1)
        // Node 7 (fixed): no node rule → class default.
        #expect(AlertsConfigViewModel.effectiveRule(
            in: records, type: .stale, nodeNum: 7, nodeClass: .fixed
        )?.threshold == 12)
        // Node 7 (mobile): no node/class rule → global default.
        #expect(AlertsConfigViewModel.effectiveRule(
            in: records, type: .stale, nodeNum: 7, nodeClass: .mobile
        )?.threshold == 24)
    }

    @Test
    func `disabled rules are skipped in precedence`() {
        let records = [
            AlertRuleRecord(scope: .global, type: .batteryBelow, threshold: 20),
            AlertRuleRecord(scope: .node(42), type: .batteryBelow, threshold: 5, enabled: false)
        ]
        // Node rule disabled → falls back to global.
        #expect(AlertsConfigViewModel.effectiveRule(
            in: records, type: .batteryBelow, nodeNum: 42, nodeClass: .fixed
        )?.threshold == 20)
    }

    @Test
    func `precedence display matches the RuleEngine resolution`() {
        // Same hierarchy expressed in both models; the screen's display must agree
        // with the engine that actually evaluates alerts.
        let records = [
            AlertRuleRecord(scope: .global, type: .stale, threshold: 24),
            AlertRuleRecord(scope: .nodeClass(.fixed), type: .stale, threshold: 12),
            AlertRuleRecord(scope: .node(42), type: .stale, threshold: 1)
        ]
        let engineRules = records.map { record -> AlertRule in
            let scope: RuleScope = switch record.scope {
            case .global: .global
            case let .nodeClass(nodeClass): .nodeClass(nodeClass)
            case let .node(num): .node(num)
            }
            return AlertRule(type: .stale, scope: scope, threshold: record.threshold, enabled: record.enabled)
        }
        let ruleSet = RuleSet(engineRules)

        for (nodeNum, nodeClass) in [(UInt32(42), NodeClass.fixed), (7, .fixed), (7, .mobile)] {
            let mine = AlertsConfigViewModel.effectiveRule(
                in: records, type: .stale, nodeNum: nodeNum, nodeClass: nodeClass
            )
            let engine = ruleSet.effectiveRule(type: .stale, nodeNum: nodeNum, nodeClass: nodeClass)
            #expect(mine?.threshold == engine?.threshold)
        }
    }

    // MARK: Snooze

    @Test
    func `default snooze steps, clamps and persists`() async {
        let store = InMemoryAlertRuleStore(defaultSnoozeSeconds: 3600)
        let viewModel = AlertsConfigViewModel(rules: store)
        await viewModel.load()
        #expect(viewModel.defaultSnoozeSeconds == 3600)

        await viewModel.stepSnooze(by: 1) // +300s
        #expect(viewModel.defaultSnoozeSeconds == 3900)
        await viewModel.stepSnooze(by: 10000) // clamp to upper bound
        #expect(viewModel.defaultSnoozeSeconds == AlertsConfigViewModel.snoozeRange.upperBound)

        // Persisted: a fresh view model reads it back.
        let reader = AlertsConfigViewModel(rules: store)
        await reader.load()
        #expect(reader.defaultSnoozeSeconds == AlertsConfigViewModel.snoozeRange.upperBound)
    }

    @Test
    func `snooze label formats hours and minutes`() {
        #expect(AlertsConfigViewModel.formatDuration(3600) == "1h 0m")
        #expect(AlertsConfigViewModel.formatDuration(2700) == "45m")
        #expect(AlertsConfigViewModel.formatDuration(5400) == "1h 30m")
    }
}
