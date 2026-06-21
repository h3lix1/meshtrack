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

    static let packets: [PacketInspection] = [
        PacketInspection(
            packetID: 0x2A3B_4C5D, from: 0x5A1B_0303, to: 0xFFFF_FFFF, portNum: "TELEMETRY_APP",
            channel: 0, hopStart: 3, hopLimit: 1, snr: -8.5, rssi: -112, relayNode: 0x09, viaMqtt: true,
            payloadSummary: "DeviceMetrics — batt 88%, 4.01 V, ch_util 12%",
            receptions: [
                .init(gatewayName: "SF-Gate", millisFromFirst: 0, snr: -8.5),
                .init(gatewayName: "Marin", millisFromFirst: 47, snr: -11.2),
                .init(gatewayName: "Oakland", millisFromFirst: 118, snr: -14.0)
            ]
        ),
        PacketInspection(
            packetID: 0x7788_99AA, from: 0xF1B8_0606, to: 0xFFFF_FFFF, portNum: "POSITION_APP",
            channel: 0, hopStart: 3, hopLimit: 1, snr: -6.0, rssi: -98, relayNode: 0xAB, viaMqtt: true,
            payloadSummary: "Position — 37.5485, -121.9886, ±12 m, 9 sats",
            receptions: [
                .init(gatewayName: "Fremont", millisFromFirst: 0, snr: -6.0),
                .init(gatewayName: "Hayward", millisFromFirst: 63, snr: -9.5)
            ]
        ),
        PacketInspection(
            packetID: 0xDEAD_BEEF, from: 0x49B5_0909, to: 0xFFFF_FFFF, portNum: "NODEINFO_APP",
            channel: 0, hopStart: 2, hopLimit: 0, snr: -12.5, rssi: -119, relayNode: 0x0D, viaMqtt: true,
            payloadSummary: "User — WalnutCk (long), HELTEC_V3",
            receptions: [
                .init(gatewayName: "Concord", millisFromFirst: 0, snr: -12.5),
                .init(gatewayName: "WalnutCk", millisFromFirst: 34, snr: -7.1),
                .init(gatewayName: "SF-Gate", millisFromFirst: 201, snr: -16.8)
            ]
        ),
        PacketInspection(
            packetID: 0x1337_1337, from: 0x150A_0202, to: 0x5A1B_0303, portNum: "TEXT_MESSAGE_APP",
            channel: 2, hopStart: 3, hopLimit: 0, snr: -3.0, rssi: -84, relayNode: 0x01, viaMqtt: false,
            payloadSummary: "Text — \"net check, all nodes ack\"",
            receptions: [
                .init(gatewayName: "SF-Gate", millisFromFirst: 0, snr: -3.0)
            ]
        )
    ]

    static let throughputSample: [Double] = (0 ..< 44).map { index in
        let wave = sin(Double(index) * 0.4) * 600.0 + sin(Double(index) * 1.3) * 220.0
        return 5000.0 + wave
    }

    static let metrics = DaemonMetrics(
        ingestRate: 5240, decodeSuccessPct: 97.1, decryptSuccessPct: 91.4, dedupCollapsePct: 47,
        nodesTracked: 312, telemetryRows: 184_920, uptimeHours: 72.4,
        throughput: throughputSample,
        brokers: [
            .init(name: "mqtt.bayme.sh", connected: true, messagesPerSec: 4980),
            .init(name: "mqtt.meshtastic.org", connected: true, messagesPerSec: 258),
            .init(name: "serial:/dev/cu.usbmodem3101", connected: false, messagesPerSec: 0)
        ]
    )
}
