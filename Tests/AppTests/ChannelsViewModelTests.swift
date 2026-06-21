@testable import App
import Domain
import Persistence
import Testing

@Suite("ChannelsViewModel")
struct ChannelsViewModelTests {
    // MARK: Pure transforms

    @Test
    func `sender index resolves short → long → hex`() {
        let nodes = [
            NodeRecord(node_num: 0x01, short_name: "BASE", first_seen_at: 0, last_heard_at: 0),
            NodeRecord(node_num: 0x02, long_name: "Repeater North", first_seen_at: 0, last_heard_at: 0),
            NodeRecord(node_num: 0xA1B2_C3D4, first_seen_at: 0, last_heard_at: 0)
        ]
        let index = ChannelsViewModel.senderIndex(nodes)
        #expect(index[0x01] == "BASE")
        #expect(index[0x02] == "Repeater North")
        #expect(index[0xA1B2_C3D4] == "!a1b2c3d4")
    }

    @Test
    func `display falls back to hex for an unknown sender`() {
        let record = MessageRecord(
            packet_id: 1, from_num: 0x09, to_num: Int64(meshBroadcastAddress),
            channel: 7, body: "hi", rx_time: 0
        )
        let display = ChannelsViewModel.display(record, senders: [:])
        #expect(display.sender == "!00000009")
    }

    @Test
    func `mention segmentation splits plain text and call-outs`() {
        let segments = ChannelsViewModel.segments("hey @alice and @bob_1, ping @")
        // Plain "hey ", mention alice, plain " and ", mention bob_1, plain ", ping @"
        #expect(segments.count == 5)
        #expect(segments[0] == .init(kind: .text, text: "hey "))
        #expect(segments[1] == .init(kind: .mention(name: "alice"), text: "@alice"))
        #expect(segments[2] == .init(kind: .text, text: " and "))
        #expect(segments[3] == .init(kind: .mention(name: "bob_1"), text: "@bob_1"))
        #expect(segments[4] == .init(kind: .text, text: ", ping @"))
    }

    @Test
    func `mention extraction matches the domain rule`() {
        let segments = ChannelsViewModel.segments("@alpha @beta-x @")
        let mentions = segments.compactMap { seg -> String? in
            if case let .mention(name) = seg.kind { name } else { nil }
        }
        // "beta" stops at '-'; lone trailing '@' is not a mention.
        #expect(mentions == ["alpha", "beta"])
    }

    @Test
    func `channel name falls back to a hash label when unnamed`() {
        let named = MessageRecord(
            packet_id: 1, from_num: 1, to_num: 0, channel: 2,
            channel_name: "LongFast", body: "x", rx_time: 0
        )
        let unnamed = MessageRecord(
            packet_id: 2, from_num: 1, to_num: 0, channel: 0xAB,
            body: "x", rx_time: 0
        )
        let withName = ChannelsViewModel.channelName(named)
        #expect(withName.label == "LongFast")
        #expect(withName.isUnnamed == false)

        let noName = ChannelsViewModel.channelName(unnamed)
        #expect(noName.label == "#ab")
        #expect(noName.isUnnamed)
    }

    @Test
    func `grouping orders channels by most-recent activity and transcripts oldest-first`() {
        let senders: [Int64: String] = [1: "ONE", 2: "TWO"]
        let records = [
            // newest-first input (matches recentMessages order)
            MessageRecord(packet_id: 30, from_num: 2, to_num: 0, channel: 99, body: "newest", rx_time: 300),
            MessageRecord(packet_id: 20, from_num: 1, to_num: 0, channel: 7, body: "b", rx_time: 200),
            MessageRecord(packet_id: 10, from_num: 1, to_num: 0, channel: 7, body: "a", rx_time: 100)
        ]
        let groups = ChannelsViewModel.group(records, senders: senders)
        #expect(groups.map(\.channel) == [99, 7]) // 99 last-active at 300 > 7 at 200
        #expect(groups[1].messages.map(\.body) == ["a", "b"]) // oldest-first within channel
        #expect(groups[1].messageCount == 2)
        #expect(groups[0].lastActivity == Instant(nanosecondsSinceEpoch: 300))
    }

    @Test
    func `dm vs broadcast classification reads the is_dm flag`() {
        let broadcast = MessageRecord(
            packet_id: 1, from_num: 1, to_num: Int64(meshBroadcastAddress),
            channel: 7, body: "all", rx_time: 0, is_dm: false
        )
        let direct = MessageRecord(
            packet_id: 2, from_num: 1, to_num: 42,
            channel: 7, body: "you", rx_time: 0, is_dm: true
        )
        #expect(ChannelsViewModel.display(broadcast, senders: [:]).isDirectMessage == false)
        #expect(ChannelsViewModel.display(direct, senders: [:]).isDirectMessage)
    }

    // MARK: Integration over an in-memory store

    @Test
    @MainActor
    func `load groups seeded messages with resolved senders`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(
            NodeRecord(node_num: 1, short_name: "BASE", first_seen_at: 0, last_heard_at: 0)
        )
        try await store.recordMessage(MessageRecord(
            packet_id: 10, from_num: 1, to_num: Int64(meshBroadcastAddress),
            channel: 7, channel_name: "LongFast", body: "hello @BASE", rx_time: 100
        ))
        try await store.recordMessage(MessageRecord(
            packet_id: 11, from_num: 2, to_num: 1,
            channel: 7, channel_name: "LongFast", body: "dm", rx_time: 200, is_dm: true
        ))

        let viewModel = ChannelsViewModel(store: store)
        try await viewModel.load()

        #expect(viewModel.channels.count == 1)
        let channel = try #require(viewModel.channels.first)
        #expect(channel.name == "LongFast")
        #expect(channel.isUnnamed == false)
        #expect(channel.messages.map(\.body) == ["hello @BASE", "dm"])
        #expect(channel.messages[0].sender == "BASE")
        #expect(channel.messages[0].mentions == ["BASE"])
        #expect(channel.messages[0].isDirectMessage == false)
        #expect(channel.messages[1].sender == "!00000002") // unknown → hex
        #expect(channel.messages[1].isDirectMessage)
    }

    @Test
    func `attributed body highlights mention runs and preserves the full text`() {
        let display = ChannelsViewModel.display(
            MessageRecord(
                packet_id: 1,
                from_num: 1,
                to_num: 0,
                channel: 7,
                body: "ping @ops now",
                rx_time: 0
            ),
            senders: [:]
        )
        let attributed = ChannelsView.attributedBody(display)
        // Round-trips to the original body.
        #expect(String(attributed.characters) == "ping @ops now")
        // The mention run carries the highlight colour; plain runs do not.
        let mentionRun = attributed.runs.first { $0.foregroundColor == .yellow }
        #expect(mentionRun != nil)
        if let mentionRun {
            #expect(String(attributed[mentionRun.range].characters) == "@ops")
        }
    }

    @Test
    @MainActor
    func `selectedSummary defaults to the first channel and follows selection`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.recordMessage(MessageRecord(
            packet_id: 1, from_num: 1, to_num: 0, channel: 7, body: "a", rx_time: 100
        ))
        try await store.recordMessage(MessageRecord(
            packet_id: 2, from_num: 1, to_num: 0, channel: 8, body: "b", rx_time: 200
        ))

        let viewModel = ChannelsViewModel(store: store)
        try await viewModel.load()

        // Default: first (most-recently-active) channel.
        #expect(viewModel.selectedSummary?.channel == 8)
        viewModel.select(7)
        #expect(viewModel.selectedSummary?.channel == 7)
    }
}
