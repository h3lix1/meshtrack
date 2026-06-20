import Domain
import Foundation
import Testing
@testable import Transport

@Suite("ReplayAdapter + corpus")
struct ReplayAdapterTests {
    private func writeCorpus(meta: String, frames: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try meta.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        try frames.write(to: dir.appendingPathComponent("frames.ndjson"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test
    func `frames replay in seq order and drive the injected clock to replay time`() async throws {
        // Deliberately out of seq order in the file; loader sorts by seq.
        let frames = """
        {"seq":2,"rx_time_ns":300,"transport":"mqtt","topic":"t2","gateway_id":"!g","payload_b64":"ECA="}
        {"seq":0,"rx_time_ns":100,"transport":"mqtt","topic":"t0","gateway_id":"!g","payload_b64":"AQID"}
        {"seq":1,"rx_time_ns":200,"transport":"serial","payload_b64":"AA=="}
        """
        let meta = #"{"name":"t","source":"synthetic","captured_at":"2026-01-01T00:00:00Z","synthetic":true}"#
        let dir = try writeCorpus(meta: meta, frames: frames)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = InjectedClock()
        let adapter = try ReplayAdapter(directory: dir, clock: clock)
        #expect(adapter.corpus.frames.map(\.seq) == [0, 1, 2])
        #expect(adapter.lastInstant == Instant(nanosecondsSinceEpoch: 300))

        var collected: [InboundFrame] = []
        for await frame in adapter.frames() {
            collected.append(frame)
        }

        #expect(collected.map(\.receivedAt.nanosecondsSinceEpoch) == [100, 200, 300])
        #expect(collected.map(\.transport) == [.mqtt, .serial, .mqtt])
        #expect(collected[0].payload == [0x01, 0x02, 0x03])
        #expect(collected[1].topic == nil)
        // After the stream finishes the clock sits at the last frame's time.
        #expect(clock.now() == Instant(nanosecondsSinceEpoch: 300))
    }

    @Test
    func `a missing corpus directory throws, never crashes`() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
        #expect(throws: ReplayError.self) {
            _ = try ReplayAdapter(directory: missing)
        }
    }

    @Test
    func `a non-base64 payload throws invalidBase64`() throws {
        let frames = #"{"seq":0,"rx_time_ns":1,"transport":"mqtt","payload_b64":"not valid base64 !!"}"#
        let meta = #"{"name":"t","source":"synthetic","captured_at":"x","synthetic":true}"#
        let dir = try writeCorpus(meta: meta, frames: frames)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ReplayError.self) {
            _ = try ReplayAdapter(directory: dir)
        }
    }

    @Test
    func `an unknown transport throws rather than dropping the frame`() throws {
        let frames = #"{"seq":0,"rx_time_ns":1,"transport":"carrier-pigeon","payload_b64":"AQID"}"#
        let meta = #"{"name":"t","source":"synthetic","captured_at":"x","synthetic":true}"#
        let dir = try writeCorpus(meta: meta, frames: frames)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ReplayError.self) {
            _ = try ReplayAdapter(directory: dir)
        }
    }

    @Test
    func `the committed synthetic-basic golden fixture loads and parses`() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let corpus = try Corpus.load(directory: root.appendingPathComponent("Corpus/synthetic-basic"))
        #expect(corpus.meta.synthetic == true)
        #expect(corpus.frames.count == 3)
        #expect(corpus.frames.map(\.seq) == [0, 1, 2])
        #expect(try Corpus.payloadBytes(of: corpus.frames[0]) == [0x01, 0x02, 0x03])
    }
}
