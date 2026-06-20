// Typed, `Sendable` models for the Meshtrack scenario DSL.
//
// These are the parsed AST that `ScenarioParser` produces from YAML and that
// `ScenarioRunner` executes. They carry no Foundation and no I/O: a `Scenario`
// is a plain value you can build in a test, hand to the runner, and compare.
//
// The concrete YAML schema is documented in `SCHEMA.md`. It is inspired by
// SPEC §6.2, with the spec's illustrative `xN` fix-suffix replaced by a real
// `count:` field on each fix step.

/// The node *class* a scenario node belongs to (SPEC §2.1).
///
/// Class drives default alert behaviour. The scenario harness records it so
/// later phases can assert class-specific semantics (e.g. `mobile` nodes use
/// geofence-exit rather than "moved at all").
public enum NodeClass: String, Sendable, Equatable, CaseIterable {
    case fixed
    case mobile
    case gateway
    case unknown
}

/// The arming parameters captured when a node is armed for movement (SPEC §2.3).
///
/// `thresholdMeters` is the movement threshold; `accuracyMarginMeters` is the
/// extra slack added to the threshold to absorb position accuracy
/// (`threshold + position_accuracy_margin`). When the margin is omitted in YAML
/// it defaults to ``ArmConfig/defaultAccuracyMarginMeters``.
public struct ArmConfig: Sendable, Equatable {
    /// Default accuracy margin (metres) applied when `accuracy_margin_m` is absent.
    public static let defaultAccuracyMarginMeters = 0.0

    /// Default consecutive-fix confirmation count (SPEC §2.3, `N=3`).
    public static let defaultConfirmationCount = 3

    /// Default escape factor: a single fix this many × over threshold confirms
    /// movement immediately (SPEC §2.3, default `3×`).
    public static let defaultEscapeFactor = 3.0

    public var thresholdMeters: Double
    public var accuracyMarginMeters: Double
    public var confirmationCount: Int
    public var escapeFactor: Double

    public init(
        thresholdMeters: Double,
        accuracyMarginMeters: Double = ArmConfig.defaultAccuracyMarginMeters,
        confirmationCount: Int = ArmConfig.defaultConfirmationCount,
        escapeFactor: Double = ArmConfig.defaultEscapeFactor
    ) {
        self.thresholdMeters = thresholdMeters
        self.accuracyMarginMeters = accuracyMarginMeters
        self.confirmationCount = confirmationCount
        self.escapeFactor = escapeFactor
    }
}

/// How a single fix step's offset from the anchor is expressed.
///
/// Exactly one form is chosen per step (the schema forbids mixing). Both forms
/// carry a horizontal accuracy so the movement detector can apply its accuracy
/// margin (SPEC §2.3).
public enum FixOffset: Sendable, Equatable {
    /// A delta in decimal degrees, with a reported horizontal accuracy (metres).
    /// Mirrors the SPEC §6.2 jitter example `{ dlat, dlon, h_accuracy }`.
    case delta(dlat: Double, dlon: Double, horizontalAccuracyMeters: Double)

    /// A straight-line distance from the anchor (metres), with a reported
    /// horizontal accuracy. Mirrors the SPEC §6.2 `{ meters_from_anchor }` form.
    case metersFromAnchor(Double, horizontalAccuracyMeters: Double)
}

/// One fix step in a scenario: an offset, repeated `count` times.
///
/// `count` is the concrete replacement for the SPEC's illustrative `xN` suffix.
/// A step with `count: 3` enqueues three identical fixes — e.g. the "confirmed
/// move" example needs three consecutive candidate fixes to confirm.
public struct FixStep: Sendable, Equatable {
    /// Default repeat count when `count:` is omitted in YAML.
    public static let defaultCount = 1

    public var offset: FixOffset
    public var count: Int

    public init(offset: FixOffset, count: Int = FixStep.defaultCount) {
        self.offset = offset
        self.count = count
    }
}

/// A single expected-alert assertion: an alert `type` and how many times it is
/// expected to fire over the scenario (SPEC §6.2 `expect_alerts`).
public struct ExpectedAlert: Sendable, Equatable {
    public var type: String
    public var count: Int

    public init(type: String, count: Int) {
        self.type = type
        self.count = count
    }
}

/// A single node's scenario: arming, a sequence of fixes, an optional silence
/// gap, and the exact alerts the harness expects to result.
public struct Scenario: Sendable, Equatable {
    /// Node identity (the `node:` key — a `!hexid` or short id, not the numeric key).
    public var node: String
    /// The node's class, if declared. `nil` means "unspecified" (not `.unknown`).
    public var nodeClass: NodeClass?
    /// Arming config, if the node is armed for movement.
    public var arm: ArmConfig?
    /// Ordered fix steps fed to the movement detector.
    public var fixes: [FixStep]
    /// Hours of silence to simulate before evaluating liveness (SPEC §2.2 stale).
    public var silenceHours: Double?
    /// The exact alert sequence the scenario asserts (order-insensitive by type).
    public var expectedAlerts: [ExpectedAlert]

    public init(
        node: String,
        nodeClass: NodeClass? = nil,
        arm: ArmConfig? = nil,
        fixes: [FixStep] = [],
        silenceHours: Double? = nil,
        expectedAlerts: [ExpectedAlert] = []
    ) {
        self.node = node
        self.nodeClass = nodeClass
        self.arm = arm
        self.fixes = fixes
        self.silenceHours = silenceHours
        self.expectedAlerts = expectedAlerts
    }
}

public extension Scenario {
    /// The total number of fixes this scenario produces (sum of step counts).
    var totalFixCount: Int {
        fixes.reduce(0) { $0 + $1.count }
    }
}

/// A parsed scenario document: the ordered list of node scenarios in one file.
public struct ScenarioSuite: Sendable, Equatable {
    public var scenarios: [Scenario]

    public init(scenarios: [Scenario]) {
        self.scenarios = scenarios
    }
}
