// Logging — structured logging with mandatory secret redaction (SPEC §8 Safety).
// A logging wrapper that scrubs PSKs / admin keys / credentials before anything
// reaches os.Logger or stdout. Phase 1 placeholder.

/// Module marker; superseded by the redacting structured logger.
public enum LoggingModule {
    public static let name = "Logging"
}
