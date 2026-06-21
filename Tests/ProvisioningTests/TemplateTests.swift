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
}
