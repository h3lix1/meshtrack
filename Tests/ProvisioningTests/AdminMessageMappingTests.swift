import MeshProtos
@testable import Provisioning
import Testing

@Suite("AdminMessageMapping — change↔AdminMessage / Config↔snapshot (SPEC §2.7)")
struct AdminMessageMappingTests {
    // MARK: Change → AdminMessage (the apply path)

    @Test
    func `no changes produce no messages`() throws {
        #expect(try AdminMessageMapping.messages(for: []).isEmpty)
    }

    @Test
    func `a config change is wrapped in a begin and commit edit transaction`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "region", from: "EU_868", to: "US")
        ])
        // begin → setConfig → commit
        #expect(messages.count == 3)
        #expect(messages.first?.beginEditSettings == true)
        #expect(messages.last?.commitEditSettings == true)
    }

    @Test
    func `region maps to a setConfig LoRa message with the right region code`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "region", from: nil, to: "EU_868")
        ])
        let body = messages.filter { if case .setConfig = $0.payloadVariant { true } else { false } }
        #expect(body.count == 1)
        guard case let .lora(lora)? = body.first?.setConfig.payloadVariant else {
            Issue.record("expected a LoRa config payload")
            return
        }
        #expect(lora.region == .eu868)
    }

    @Test
    func `role maps to a setConfig device message with the right role`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "role", from: "CLIENT", to: "ROUTER")
        ])
        let body = messages.filter { if case .setConfig = $0.payloadVariant { true } else { false } }
        guard case let .device(device)? = body.first?.setConfig.payloadVariant else {
            Issue.record("expected a device config payload")
            return
        }
        #expect(device.role == .router)
    }

    @Test
    func `short and long name map to a single setOwner message`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "short_name", from: nil, to: "BMSH"),
            ConfigChange(field: "long_name", from: nil, to: "Bay Mesh Node")
        ])
        let owners = messages.filter { if case .setOwner = $0.payloadVariant { true } else { false } }
        #expect(owners.count == 1)
        #expect(owners.first?.setOwner.shortName == "BMSH")
        #expect(owners.first?.setOwner.longName == "Bay Mesh Node")
    }

    @Test
    func `a mixed change set yields owner plus one setConfig per config type`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "region", from: nil, to: "US"),
            ConfigChange(field: "role", from: nil, to: "ROUTER"),
            ConfigChange(field: "short_name", from: nil, to: "BMSH")
        ])
        // begin + owner + lora + device + commit = 5
        #expect(messages.count == 5)
        let owners = messages.filter { if case .setOwner = $0.payloadVariant { true } else { false } }
        let configs = messages.filter { if case .setConfig = $0.payloadVariant { true } else { false } }
        #expect(owners.count == 1)
        #expect(configs.count == 2)
    }

    @Test
    func `position precision maps to a position config message`() throws {
        let messages = try AdminMessageMapping.messages(for: [
            ConfigChange(field: "position_precision", from: nil, to: "16")
        ])
        let body = messages.filter { if case .setConfig = $0.payloadVariant { true } else { false } }
        guard case let .position(position)? = body.first?.setConfig.payloadVariant else {
            Issue.record("expected a position config payload")
            return
        }
        #expect(position.positionFlags == 16)
    }

    @Test
    func `an unsupported field is rejected, not silently dropped`() throws {
        #expect(throws: AdminMappingError.unsupportedField("mqtt_enabled")) {
            try AdminMessageMapping.messages(for: [
                ConfigChange(field: "mqtt_enabled", from: nil, to: "true")
            ])
        }
    }

    // MARK: validate (the confirm-time guard)

    @Test
    func `validate accepts a well-formed change set`() throws {
        try AdminMessageMapping.validate([
            ConfigChange(field: "region", from: nil, to: "US"),
            ConfigChange(field: "role", from: nil, to: "TRACKER"),
            ConfigChange(field: "position_precision", from: nil, to: "10")
        ])
    }

    @Test
    func `validate rejects an unknown region`() throws {
        #expect(throws: AdminMappingError.unknownRegion("ATLANTIS")) {
            try AdminMessageMapping.validate([ConfigChange(field: "region", from: nil, to: "ATLANTIS")])
        }
    }

    @Test
    func `validate rejects an unknown role`() throws {
        #expect(throws: AdminMappingError.unknownRole("OVERLORD")) {
            try AdminMessageMapping.validate([ConfigChange(field: "role", from: nil, to: "OVERLORD")])
        }
    }

    @Test
    func `validate rejects a non-numeric position precision`() throws {
        #expect(throws: AdminMappingError.invalidNumber(field: "position_precision", value: "lots")) {
            try AdminMessageMapping.validate([
                ConfigChange(field: "position_precision", from: nil, to: "lots")
            ])
        }
    }

    @Test
    func `region parsing is case and separator insensitive`() throws {
        // "eu-868" normalises to EU_868.
        try AdminMessageMapping.validate([ConfigChange(field: "region", from: nil, to: "eu-868")])
        #expect(AdminMessageMapping.regionCode("eu-868") == .eu868)
    }

    // MARK: Config response → snapshot (the read-back / verify path)

    @Test
    func `a LoRa config decodes to a region snapshot`() {
        var lora = Config.LoRaConfig()
        lora.region = .us
        var config = Config()
        config.lora = lora
        let snapshot = AdminMessageMapping.snapshot(config: config, owner: nil)
        #expect(snapshot["region"] == "US")
    }

    @Test
    func `an owner decodes to short and long name, skipping empties`() {
        var owner = User()
        owner.shortName = "BMSH"
        // longName left empty
        let snapshot = AdminMessageMapping.snapshot(config: nil, owner: owner)
        #expect(snapshot["short_name"] == "BMSH")
        #expect(snapshot["long_name"] == nil)
    }

    @Test
    func `encode then decode round-trips region and role through the protobufs`() throws {
        let changes = [
            ConfigChange(field: "region", from: nil, to: "EU_868"),
            ConfigChange(field: "role", from: nil, to: "ROUTER")
        ]
        // Simulate the node taking the change: pull the setConfig payloads back out
        // and decode them as a read-back.
        let configs = try AdminMessageMapping.messages(for: changes)
            .compactMap { message -> Config? in
                if case .setConfig = message.payloadVariant { message.setConfig } else { nil }
            }
        let snapshot = MeshAdminChannel.snapshot(from: AdminReadback(configs: configs, owner: nil))
        #expect(snapshot["region"] == "EU_868")
        #expect(snapshot["role"] == "ROUTER")
    }

    // MARK: configTypes / touchesOwner (read-back planning)

    @Test
    func `configTypes maps changed fields to the config-types a read-back requests`() throws {
        let types = try AdminMessageMapping.configTypes(for: [
            ConfigChange(field: "region", from: nil, to: "US"),
            ConfigChange(field: "role", from: nil, to: "ROUTER"),
            ConfigChange(field: "short_name", from: nil, to: "BMSH")
        ])
        #expect(types == [.loraConfig, .deviceConfig])
    }

    @Test
    func `touchesOwner is true only when a name field changes`() {
        #expect(AdminMessageMapping.touchesOwner([ConfigChange(field: "short_name", from: nil, to: "X")]))
        #expect(!AdminMessageMapping.touchesOwner([ConfigChange(field: "region", from: nil, to: "US")]))
    }
}
