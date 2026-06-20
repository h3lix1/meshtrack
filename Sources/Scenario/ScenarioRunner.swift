// The acceptance runner: execute parsed scenarios through an injected evaluator,
// collect produced alerts, and compare them to `expect_alerts` (SPEC §6.5).
//
// The runner is the stable harness. It owns *comparison and reporting*, never
// detection — detection is the injected `ScenarioEvaluator`'s job. Comparison is
// by alert type and multiplicity: for each type we compare the expected count to
// the produced count, and surface every mismatch in a readable diff.

/// The outcome of running a single scenario: pass/fail plus a human-readable diff.
public struct ScenarioResult: Sendable, Equatable {
    /// The `node:` id of the scenario this result describes.
    public var node: String
    /// Whether produced alerts matched `expect_alerts` exactly (by type + count).
    public var passed: Bool
    /// One line per alert type whose expected and produced counts disagree.
    /// Empty when `passed` is `true`.
    public var mismatches: [AlertCountMismatch]

    public init(node: String, passed: Bool, mismatches: [AlertCountMismatch]) {
        self.node = node
        self.passed = passed
        self.mismatches = mismatches
    }

    /// A readable, multi-line diff suitable for a test-failure message.
    public var diff: String {
        guard !passed else { return "PASS  \(node): alerts matched expectations" }
        let lines = mismatches.map { mismatch in
            "  - \(mismatch.type): expected \(mismatch.expected), produced \(mismatch.produced)"
        }
        return (["FAIL  \(node): alert mismatch"] + lines).joined(separator: "\n")
    }
}

/// A single per-type disagreement between expected and produced alert counts.
public struct AlertCountMismatch: Sendable, Equatable {
    public var type: String
    public var expected: Int
    public var produced: Int

    public init(type: String, expected: Int, produced: Int) {
        self.type = type
        self.expected = expected
        self.produced = produced
    }
}

/// The outcome of running a whole suite: each scenario's result plus a roll-up.
public struct SuiteResult: Sendable, Equatable {
    public var results: [ScenarioResult]

    public init(results: [ScenarioResult]) {
        self.results = results
    }

    /// `true` only when every scenario in the suite passed.
    public var passed: Bool {
        results.allSatisfy(\.passed)
    }

    /// A readable report: one block per scenario, plus a final tally.
    public var report: String {
        let blocks = results.map(\.diff)
        let passes = results.count(where: \.passed)
        let tally = "\(passes)/\(results.count) scenarios passed"
        return (blocks + [tally]).joined(separator: "\n")
    }
}

/// Runs scenarios through an injected ``ScenarioEvaluator`` and compares the
/// produced alerts to each scenario's `expect_alerts`.
public struct ScenarioRunner: Sendable {
    private let evaluator: any ScenarioEvaluator

    /// - Parameter evaluator: the detection seam. Defaults to ``NoOpEvaluator``,
    ///   which produces no alerts (so empty-expectation scenarios pass and any
    ///   alert-expecting scenario fails until the real detectors are wired).
    public init(evaluator: any ScenarioEvaluator = NoOpEvaluator()) {
        self.evaluator = evaluator
    }

    /// Run a single scenario and compare produced vs. expected alerts.
    public func run(_ scenario: Scenario) -> ScenarioResult {
        let produced = evaluator.evaluate(scenario)
        let mismatches = Self.compare(
            expected: scenario.expectedAlerts,
            produced: produced
        )
        return ScenarioResult(
            node: scenario.node,
            passed: mismatches.isEmpty,
            mismatches: mismatches
        )
    }

    /// Run every scenario in a suite.
    public func run(suite: ScenarioSuite) -> SuiteResult {
        SuiteResult(results: suite.scenarios.map(run))
    }

    // MARK: - Comparison

    /// Compare expected to produced alerts by type and multiplicity. Returns a
    /// stable, deterministically-ordered list of mismatches (empty == match).
    static func compare(
        expected: [ExpectedAlert],
        produced: [ProducedAlert]
    ) -> [AlertCountMismatch] {
        let expectedCounts = expected.reduce(into: [String: Int]()) { counts, alert in
            counts[alert.type, default: 0] += alert.count
        }
        let producedCounts = produced.reduce(into: [String: Int]()) { counts, alert in
            counts[alert.type, default: 0] += 1
        }

        // Union of every type that appears on either side, sorted for stable diffs.
        let allTypes = Set(expectedCounts.keys).union(producedCounts.keys).sorted()

        return allTypes.compactMap { type in
            let expectedCount = expectedCounts[type, default: 0]
            let producedCount = producedCounts[type, default: 0]
            guard expectedCount != producedCount else { return nil }
            return AlertCountMismatch(
                type: type,
                expected: expectedCount,
                produced: producedCount
            )
        }
    }
}
