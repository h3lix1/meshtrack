import Domain
import RuleEngine
@testable import Scenario
import Testing

@Suite("LivenessScenarioEvaluator (acceptance)")
struct LivenessScenarioEvaluatorTests {
    @Test
    func `a silent node fires exactly one stale alert, matching expectations`() throws {
        let yaml = """
        - node: C789
          silence_hours: 26
          managed: true
          expect_alerts:
            - { type: stale, count: 1 }
        """
        let suite = try ScenarioParser().parse(yaml: yaml)
        let result = ScenarioRunner(evaluator: LivenessScenarioEvaluator()).run(suite: suite)
        #expect(result.passed, "expected stale to fire once; report:\n\(result.report)")
    }

    @Test
    func `a node heard recently does not fire stale (no false positive)`() throws {
        let yaml = """
        - node: A1
          silence_hours: 1
          managed: true
          expect_alerts: []
        """
        let suite = try ScenarioParser().parse(yaml: yaml)
        let result = ScenarioRunner(evaluator: LivenessScenarioEvaluator()).run(suite: suite)
        #expect(result.passed, "\(result.report)")
    }
}
