// ObservabilityPreviewData — deterministic `IngestHealth` snapshots for previews,
// snapshot rendering, and tests (G10). Fixed numbers so the headless render and
// the derivation tests agree.

import Domain
import Foundation

/// Fixed snapshots feeding `#Preview`s and the snapshot harness.
public enum ObservabilityPreviewData {
    /// A second expressed in nanoseconds (snapshot timestamps).
    private static let second: Int64 = 1_000_000_000

    /// A healthy, fresh, fully-connected feed.
    public static func healthySnapshot() -> IngestHealth {
        IngestHealth(
            framesProcessed: 1240,
            packetsDecoded: 1198,
            decodeErrors: 6,
            observationsRecorded: 980,
            duplicateDeliveriesSkipped: 218,
            telemetryPointsRecorded: 412,
            positionFixesRecorded: 96,
            messagesRecorded: 37,
            lastPacketAt: Instant(nanosecondsSinceEpoch: 600 * second),
            startedAt: Instant(nanosecondsSinceEpoch: 0),
            throughputSamples: [1.2, 1.8, 2.4, 2.0, 2.9, 3.4, 2.7, 3.1, 3.8, 4.2, 3.6, 4.0],
            transports: [
                TransportHealth(
                    transport: .mqtt, connected: true, framesReceived: 1180,
                    lastFrameAt: Instant(nanosecondsSinceEpoch: 600 * second)
                ),
                TransportHealth(
                    transport: .serial, connected: true, framesReceived: 60,
                    lastFrameAt: Instant(nanosecondsSinceEpoch: 590 * second)
                )
            ]
        )
    }

    /// A degraded feed: stale, high decode errors, one transport down.
    public static func degradedSnapshot() -> IngestHealth {
        IngestHealth(
            framesProcessed: 800,
            packetsDecoded: 540,
            decodeErrors: 260,
            observationsRecorded: 500,
            duplicateDeliveriesSkipped: 40,
            telemetryPointsRecorded: 88,
            positionFixesRecorded: 12,
            messagesRecorded: 4,
            lastPacketAt: Instant(nanosecondsSinceEpoch: 100 * second),
            startedAt: Instant(nanosecondsSinceEpoch: 0),
            throughputSamples: [3.0, 2.1, 1.2, 0.6, 0.3, 0.1, 0.0, 0.0],
            transports: [
                TransportHealth(
                    transport: .mqtt, connected: false, framesReceived: 760,
                    lastFrameAt: Instant(nanosecondsSinceEpoch: 100 * second)
                ),
                TransportHealth(
                    transport: .serial, connected: true, framesReceived: 40,
                    lastFrameAt: Instant(nanosecondsSinceEpoch: 700 * second)
                )
            ]
        )
    }

    /// A VM showing the healthy feed, with "now" 12s after the last packet.
    @MainActor public static func healthy() -> ObservabilityViewModel {
        let viewModel = ObservabilityViewModel()
        viewModel.update(healthySnapshot(), now: Instant(nanosecondsSinceEpoch: 612 * second))
        return viewModel
    }

    /// A VM showing the degraded feed, with "now" 10 minutes after the last packet
    /// (so the lag tile reads "bad").
    @MainActor public static func degraded() -> ObservabilityViewModel {
        let viewModel = ObservabilityViewModel()
        viewModel.update(degradedSnapshot(), now: Instant(nanosecondsSinceEpoch: 700 * second))
        return viewModel
    }
}
