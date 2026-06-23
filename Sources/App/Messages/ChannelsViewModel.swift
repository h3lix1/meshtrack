// ChannelsViewModel — presentation logic for the monitor-only Channels view
// (ADR 0006). Loads decoded text messages from the store, groups them by channel,
// resolves sender short-names from node records, segments bodies for @mention
// highlighting, and classifies each message as a DM or a broadcast. Pure
// formatting + an async `load` over the store; no SwiftUI, so it is unit-tested.
//
// Read-only: there is no send path in Phase 7 (the non-goal narrows to *two-way*
// chat, ADR 0006).

import Domain
import Foundation
import Observation
import Persistence

/// One run of a message body: plain text, or a `@mention` to highlight.
public struct MessageBodySegment: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        /// A `@name` call-out. `name` is the mention without the leading `@`.
        case mention(name: String)
    }

    public let kind: Kind
    /// The literal text of this run, including the leading `@` for mentions.
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A decoded message formatted for the transcript.
public struct MessageDisplay: Sendable, Equatable, Identifiable {
    public let id: Int64
    /// The sending node's resolved short-name (falls back to hex id).
    public let sender: String
    /// The sender's numeric node id (for resolution / debugging).
    public let fromNum: Int64
    /// The body split into plain / mention runs for highlighting.
    public let segments: [MessageBodySegment]
    /// `true` when addressed to a specific node rather than the broadcast id.
    public let isDirectMessage: Bool
    /// When we received the message.
    public let rxTime: Instant

    public init(
        id: Int64,
        sender: String,
        fromNum: Int64,
        segments: [MessageBodySegment],
        isDirectMessage: Bool,
        rxTime: Instant
    ) {
        self.id = id
        self.sender = sender
        self.fromNum = fromNum
        self.segments = segments
        self.isDirectMessage = isDirectMessage
        self.rxTime = rxTime
    }

    /// The plain body text, mentions included (segments rejoined).
    public var body: String {
        segments.map(\.text).joined()
    }

    /// The mention names found in the body, in order of appearance.
    public var mentions: [String] {
        segments.compactMap { segment in
            if case let .mention(name) = segment.kind { name } else { nil }
        }
    }
}

/// A channel and its messages, summarised for the channel list.
public struct ChannelSummary: Sendable, Equatable, Identifiable {
    /// The channel hash (`MeshPacket.channel`).
    public var id: Int64 {
        channel
    }

    public let channel: Int64
    /// Human channel name when known, else a hash-derived label (`#<hex>`).
    public let name: String
    /// `true` when the name is a fallback (no `channel_name` was recorded).
    public let isUnnamed: Bool
    /// Messages on this channel, oldest-first (transcript order).
    public let messages: [MessageDisplay]

    public init(
        channel: Int64,
        name: String,
        isUnnamed: Bool,
        messages: [MessageDisplay]
    ) {
        self.channel = channel
        self.name = name
        self.isUnnamed = isUnnamed
        self.messages = messages
    }

    /// When the most-recent message on this channel arrived (for ordering).
    public var lastActivity: Instant {
        messages.last?.rxTime ?? .epoch
    }

    public var messageCount: Int {
        messages.count
    }
}

@Observable
@MainActor
public final class ChannelsViewModel {
    /// Channels with their transcripts, most-recent activity first.
    public private(set) var channels: [ChannelSummary] = []
    /// The selected channel hash, if any (drives the transcript pane).
    public var selectedChannel: Int64?

    @ObservationIgnored private let store: MeshStore
    @ObservationIgnored private let limit: Int

    public init(store: MeshStore, limit: Int = 500) {
        self.store = store
        self.limit = limit
    }

    /// The currently-selected channel's summary, or the first channel as a
    /// default when nothing is selected.
    public var selectedSummary: ChannelSummary? {
        if let selectedChannel {
            return channels.first { $0.channel == selectedChannel }
        }
        return channels.first
    }

    /// Load recent messages, resolve senders, and group by channel.
    public func load() async throws {
        let records = try await store.recentMessages(limit: limit)
        let nodes = try await store.allNodes()
        let senders = Self.senderIndex(nodes)
        channels = Self.group(records, senders: senders)
        if let selectedChannel, !channels.contains(where: { $0.channel == selectedChannel }) {
            self.selectedChannel = nil
        }
    }

    /// Re-read the store so live ingest is reflected after the first `load()`.
    /// Identical to `load()` (kept as a named seam the view + auto-refresh call;
    /// the lead may swap this for a store-observation push without touching the
    /// view). The current selection is preserved when its channel still exists.
    public func refresh() async throws {
        try await load()
    }

