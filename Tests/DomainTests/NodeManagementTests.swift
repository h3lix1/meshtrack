@testable import Domain
import Testing

@Suite("NodeManagement + ReceptionLatency")
struct NodeManagementTests {
    @Test
    func `unowned is neither mine nor managed and does not evaluate ownership rules`() {
        let management = NodeManagement.unowned
        #expect(management.isMine == false)
        #expect(management.isManaged == false)
        #expect(management.evaluatesOwnershipRules == false)
    }

    @Test
    func `a managed node evaluates ownership rules; an unmanaged one does not`() {
        #expect(NodeManagement(isManaged: true).evaluatesOwnershipRules == true)
        #expect(NodeManagement(isMine: true, isManaged: false).evaluatesOwnershipRules == false)
    }

    @Test
    func `latency is ingest_time minus rx_time, in ns and seconds`() {
        let rx = Instant(nanosecondsSinceEpoch: 1_000_000_000)
        let ingest = Instant(nanosecondsSinceEpoch: 3_500_000_000)
        let latency = ReceptionLatency(rxTime: rx, ingestTime: ingest)
        #expect(latency.nanoseconds == 2_500_000_000)
        #expect(abs(latency.seconds - 2.5) < 1e-9)
    }

    @Test
    func `latency can be negative under clock skew`() {
        let rx = Instant(nanosecondsSinceEpoch: 5_000_000_000)
        let ingest = Instant(nanosecondsSinceEpoch: 4_000_000_000)
        #expect(ReceptionLatency(rxTime: rx, ingestTime: ingest).nanoseconds == -1_000_000_000)
    }

    @Test
    func `latency is nil when ingest_time is unknown (pre-v3 back-compat)`() {
        let rx = Instant(nanosecondsSinceEpoch: 1000)
        #expect(ReceptionLatency.between(rxTime: rx, ingestTime: nil) == nil)
        #expect(ReceptionLatency.between(rxTime: rx, ingestTime: rx)?.nanoseconds == 0)
    }
}
