// OpenGrokCrashHandler.swift
//
// Crash-report capture and redaction contract (W2-S4 bootstrap scaffold).
// Crash reports redact secrets, write only below OPENGROK_HOME, and never
// corrupt active session journals. Platform specifics (signal handlers,
// macOS .ips, Windows SEH/minidumps) live behind the adapter.
//
// The owning slice (W2-S4) replaces `BootstrapCrashHandler` with the real
// platform handler. Reference: xai-crash-handler.

import Foundation

/// Crash-handler errors.
public enum CrashHandlerError: Error, Equatable, Sendable {
    case installFailed(String)
    case unsupported(String)
    case writeFailed(String)
}

/// A redacted, session-safe crash report.
public struct CrashReport: Sendable, Equatable {
    public var summary: String
    public var redactedBacktrace: [String]
    public var openGrokHomeRelativePath: String
    public init(summary: String, redactedBacktrace: [String], openGrokHomeRelativePath: String) {
        self.summary = summary
        self.redactedBacktrace = redactedBacktrace
        self.openGrokHomeRelativePath = openGrokHomeRelativePath
    }
}

/// Crash capture, redaction, and persistence below OPENGROK_HOME.
public protocol CrashHandler: Sendable {
    /// Install platform crash/signal hooks. Idempotent.
    func install(openGrokHome: URL) async throws
    /// Record a redacted report without corrupting active session journals.
    func record(_ report: CrashReport, openGrokHome: URL) async throws -> URL
}

/// Bootstrap handler that reports `unsupported` for install/record. The owning
/// slice (W2-S4) provides the real signal/SEH/minidump adapter.
public struct BootstrapCrashHandler: CrashHandler {
    public init() {}
    public func install(openGrokHome: URL) async throws {
        throw CrashHandlerError.unsupported("BootstrapCrashHandler does not install; W2-S4 provides the platform handler.")
    }
    public func record(_ report: CrashReport, openGrokHome: URL) async throws -> URL {
        throw CrashHandlerError.unsupported("BootstrapCrashHandler does not record; W2-S4 provides the platform handler.")
    }
}
