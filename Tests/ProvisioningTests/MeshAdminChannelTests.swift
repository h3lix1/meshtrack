import MeshProtos
@testable import Provisioning
import Testing

@Suite("MeshAdminChannel — the AdminChannel over the air (SPEC §2.7)")
struct MeshAdminChannelTests {
    /// A fake `AdminTransport` standing in for the radio (the HIL effect). It
    /// records every sent batch and decodes applied setConfig/setOwner messages
    /// into the config it reports back — so an `AdminApplier` round-trip verifies.
    private actor FakeTransport: AdminTransport {
        private(set) var sentBatches: [[AdminMessage]] = []
        private var configByType: [AdminMessage.ConfigType: Config] = [:]
        private var owner: User?
        var failSend = false

        init(region: Config.LoRaConfig.RegionCode? = nil) {
            if let region {
                var lora = Config.LoRaConfig()
                lora.region = region
                var config = Config()
                config.lora = lora
                configByType[.loraConfig] = config
            }
        }

        func setFailSend(_ value: Bool) {
            failSend = value
        }

        func send(_ messages: [AdminMessage], to _: AdminTarget) async throws {
            if failSend { throw AdminTransportError.notConnected }
            sentBatches.append(messages)
            for message in messages {
                switch message.payloadVariant {
                case let .setConfig(config):
                    store(config)
                case let .setOwner(user):
                    owner = user
                default:
                    break
                }
            }
        }

        func readback(
            configTypes: Set<AdminMessage.ConfigType>,
            owner wantsOwner: Bool,
            from _: AdminTarget
        ) async throws -> AdminReadback {
            let configs = configTypes.compactMap { configByType[$0] }
            return AdminReadback(configs: configs, owner: wantsOwner ? owner : nil)
        }

        var batchCount: Int {
            sentBatches.count
        }

        private func store(_ config: Config) {
            switch config.payloadVariant {
            case .lora: configByType[.loraConfig] = config
            case .device: configByType[.deviceConfig] = config
            case .position: configByType[.positionConfig] = config
            default: break
            }
        }
    }

    private let target = AdminTarget(nodeNum: 0x1234, authority: .local)
    private let template = NodeTemplate(
        name: "Bay", region: "US", role: "ROUTER", shortNameDSL: "{id[-4:]}"
    )
    private let context = NamingContext(id: "!aabb1234")

    @Test
    func `currentConfig reads region from the node`() async throws {
        let transport = FakeTransport(region: .eu868)
        let channel = MeshAdminChannel(transport: transport, target: target)
        let config = try await channel.currentConfig()
        #expect(config["region"] == "EU_868")
    }

    @Test
    func `apply sends a begin-set-commit batch and read-back then verifies`() async throws {
        let transport = FakeTransport(region: .eu868)
        let channel = MeshAdminChannel(transport: transport, target: target)
        let applier = AdminApplier(channel: channel)

        let plan = try await applier.plan(template: template, context: context)
        #expect(!plan.isNoOp)
        try await applier.apply(plan, template: template, context: context)

        // The node now matches: a fresh plan is a no-op (read-back verified).
        #expect(try await applier.plan(template: template, context: context).isNoOp)
        #expect(await transport.batchCount == 1)
        // The single batch is wrapped begin…commit.
        let batch = try #require(await transport.sentBatches.first)
        #expect(batch.first?.beginEditSettings == true)
        #expect(batch.last?.commitEditSettings == true)
    }

    @Test
    func `apply with no changes sends nothing`() async throws {
        let transport = FakeTransport(region: .us)
        let channel = MeshAdminChannel(transport: transport, target: target)
        try await channel.apply([])
        #expect(await transport.batchCount == 0)
    }

    @Test
    func `the applier validates before this adapter sends, rejecting an unknown region`() async throws {
        // Validation lives in the shared AdminApplier orchestration, so the over-the-air
        // adapter inherits it: an unknown region is rejected before any batch is sent.
        let transport = FakeTransport()
        let channel = MeshAdminChannel(transport: transport, target: target)
        let applier = AdminApplier(channel: channel)
        let plan = ApplyPlan(changes: [ConfigChange(field: "region", from: nil, to: "ATLANTIS")])
        await #expect(throws: AdminMappingError.unknownRegion("ATLANTIS")) {
            try await applier.apply(plan, template: template, context: context)
        }
        // Nothing was sent — validation gates the effect.
        #expect(await transport.batchCount == 0)
    }

    @Test
    func `a transport fault surfaces and the apply does not verify`() async throws {
        let transport = FakeTransport(region: .eu868)
        await transport.setFailSend(true)
        let channel = MeshAdminChannel(transport: transport, target: target)
        await #expect(throws: AdminTransportError.notConnected) {
            try await channel.apply([ConfigChange(field: "region", from: "EU_868", to: "US")])
        }
    }

    @Test
    func `remote authority is carried on the target without leaking key bytes`() {
        let remote = AdminTarget(nodeNum: 7, authority: .remotePKI(adminKeyID: "kc:admin-1"))
        #expect(remote.authority.isRemote)
        #expect(!AdminTarget(nodeNum: 7, authority: .local).authority.isRemote)
    }
}
