// ExternalAuth.swift
//
// External auth-provider binary: parse stdout as JSON or bare token.

import Foundation
import OpenGrokConfig

/// Parsed external provider output.
public struct ExternalAuthOutput: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresIn: UInt64?
    public var issuer: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresIn: UInt64? = nil,
        issuer: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.issuer = issuer
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case issuer
    }
}

public struct ExternalAuthExecution: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol ExternalAuthProcessRunner: Sendable {
    func run(
        command: String,
        args: [String]?,
        cwd: String?,
        timeout: TimeInterval,
        refreshToken: String?
    ) -> ExternalAuthExecution?
}

/// Bounded, synchronous process adapter used by named auth providers. It
/// waits on a termination handler rather than `waitUntilExit()`, whose
/// notification can be lost when the child exits before the wait begins.
public struct DefaultExternalAuthProcessRunner: ExternalAuthProcessRunner, Sendable {
    public var maxOutputBytes: Int

    public init(maxOutputBytes: Int = 64 * 1024) {
        self.maxOutputBytes = max(1, maxOutputBytes)
    }

    public func run(
        command: String,
        args: [String]?,
        cwd: String?,
        timeout: TimeInterval,
        refreshToken: String?
    ) -> ExternalAuthExecution? {
        let process = Process()
        if let args {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
        }
        if let cwd, !cwd.isEmpty {
            process.currentDirectoryURL = expandedCWD(cwd)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GROK_AUTH_EXPIRED"] = refreshToken == nil ? nil : "1"
        if let refreshToken, !refreshToken.isEmpty {
            environment["GROK_AUTH_REFRESH_TOKEN"] = refreshToken
        }
        process.environment = environment

        let directory = FileManager.default.temporaryDirectory
        let suffix = UUID().uuidString
        let stdoutURL = directory.appendingPathComponent("opengrok-auth-\(suffix).out")
        let stderrURL = directory.appendingPathComponent("opengrok-auth-\(suffix).err")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        guard let stdout = try? FileHandle(forWritingTo: stdoutURL),
              let stderr = try? FileHandle(forWritingTo: stderrURL) else {
            return nil
        }
        process.standardOutput = stdout
        process.standardError = stderr

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            return nil
        }

        let completed = done.wait(timeout: .now() + max(0, timeout)) == .success
        if !completed {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            if process.isRunning { process.interrupt() }
            _ = done.wait(timeout: .now() + 1)
        }
        try? stdout.close()
        try? stderr.close()
        guard completed else { return nil }

        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
        return ExternalAuthExecution(
            stdout: String(data: stdoutData.prefix(maxOutputBytes), encoding: .utf8) ?? "",
            stderr: String(data: stderrData.prefix(maxOutputBytes), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func expandedCWD(_ value: String) -> URL {
        if value == "~" { return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
        if value.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(String(value.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
}

public final class NamedAuthProviderResolver: @unchecked Sendable {
    private let configuration: AuthProviderConfig
    private let runner: any ExternalAuthProcessRunner
    private let lock = NSLock()
    private let waiters = DispatchSemaphore(value: 0)
    private var refreshing = false
    private var cachedToken: String?
    private var cachedRefreshToken: String?
    private var expiresAt: Date?
    private let now: @Sendable () -> Date

    public init(
        configuration: AuthProviderConfig,
        runner: any ExternalAuthProcessRunner = DefaultExternalAuthProcessRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.runner = runner
        self.now = now
    }

    public func currentToken() -> String? {
        guard configuration.isUsable else { return nil }
        while true {
            lock.lock()
            let current = cachedToken
            let validUntil = expiresAt
            let skewedExpiry = validUntil.map { $0.addingTimeInterval(-60) }
            if let current, let skewedExpiry, now() < skewedExpiry {
                lock.unlock()
                return current
            }
            if !refreshing {
                refreshing = true
                lock.unlock()
                let result = refresh()
                lock.lock()
                refreshing = false
                if let result {
                    cachedToken = result.accessToken
                    cachedRefreshToken = result.refreshToken
                    let ttl = result.expiresIn ?? configuration.tokenTTLSecs ?? 300
                    expiresAt = now().addingTimeInterval(TimeInterval(ttl))
                }
                lock.unlock()
                waiters.signal()
                return result?.accessToken
            }
            lock.unlock()
            waiters.wait()
        }
    }

    private func refresh() -> ExternalAuthOutput? {
        let execution = runner.run(
            command: configuration.command,
            args: configuration.args,
            cwd: configuration.cwd,
            timeout: TimeInterval(configuration.effectiveTimeoutSecs),
            refreshToken: cachedRefreshToken
        )
        guard let execution else { return nil }
        return try? parseExternalAuthOutputValue(
            stdout: execution.stdout,
            exitCode: execution.exitCode
        )
    }
}

/// Parse process stdout into a `GrokAuth`. Accepts bare token or JSON.
public func parseExternalAuthOutput(
    stdout: String,
    exitCode: Int32,
    now: Date = Date()
) throws -> GrokAuth {
    let parsed = try parseExternalAuthOutputValue(stdout: stdout, exitCode: exitCode)
    let expiresAt = parsed.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
    let issuer: String?
    if let raw = parsed.issuer {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        issuer = trimmed.isEmpty ? nil : trimmed
    } else {
        issuer = nil
    }
    return GrokAuth(
        key: parsed.accessToken,
        authMode: .external,
        createTime: now,
        refreshToken: parsed.refreshToken,
        expiresAt: expiresAt,
        oidcIssuer: issuer
    )
}

public func parseExternalAuthOutputValue(
    stdout: String,
    exitCode: Int32
) throws -> ExternalAuthOutput {
    guard exitCode == 0 else {
        throw AuthError.protocolError("external auth provider exited with \(exitCode)")
    }
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AuthError.protocolError("external auth provider produced no output")
    }

    if let data = trimmed.data(using: .utf8),
       let parsed = try? JSONDecoder().decode(ExternalAuthOutput.self, from: data) {
        guard !parsed.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AuthError.protocolError("external auth provider returned an empty access token")
        }
        return parsed
    }

    return ExternalAuthOutput(accessToken: trimmed)
}

/// Default runner using `/bin/sh -c` with timeout. Not used in hermetic tests.
public func runExternalAuthCommand(
    _ command: String,
    isRefresh: Bool,
    timeout: TimeInterval? = nil
) -> GrokAuth? {
    let execution = DefaultExternalAuthProcessRunner().run(
        command: command,
        args: nil,
        cwd: nil,
        timeout: timeout ?? (isRefresh ? 5 : 60),
        refreshToken: isRefresh ? "expired" : nil
    )
    guard let execution else { return nil }
    return try? parseExternalAuthOutput(
        stdout: execution.stdout,
        exitCode: execution.exitCode
    )
}
