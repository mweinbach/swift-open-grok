// CrashBootstrap.swift
//
// The startup entry point for crash handling. Everything in
// `OpenGrokCrashHandler.swift` was already implemented and correct, but
// `installCrashHandler` / `PlatformCrashHandler.install` / `checkPreviousCrash`
// had zero call sites anywhere in `Sources/` — so a SIGSEGV left a wrecked
// terminal and produced no report at all.
//
// Port of the install sequence at `xai-grok-pager-bin/src/main.rs:1690-1706`.
//
// Two properties are deliberately separated:
//
//   * **Terminal restore is unconditional.** A crash that leaves the terminal
//     in raw mode with the alternate screen active makes the user's shell
//     unusable and has nothing to do with whether they consented to crash
//     reporting. Rust restores unconditionally; so does this.
//   * **Report capture is opt-in**, gated on `crash_handler_enabled`. Only the
//     full handler writes a blob to disk.

import Foundation

/// What `CrashBootstrap.start` did, so callers can surface a notice.
public struct CrashBootstrapResult: Sendable {
    /// Whether full blob capture (not just terminal restore) is active.
    public let captureInstalled: Bool
    /// A crash recovered from the previous session, already archived.
    public let previousCrash: PreviousCrashReport?

    public init(captureInstalled: Bool, previousCrash: PreviousCrashReport?) {
        self.captureInstalled = captureInstalled
        self.previousCrash = previousCrash
    }

    /// A short, redacted, user-facing notice about the previous crash, or `nil`
    /// when the last session exited cleanly.
    ///
    /// Deliberately terse and path-redacted: this prints at startup, before the
    /// user has asked for anything, so it names the report and stops.
    public var previousCrashNotice: String? {
        guard let previousCrash else { return nil }
        let path = redactPath(previousCrash.reportPath.path)
        return """
            Open Grok exited unexpectedly on its previous run \
            (\(previousCrash.signalName), version \(previousCrash.appVersion)).
            A crash report was saved to \(path)
            """
    }
}

public enum CrashBootstrap {
    /// Install crash handling and recover any report left by the last session.
    ///
    /// Call this once, as early in startup as possible.
    ///
    /// - Parameters:
    ///   - openGrokHome: the resolved `OPENGROK_HOME` root. The crash directory
    ///     is always `<home>/crash`, and writes are confined below it.
    ///   - appVersion: stamped into the blob so a report names the build that
    ///     produced it.
    ///   - reportingEnabled: `crash_handler_enabled`. When false, only the
    ///     terminal-restore handler is installed and nothing is written to disk.
    @discardableResult
    public static func start(
        openGrokHome: URL,
        appVersion: String,
        reportingEnabled: Bool
    ) -> CrashBootstrapResult {
        let crashDir = openGrokHome.appendingPathComponent("crash", isDirectory: true)

        // Ordering is load-bearing: installing truncates `last-crash.bin`, so
        // the previous session's blob has to be consumed first or it is lost.
        let previous = reportingEnabled ? checkPreviousCrash(crashDir: crashDir) : nil

        guard reportingEnabled else {
            installTerminalRestoreOnly()
            return CrashBootstrapResult(captureInstalled: false, previousCrash: nil)
        }

        let installed = installCrashHandler(
            CrashHandlerConfig(appVersion: appVersion, crashDir: crashDir),
            openGrokHome: openGrokHome
        )
        if !installed {
            // Capture is unavailable on this platform (or the crash directory
            // could not be opened safely). The terminal must still be restored,
            // so fall back rather than leaving no handler at all.
            installTerminalRestoreOnly()
        }
        return CrashBootstrapResult(captureInstalled: installed, previousCrash: previous)
    }

    /// Whether crash reporting is enabled, resolving the config value against
    /// the environment overrides Rust honors.
    ///
    /// Defaults to enabled, matching Rust's `crash_handler_enabled`. Reporting
    /// here means *writing a redacted local file under OPENGROK_HOME* — nothing
    /// is transmitted anywhere, so the default does not leak.
    public static func reportingEnabled(
        configuredValue: Bool?,
        environment: [String: String]
    ) -> Bool {
        if let raw = environment["OPENGROK_CRASH_HANDLER"] ?? environment["GROK_CRASH_HANDLER"],
           let parsed = parseBool(raw) {
            return parsed
        }
        if environment["OPENGROK_DISABLE_CRASH_HANDLER"].flatMap(parseBool) == true {
            return false
        }
        return configuredValue ?? true
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled": return true
        case "0", "false", "no", "off", "disabled": return false
        default: return nil
        }
    }
}
