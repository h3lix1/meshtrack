// ArmingFlowViewModel — capture-anchor / disarm flow over the `arming` table (G5,
// SPEC §2.3).
//
// Reuses the NodeDetail arming-gate semantics: nothing is written until the
// operator explicitly arms (a deliberate, two-step safety action), so an anchor is
// never captured by accident. Capturing anchors a node at its latest stored
// position fix and arms movement detection; disarming clears the armed flag while
// keeping the row for history. The console reads back armed / anchored / moved /
// returned state straight from the persisted row.
//
// Testable `@MainActor @Observable` view model over an in-memory `MeshStore`; the
// view is bespoke for snapshot fidelity.

import Domain
import Foundation
import Observation
import Persistence

/// One node's arming state formatted for the console.
public struct ArmingDisplay: Sendable, Equatable, Identifiable {
    public var id: Int64 {
        nodeNum
    }

    public let nodeNum: Int64
    public let nodeName: String
    public let armed: Bool
    public let state: ArmingState
    public let thresholdMeters: Double
    /// The captured anchor (lat, lon), nil when never captured.
    public let anchor: (lat: Double, lon: Double)?
    public let capturedAt: Instant?

    public init(
        nodeNum: Int64,
        nodeName: String,
        armed: Bool,
        state: ArmingState,
        thresholdMeters: Double,
        anchor: (lat: Double, lon: Double)?,
        capturedAt: Instant?
    ) {
        self.nodeNum = nodeNum
        self.nodeName = nodeName
        self.armed = armed
        self.state = state
        self.thresholdMeters = thresholdMeters
        self.anchor = anchor
        self.capturedAt = capturedAt
    }

    public static func == (lhs: ArmingDisplay, rhs: ArmingDisplay) -> Bool {
        lhs.nodeNum == rhs.nodeNum && lhs.nodeName == rhs.nodeName && lhs.armed == rhs.armed
            && lhs.state == rhs.state && lhs.thresholdMeters == rhs.thresholdMeters
            && lhs.anchor?.lat == rhs.anchor?.lat && lhs.anchor?.lon == rhs.anchor?.lon
            && lhs.capturedAt == rhs.capturedAt
    }
}

/// Typed failures for the arming flow.
public enum ArmingFlowError: Error, Equatable, Sendable {
    /// Capture was requested but the operator hadn't armed first (safety gate).
    case notArmed
    /// Capture was requested for a node with no stored position fix to anchor on.
    case noPositionFix(nodeNum: Int64)
}

@Observable
@MainActor
public final class ArmingFlowViewModel {
    /// The arming rows, one per node that has ever been armed/anchored.
    public private(set) var rows: [ArmingDisplay] = []

    /// The default geofence threshold a fresh capture uses (meters). Operator-set
    /// in the view before capturing.
    public var defaultThresholdMeters: Double = 50

    @ObservationIgnored private let store: MeshStore
    @ObservationIgnored private let clock: Clock
    @ObservationIgnored private var nodeNames: [Int64: String] = [:]

    public init(store: MeshStore, clock: Clock) {
        self.store = store
        self.clock = clock
    }

    /// Load arming rows + node names for display.
    public func load() async throws {
        let nodes = try await store.allNodes()
        nodeNames = Dictionary(
            nodes.map { ($0.node_num, Self.name(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let arming = try await store.allArming()
        rows = arming.map { Self.display($0, names: nodeNames) }
    }

    /// Capture an anchor for `nodeNum` at its latest stored position, arming
    /// movement detection. The arming gate is enforced: `armed` must be true (the
    /// view's ARM toggle). Anchors at the node's most-recent position fix.
    public func capture(nodeNum: Int64, armed: Bool, thresholdMeters: Double? = nil) async throws {
        guard armed else { throw ArmingFlowError.notArmed }
        guard let fix = try await store.latestPositionFix(nodeNum: nodeNum) else {
            throw ArmingFlowError.noPositionFix(nodeNum: nodeNum)
        }
        let record = ArmingRecord(
            node_num: nodeNum,
            armed: true,
            threshold_m: thresholdMeters ?? defaultThresholdMeters,
            anchor_lat: fix.lat,
            anchor_lon: fix.lon,
            anchor_accuracy: fix.h_accuracy,
            captured_at: clock.now().nanosecondsSinceEpoch,
            state: .anchored
        )
        try await store.saveArming(record)
        try await load()
    }

    /// Disarm a node: clear the armed flag (keeping the anchor row for history).
    public func disarm(nodeNum: Int64) async throws {
        guard var record = try await store.arming(nodeNum: nodeNum) else { return }
        record.armed = false
        try await store.saveArming(record)
        try await load()
    }

    // MARK: Pure mapping (testable without a store)

    static func display(_ record: ArmingRecord, names: [Int64: String]) -> ArmingDisplay {
        let anchor = anchor(of: record)
        return ArmingDisplay(
            nodeNum: record.node_num,
            nodeName: names[record.node_num] ?? hexID(record.node_num),
            armed: record.armed,
            state: record.state,
            thresholdMeters: record.threshold_m,
            anchor: anchor,
            capturedAt: record.captured_at.map { Instant(nanosecondsSinceEpoch: $0) }
        )
    }

    /// The captured anchor as a tuple, or nil when either coordinate is absent.
    private static func anchor(of record: ArmingRecord) -> (lat: Double, lon: Double)? {
        guard let lat = record.anchor_lat, let lon = record.anchor_lon else { return nil }
        return (lat, lon)
    }

    private static func name(for node: NodeRecord) -> String {
        node.short_name ?? node.long_name ?? hexID(node.node_num)
    }

    static func hexID(_ nodeNum: Int64) -> String {
        NodeID.hex(UInt32(truncatingIfNeeded: nodeNum))
    }
}
