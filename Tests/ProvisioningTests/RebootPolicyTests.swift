@testable import Provisioning
import Testing

@Suite("RebootPolicy — surface reboot-needed changes (SPEC §2.7)")
struct RebootPolicyTests {
    @Test
    func `a region change requires a reboot`() {
        let assessment = RebootPolicy.assess([ConfigChange(field: "region", from: "EU_868", to: "US")])
        #expect(assessment.requiresReboot)
        #expect(assessment.rebootingFields == ["region"])
    }

    @Test
    func `a role change requires a reboot`() {
        let assessment = RebootPolicy.assess([ConfigChange(field: "role", from: "CLIENT", to: "ROUTER")])
        #expect(assessment.requiresReboot)
        #expect(assessment.rebootingFields == ["role"])
    }

    @Test
    func `name-only changes apply live without a reboot`() {
        let assessment = RebootPolicy.assess([
            ConfigChange(field: "short_name", from: nil, to: "BMSH"),
            ConfigChange(field: "long_name", from: nil, to: "Bay Mesh")
        ])
        #expect(!assessment.requiresReboot)
        #expect(assessment.rebootingFields.isEmpty)
    }

    @Test
    func `a mixed plan reports only the rebooting fields, sorted`() {
        let assessment = RebootPolicy.assess(ApplyPlan(changes: [
            ConfigChange(field: "short_name", from: nil, to: "BMSH"),
            ConfigChange(field: "role", from: nil, to: "ROUTER"),
            ConfigChange(field: "region", from: nil, to: "US")
        ]))
        #expect(assessment.requiresReboot)
        #expect(assessment.rebootingFields == ["region", "role"])
    }

    @Test
    func `an empty plan needs no reboot`() {
        #expect(!RebootPolicy.assess(ApplyPlan(changes: [])).requiresReboot)
    }
}
