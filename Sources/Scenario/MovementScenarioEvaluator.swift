// MovementScenarioEvaluator — runs a scenario's fixes through the MovementDetector
// and maps confirmed events to alerts (SPEC §2.3/§6.5 / Phase 3 done-condition).
//
// Class-based semantics (SPEC §2.3): a `mobile` node emits `geofence_exit` rather
// than `moved`. This is what proves "jitter → zero alerts, real move → exactly one"
// through the acceptance harness.

import Domain
import RuleEngine

public struct MovementScenarioEvaluator: ScenarioEvaluator {
    private static let metersPerDegreeLatitude = 111_320.0
    private let anchor: GeoPoint

    public init(anchor: GeoPoint = GeoPoint(latitude: 0, longitude: 0)) {
        self.anchor = anchor
    }

    public func evaluate(_ scenario: Scenario) -> [ProducedAlert] {
        guard let arm = scenario.arm, !scenario.fixes.isEmpty else { return [] }
        var detector = MovementDetector(
            anchor: anchor,
            anchorAccuracyMeters: 0,
            config: MovementConfig(
                thresholdMeters: arm.thresholdMeters,
                accuracyMarginMeters: arm.accuracyMarginMeters,
                confirmationCount: arm.confirmationCount,
                escapeFactor: arm.escapeFactor
            )
        )
        let mobile = scenario.nodeClass == .mobile
        var alerts: [ProducedAlert] = []
        for step in scenario.fixes {
            for _ in 0 ..< step.count {
                guard let event = detector.ingest(sample(for: step.offset)) else { continue }
                let type: AlertType = switch event {
                case .moved: mobile ? .geofenceExit : .moved
                case .returned: .returned
                }
                alerts.append(ProducedAlert(type: type.rawValue))
            }
        }
        return alerts
    }

    private func sample(for offset: FixOffset) -> PositionSample {
        switch offset {
        case let .delta(dlat, dlon, accuracy):
            PositionSample(
                point: GeoPoint(latitude: anchor.latitude + dlat, longitude: anchor.longitude + dlon),
                horizontalAccuracyMeters: accuracy,
                at: .epoch
            )
        case let .metersFromAnchor(meters, accuracy):
            PositionSample(
                point: GeoPoint(
                    latitude: anchor.latitude + meters / Self.metersPerDegreeLatitude,
                    longitude: anchor.longitude
                ),
                horizontalAccuracyMeters: accuracy,
                at: .epoch
            )
        }
    }
}
