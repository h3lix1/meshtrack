import Domain
@testable import Scenario
import Testing

@Suite("MovementScenarioEvaluator (acceptance, SPEC §6.2)")
struct MovementScenarioEvaluatorTests {
    private func run(_ yaml: String) throws -> SuiteResult {
        let suite = try ScenarioParser().parse(yaml: yaml)
        return ScenarioRunner(evaluator: MovementScenarioEvaluator()).run(suite: suite)
    }

    @Test
    func `jitter within accuracy produces zero movement alerts`() throws {
        let result = try run("""
        - node: A123
          class: fixed
          arm: { threshold_m: 100 }
          fixes:
            - { dlat: 0.0003, dlon: 0.0002, h_accuracy: 60, count: 5 }
          expect_alerts: []
        """)
        #expect(result.passed, "\(result.report)")
    }

    @Test
    func `a confirmed 600m move produces exactly one moved`() throws {
        let result = try run("""
        - node: B456
          class: fixed
          arm: { threshold_m: 100 }
          fixes:
            - { meters_from_anchor: 600, h_accuracy: 10, count: 3 }
          expect_alerts:
            - { type: moved, count: 1 }
        """)
        #expect(result.passed, "\(result.report)")
    }

    @Test
    func `a mobile node emits geofence_exit instead of moved`() throws {
        let result = try run("""
        - node: M1
          class: mobile
          arm: { threshold_m: 100 }
          fixes:
            - { meters_from_anchor: 600, h_accuracy: 10, count: 3 }
          expect_alerts:
            - { type: geofence_exit, count: 1 }
        """)
        #expect(result.passed, "\(result.report)")
    }
}
