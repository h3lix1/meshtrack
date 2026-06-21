@testable import Provisioning
import Testing

@Suite("FleetApplier — safe rolling rollout (SPEC §2.7)")
struct FleetApplierTests {
    private actor GoodChannel: AdminChannel {
        private var config: [String: String]
        init(_ config: [String: String]) {
            self.config = config
        }

        func currentConfig() -> [String: String] {
            config
        }

        func apply(_ changes: [ConfigChange]) {
            for change in changes {
                config[change.field] = change.to
            }
        }
    }

    /// Drops applies → read-back verification fails.
    private actor BrokenChannel: AdminChannel {
        private let config: [String: String]
        init(_ config: [String: String]) {
            self.config = config
        }

        func currentConfig() -> [String: String] {
            config
        }

        func apply(_: [ConfigChange]) {}
    }

    private let template = NodeTemplate(name: "t", region: "US", role: "CLIENT")
    private func member(_ num: Int64) -> FleetMember {
        FleetMember(nodeNum: num, context: NamingContext(id: "!\(String(num, radix: 16))"))
    }

    @Test
    func `every node is applied and verified, in order`() async {
        let channels: [Int64: any AdminChannel] = [
            1: GoodChannel(["region": "EU_868"]), 2: GoodChannel([:]), 3: GoodChannel([:])
        ]
        let applier = FleetApplier { channels[$0] ?? GoodChannel([:]) }
        let result = await applier.rollOut(template: template, to: [member(1), member(2), member(3)])
        #expect(result.outcomes.map(\.nodeNum) == [1, 2, 3])
        #expect(result.allSucceeded)
        #expect(result.verifiedCount == 3)
    }

    @Test
    func `a failed node halts the rollout so the network isn't destabilised`() async {
        let channels: [Int64: any AdminChannel] = [
            1: GoodChannel([:]), 2: BrokenChannel(["region": "EU_868"]), 3: GoodChannel([:])
        ]
        let applier = FleetApplier { channels[$0] ?? GoodChannel([:]) }
        let result = await applier.rollOut(template: template, to: [member(1), member(2), member(3)])
        #expect(result.outcomes.map(\.nodeNum) == [1, 2]) // node 3 never attempted
        #expect(result.outcomes[0].status == .verified)
        #expect(!result.allSucceeded)
    }

    @Test
    func `with haltOnFailure off, the rollout continues past a failure`() async {
        let channels: [Int64: any AdminChannel] = [
            1: GoodChannel([:]), 2: BrokenChannel(["region": "EU_868"]), 3: GoodChannel([:])
        ]
        let applier = FleetApplier { channels[$0] ?? GoodChannel([:]) }
        let result = await applier.rollOut(
            template: template, to: [member(1), member(2), member(3)], haltOnFailure: false
        )
        #expect(result.outcomes.map(\.nodeNum) == [1, 2, 3])
        #expect(result.verifiedCount == 2)
    }

    @Test
    func `a node already matching the template is a no-op`() async {
        let desired = try? template.desiredConfig(for: member(1).context)
        let applier = FleetApplier { _ in GoodChannel(desired ?? [:]) }
        let result = await applier.rollOut(template: template, to: [member(1)])
        #expect(result.outcomes.first?.status == .noChange)
    }
}
