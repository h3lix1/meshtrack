// MovementDetector — confirmed movement with accuracy margin + hysteresis
// (SPEC §2.3). This is signal processing, not a subtraction: GPS jitter inside
// the accuracy envelope must NEVER confirm movement, and a real move must confirm
// exactly once with no flapping.
//
// Pure value type. The owning actor captures an anchor and feeds fixes; each
// `ingest` returns a MovementEvent only on a confirmed state change. No GPS →
// the node is never fed here (no position source).

public struct MovementConfig: Sendable, Equatable {
    /// Movement threshold (metres) from the anchor.
    public var thresholdMeters: Double
    /// Extra fixed margin added to the accuracy envelope.
    public var accuracyMarginMeters: Double
    /// Consecutive candidate fixes required to confirm (default 3).
    public var confirmationCount: Int
    /// A single fix beyond the candidate boundary by this factor confirms at once
    /// (default 3×).
    public var escapeFactor: Double
    /// Return is confirmed when back inside `threshold * returnRatio` (default 0.6).
    public var returnRatio: Double

    public init(
        thresholdMeters: Double,
        accuracyMarginMeters: Double = 0,
        confirmationCount: Int = 3,
        escapeFactor: Double = 3,
        returnRatio: Double = 0.6
    ) {
        self.thresholdMeters = thresholdMeters
        self.accuracyMarginMeters = accuracyMarginMeters
        self.confirmationCount = confirmationCount
        self.escapeFactor = escapeFactor
        self.returnRatio = returnRatio
    }
}

/// One position fix fed to the detector.
public struct PositionSample: Sendable, Equatable {
    public let point: GeoPoint
    public let horizontalAccuracyMeters: Double
    public let at: Instant

    public init(point: GeoPoint, horizontalAccuracyMeters: Double, at: Instant) {
        self.point = point
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.at = at
    }
}

public enum MovementState: Sendable, Equatable {
    case anchored
    case moved
}

public enum MovementEvent: Sendable, Equatable {
    case moved
    case returned
}

public struct MovementDetector: Sendable {
    public let anchor: GeoPoint
    public let anchorAccuracyMeters: Double
    public let config: MovementConfig
    public private(set) var state: MovementState = .anchored

    private var consecutiveOutside = 0
    private var consecutiveInside = 0

    public init(anchor: GeoPoint, anchorAccuracyMeters: Double, config: MovementConfig) {
        self.anchor = anchor
        self.anchorAccuracyMeters = anchorAccuracyMeters
        self.config = config
    }

    /// Feed a fix. Returns a `MovementEvent` only when the confirmed state changes.
    public mutating func ingest(_ sample: PositionSample) -> MovementEvent? {
        // Never confirm movement on a fix coarser than the threshold (SPEC §2.3).
        if sample.horizontalAccuracyMeters > config.thresholdMeters { return nil }

        let distance = Haversine.distanceMeters(from: anchor, to: sample.point)
        return switch state {
        case .anchored: ingestAnchored(distance: distance, accuracy: sample.horizontalAccuracyMeters)
        case .moved: ingestMoved(distance: distance)
        }
    }

    private mutating func ingestAnchored(distance: Double, accuracy: Double) -> MovementEvent? {
        // Candidate boundary widens with both the anchor's and the fix's accuracy.
        let boundary = config.thresholdMeters + config.accuracyMarginMeters + accuracy + anchorAccuracyMeters
        guard distance > boundary else {
            consecutiveOutside = 0
            return nil
        }
        consecutiveOutside += 1
        consecutiveInside = 0
        let escaped = distance > boundary * config.escapeFactor
        guard escaped || consecutiveOutside >= config.confirmationCount else { return nil }
        state = .moved
        consecutiveOutside = 0
        return .moved
    }

    private mutating func ingestMoved(distance: Double) -> MovementEvent? {
        // Hysteresis: only "returned" when well back inside, sustained (no flapping).
        guard distance < config.thresholdMeters * config.returnRatio else {
            consecutiveInside = 0
            return nil
        }
        consecutiveInside += 1
        consecutiveOutside = 0
        guard consecutiveInside >= config.confirmationCount else { return nil }
        state = .anchored
        consecutiveInside = 0
        return .returned
    }
}
