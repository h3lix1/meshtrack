// TrafficSampleData — a small, deterministic corpus of decoded packets used to seed
// the analytics screens' previews + snapshot fixtures (and a few tests). Pure data,
// no I/O. Modelled on a realistic public-mesh mix: a chatty position/telemetry node,
// a couple of relays, duplicate gateway receptions, a spread of ports and hops.

import Domain

public enum TrafficSampleData {
    /// A representative stream of receptions (duplicate floods included) over a few
    /// minutes, so the screens show non-trivial counts, spread, and chattiness.
    public static let packets: [DecodedPacket] = build()

    /// One logical packet's flood: its identity/port/hops + the gateways that heard it.
    private struct FloodSpec {
        let from: UInt32
        let packetID: UInt32
        let port: MeshPort
        let hopStart: UInt8
        let hopLimit: UInt8
        let channel: UInt32
        let gateways: [UInt32]
        let at: Double
    }

    private static func build() -> [DecodedPacket] {
        specs().flatMap(flood)
    }

    /// The deterministic flood specs the corpus is built from.
    private static func specs() -> [FloodSpec] {
        // A chatty position+telemetry node, heard by 3 gateways each time.
        var specs: [FloodSpec] = (0 ..< 8).map { index in
            FloodSpec(
                from: 0x00A1_B2C3, packetID: UInt32(1000 + index),
                port: index.isMultiple(of: 2) ? .position : .telemetry,
                hopStart: 3, hopLimit: 1, channel: 0x08,
                gateways: [0xAA, 0xBB, 0xCC], at: Double(index) * 20
            )
        }
        specs += [
            // A nodeinfo + a couple of text messages, fewer receptions, wider hops.
            FloodSpec(
                from: 0x00D4_E5F6, packetID: 2001, port: .nodeInfo,
                hopStart: 4, hopLimit: 1, channel: 0x08, gateways: [0xAA, 0xBB], at: 30
            ),
            FloodSpec(
                from: 0x00D4_E5F6, packetID: 2002, port: .textMessage,
                hopStart: 5, hopLimit: 2, channel: 0x1F, gateways: [0xAA], at: 45
            ),
            // A routing/ack node and a map-report — single receptions.
            FloodSpec(
                from: 0x0077_8899, packetID: 3001, port: .routing,
                hopStart: 2, hopLimit: 1, channel: 0x08, gateways: [0xCC], at: 60
            ),
            FloodSpec(
                from: 0x0077_8899, packetID: 3002, port: .mapReport,
                hopStart: 7, hopLimit: 0, channel: 0x08, gateways: [0xAA, 0xCC], at: 75
            ),
            // An unmodelled raw port, to exercise the .other(n) catalogue fallback.
            FloodSpec(
                from: 0x0011_2233, packetID: 4001, port: .other(66), // RANGE_TEST_APP
                hopStart: 1, hopLimit: 1, channel: 0x08, gateways: [0xBB], at: 90
            )
        ]
        return specs
    }

    /// Expand one spec into one reception per gateway (the duplicate flood).
    private static func flood(_ spec: FloodSpec) -> [DecodedPacket] {
        spec.gateways.enumerated().map { offset, gateway in
            DecodedPacket(
                from: spec.from, to: 0xFFFF_FFFF, packetID: spec.packetID, channel: spec.channel,
                port: spec.port, payload: [],
                rxTime: Instant.epoch.adding(seconds: spec.at + Double(offset)),
                hopStart: spec.hopStart, hopLimit: spec.hopLimit, gatewayID: gateway
            )
        }
    }
}
