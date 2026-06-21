// Corpus capture: subscribe to a live broker and write a golden corpus for the
// replay tier (SPEC §6). Credentials come from the environment, never the repo.
//
//   swift run meshtrackd capture <seconds> <outdir>
//   env: MESHTRACK_MQTT_HOST / PORT / USER / PASS / TLS(=1) / TOPIC

import Domain
import Foundation
import Transport

enum Capture {
    static func run(seconds: Double, outputDir: String, clock: any Domain.Clock) async {
        let config = makeConfig()
        print("capturing from \(config.host):\(config.port) for \(Int(seconds))s; topics \(config.topics)")
        let adapter = MQTTAdapter(config: config, clock: clock)
        let collector = FrameCollector()
        let consumer = Task {
            for await frame in adapter.frames() {
                await collector.add(frame)
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        consumer.cancel()

        let frames = await collector.snapshot()
        print("captured \(frames.count) frames")
        if frames.isEmpty {
            print("no frames — check broker host/creds/topic and network reachability")
        } else {
            write(frames, to: outputDir)
        }
    }

    private static func makeConfig() -> MQTTConfig {
        let env = ProcessInfo.processInfo.environment
        return MQTTConfig(
            host: env["MESHTRACK_MQTT_HOST"] ?? "mqtt.bayme.sh",
            port: UInt16(env["MESHTRACK_MQTT_PORT"] ?? "") ?? 1883,
            username: env["MESHTRACK_MQTT_USER"],
            password: env["MESHTRACK_MQTT_PASS"],
            useTLS: env["MESHTRACK_MQTT_TLS"] == "1",
            topics: [env["MESHTRACK_MQTT_TOPIC"] ?? "msh/+/2/e/#"]
        )
    }

    private static func write(_ frames: [InboundFrame], to dir: String) {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()

        let lines = frames.enumerated().compactMap { index, frame -> String? in
            let record = CorpusFrame(
                seq: index,
                rxTimeNs: frame.receivedAt.nanosecondsSinceEpoch,
                transport: frame.transport,
                topic: frame.topic,
                gatewayID: frame.gatewayID,
                payloadB64: Data(frame.payload).base64EncodedString()
            )
            return (try? encoder.encode(record)).flatMap { String(data: $0, encoding: .utf8) }
        }
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: "\(dir)/frames.ndjson", atomically: true, encoding: .utf8)

        let meta = CorpusMeta(
            name: (dir as NSString).lastPathComponent,
            source: "mqtt-capture",
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            frameCount: frames.count,
            synthetic: false
        )
        if let data = try? encoder.encode(meta), let json = String(data: data, encoding: .utf8) {
            try? json.write(toFile: "\(dir)/meta.json", atomically: true, encoding: .utf8)
        }
        print("wrote corpus to \(dir)/")
    }
}

private actor FrameCollector {
    private var frames: [InboundFrame] = []
    func add(_ frame: InboundFrame) {
        frames.append(frame)
    }

    func snapshot() -> [InboundFrame] {
        frames
    }
}
