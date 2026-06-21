@testable import Logging
import Synchronization
import Testing

/// Thread-safe capture of `(level, line)` pairs emitted through an injected sink,
/// so logger output can be asserted deterministically without touching OSLog.
private final class CapturedLog: Sendable {
    private let entries = Mutex<[(level: LogLevel, line: String)]>([])

    var sink: RedactingLogger.Sink {
        { level, line in self.entries.withLock { $0.append((level, line)) } }
    }

    var lines: [String] {
        entries.withLock { $0.map(\.line) }
    }

    var levels: [LogLevel] {
        entries.withLock { $0.map(\.level) }
    }

    var last: (level: LogLevel, line: String)? {
        entries.withLock { $0.last }
    }

    var count: Int {
        entries.withLock { $0.count }
    }
}

@Suite("RedactingLogger — routes through the sink with secrets masked")
struct RedactingLoggerTests {
    static let pskHex = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b"

    @Test func `routes a secret-bearing message through the sink masked`() throws {
        let captured = CapturedLog()
        let log = RedactingLogger(sink: captured.sink)

        log.notice("opened channel psk=\(Self.pskHex)")

        let line = try #require(captured.last?.line)
        #expect(!line.contains(Self.pskHex))
        #expect(line.contains(redactionPlaceholder))
        #expect(line.contains("opened channel"))
    }

    @Test func `passes benign messages through verbatim`() {
        let captured = CapturedLog()
        let log = RedactingLogger(sink: captured.sink)

        log.info("collector started; node !a1b2c3d4 online")

        #expect(captured.last?.line == "collector started; node !a1b2c3d4 online")
    }

    @Test func `tags each line with its level`() {
        let captured = CapturedLog()
        let log = RedactingLogger(sink: captured.sink)

        log.debug("d")
        log.info("i")
        log.notice("n")
        log.error("e")

        #expect(captured.levels == [.debug, .info, .notice, .error])
        #expect(captured.lines == ["d", "i", "n", "e"])
    }

    @Test func `explicit log(level:) honours the given level`() {
        let captured = CapturedLog()
        let log = RedactingLogger(sink: captured.sink)

        log.log(.error, "boom: password=oops")

        #expect(captured.last?.level == .error)
        #expect(captured.last?.line.contains("oops") == false)
    }

    @Test func `redacts interpolated field values, not just literals`() {
        let captured = CapturedLog()
        let log = RedactingLogger(sink: captured.sink)
        let psk = Self.pskHex // simulates a field value spliced in at the call site

        log.error("decrypt failed for key=\(psk)")

        #expect(captured.last?.line.contains(psk) == false)
        #expect(captured.last?.line.contains(redactionPlaceholder) == true)
    }

    @Test func `emits exactly one line per call`() {
        let captured = CapturedLog()
        let log = RedactingLogger(sink: captured.sink)

        log.notice("one")
        log.notice("two")

        #expect(captured.count == 2)
    }

    @Test func `os-log-backed logger constructs and emits at every level`() {
        // The default sink path: no capture, just prove the production constructor
        // wires up and every level routes to os.Logger cleanly (output goes to the
        // unified log). A secret-bearing call must still return without leaking.
        let log = RedactingLogger(subsystem: "org.meshtrack.test", category: "logging")
        log.debug("startup psk=\(Self.pskHex)")
        log.info("scanning")
        log.notice("connected")
        log.error("teardown")
        log.log(.notice, "explicit level via os.Logger")
    }

    @Test func `level ordering supports severity filtering`() {
        #expect(LogLevel.debug < .info)
        #expect(LogLevel.info < .notice)
        #expect(LogLevel.notice < .error)
        #expect(LogLevel.allCases.count == 4)
    }
}
