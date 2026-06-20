import Domain
@testable import Scenario
import Testing

@Suite("Scenario DSL parser + runner")
struct ScenarioParserRunnerTests {
    /// The three SPEC §6.2 examples, re-expressed in the concrete schema
    /// (`xN` → `count:`, explicit `h_accuracy` on every fix).
    static let specExamples = """
    - node: A123
      class: fixed
      arm: { threshold_m: 100 }
      fixes:
        - { dlat: 0.0003, dlon: 0.0002, h_accuracy: 60, count: 5 }
      expect_alerts: []
    - node: B456
      class: fixed
      arm: { threshold_m: 100 }
      fixes:
        - { meters_from_anchor: 600, h_accuracy: 10, count: 3 }
      expect_alerts:
        - { type: moved, count: 1 }
    - node: C789
      silence_hours: 26
      expect_alerts:
        - { type: stale, count: 1 }
    """

    @Test
    func `parses the three SPEC §6.2 examples into the correct model`() throws {
        let suite = try ScenarioParser().parse(yaml: Self.specExamples)
        #expect(suite.scenarios.count == 3)

        let jitter = suite.scenarios[0]
        #expect(jitter.node == "A123")
        #expect(jitter.nodeClass == .fixed)
        #expect(jitter.arm?.thresholdMeters == 100)
        #expect(jitter.fixes == [
            FixStep(offset: .delta(dlat: 0.0003, dlon: 0.0002, horizontalAccuracyMeters: 60), count: 5)
        ])
        #expect(jitter.totalFixCount == 5)
        #expect(jitter.expectedAlerts.isEmpty)

        let move = suite.scenarios[1]
        #expect(move.fixes == [
            FixStep(offset: .metersFromAnchor(600, horizontalAccuracyMeters: 10), count: 3)
        ])
        #expect(move.expectedAlerts == [ExpectedAlert(type: "moved", count: 1)])

        let silence = suite.scenarios[2]
        #expect(silence.arm == nil)
        #expect(silence.silenceHours == 26)
        #expect(silence.expectedAlerts == [ExpectedAlert(type: "stale", count: 1)])
    }

    @Test
    func `NoOpEvaluator passes empty expectations and fails alert expectations`() throws {
        let suite = try ScenarioParser().parse(yaml: Self.specExamples)
        let result = ScenarioRunner().run(suite: suite)

        let byNode = Dictionary(uniqueKeysWithValues: result.results.map { ($0.node, $0) })
        #expect(byNode["A123"]?.passed == true)
        #expect(byNode["B456"]?.passed == false)
        #expect(byNode["C789"]?.passed == false)
        #expect(result.passed == false)
        #expect(byNode["B456"]?.mismatches == [
            AlertCountMismatch(type: "moved", expected: 1, produced: 0)
        ])
    }

    @Test
    func `a scripted evaluator that produces the expected alert makes the runner pass`() throws {
        let suite = try ScenarioParser().parse(yaml: Self.specExamples)
        let move = ScenarioRunner(evaluator: ScriptedEvaluator()).run(suite.scenarios[1])
        #expect(move.passed)
        #expect(move.mismatches.isEmpty)
    }

    /// Produces one `moved` alert for any armed node — enough to satisfy B456.
    private struct ScriptedEvaluator: ScenarioEvaluator {
        func evaluate(_ scenario: Scenario) -> [ProducedAlert] {
            scenario.arm == nil ? [] : [ProducedAlert(type: "moved")]
        }
    }

    @Test
    func `a fix step with both offset forms is rejected`() {
        let yaml = """
        - node: X
          fixes:
            - { meters_from_anchor: 600, dlat: 0.1, dlon: 0.1, h_accuracy: 5 }
        """
        #expect(throws: ScenarioParseError.self) {
            _ = try ScenarioParser().parse(yaml: yaml)
        }
    }

    @Test
    func `an unknown class is rejected`() {
        #expect(throws: ScenarioParseError.self) {
            _ = try ScenarioParser().parse(yaml: "- { node: X, class: amphibious }")
        }
    }

    @Test
    func `a scenario missing the required node key is rejected`() {
        #expect(throws: ScenarioParseError.self) {
            _ = try ScenarioParser().parse(yaml: "- { class: fixed }")
        }
    }

    @Test
    func `a non-sequence document root is rejected`() {
        #expect(throws: ScenarioParseError.self) {
            _ = try ScenarioParser().parse(yaml: "node: X")
        }
    }

    @Test
    func `an empty/comment-only document parses to an empty suite`() throws {
        let suite = try ScenarioParser().parse(yaml: "# just a comment\n")
        #expect(suite.scenarios.isEmpty)
    }
}
