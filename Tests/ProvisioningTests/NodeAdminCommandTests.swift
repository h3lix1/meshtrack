// NodeAdminCommandTests — the imperative favorite / ignore admin commands (Phase 10).
//
// These are NOT config diffs: they target a node-num and the firmware applies them
// immediately (no begin/commit). We prove each command maps to the right
// `AdminMessage` oneof field, round-trips through the wire codec, and that the
// channel sends exactly one message (no edit transaction wrapping).

import MeshProtos
@testable import Provisioning
import Testing

@Suite("NodeAdminCommand — favorite / ignore over admin (Phase 10)")
struct NodeAdminCommandTests {
    @Test
    func `favorite maps to setFavoriteNode`() {
        let message = AdminMessageMapping.message(for: .favorite(nodeNum: 0xAABB_CCDD))
        guard case let .setFavoriteNode(node) = message.payloadVariant else {
            Issue.record("expected setFavoriteNode")
            return
        }
        #expect(node == 0xAABB_CCDD)
    }

    @Test
    func `unfavorite maps to removeFavoriteNode`() {
        let message = AdminMessageMapping.message(for: .unfavorite(nodeNum: 42))
        guard case let .removeFavoriteNode(node) = message.payloadVariant else {
            Issue.record("expected removeFavoriteNode")
            return
        }
        #expect(node == 42)
    }

    @Test
    func `ignore maps to setIgnoredNode`() {
        let message = AdminMessageMapping.message(for: .ignore(nodeNum: 7))
        guard case let .setIgnoredNode(node) = message.payloadVariant else {
            Issue.record("expected setIgnoredNode")
            return
        }
        #expect(node == 7)
    }

    @Test
    func `unignore maps to removeIgnoredNode`() {
        let message = AdminMessageMapping.message(for: .unignore(nodeNum: 7))
        guard case let .removeIgnoredNode(node) = message.payloadVariant else {
            Issue.record("expected removeIgnoredNode")
            return
        }
        #expect(node == 7)
    }

    @Test
    func `a command round-trips through the wire codec`() throws {
        let message = AdminMessageMapping.message(for: .favorite(nodeNum: 0x1234))
        let wire: [UInt8] = try message.serializedBytes()
        let parsed = try AdminMessage(serializedBytes: wire)
        guard case let .setFavoriteNode(node) = parsed.payloadVariant else {
            Issue.record("expected setFavoriteNode after round-trip")
            return
        }
        #expect(node == 0x1234)
    }

    @Test
    func `command accessors expose the target node and label`() {
        #expect(NodeAdminCommand.favorite(nodeNum: 9).nodeNum == 9)
        #expect(NodeAdminCommand.ignore(nodeNum: 9).nodeNum == 9)
        #expect(NodeAdminCommand.favorite(nodeNum: 9).label == "Favorite")
        #expect(NodeAdminCommand.unignore(nodeNum: 9).label == "Unignore")
    }

    // MARK: Over the channel — exactly one message, no edit transaction

    private actor RecordingTransport: AdminTransport {
        private(set) var sent: [[AdminMessage]] = []

        func send(_ messages: [AdminMessage], to _: AdminTarget) async throws {
            sent.append(messages)
        }

        func readback(
            configTypes _: Set<AdminMessage.ConfigType>,
            moduleConfigTypes _: Set<AdminMessage.ModuleConfigType>,
            owner _: Bool,
            channel _: Bool,
            from _: AdminTarget
        ) async throws -> AdminReadback {
            AdminReadback()
        }

        var batches: [[AdminMessage]] {
            sent
        }
    }

    @Test
    func `the channel sends a single favorite message with no begin or commit`() async throws {
        let transport = RecordingTransport()
        let channel = MeshAdminChannel(
            transport: transport,
            target: AdminTarget(nodeNum: 0x1234, authority: .local)
        )
        try await channel.send(.favorite(nodeNum: 0x1234))

        let batches = await transport.batches
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.count == 1) // exactly one message, NOT begin/set/commit
        guard case .setFavoriteNode = batch.first?.payloadVariant else {
            Issue.record("expected a bare setFavoriteNode")
            return
        }
    }
}
