@testable import App
import Foundation
import MeshProtos
import Provisioning
import Testing

@Suite("OTAAdminChannelFactory — production OTA wiring for Fleet + Provision (Finding 8)")
struct OTAAdminChannelFactoryTests {
    /// A spy `AdminLink` that records the targets it was asked to reach and answers
    /// get-requests from in-memory node state, so a factory-built channel can be
    /// driven end-to-end and proven to SEND over the air (not touch a DB).
    private actor SpyLink: AdminLink {
        private(set) var sentTargets: [AdminTarget] = []
        private(set) var sent: [AdminMessage] = []
        private var configByType: [AdminMessage.ConfigType: Config] = [:]

        init(region: Config.LoRaConfig.RegionCode) {
            var lora = Config.LoRaConfig()
            lora.region = region
            var config = Config()
            config.lora = lora
            configByType[.loraConfig] = config
        }

        func exchange(_ message: AdminMessage, with target: AdminTarget) async throws -> AdminMessage? {
            sentTargets.append(target)
            sent.append(message)
            switch message.payloadVariant {
            case let .setConfig(config):
                store(config)
                return nil
            case let .getConfigRequest(type):
                var reply = AdminMessage()
                reply.getConfigResponse = configByType[type] ?? Config()
                return reply
            case .getOwnerRequest:
                var reply = AdminMessage()
                reply.getOwnerResponse = User()
                return reply
            default:
                return nil
            }
        }

        private func store(_ config: Config) {
            switch config.payloadVariant {
            case .lora: configByType[.loraConfig] = config
            case .device: configByType[.deviceConfig] = config
            default: break
            }
        }

        var didSend: Bool {
            !sent.isEmpty
        }

        func targetsSeen() -> [AdminTarget] {
            sentTargets
        }
    }

    private let template = NodeTemplate(name: "t", region: "US", role: "CLIENT")
    private let context = NamingContext(id: "!aabb1234")

    @Test
    func `the fleet resolver builds an OTA channel that sends admin messages over the link`() async throws {
        let link = SpyLink(region: .eu868)
        let factory = OTAAdminChannelFactory(link: link, fleetAuthority: .local)
        let resolve = factory.fleetChannelFor()

        // Drive a full apply through a factory-built channel.
        let channel = resolve(0x42)
        let applier = AdminApplier(channel: channel)
        let plan = try await applier.plan(template: template, context: context)
        try await applier.apply(plan, template: template, context: context)

        // It SENT admin messages over the link (real OTA), addressed to the node.
        #expect(await link.didSend)
        let targets = await link.targetsSeen()
        #expect(targets.allSatisfy { $0.nodeNum == 0x42 })
        #expect(targets.allSatisfy { $0.authority == .local })
        // And it verified by read-back: a fresh plan is now a no-op.
        #expect(try await applier.plan(template: template, context: context).isNoOp)
    }

    @Test
    func `the provision resolver carries the target's own authority over the air`() async throws {
        let link = SpyLink(region: .eu868)
        let factory = OTAAdminChannelFactory(link: link)
        let resolve = factory.provisionChannelFor()

        // A remote PKI-admin target — its authority must reach the link unchanged.
        let target = AdminTarget(nodeNum: 7, authority: .remotePKI(adminKeyID: "kc:admin-1"))
        let channel = resolve(target)
        try await channel.apply([ConfigChange(field: "region", from: "EU_868", to: "US")])

        let targets = await link.targetsSeen()
        #expect(!targets.isEmpty)
        #expect(targets.allSatisfy { $0.nodeNum == 7 })
        #expect(targets.allSatisfy { $0.authority == .remotePKI(adminKeyID: "kc:admin-1") })
    }

    @Test
    func `the fleet authority default is applied to every fleet channel`() async throws {
        let link = SpyLink(region: .eu868)
        let factory = OTAAdminChannelFactory(
            link: link, fleetAuthority: .remoteLegacyChannel(channelName: "admin")
        )
        let channel = factory.fleetChannelFor()(99)
        try await channel.apply([ConfigChange(field: "region", from: "EU_868", to: "US")])

        let targets = await link.targetsSeen()
        #expect(!targets.isEmpty)
        #expect(targets.allSatisfy { $0.authority == .remoteLegacyChannel(channelName: "admin") })
    }
}
