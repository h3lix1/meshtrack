// ManagedSuppressionScenarioTests — ADR 0008, Finding 1 (HIGH).
//
// Proves the ownership gate is LIVE in the real condition-producing path, not
// just in the RuleEvaluator unit. The production seam is
// `LivenessScenarioEvaluator` → `RuleEvaluator.conditions(…, management:)` →
// `AlertEngine`, driven here through the same `ScenarioRunner` the acceptance
// harness uses. An unmanaged node that WOULD fire stale produces no alert; the
// management flag flows through end-to-end (DSL flag and the store-backed
// production adapter), so the gate is wired, not inert.

import Domain
import RuleEngine
@testable import Scenario
import Testing

@Suite("Managed-aware suppression — through the production scenario path (ADR 0008)")
struct ManagedSuppressionScenarioTests {
    /// A node silent long enough that `stale` (24h default) WOULD fire if managed.
    private static let silentYAML = """
    - node: DEAD
      silence_hours: 48
      managed: false
      expect_alerts: []
    """

    /// The same node, declared managed: stale must fire exactly once.
    private static let managedSilentYAML = """
    - node: DEAD
      silence_hours: 48
      managed: true
      expect_alerts:
        - { type: stale, count: 1 }
    """

    @Test
    func `parser reads the managed flag and defaults it to false (unmanaged)`() throws {
        let suite = try ScenarioParser().parse(yaml: Self.silentYAML)
        #expect(suite.scenarios.first?.isManaged == false)

        // ADR 0008: omitting `managed` defaults to UNMANAGED, matching Domain's
        // `.unowned` default — an unclassified node never fires a false alert.
        let defaulted = try ScenarioParser().parse(yaml: """
        - node: A1
          silence_hours: 1
          expect_alerts: []
        """)
        #expect(defaulted.scenarios.first?.isManaged == false)
    }

    @Test
    func `a node omitting BOTH managed and silence_hours produces NO stale alert`() throws {
        // The Finding-6 regression: an unclassified node (no `managed`, no
        // `silence_hours`) must default to unmanaged and stay silent — never a
        // stale/battery/voltage alert for an unknown stranger node (ADR 0008).
        let yaml = """
        - node: BEEF
          expect_alerts: []
        """
        let suite = try ScenarioParser().parse(yaml: yaml)
        #expect(suite.scenarios.first?.isManaged == false)
        let result = ScenarioRunner(evaluator: LivenessScenarioEvaluator()).run(suite: suite)
        #expect(result.passed, "unclassified node must stay silent; report:\n\(result.report)")
    }

    @Test
    func `even a long-silent node fires NO stale when managed is omitted`() throws {
        // Belt-and-braces: the node IS silent long enough to be stale, but with
        // `managed` omitted it defaults to unmanaged, so no stale alert fires.
        let yaml = """
        - node: BEEF
          silence_hours: 48
          expect_alerts: []
        """
        let suite = try ScenarioParser().parse(yaml: yaml)
        #expect(suite.scenarios.first?.isManaged == false)
        let result = ScenarioRunner(evaluator: LivenessScenarioEvaluator()).run(suite: suite)
        #expect(result.passed, "omitted managed defaults to unmanaged → silent; report:\n\(result.report)")
    }

    @Test
    func `an UNMANAGED silent node produces NO stale alert through the runner`() throws {
        let suite = try ScenarioParser().parse(yaml: Self.silentYAML)
        // Default lookup: the scenario's own `managed: false` drives the gate.
        let result = ScenarioRunner(evaluator: LivenessScenarioEvaluator()).run(suite: suite)
        #expect(result.passed, "unmanaged node must stay silent; report:\n\(result.report)")
    }

    @Test
    func `a MANAGED silent node still fires stale (regression)`() throws {
        let suite = try ScenarioParser().parse(yaml: Self.managedSilentYAML)
        let result = ScenarioRunner(evaluator: LivenessScenarioEvaluator()).run(suite: suite)
        #expect(result.passed, "managed node must still fire; report:\n\(result.report)")
    }

    @Test
    func `the store-backed production lookup suppresses a node absent from the managed set`() throws {
        // Production adapter: only node 0x0001 is managed; 0xDEAD (the scenario
        // node) is NOT in the store's managed set, so it must stay silent even
        // though it has been silent long enough to be stale.
        let lookup = StoreNodeManagementLookup(managedNodeNums: [0x0001])
        let yaml = """
        - node: DEAD
          silence_hours: 48
          expect_alerts: []
        """
        let suite = try ScenarioParser().parse(yaml: yaml)
        let evaluator = LivenessScenarioEvaluator(managementLookup: lookup)
        let result = ScenarioRunner(evaluator: evaluator).run(suite: suite)
        #expect(result.passed, "store says unmanaged → no alert; report:\n\(result.report)")
    }

    @Test
    func `the store-backed production lookup lets a managed node fire`() throws {
        // node 0xDEAD IS in the managed set: the same silence now fires stale once.
        let lookup = StoreNodeManagementLookup(managedNodeNums: [0xDEAD])
        let yaml = """
        - node: DEAD
          silence_hours: 48
          expect_alerts:
            - { type: stale, count: 1 }
        """
        let suite = try ScenarioParser().parse(yaml: yaml)
        let evaluator = LivenessScenarioEvaluator(managementLookup: lookup)
        let result = ScenarioRunner(evaluator: evaluator).run(suite: suite)
        #expect(result.passed, "store says managed → stale fires; report:\n\(result.report)")
    }

    @Test
    func `the injected lookup overrides the scenario's own managed flag`() throws {
        // Scenario declares managed: true, but the production lookup says the node
        // is NOT managed — the lookup (the live store) must win, so no alert.
        let lookup = FixedNodeManagementLookup([:], fallback: .unowned)
        let yaml = """
        - node: DEAD
          silence_hours: 48
          managed: true
          expect_alerts: []
        """
        let suite = try ScenarioParser().parse(yaml: yaml)
        let evaluator = LivenessScenarioEvaluator(managementLookup: lookup)
        let result = ScenarioRunner(evaluator: evaluator).run(suite: suite)
        #expect(result.passed, "injected lookup overrides DSL flag; report:\n\(result.report)")
    }
}
