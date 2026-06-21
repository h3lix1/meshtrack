// Sample alerts / fleet rollout / telemetry for previews + snapshots.

import Foundation

public extension SampleNetwork {
    static let alerts: [AlertDisplay] = [
        .init(
            type: "Battery low",
            nodeName: "!49b50909",
            detail: "WalnutCk: battery 12% < 20%",
            state: .firing
        ),
        .init(
            type: "Node went silent",
            nodeName: "!f1b80606",
            detail: "Fremont: silent 31m (> 30m)",
            state: .firing
        ),
        .init(
            type: "Voltage low",
            nodeName: "!eba30d0d",
            detail: "Concord: 3.1V < 3.3V",
            state: .acknowledged
        ),
        .init(
            type: "Node moved",
            nodeName: "!5a1b0303",
            detail: "SanJose: confirmed 640m move",
            state: .resolved
        ),
        .init(
            type: "Battery low",
            nodeName: "!f1b80606",
            detail: "Fremont: battery 28% < 30%",
            state: .acknowledged
        )
    ]

    static let rollout: [FleetRolloutRow] = [
        .init(nodeName: "SF-Gate", status: .verified),
        .init(nodeName: "Oakland", status: .verified),
        .init(nodeName: "Berkeley", status: .verified),
        .init(nodeName: "Marin", status: .applying),
        .init(nodeName: "DalyCity", status: .pending),
        .init(nodeName: "Richmond", status: .pending),
        .init(nodeName: "SanMateo", status: .pending)
    ]

    static let telemetry: [TelemetrySample] = {
        let nodes = ["SF-Gate", "WalnutCk", "Fremont", "Berkeley"]
        let starts = [99.0, 42.0, 60.0, 82.0]
        var samples: [TelemetrySample] = []
        for (index, node) in nodes.enumerated() {
            for hour in 0 ... 23 {
                let drain = Double(hour) * (0.7 + Double(index) * 0.35)
                let wobble = sin(Double(hour) * 0.55 + Double(index)) * 2.5
                samples.append(TelemetrySample(
                    node: node,
                    hour: hour,
                    battery: max(6, starts[index] - drain + wobble)
                ))
            }
        }
        return samples
    }()
}
