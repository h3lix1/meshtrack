// GRDB record for the monitor-only `message` table (schema v3, ADR 0006).
//
// Decoded `TEXT_MESSAGE_APP` payloads, surfaced read-only in the Channels view.
// Property names mirror the SQLite column names (snake_case, SPEC §5) so Codable
// maps to columns with zero CodingKeys. Lives in its own file to keep Records.swift
// within the file-length budget.

import GRDB

// swiftlint:disable identifier_name
// Justification: record properties mirror SQLite column names (snake_case) — the
// database's naming style, scoped to this adapter file only.

/// `message` — a decoded `TEXT_MESSAGE_APP` payload (monitor-only, ADR 0006).
/// Append-only; written once per dedup key by the ingest pipeline. `is_dm`
/// distinguishes a direct message (`to_num` is a node) from a broadcast.
public struct MessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = Table.message
    public var id: Int64?
    public var packet_id: Int64
    public var from_num: Int64
    public var to_num: Int64
    public var channel: Int64
    public var channel_name: String?
    public var body: String
    public var rx_time: Int64
    public var is_dm: Bool

    public init(
        id: Int64? = nil,
        packet_id: Int64,
        from_num: Int64,
        to_num: Int64,
        channel: Int64,
        channel_name: String? = nil,
        body: String,
        rx_time: Int64,
        is_dm: Bool = false
    ) {
        self.id = id
        self.packet_id = packet_id
        self.from_num = from_num
        self.to_num = to_num
        self.channel = channel
        self.channel_name = channel_name
        self.body = body
        self.rx_time = rx_time
        self.is_dm = is_dm
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// swiftlint:enable identifier_name
