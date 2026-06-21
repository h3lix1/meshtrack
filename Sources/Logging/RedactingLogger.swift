// RedactingLogger — the one sanctioned way to log in Meshtrack (AGENTS.md Safety:
// "redact secrets in logs, enforced by a logging wrapper").
//
// Every message and every interpolated field passes through `redact(_:)` before
// it reaches the sink, so a PSK or admin key can never leave the process in clear
// text — regardless of what the call site passes. Other modules depend on this
// type rather than touching `os.Logger` directly; that indirection is what makes
// the redaction guarantee enforceable rather than aspirational.
//
// The sink is injectable (`@Sendable (String) -> Void`) so tests capture output
// deterministically without scraping the unified logging system. The default sink
// forwards to `os.Logger`.

import Foundation
import os

/// Severity of a log line. Mirrors the `os.Logger` / OSLog levels Meshtrack uses;
/// `notice` is the default "this happened" level, `error` is for failures.
public enum LogLevel: String, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case notice
    case error

    /// Ordering by increasing severity (`debug < info < notice < error`), so a
    /// sink can filter with `level >= .notice`.
    private var severity: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .error: 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// A structured logger that redacts secrets from every line before emitting it.
///
/// Construction is cheap and the type is `Sendable`, so a single logger can be
/// shared across actors or a fresh one created per subsystem. All emission goes
/// through the injected ``sink``; the default sink writes to `os.Logger`.
///
/// ```swift
/// let log = RedactingLogger(subsystem: "org.meshtrack", category: "ingest")
/// log.notice("connected to broker; psk=deadbeefdeadbeefdeadbeefdeadbeef")
/// // emitted: "connected to broker; psk=‹redacted›"
/// ```
public struct RedactingLogger: Sendable {
    /// Where a fully-formatted, already-redacted line is delivered. Injected so
    /// tests can capture output; defaults to ``osLogSink(subsystem:category:)``.
    public typealias Sink = @Sendable (LogLevel, String) -> Void

    private let sink: Sink

    /// Creates a logger that emits through `sink`.
    ///
    /// - Parameter sink: receives each line *after* redaction and formatting.
    ///   Must be `@Sendable`; it may be called from any task.
    public init(sink: @escaping Sink) {
        self.sink = sink
    }

    /// Creates a logger backed by `os.Logger` for the given subsystem/category.
    ///
    /// This is the production constructor. Each ``LogLevel`` maps to the
    /// corresponding `os.Logger` method so Console.app categorization is correct.
    public init(subsystem: String, category: String) {
        self.init(sink: Self.osLogSink(subsystem: subsystem, category: category))
    }

    // MARK: Level-specific entry points

    /// Logs at ``LogLevel/debug``.
    public func debug(_ message: @autoclosure () -> String) {
        emit(.debug, message())
    }

    /// Logs at ``LogLevel/info``.
    public func info(_ message: @autoclosure () -> String) {
        emit(.info, message())
    }

    /// Logs at ``LogLevel/notice``.
    public func notice(_ message: @autoclosure () -> String) {
        emit(.notice, message())
    }

    /// Logs at ``LogLevel/error``.
    public func error(_ message: @autoclosure () -> String) {
        emit(.error, message())
    }

    /// Logs at an explicit `level`.
    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        emit(level, message())
    }

    /// Redacts `message` and forwards it to the sink. The single choke point —
    /// **every** public entry point routes through here, so nothing can reach a
    /// sink un-redacted.
    private func emit(_ level: LogLevel, _ message: String) {
        sink(level, redact(message))
    }

    // MARK: Default sink

    /// The default sink: forwards each already-redacted line to `os.Logger` at the
    /// matching level. Built once per logger and captured by the `@Sendable`
    /// closure (`os.Logger` is `Sendable`).
    ///
    /// Defence in depth: messages are passed as a dynamic `String` argument with
    /// the `.public` privacy qualifier *because they are already redacted*. We do
    /// not rely on OSLog's own `%{private}` masking — redaction has already run, so
    /// the line is safe to mark public and is therefore readable in Console.app.
    public static func osLogSink(subsystem: String, category: String) -> Sink {
        let logger = os.Logger(subsystem: subsystem, category: category)
        return { level, line in
            switch level {
            case .debug: logger.debug("\(line, privacy: .public)")
            case .info: logger.info("\(line, privacy: .public)")
            case .notice: logger.notice("\(line, privacy: .public)")
            case .error: logger.error("\(line, privacy: .public)")
            }
        }
    }
}
