// LatencyDistribution — pure summary statistics + a small histogram over a set of
// receive→publish latencies (G6, SPEC §2.11). Descriptive telemetry only (never an
// alert input — clock skew makes it unreliable for thresholds). Pure + Sendable so
// the analytics view and tests share one computation.

import Domain

public struct LatencyDistribution: Sendable, Equatable {
    /// One histogram bucket: `[lowerMillis, upperMillis)` and its count.
    public struct Bucket: Identifiable, Sendable, Equatable {
        public let lowerMillis: Int
        public let upperMillis: Int
        public let count: Int

        public var id: Int { lowerMillis }

        public init(lowerMillis: Int, upperMillis: Int, count: Int) {
            self.lowerMillis = lowerMillis
            self.upperMillis = upperMillis
            self.count = count
        }

        public var label: String { "\(lowerMillis)–\(upperMillis)ms" }
    }

    public let sampleCount: Int
    public let minMillis: Int
    public let maxMillis: Int
    public let meanMillis: Int
    /// 50th percentile (lower-rank, nearest-value).
    public let medianMillis: Int
    /// 95th percentile (lower-rank, nearest-value).
    public let p95Millis: Int
    public let buckets: [Bucket]

    public var isEmpty: Bool { sampleCount == 0 }

    public init(
        sampleCount: Int,
        minMillis: Int,
        maxMillis: Int,
        meanMillis: Int,
        medianMillis: Int,
        p95Millis: Int,
        buckets: [Bucket]
    ) {
        self.sampleCount = sampleCount
        self.minMillis = minMillis
        self.maxMillis = maxMillis
        self.meanMillis = meanMillis
        self.medianMillis = medianMillis
        self.p95Millis = p95Millis
        self.buckets = buckets
    }

    public static let empty = LatencyDistribution(
        sampleCount: 0, minMillis: 0, maxMillis: 0, meanMillis: 0,
        medianMillis: 0, p95Millis: 0, buckets: []
    )

    /// Build the distribution from raw millisecond samples (negative skew values
    /// are clamped to 0 — they reflect clock skew, not real latency, and would
    /// distort the histogram). Returns `.empty` for no samples.
    public init(millis rawSamples: [Int], bucketCount: Int = 6) {
        let samples = rawSamples.map { max(0, $0) }.sorted()
        guard let lo = samples.first, let hi = samples.last else {
            self = .empty
            return
        }
        let n = samples.count
        let sum = samples.reduce(0, +)
        let mean = Int((Double(sum) / Double(n)).rounded())

        func percentile(_ p: Double) -> Int {
            // lower-rank nearest: clamp index into bounds.
            let rank = Int((p * Double(n - 1)).rounded())
            return samples[min(max(rank, 0), n - 1)]
        }

        let span = max(1, hi - lo)
        let count = max(1, bucketCount)
        let width = max(1, (span + count - 1) / count) // ceil so hi lands in last bucket
        var bucketList: [Bucket] = []
        for i in 0..<count {
            let lower = lo + i * width
            let upper = lower + width
            let c = samples.filter { $0 >= lower && $0 < upper }.count
            // the very last bucket is inclusive of the max value.
            let inclusiveC = (i == count - 1) ? samples.filter { $0 >= lower && $0 <= upper }.count : c
            bucketList.append(Bucket(lowerMillis: lower, upperMillis: upper, count: inclusiveC))
            if lower + width > hi { break }
        }

        self.init(
            sampleCount: n,
            minMillis: lo,
            maxMillis: hi,
            meanMillis: mean,
            medianMillis: percentile(0.5),
            p95Millis: percentile(0.95),
            buckets: bucketList
        )
    }
}