    /// Poll the store on a fixed interval so the transcript follows live ingest
    /// (Finding 18: `ChannelsView` previously loaded once and never updated). Runs
    /// until the surrounding `Task` is cancelled (e.g. the view disappears). A
    /// failed refresh is swallowed so a transient store error never tears down the
    /// loop. Injection seam: the lead can replace this with a store-observation
    /// stream; the unit tests drive `refresh()` directly.
    public func startAutoRefresh(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            try? await refresh()
        }
    }

    /// Select a channel by hash (read-only navigation).
    public func select(_ channel: Int64) {
        selectedChannel = channel
    }

    // MARK: Pure transforms (unit-tested)

    /// node_num → display short-name (short → long → hex fallback).
    nonisolated static func senderIndex(_ nodes: [NodeRecord]) -> [Int64: String] {
        var index: [Int64: String] = [:]
        for node in nodes {
            index[node.node_num] = node.short_name
                ?? node.long_name
                ?? NodeListViewModel.hexID(node.node_num)
        }
        return index
    }

    /// Group records by channel into summaries, newest-activity first. Within a
    /// channel, messages are ordered oldest-first (transcript order).
    nonisolated static func group(
        _ records: [MessageRecord],
        senders: [Int64: String]
    ) -> [ChannelSummary] {
        var byChannel: [Int64: [MessageRecord]] = [:]
        var order: [Int64] = []
        for record in records {
            if byChannel[record.channel] == nil {
                order.append(record.channel)
            }
            byChannel[record.channel, default: []].append(record)
        }

        let summaries = order.map { channel -> ChannelSummary in
            let rows = (byChannel[channel] ?? [])
                .sorted { $0.rx_time < $1.rx_time }
            let messages = rows.map { display($0, senders: senders) }
            // Derive the label from the NEWEST recorded name, not `rows.first`
            // (oldest): otherwise a stale unnamed/hash label sticks even after a
            // newer message carries a real channel name (Finding 18).
            let name = channelName(rows, channel: channel)
            return ChannelSummary(
                channel: channel,
                name: name.label,
                isUnnamed: name.isUnnamed,
                messages: messages
            )
        }
        return summaries.sorted {
            $0.lastActivity > $1.lastActivity
        }
    }

    /// Format one record into a transcript line.
    nonisolated static func display(
        _ record: MessageRecord,
        senders: [Int64: String]
    ) -> MessageDisplay {
        let sender = senders[record.from_num]
            ?? NodeListViewModel.hexID(record.from_num)
        return MessageDisplay(
            id: record.id ?? record.packet_id,
            sender: sender,
            fromNum: record.from_num,
            segments: segments(record.body),
            isDirectMessage: record.is_dm,
            rxTime: Instant(nanosecondsSinceEpoch: record.rx_time)
        )
    }

    /// A channel's display label: its recorded name, else a hash-derived
    /// `#<hex>` fallback.
    nonisolated static func channelName(
        _ record: MessageRecord?
    ) -> (label: String, isUnnamed: Bool) {
        if let name = record?.channel_name, !name.isEmpty {
            return (name, false)
        }
        let hash = record?.channel ?? 0
        let hex = String(format: "%x", UInt32(truncatingIfNeeded: hash))
        return ("#" + hex, true)
    }

    /// A channel's display label derived from its rows: the NEWEST non-empty
    /// `channel_name` wins, so a real name set later overrides an earlier
    /// unnamed/hash reception (Finding 18). Falls back to a `#<hex>` hash label
    /// when no row ever carried a name. `rows` may be in any order; recency is
    /// decided by `rx_time` (with `id` as the tie-break for equal times).
    nonisolated static func channelName(
        _ rows: [MessageRecord],
        channel: Int64
    ) -> (label: String, isUnnamed: Bool) {
        let newestNamed = rows
            .filter { !($0.channel_name ?? "").isEmpty }
            .max { lhs, rhs in
                if lhs.rx_time != rhs.rx_time { return lhs.rx_time < rhs.rx_time }
                return (lhs.id ?? 0) < (rhs.id ?? 0)
            }
        if let name = newestNamed?.channel_name, !name.isEmpty {
            return (name, false)
        }
        let hex = String(format: "%x", UInt32(truncatingIfNeeded: channel))
        return ("#" + hex, true)
    }

    /// Split a body into plain / mention runs. Mirrors `MeshMessage.mentions`:
    /// a mention starts at `@` and runs over word characters (alphanumeric +
    /// `_`); an empty `@` (followed by a non-word char) stays plain text.
    nonisolated static func segments(_ body: String) -> [MessageBodySegment] {
        var segments: [MessageBodySegment] = []
        var plain = ""
        var index = body.startIndex

        func flushPlain() {
            if !plain.isEmpty {
                segments.append(MessageBodySegment(kind: .text, text: plain))
                plain = ""
            }
        }

        while index < body.endIndex {
            if body[index] == "@" {
                let nameStart = body.index(after: index)
                var nameEnd = nameStart
                while nameEnd < body.endIndex, isMentionCharacter(body[nameEnd]) {
                    nameEnd = body.index(after: nameEnd)
                }
                if nameEnd > nameStart {
                    flushPlain()
                    let name = String(body[nameStart ..< nameEnd])
                    segments.append(
                        MessageBodySegment(kind: .mention(name: name), text: "@" + name)
                    )
                    index = nameEnd
                    continue
                }
                // Lone `@` (no following word char): keep as plain text.
                plain.append("@")
                index = nameStart
            } else {
                plain.append(body[index])
                index = body.index(after: index)
            }
        }
        flushPlain()
        return segments
    }

    /// A character that may appear inside a mention: a single alphanumeric or
    /// `_` scalar. Mirrors `MeshMessage.mentions`, which scans Unicode scalars.
    private nonisolated static func isMentionCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return scalar.properties.isAlphabetic
            || ("0" ... "9").contains(scalar)
            || scalar == "_"
    }
}
