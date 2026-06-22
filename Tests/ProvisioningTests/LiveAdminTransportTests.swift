import Foundation
import MeshProtos
@testable import Provisioning
import Testing

@Suite("LiveAdminTransport — the real OTA admin apply path (SPEC §2.7, §10, Finding 8)")
struct LiveAdminTransportTests {
    /// A SPY `AdminLink` standing in for the radio (the HIL primitive). It records
    /// every admin message SENT, and answers get-requests from node state it mutates
    /// when a set message arrives. Crucially it is NOT a same-DB echo: the apply path
    /// must send real begin→set→commit admin messages and the verify must read the
    /// node's config BACK through the protocol — the spy proves both happened, by
    /// serializing each message through the wire codec (so a wrong-field mapping can't
    /// hide behind a verbatim struct echo).
    private actor SpyAdminLink: AdminLink {
        private(set) var sent: [AdminMessage] = []
        private var configByType: [AdminMessage.ConfigType: Config] = [:]
        private var owner = User()
        private var channel = Channel()
        var failExchange = false

        init(region: Config.LoRaConfig.RegionCode? = nil) {
            if let region {
                var lora = Config.LoRaConfig()
                lora.region = region
                var config = Config()
                config.lora = lora
                configByType[.loraConfig] = config
            }
        }

        func setFailExchange(_ value: Bool) { failExchange = value }

        func exchange(_ message: AdminMessage, with _: AdminTarget) async throws -> AdminMessage? {
            if failExchange { throw AdminTransportError.notConnected }
            // Round-trip through the wire codec — the node only ever sees decoded
            // bytes, never the struct we were handed.
            let wire: [UInt8] = try message.serializedBytes()
            let parsed = try AdminMessage(serializedBytes: wire)
            sent.append(parsed)
            switch parsed.payloadVariant {
            case let .setConfig(config):
                store(config)
                return nil
            case let .setOwner(user):
                owner = user
                return nil
            case let .setChannel(channel):
                self.channel = channel
                return nil
            case let .getConfigRequest(type):
                var reply = AdminMessage()
                reply.getConfigResponse = configByType[type] ?? Config()
                return reply
            case .getOwnerRequest:
                var reply = AdminMessage()
                reply.getOwnerResponse = owner
                return reply
            case .getChannelRequest:
                var reply = AdminMessage()
                reply.getChannelResponse = channel
                return reply
            default:
                // begin/commit edit transaction — acknowledged, no reply.
                return nil
            }
        }

        /// The kinds of messages sent, in order (begin/set/commit/get…), for asserting
        /// the transaction shape without matching on payload bytes.
        func sentKinds() -> [String] { sent.map(Self.kind) }

        private func store(_ config: Config) {
            switch config.payloadVariant {
            case .lora: configByType[.loraConfig] = config
            case .device: configByType[.deviceConfig] = config
            default: break
            }
        }

        private static func kind(_ message: AdminMessage) -> String {
            switch message.payloadVariant {
            case .beginEditSettings: "begin"
            case .commitEditSettings: "commit"
            case .setConfig: "setConfig"
            case .setOwner: "setOwner"
            case .setChannel: "setChannel"
            case .getConfigRequest: "getConfig"
            case .getOwnerRequest: "getOwner"
            case .getChannelRequest: "getChannel"
            default: "other"
            }
        }
    }

    private let target = AdminTarget(nodeNum: 0x1234, authority: .local)
    private let context = NamingContext(id: "!aabb1234")

    @Test
    func `the production apply path SENDS begin-set-commit admin messages and verifies via read-back`() async throws {
        // A node currently on EU_868; the template wants US + a router role + an owner.
        let link = SpyAdminLink(region: .eu868)
        let transport = LiveAdminTransport(link: link)
        let channel = MeshAdminChannel(transport: transport, target: target)
        let applier = AdminApplier(channel: channel)
        let template = NodeTemplate(
            name: "Bay", region: "US", role: "ROUTER", shortNameDSL: "{id[-4:]}"
        )

        // Plan reads the node's current config OVER THE LINK (a real getConfig), so
        // it's a genuine diff, not a same-DB comparison.
        let plan = try await applier.plan(template: template, context: context)
        #expect(!plan.isNoOp)

        try await applier.apply(plan, template: template, context: context)

        // The apply SENT a wrapped begin → set… → commit transaction over the link
        // (the plan's read-back getConfig precedes it, so we assert the subsequence,
        // not `sent.first`).
        let sent = await link.sent
        #expect(sent.contains { $0.beginEditSettings == true })
        #expect(sent.contains { if case .setConfig = $0.payloadVariant { true } else { false } })
        #expect(sent.contains { if case .setOwner = $0.payloadVariant { true } else { false } })
        #expect(sent.contains { $0.commitEditSettings == true })

        // The begin precedes every set, and a commit follows them — a real transaction.
        let kinds = await link.sentKinds()
        let beginIndex = try #require(kinds.firstIndex(of: "begin"))
        let commitIndex = try #require(kinds.lastIndex(of: "commit"))
        #expect(beginIndex < commitIndex)
        #expect(kinds[beginIndex ..< commitIndex].contains("setConfig"))
        #expect(kinds[beginIndex ..< commitIndex].contains("setOwner"))

        // And verification READ THE CONFIG BACK over the link: a fresh plan is a
        // no-op only because the node reports the new values via getConfig/getOwner.
        #expect(try await applier.plan(template: template, context: context).isNoOp)
        let readKinds = await link.sentKinds()
        #expect(readKinds.contains("getConfig")) // region/role read back
        #expect(readKinds.contains("getOwner")) // owner read back
    }

