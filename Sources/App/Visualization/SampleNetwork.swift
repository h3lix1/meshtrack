// Sample network data for previews + snapshots (Bay Area mesh). Real data comes
// from the live store/MQTT feed; this drives the visual-validation snapshots.

import Domain

public enum SampleNetwork {
    public static let nodes: [NetworkNode] = [
        .init(
            id: 0xA1B2_C3D4,
            name: "SF-Gate",
            position: .init(latitude: 37.7749, longitude: -122.4194),
            hopsFromGateway: 0,
            batteryPercent: 96,
            isGateway: true
        ),
        .init(
            id: 0x0AC1_5511,
            name: "Oakland",
            position: .init(latitude: 37.8044, longitude: -122.2712),
            hopsFromGateway: 1,
            batteryPercent: 88
        ),
        .init(
            id: 0x0BE2_4202,
            name: "Berkeley",
            position: .init(latitude: 37.8715, longitude: -122.2730),
            hopsFromGateway: 2,
            batteryPercent: 73
        ),
        .init(
            id: 0x5A1B_0303,
            name: "SanJose",
            position: .init(latitude: 37.3382, longitude: -121.8863),
            hopsFromGateway: 3,
            batteryPercent: 41
        ),
        .init(
            id: 0x9A10_0404,
            name: "PaloAlto",
            position: .init(latitude: 37.4419, longitude: -122.1430),
            hopsFromGateway: 2,
            batteryPercent: 64
        ),
        .init(
            id: 0x3A21_0505,
            name: "Marin",
            position: .init(latitude: 37.9735, longitude: -122.5311),
            hopsFromGateway: 1,
            batteryPercent: 90,
            isGateway: true
        ),
        .init(
            id: 0xF1B8_0606,
            name: "Fremont",
            position: .init(latitude: 37.5485, longitude: -121.9886),
            hopsFromGateway: 3,
            batteryPercent: 28
        ),
        .init(
            id: 0x16CE_0707,
            name: "Hayward",
            position: .init(latitude: 37.6688, longitude: -122.0808),
            hopsFromGateway: 2,
            batteryPercent: 55
        ),
        .init(
            id: 0xA038_0808,
            name: "MtnView",
            position: .init(latitude: 37.3861, longitude: -122.0839),
            hopsFromGateway: 3,
            batteryPercent: 80
        ),
        .init(
            id: 0x49B5_0909,
            name: "WalnutCk",
            position: .init(latitude: 37.9101, longitude: -122.0652),
            hopsFromGateway: 2,
            batteryPercent: 12
        ),
        .init(
            id: 0xC0FF_0A0A,
            name: "DalyCity",
            position: .init(latitude: 37.6879, longitude: -122.4702),
            hopsFromGateway: 1,
            batteryPercent: 99
        ),
        .init(
            id: 0x2C72_0B0B,
            name: "Richmond",
            position: .init(latitude: 37.9358, longitude: -122.3477),
            hopsFromGateway: 2,
            batteryPercent: 67
        ),
        .init(
            id: 0x441D_0C0C,
            name: "SanMateo",
            position: .init(latitude: 37.5630, longitude: -122.3255),
            hopsFromGateway: 2,
            batteryPercent: 49
        ),
        .init(
            id: 0xEBA3_0D0D,
            name: "Concord",
            position: .init(latitude: 37.9780, longitude: -122.0311),
            hopsFromGateway: 3,
            batteryPercent: 35
        )
    ]

    private static func position(_ id: Int64) -> GeoPoint {
        nodes.first { $0.id == id }?.position ?? .init(latitude: 37.7, longitude: -122.3)
    }

    public static let traces: [PacketTrace] = [
        // San Jose → Palo Alto (guessed relay) → Oakland → SF gateway, 3 hops.
        .init(id: 0x2A3B_4C5D, sourceNode: 0x5A1B_0303, edges: [
            .init(from: position(0x5A1B_0303), to: position(0x9A10_0404), kind: .guessed),
            .init(from: position(0x9A10_0404), to: position(0x0AC1_5511), kind: .observed),
            .init(from: position(0x0AC1_5511), to: position(0xA1B2_C3D4), kind: .observed)
        ], hops: 3, startedAt: 0.0),
        // Fremont → Hayward (relay) → Oakland gateway, 2 hops.
        .init(id: 0x7788_99AA, sourceNode: 0xF1B8_0606, edges: [
            .init(from: position(0xF1B8_0606), to: position(0x16CE_0707), kind: .guessed),
            .init(from: position(0x16CE_0707), to: position(0x0AC1_5511), kind: .observed)
        ], hops: 2, startedAt: 0.4),
        // Concord → Walnut Creek (relay) → Marin gateway, 2 hops.
        .init(id: 0xDEAD_BEEF, sourceNode: 0xEBA3_0D0D, edges: [
            .init(from: position(0xEBA3_0D0D), to: position(0x49B5_0909), kind: .guessed),
            .init(from: position(0x49B5_0909), to: position(0x3A21_0505), kind: .observed)
        ], hops: 2, startedAt: 0.8),
        // Mountain View → San Mateo → Daly City gateway, 2 hops.
        .init(id: 0x1337_1337, sourceNode: 0xA038_0808, edges: [
            .init(from: position(0xA038_0808), to: position(0x441D_0C0C), kind: .guessed),
            .init(from: position(0x441D_0C0C), to: position(0xC0FF_0A0A), kind: .observed)
        ], hops: 2, startedAt: 1.1)
    ]
}
