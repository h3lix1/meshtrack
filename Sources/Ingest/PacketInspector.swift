// PacketInspector — render a decoded packet for the debug view / logs (SPEC §1
// "packet inspector"). Pure formatter over DecodedPacket; decodes telemetry and
// position payloads for human-readable display. The SwiftUI debug view (later)
// renders this; the CLI and logs can use it now.

import Domain
import Foundation
import MeshProtos

/// A human-readable rendering of a decoded packet: a one-line `summary` plus
/// detail lines.
public struct PacketInspection: Sendable, Equatable {
    public let summary: String
    public let detail: [String]

    public init(summary: String, detail: [String]) {
        self.summary = summary
        self.detail = detail
    }
}

public enum PacketInspector {
    public static func inspect(_ packet: DecodedPacket) -> PacketInspection {
        let to = packet.to == 0xFFFF_FFFF ? "broadcast" : hexID(packet.to)
        let lock = packet.wasEncrypted ? " 🔒" : ""
        let summary = "\(hexID(packet.from)) → \(to)  \(portName(packet.port))\(lock)"

        var detail = ["packetID: \(packet.packetID)", "channel: \(packet.channel)"]
        if let rssi = packet.rxRssi { detail.append("rssi: \(rssi) dBm") }
        if let snr = packet.rxSnr { detail.append("snr: \(snr) dB") }
        if let start = packet.hopStart, let limit = packet.hopLimit {
            detail.append("hops: \(Int(start) - Int(limit))/\(start)")
        }
        detail.append("payload: \(packet.payload.count) bytes")
        detail.append(contentsOf: payloadDetail(packet))
        return PacketInspection(summary: summary, detail: detail)
    }

    private static func payloadDetail(_ packet: DecodedPacket) -> [String] {
        switch packet.port {
        case .telemetry: telemetryDetail(packet.payload)
        case .position: positionDetail(packet.payload)
        default: []
        }
    }

    private static func telemetryDetail(_ payload: [UInt8]) -> [String] {
        guard let telemetry = try? Telemetry(serializedBytes: Data(payload)),
              let variant = telemetry.variant else { return [] }
        switch variant {
        case let .deviceMetrics(metrics):
            var lines: [String] = []
            if metrics.hasBatteryLevel { lines.append("battery: \(metrics.batteryLevel)%") }
            if metrics.hasVoltage { lines.append("voltage: \(metrics.voltage) V") }
            if metrics.hasChannelUtilization { lines.append("chUtil: \(metrics.channelUtilization)%") }
            return lines
        case let .environmentMetrics(metrics):
            var lines: [String] = []
            if metrics.hasTemperature { lines.append("temp: \(metrics.temperature) °C") }
            if metrics.hasRelativeHumidity { lines.append("humidity: \(metrics.relativeHumidity)%") }
            return lines
        default:
            return []
        }
    }

    private static func positionDetail(_ payload: [UInt8]) -> [String] {
        guard let position = try? Position(serializedBytes: Data(payload)),
              position.hasLatitudeI, position.hasLongitudeI else { return ["no GPS fix"] }
        let lat = Double(position.latitudeI) * 1e-7
        let lon = Double(position.longitudeI) * 1e-7
        return ["lat: \(lat)", "lon: \(lon)"]
    }

    private static func hexID(_ value: UInt32) -> String {
        "!" + String(format: "%08x", value)
    }

    private static func portName(_ port: MeshPort) -> String {
        switch port {
        case .textMessage: "TEXT"
        case .position: "POSITION"
        case .nodeInfo: "NODEINFO"
        case .routing: "ROUTING"
        case .admin: "ADMIN"
        case .waypoint: "WAYPOINT"
        case .telemetry: "TELEMETRY"
        case .mapReport: "MAPREPORT"
        case let .other(raw): "PORT(\(raw))"
        }
    }
}
