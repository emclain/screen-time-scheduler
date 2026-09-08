import os

// MARK: - Loggers

extension Logger {
    private static let subsystem = "net.emclain.ScreenScheduler"

    static let auth   = Logger(subsystem: subsystem, category: "auth")
    static let dam    = Logger(subsystem: subsystem, category: "dam")
    static let shield = Logger(subsystem: subsystem, category: "shield")
    static let sync   = Logger(subsystem: subsystem, category: "sync")
}

// MARK: - Stable event names

enum LogEvent {
    static let authRequested    = "auth_requested"
    /// Final status after an authorization attempt — logged on BOTH the success
    /// and failure paths, so it is deliberately not called "granted". Read it
    /// together with the `changed=` field, not on its own.
    static let authResult       = "auth_result"
    static let damIntervalStart = "dam_interval_start"
    static let damIntervalEnd   = "dam_interval_end"
    static let damMissedCallback = "dam_missed_callback"
    static let shieldApplied    = "shield_applied"
    static let shieldCleared    = "shield_cleared"
    static let tokenLoadFailed  = "token_load_failed"
}

// MARK: - Convenience wrappers

func logDebug(_ logger: Logger, _ message: String) {
    logger.debug("\(message, privacy: .public)")
}

/// Uses `notice`, not `info`, deliberately.
///
/// Console.app and `log show` both hide info-level messages unless you opt in
/// (Action -> Include Info Messages, or `--info`). This app is diagnosed on
/// machines that cannot run Xcode, where the log IS the instrument, so its
/// events must be visible by default. Notice level is persisted and shown
/// without any extra flag.
func logInfo(_ logger: Logger, _ message: String) {
    logger.notice("\(message, privacy: .public)")
}

func logWarn(_ logger: Logger, _ message: String) {
    logger.warning("\(message, privacy: .public)")
}

func logError(_ logger: Logger, _ message: String) {
    logger.error("\(message, privacy: .public)")
}
