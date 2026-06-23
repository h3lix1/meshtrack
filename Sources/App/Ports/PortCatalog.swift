// PortCatalog — a static, App-local catalogue describing each Meshtastic
// application port (`PortNum`). Domain models only the handful of ports the rest
// of the app reasons about (`MeshPort`); the human-facing NAME + one-line
// DESCRIPTION of what a port carries is a presentation concern, so it lives here
// in App rather than bloating the pure Domain layer.
//
// The full PortNum list is taken from `Sources/MeshProtos/portnums.pb.swift`
// (READ ONLY, generated). We carry the commonly-seen ports by raw number and fall
// back to a generated "PORT_<n>" label for anything unmodelled — so a brand-new
// firmware port still renders sensibly without a code change.

import Domain

/// A human-readable description of one Meshtastic port: its canonical Meshtastic
/// name (e.g. `TEXT_MESSAGE_APP`) and a one-line summary of the payload it carries.
public struct PortDescriptor: Sendable, Equatable {
    /// The raw `PortNum` value (the wire number).
    public let rawValue: Int
    /// The canonical Meshtastic constant name, e.g. `POSITION_APP`.
    public let name: String
    /// A one-line description of what this port carries.
    public let summary: String

    public init(rawValue: Int, name: String, summary: String) {
        self.rawValue = rawValue
        self.name = name
        self.summary = summary
    }
}

/// The static catalogue. Pure, `Sendable`, no I/O — just a lookup table.
public enum PortCatalog {
    /// Describe a `MeshPort`: its catalogue entry, or a synthesised descriptor for
    /// an unmodelled raw port (`.other(n)` or any number not in the table).
    public static func descriptor(for port: MeshPort) -> PortDescriptor {
        descriptor(forRawValue: port.portNumRawValue)
    }

    /// Describe a raw `PortNum`. Known ports come from the table; everything else
    /// gets a generated "PORT_<n>" descriptor so unknown ports still render.
    public static func descriptor(forRawValue raw: Int) -> PortDescriptor {
        known[raw] ?? PortDescriptor(
            rawValue: raw,
            name: "PORT_\(raw)",
            summary: "Unrecognised application port \(raw)."
        )
    }

    /// The catalogue keyed by raw `PortNum`, drawn from the generated `PortNum` enum.
    private static let known: [Int: PortDescriptor] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.rawValue, $0) }
    )

    /// Every catalogued port. Numbers match `portnums.pb.swift`.
    static let entries: [PortDescriptor] = [
        .init(rawValue: 0, name: "UNKNOWN_APP", summary: "Deprecated/unset port; treated as raw text."),
        .init(rawValue: 1, name: "TEXT_MESSAGE_APP", summary: "Plain UTF-8 chat messages between users."),
        .init(rawValue: 2, name: "REMOTE_HARDWARE_APP", summary: "GPIO read/write on a remote node."),
        .init(rawValue: 3, name: "POSITION_APP", summary: "GPS position fixes (lat/lon/alt)."),
        .init(rawValue: 4, name: "NODEINFO_APP", summary: "Node identity: name, hardware, role."),
        .init(rawValue: 5, name: "ROUTING_APP", summary: "Mesh routing: acks, traceroute, error returns."),
        .init(rawValue: 6, name: "ADMIN_APP", summary: "Remote configuration / admin commands."),
        .init(rawValue: 7, name: "TEXT_MESSAGE_COMPRESSED_APP", summary: "Compressed chat (unicode-aware)."),
        .init(rawValue: 8, name: "WAYPOINT_APP", summary: "Shared map waypoints / pins."),
        .init(rawValue: 9, name: "AUDIO_APP", summary: "Codec2-encoded push-to-talk audio frames."),
        .init(rawValue: 10, name: "DETECTION_SENSOR_APP", summary: "Binary detection-sensor trip events."),
        .init(rawValue: 11, name: "ALERT_APP", summary: "High-priority alert / klaxon messages."),
        .init(rawValue: 12, name: "KEY_VERIFICATION_APP", summary: "Out-of-band public-key verification."),
        .init(rawValue: 32, name: "REPLY_APP", summary: "Ping/echo reply test payloads."),
        .init(rawValue: 33, name: "IP_TUNNEL_APP", summary: "Experimental IP-over-mesh tunnel frames."),
        .init(rawValue: 34, name: "PAXCOUNTER_APP", summary: "Counts nearby WiFi/BLE devices."),
        .init(rawValue: 64, name: "SERIAL_APP", summary: "Transparent serial bridge data."),
        .init(rawValue: 65, name: "STORE_FORWARD_APP", summary: "Store-and-forward history relay."),
        .init(rawValue: 66, name: "RANGE_TEST_APP", summary: "Sequenced range-test beacons."),
        .init(rawValue: 67, name: "TELEMETRY_APP", summary: "Device/environment/power telemetry samples."),
        .init(rawValue: 70, name: "TRACEROUTE_APP", summary: "Hop-by-hop path discovery requests."),
        .init(rawValue: 71, name: "NEIGHBORINFO_APP", summary: "A node's directly-heard neighbour list."),
        .init(rawValue: 72, name: "ATAK_PLUGIN", summary: "ATAK situational-awareness plugin data."),
        .init(rawValue: 73, name: "MAP_REPORT_APP", summary: "Periodic position/role report for mapping."),
        .init(rawValue: 76, name: "RETICULUM_TUNNEL_APP", summary: "Reticulum network tunnel frames."),
        .init(rawValue: 256, name: "PRIVATE_APP", summary: "Reserved private/experimental application range.")
    ]
}
