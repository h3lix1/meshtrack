@testable import App
import Domain
import Persistence
import Testing

@Suite("NodeAnalytics aggregations")
struct NodeAnalyticsAggregationsTests {
    // MARK: Helpers

    private func observation(
        snr: Double? = nil,
        rssi: Int? = nil,
        hopStart: Int? = nil,
        hopLimit: Int? = nil,
        gateway: String? = nil,
        rxNanos: Int64 = 0
    ) -> ObservationRecord {
        ObservationRecord(
            node_num: 1,
            packet_id: 1,
            transport: .mqtt,
            gateway_id: gateway,
            rx_time: rxNanos,
            rx_rssi: rssi,
            rx_snr: snr,
            hop_start: hopStart,
            hop_limit: hopLimit
        )
    }

    private func packet(port: MeshPort) -> DecodedPacket {
        DecodedPacket(
            from: 1, to: 0xFFFF_FFFF, packetID: 1, channel: 0,
            port: port, payload: [], rxTime: Instant(nanosecondsSinceEpoch: 0)
        )
    }

    // MARK: Distribution

    @Test
    func `distribution bins values into equal-width buckets and computes stats`() {
        let dist = NodeAnalytics.distribution(of: [0, 0, 10, 20], binCount: 2)
        #expect(dist.sampleCount == 4)
        #expect(dist.minValue == 0)
        #expect(dist.maxValue == 20)
        #expect(dist.mean == 7.5)
        #expect(dist.bins.count == 2)
        // width 10: [0,10) holds 0,0; [10,20] holds 10 and the clamped top value 20.
        #expect(dist.bins[0].count == 2)
        #expect(dist.bins[1].count == 2)
        #expect(dist.bins[0].lowerBound == 0)
        #expect(dist.bins[1].upperBound == 20)
    }

    @Test
    func `distribution of empty values is empty`() {
        #expect(NodeAnalytics.distribution(of: []) == .empty)
    }

    @Test
    func `distribution of a single distinct value widens the span and counts it`() {
        let dist = NodeAnalytics.distribution(of: [-7, -7, -7], binCount: 4)
        #expect(dist.sampleCount == 3)
        #expect(dist.minValue == -7)
        #expect(dist.maxValue == -7)
        #expect(dist.bins.reduce(0) { $0 + $1.count } == 3)
    }

    @Test
    func `snr and rssi distributions ignore nil samples`() {
        let observations = [
            observation(snr: -5, rssi: -90),
            observation(snr: nil, rssi: -80),
            observation(snr: -15, rssi: nil)
        ]
        #expect(NodeAnalytics.snrDistribution(observations: observations).sampleCount == 2)
        #expect(NodeAnalytics.rssiDistribution(observations: observations).sampleCount == 2)
    }

    // MARK: Hop histogram

    @Test
    func `hop count is start minus limit, nil when missing or negative`() {
        #expect(NodeAnalytics.hopCount(observation(hopStart: 3, hopLimit: 1)) == 2)
        #expect(NodeAnalytics.hopCount(observation(hopStart: 3, hopLimit: 3)) == 0)
        #expect(NodeAnalytics.hopCount(observation(hopStart: nil, hopLimit: 1)) == nil)
        #expect(NodeAnalytics.hopCount(observation(hopStart: 1, hopLimit: 3)) == nil)
    }

    @Test
    func `hop histogram is dense from zero to the max observed hop`() {
        let observations = [
            observation(hopStart: 0, hopLimit: 0), // 0 hops
            observation(hopStart: 3, hopLimit: 1), // 2 hops
            observation(hopStart: 3, hopLimit: 1), // 2 hops
            observation(hopStart: nil, hopLimit: nil) // ignored
        ]
        let hist = NodeAnalytics.hopHistogram(observations: observations)
        #expect(hist.map(\.hops) == [0, 1, 2])
        #expect(hist.map(\.count) == [1, 0, 2])
    }

    @Test
    func `hop histogram of empty input is empty`() {
        #expect(NodeAnalytics.hopHistogram(observations: []).isEmpty)
    }

    // MARK: Peer summaries

    @Test
    func `peer summaries rank gateways by reception count with average snr`() {
        let observations = [
            observation(snr: -4, gateway: "gw-a"),
            observation(snr: -6, gateway: "gw-a"),
            observation(snr: -10, gateway: "gw-b")
        ]
        let peers = NodeAnalytics.peerSummaries(observations: observations)
        #expect(peers.map(\.gatewayID) == ["gw-a", "gw-b"])
        #expect(peers[0].receptionCount == 2)
        #expect(peers[0].averageSNR == -5)
        #expect(peers[1].averageSNR == -10)
    }

    @Test
    func `peer summaries fold a missing gateway into unknown`() {
        let peers = NodeAnalytics.peerSummaries(observations: [observation(gateway: nil)])
        #expect(peers.first?.gatewayID == "unknown")
    }

    // MARK: Hourly activity

    @Test
    func `hour of day buckets nanoseconds into 0 to 23 UTC`() {
        #expect(NodeAnalytics.hourOfDay(nanoseconds: 0) == 0)
        // 13:00 UTC = 13 * 3600 s.
        #expect(NodeAnalytics.hourOfDay(nanoseconds: 13 * 3600 * 1_000_000_000) == 13)
        // Wraps across a day boundary: 25h → hour 1.
        #expect(NodeAnalytics.hourOfDay(nanoseconds: 25 * 3600 * 1_000_000_000) == 1)
    }

    @Test
    func `hourly activity returns a fixed 24-slot grid`() {
        let observations = [
            observation(rxNanos: 0),
            observation(rxNanos: 0),
            observation(rxNanos: 5 * 3600 * 1_000_000_000)
        ]
        let grid = NodeAnalytics.hourlyActivity(observations: observations)
        #expect(grid.count == 24)
        #expect(grid[0].count == 2)
        #expect(grid[5].count == 1)
        // Hour 12 had no receptions (empty bucket value).
        #expect(grid[12].count < 1)
    }

    // MARK: Packet-type breakdown

    @Test
    func `packet-type breakdown counts by port, ranked descending`() {
        let packets = [
            packet(port: .telemetry),
            packet(port: .telemetry),
            packet(port: .position),
            packet(port: .other(99))
        ]
        let breakdown = NodeAnalytics.packetTypeBreakdown(packets: packets)
        #expect(breakdown.first?.port == .telemetry)
        #expect(breakdown.first?.count == 2)
        #expect(breakdown.map(\.label).contains("Telemetry"))
        #expect(breakdown.map(\.label).contains("Port 99"))
    }

    @Test
    func `mesh port labels are stable`() {
        #expect(MeshPortLabel.name(.textMessage) == "Text")
        #expect(MeshPortLabel.name(.nodeInfo) == "Node Info")
        #expect(MeshPortLabel.name(.mapReport) == "Map Report")
        #expect(MeshPortLabel.name(.other(42)) == "Port 42")
    }
}
