// PacketInspectorSample — a self-contained fixture for previews and the snapshot
// harness (G6). Kept local to the Packets module so feature agents never touch the
// shared SampleNetwork.swift. Builds a PacketInspectorViewModel pre-loaded with a
// handful of decoded packets across ports, with deterministic ingest latencies.

import Domain

public enum PacketInspectorSample {
    /// A deterministic clock pinned to a fixed epoch so previews/snapshots are stable.
    private static var pinnedClock: InjectedClock {
        InjectedClock(Instant(nanosecondsSinceEpoch: 0))
    }

    private static func packet(
        from: UInt32,
        to: UInt32 = 0xFFFF_FFFF,
        id: UInt32,
        channel: UInt32 = 0,
        port: MeshPort,
        payload: [UInt8],
        rxSeconds: Double = 0,
        hopStart: UInt8 = 3,
        hopLimit: UInt8 = 1,
        relay: UInt8 = 0x2A,
        gateway: UInt32 = 0x0000_00FF,
        encrypted: Bool = true
    ) -> DecodedPacket {
        DecodedPacket(
            from: from, to: to, packetID: id, channel: channel, port: port,
            payload: payload,
            rxTime: Instant(nanosecondsSinceEpoch: 0).adding(seconds: rxSeconds),
            rxRssi: -92, rxSnr: 6.5, hopStart: hopStart, hopLimit: hopLimit,
            relayNode: relay, gatewayID: gateway, wasEncrypted: encrypted
        )
    }

    /// A view model pre-loaded with sample traffic and known latencies.
    @MainActor
    public static func viewModel() -> PacketInspectorViewModel {
        let model = PacketInspectorViewModel(clock: pinnedClock, maxPackets: 50)
        for (pkt, latencyMs) in feed {
            let ingest = pkt.rxTime.adding(seconds: Double(latencyMs) / 1000)
            model.ingest(pkt, ingestTime: ingest)
        }
        return model
    }

    /// Sample (packet, receive→publish latency in ms) pairs across ports.
    private static var feed: [(DecodedPacket, Int)] {
        [
            (packet(
                from: 0x11AA_22BB,
                id: 0x2A3B_4C5D,
                channel: 0,
                port: .textMessage,
                payload: Array("hello mesh!".utf8),
                rxSeconds: 10
            ), 182),
            (packet(
                from: 0x33CC_44DD,
                id: 0x7788_99AA,
                channel: 8,
                port: .telemetry,
                payload: [0x0D, 0x42, 0x00, 0x00, 0xA0, 0x41, 0x10, 0x64],
                rxSeconds: 11
            ), 96),
            (
                packet(
                    from: 0x55EE_66FF,
                    id: 0x1234_5678,
                    channel: 8,
                    port: .position,
                    payload: [0x0D, 0x80, 0x4C, 0x1A, 0x16, 0x15, 0x40, 0x9B, 0x8B, 0xC8],
                    rxSeconds: 12
                ),
                245
            ),
            (packet(
                from: 0x11AA_22BB,
                id: 0x0F0E_0D0C,
                channel: 0,
                port: .nodeInfo,
                payload: Array("!11aa22bb MTRK".utf8),
                rxSeconds: 13,
                encrypted: false
            ), 58),
            (packet(
                from: 0x9A9B_9C9D,
                id: 0xCAFE_BABE,
                channel: 0,
                port: .other(99),
                payload: [0xDE, 0xAD, 0xBE, 0xEF],
                rxSeconds: 14
            ), 410)
        ]
    }
}
