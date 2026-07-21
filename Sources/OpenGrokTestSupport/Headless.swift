// Headless.swift
//
// Port of `xai-grok-test-support/src/headless.rs`. The headless mode
// (`open-grok -p`) test runner: runs the grok binary as a subprocess with
// the mock server, captures output, with a 60s timeout and crash-detection
// helpers.
//
// The Rust source uses `tokio::process::Command` and `tokio::time::timeout`.
// The Swift port uses `Foundation.Process` + a detached `Task` for the
// stdout/stderr drains + `Task.timeout` semantics via a deadline check.

import Foundation
import OpenGrokTestUtilities

/// The result of a headless run. Mirrors `headless::HeadlessResult`.
public struct HeadlessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// The headless runner.
public enum Headless {
    /// 60-second timeout, matching `HEADLESS_TIMEOUT_SECS` in the Rust source.
    public static let timeoutSeconds: TimeInterval = 60

    /// Crash/linker-failure indicators that `assertNoCrashes` looks for.
    public static let crashPatterns: [String] = [
        "panicked at",
        "SIGSEGV",
        "segfault",
        "undefined symbol",
        "SIGABRT",
        "cannot open shared object",
    ]

    /// Run `open-grok` with the given args against `server`, with an isolated
    /// HOME and disabled telemetry. 60s timeout.
    public static func run(
        server: MockInferenceServer,
        args: [String],
        cwd: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> HeadlessResult {
        let hermetic = try HermeticEnv(inherit: environment)
        var env = hermetic
        defer { env.dispose() }
        let binary = try TestEnv.grokBinary(environment: environment)
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.currentDirectoryURL = cwd
        TestEnv.applyTestEnv(to: process, hermetic: hermetic, mockURL: server.url, environment: environment)
        return try runWithCommand(process, timeout: timeoutSeconds)
    }

    /// Run a pre-configured `Process` with the 60s timeout. The caller
    /// configures `executableURL`, `arguments`, `currentDirectoryURL`, and
    /// `environment` (typically via `TestEnv.applyTestEnv`).
    public static func runWithCommand(_ process: Process, timeout: TimeInterval = timeoutSeconds) throws -> HeadlessResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        #if !os(Windows)
        if let nullHandle = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = nullHandle
        }
        #endif

        try process.run()
        let pid = process.processIdentifier

        // Drain stdout/stderr on background tasks.
        let stdoutBox = LockedBox<Data>(Data())
        let stderrBox = LockedBox<Data>(Data())
        let stdoutTask = Task.detached(priority: .userInitiated) {
            let handle = stdoutPipe.fileHandleForReading
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                stdoutBox.withLock { $0.append(chunk) }
            }
            try? handle.close()
        }
        let stderrTask = Task.detached(priority: .userInitiated) {
            let handle = stderrPipe.fileHandleForReading
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                stderrBox.withLock { $0.append(chunk) }
            }
            try? handle.close()
        }

        // Wait with timeout.
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            // Wait briefly for the kill to take.
            for _ in 0..<100 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        process.waitUntilExit()
        stdoutTask.cancel()
        stderrTask.cancel()

        let stdoutData = stdoutBox.withLock { Data($0) }
        let stderrData = stderrBox.withLock { Data($0) }
        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
        _ = pid
        return HeadlessResult(
            status: process.terminationStatus,
            stdout: stdoutString,
            stderr: stderrString,
            timedOut: timedOut
        )
    }

    /// Diagnostic helper: format the tail of stderr for assertion messages.
    public static func stderrTail(_ stderr: String, maxChars: Int) -> String {
        guard stderr.count > maxChars else { return stderr }
        let start = stderr.index(stderr.endIndex, offsetBy: -maxChars)
        return String(stderr[start...])
    }

    /// Assert that a headless run succeeded (non-timeout, zero exit code).
    /// Throws `HeadlessAssertionError` on failure with a diagnostic message.
    public static func assertSuccess(
        _ result: HeadlessResult,
        label: String,
        server: MockInferenceServer? = nil
    ) throws {
        if result.timedOut {
            throw HeadlessAssertionError.timeout(
                label: label,
                timeoutSeconds: timeoutSeconds,
                stderrTail: stderrTail(result.stderr, maxChars: 500)
            )
        }
        if result.status != 0 {
            let serverSummary = server?.requestLogSummary() ?? ""
            throw HeadlessAssertionError.nonZeroExit(
                label: label,
                status: result.status,
                stderrTail: stderrTail(result.stderr, maxChars: 1000),
                requestLog: serverSummary
            )
        }
    }

    /// Throw if stderr contains any crash/linker-failure indicators.
    public static func assertNoCrashes(_ stderr: String) throws {
        let lower = stderr.lowercased()
        for pattern in crashPatterns {
            if lower.contains(pattern.lowercased()) {
                throw HeadlessAssertionError.crashIndicator(
                    pattern: pattern,
                    stderrTail: stderrTail(stderr, maxChars: 500)
                )
            }
        }
    }
}

/// Errors thrown by `Headless.assertSuccess` / `assertNoCrashes`.
public enum HeadlessAssertionError: Error, Equatable, CustomStringConvertible {
    case timeout(label: String, timeoutSeconds: TimeInterval, stderrTail: String)
    case nonZeroExit(label: String, status: Int32, stderrTail: String, requestLog: String)
    case crashIndicator(pattern: String, stderrTail: String)

    public var description: String {
        switch self {
        case let .timeout(label, secs, tail):
            return "\(label): timed out after \(secs)s\nstderr tail:\n\(tail)"
        case let .nonZeroExit(label, status, tail, log):
            return "\(label): exited with \(status)\nstderr tail:\n\(tail)\n\(log)"
        case let .crashIndicator(pattern, tail):
            return "stderr contains crash indicator '\(pattern)':\n\(tail)"
        }
    }
}