    @Test
    func `read-back is NOT a same-DB echo — a node that drops the set fails verification`() async throws {
        // A link that ACKs sets but never stores them ⇒ read-back still shows the old
        // value ⇒ verification fails. A same-DB echo (the old store-backed channel)
        // would have "verified" against its own write and passed — this proves the
        // OTA path verifies against the NODE, not against itself.
        let link = DroppingLink(region: .eu868)
        let transport = LiveAdminTransport(link: link)
        let channel = MeshAdminChannel(transport: transport, target: target)
        let applier = AdminApplier(channel: channel)
        let template = NodeTemplate(name: "Bay", region: "US", role: "CLIENT")

        let plan = try await applier.plan(template: template, context: context)
        await #expect(throws: ApplyError.self) {
            try await applier.apply(plan, template: template, context: context)
        }
    }

    @Test
    func `a precision apply reads the primary channel back and preserves its settings`() async throws {
        // SEED a primary channel with name/PSK/flags on the node; a precision-only
        // apply must read it back (getChannel) and read-modify-write so only precision
        // changes. This exercises the Finding 10 fix THROUGH the real OTA link.
        let link = ChannelSpyLink()
        var settings = ChannelSettings()
        settings.name = "BayMesh"
        settings.psk = Data([9, 9, 9])
        settings.uplinkEnabled = true
        var seeded = Channel()
        seeded.index = 0
        seeded.role = .primary
        seeded.settings = settings
        await link.seedChannel(seeded)

        let transport = LiveAdminTransport(link: link)
        let channel = MeshAdminChannel(transport: transport, target: target)
        try await channel.apply([ConfigChange(field: "position_precision", from: "0", to: "16")])

        // The apply read the channel back first (getChannel), then sent a setChannel
        // that preserved name/PSK/uplink and only moved precision.
        let setChannel = try #require(await link.lastSetChannel)
        #expect(setChannel.settings.moduleSettings.positionPrecision == 16)
        #expect(setChannel.settings.name == "BayMesh")
        #expect(setChannel.settings.psk == Data([9, 9, 9]))
        #expect(setChannel.settings.uplinkEnabled)
        #expect(await link.didGetChannel)
    }

    @Test
    func `a link fault surfaces as a transport error`() async throws {
        let link = SpyAdminLink(region: .eu868)
        await link.setFailExchange(true)
        let transport = LiveAdminTransport(link: link)
        let channel = MeshAdminChannel(transport: transport, target: target)
        await #expect(throws: AdminTransportError.notConnected) {
            try await channel.apply([ConfigChange(field: "region", from: "EU_868", to: "US")])
        }
    }

    // MARK: Supporting spies

    /// ACKs every set but never stores it — read-back keeps reporting the old region.
    private actor DroppingLink: AdminLink {
        private let config: Config
        init(region: Config.LoRaConfig.RegionCode) {
            var lora = Config.LoRaConfig()
            lora.region = region
            var config = Config()
            config.lora = lora
            self.config = config
        }

        func exchange(_ message: AdminMessage, with _: AdminTarget) async throws -> AdminMessage? {
            switch message.payloadVariant {
            case .getConfigRequest:
                var reply = AdminMessage()
                reply.getConfigResponse = config // always the OLD value
                return reply
            case .getOwnerRequest:
                var reply = AdminMessage()
                reply.getOwnerResponse = User()
                return reply
            default:
                return nil // ACK the set/begin/commit, store nothing
            }
        }
    }

    /// Records getChannel + the last setChannel, seeded with an existing channel.
    private actor ChannelSpyLink: AdminLink {
        private var channel = Channel()
        private(set) var didGetChannel = false
        private(set) var lastSetChannel: Channel?

        func seedChannel(_ value: Channel) { channel = value }

        func exchange(_ message: AdminMessage, with _: AdminTarget) async throws -> AdminMessage? {
            let wire: [UInt8] = try message.serializedBytes()
            let parsed = try AdminMessage(serializedBytes: wire)
            switch parsed.payloadVariant {
            case .getChannelRequest:
                didGetChannel = true
                var reply = AdminMessage()
                reply.getChannelResponse = channel
                return reply
            case let .setChannel(channel):
                lastSetChannel = channel
                self.channel = channel
                return nil
            default:
                return nil
            }
        }
    }
}
