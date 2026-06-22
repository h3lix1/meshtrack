// PacketInspectorView — decode one packet down to its fields, and show the
// per-gateway reception timing (SPEC §1: "record the time taken for each node to
// receive the packet and publish onto MQTT"). PacketsView is the master/detail:
// a recent-packets list (each id its own colour) beside the inspector.

import Domain
import SwiftUI

public struct GatewayReceptionRow: Identifiable, Sendable {
    public let id = UUID()
    public let gatewayName: String
    /// Milliseconds after the first gateway saw this packet (propagation + publish).
    public let millisFromFirst: Int
    public let snr: Double

    public init(gatewayName: String, millisFromFirst: Int, snr: Double) {
        self.gatewayName = gatewayName
        self.millisFromFirst = millisFromFirst
        self.snr = snr
    }
}

public struct PacketInspection: Identifiable, Sendable {
    public let id = UUID()
    public let packetID: UInt32
    public let from: Int64
    public let to: Int64
    public let portNum: String
    public let channel: Int
    public let hopStart: Int
    public let hopLimit: Int
    public let snr: Double
    public let rssi: Int
    public let relayNode: UInt8
    public let viaMqtt: Bool
    public let payloadSummary: String
    public let receptions: [GatewayReceptionRow]

    public init(
        packetID: UInt32, from: Int64, to: Int64, portNum: String, channel: Int,
        hopStart: Int, hopLimit: Int, snr: Double, rssi: Int, relayNode: UInt8,
        viaMqtt: Bool, payloadSummary: String, receptions: [GatewayReceptionRow]
    ) {
        self.packetID = packetID
        self.from = from
        self.to = to
        self.portNum = portNum
        self.channel = channel
        self.hopStart = hopStart
        self.hopLimit = hopLimit
        self.snr = snr
        self.rssi = rssi
        self.relayNode = relayNode
        self.viaMqtt = viaMqtt
        self.payloadSummary = payloadSummary
        self.receptions = receptions
    }

    public var color: Color {
        PacketColor.color(for: packetID)
    }

    public var hops: Int {
        max(0, hopStart - hopLimit)
    }

    func hex(_ value: Int64) -> String {
        NodeID.hex(UInt32(truncatingIfNeeded: value))
    }
}

public struct PacketsView: View {
    public let packets: [PacketInspection]
    @State private var selected: PacketInspection.ID?
    public init(packets: [PacketInspection]) {
        self.packets = packets
    }

    private var current: PacketInspection? {
        packets.first { $0.id == selected } ?? packets.first
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("RECENT PACKETS")
                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(packets) { packet in
                    packetRow(packet, isSelected: packet.id == current?.id)
                        .onTapGesture { selected = packet.id }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 290)
            .frame(maxHeight: .infinity)
            .background(Color(red: 0.04, green: 0.05, blue: 0.12))
            Divider().overlay(.white.opacity(0.08))
            if let current {
                PacketInspectorView(packet: current)
            }
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }

    private func packetRow(_ packet: PacketInspection, isSelected: Bool) -> some View {
        HStack(spacing: 9) {
            Circle().fill(packet.color).frame(width: 9, height: 9).shadow(color: packet.color, radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(NodeID.hex(packet.packetID))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                Text(packet.portNum).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(packet.hops)h").font(.system(size: 10, weight: .semibold)).foregroundStyle(packet.color)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isSelected ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

public struct PacketInspectorView: View {
    public let packet: PacketInspection
    public init(packet: PacketInspection) {
        self.packet = packet
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            fieldsGrid
            timingSection
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5).fill(packet.color).frame(width: 10, height: 34)
                .shadow(color: packet.color, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Packet " + NodeID.hex(packet.packetID)).font(.system(size: 18, weight: .bold))
                Text("\(packet.hex(packet.from)) → \(packet.hex(packet.to)) · \(packet.portNum)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(packet.hops) HOPS").font(.system(size: 12, weight: .heavy))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(packet.color.opacity(0.2), in: Capsule()).foregroundStyle(packet.color)
        }
    }

    private var fieldsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            field("CHANNEL", "\(packet.channel)")
            field("HOP START / LIMIT", "\(packet.hopStart) / \(packet.hopLimit)")
            field("RELAY NODE", String(format: "0x%02x", packet.relayNode))
            field("SNR", String(format: "%.1f dB", packet.snr))
            field("RSSI", "\(packet.rssi) dBm")
            field("VIA", packet.viaMqtt ? "MQTT" : "RF")
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECEPTION TIMING — time for each gateway to hear + publish")
                .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            Text("Payload: \(packet.payloadSummary)").font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
            ForEach(packet.receptions) { reception in
                receptionRow(reception)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func receptionRow(_ reception: GatewayReceptionRow) -> some View {
        let maxMillis = max(packet.receptions.map(\.millisFromFirst).max() ?? 1, 1)
        return HStack(spacing: 10) {
            Text(reception.gatewayName).font(.system(size: 12, design: .monospaced))
                .frame(width: 90, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(packet.color.opacity(0.6))
                        .frame(width: max(
                            6,
                            geo.size.width * Double(reception.millisFromFirst) / Double(maxMillis)
                        ))
                }
            }
            .frame(height: 8)
            Text(reception.millisFromFirst == 0 ? "first" : "+\(reception.millisFromFirst)ms")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(reception.millisFromFirst == 0 ? .green : .white.opacity(0.8))
                .frame(width: 64, alignment: .trailing)
        }
    }
}
