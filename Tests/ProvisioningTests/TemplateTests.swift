@testable import Provisioning
import Testing

@Suite("Template render + config diff (SPEC §2.7)")
struct TemplateTests {
    private let template = NodeTemplate(
        name: "baymesh-fixed",
        region: "US",
        role: "CLIENT",
        shortNameDSL: "{id[-4:]}",
        longNameDSL: "{shortName}-{id[-4:]}",
        positionPrecisionBits: 14
    )
    private let context = NamingContext(id: "!aabbA123", shortName: "baymesh")

    @Test
    func `a template renders names and a desired config`() throws {
        let config = try template.desiredConfig(for: context)
        #expect(config["region"] == "US")
        #expect(config["role"] == "CLIENT")
        #expect(config["short_name"] == "A123")
        #expect(config["long_name"] == "baymesh-A123")
        #expect(config["position_precision"] == "14")
    }

    @Test
    func `a template whose short name overflows the byte limit fails to render`() {
        let bad = NodeTemplate(name: "x", region: "US", shortNameDSL: "{shortName}")
        #expect(throws: NameError.self) {
            _ = try bad.desiredConfig(for: context) // "baymesh" = 7 bytes > 4
        }
    }

    @Test
    func `diff is empty when the node already matches (idempotent)`() throws {
        let desired = try template.desiredConfig(for: context)
        #expect(ConfigDiff.changes(desired: desired, current: desired).isEmpty)
    }

    @Test
    func `diff reports only the changed fields, in stable order`() throws {
        let desired = try template.desiredConfig(for: context)
        var current = desired
        current["region"] = "EU_868" // changed
        current["short_name"] = nil // missing
        let changes = ConfigDiff.changes(desired: desired, current: current)
        #expect(changes.map(\.field) == ["region", "short_name"])
        #expect(changes.first == ConfigChange(field: "region", from: "EU_868", to: "US"))
        #expect(changes.last?.from == nil) // short_name was absent
    }

    // MARK: Broad config surface (Phase 10)

    @Test
    func `broad fields merge into the desired config alongside the named surface`() throws {
        let broad = NodeTemplate(
            name: "broad",
            region: "US",
            role: "ROUTER",
            fields: [
                "modem_preset": "MEDIUM_FAST",
                "tx_power": "20",
                "mqtt_enabled": "true",
                "hop_limit": "5"
            ]
        )
        let config = try broad.desiredConfig(for: context)
        // Named surface still present…
        #expect(config["region"] == "US")
        #expect(config["role"] == "ROUTER")
        // …and the broad group defaults ride alongside.
        #expect(config["modem_preset"] == "MEDIUM_FAST")
        #expect(config["tx_power"] == "20")
        #expect(config["mqtt_enabled"] == "true")
        #expect(config["hop_limit"] == "5")
    }

    @Test
    func `the typed named surface wins over the same key carried in broad fields`() throws {
        // region/role/position_precision are authoritative — a broad-fields duplicate
        // of one must not override the typed property.
        let conflicting = NodeTemplate(
            name: "conflict",
            region: "US",
            role: "ROUTER",
            positionPrecisionBits: 14,
            fields: ["region": "EU_868", "role": "CLIENT", "position_precision": "10"]
        )
        let config = try conflicting.desiredConfig(for: context)
        #expect(config["region"] == "US")
        #expect(config["role"] == "ROUTER")
        #expect(config["position_precision"] == "14")
    }

    @Test
    func `validate rejects a broad field that is not a known AdminConfigField`() {
        let bad = NodeTemplate(name: "bad", region: "US", fields: ["not_a_real_field": "x"])
        #expect(throws: AdminMappingError.unsupportedField("not_a_real_field")) {
            try bad.validate()
        }
    }

    @Test
    func `validate passes for a template carrying only supported broad fields`() throws {
        let good = NodeTemplate(
            name: "good",
            region: "US",
            fields: ["modem_preset": "LONG_FAST", "mqtt_enabled": "true"]
        )
        try good.validate() // does not throw
    }
}
