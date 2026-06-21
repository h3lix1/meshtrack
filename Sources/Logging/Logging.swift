// Logging — structured logging with mandatory secret redaction (SPEC §2.5,
// AGENTS.md Safety). This module is the *only* sanctioned way to log in Meshtrack:
// everything routes through ``RedactingLogger``, which scrubs PSKs, admin keys, and
// MQTT credentials via the pure ``redact(_:)`` transform before a single byte
// reaches `os.Logger`, stdout, or a log file.
//
// Layout:
//   • `Redaction.swift`       — the pure `redact(_:)` core (most-tested deliverable).
//   • `RedactingLogger.swift` — the structured logger with an injectable sink.
//
// Adding a new effect that needs to log? Take a `RedactingLogger`; never reach for
// `os.Logger` directly — that indirection is what makes the redaction guarantee
// enforceable instead of aspirational.
