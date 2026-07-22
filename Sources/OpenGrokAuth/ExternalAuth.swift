// ExternalAuth.swift
//
// External auth-provider binary: parse stdout as JSON or bare token.

import Foundation

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

/// Parse process stdout into a `GrokAuth`. Accepts bare token or JSON.
public func parseExternalAuthOutput(
    stdout: String,
    exitCode: Int32,
    now: Date = Date()
) throws -> GrokAuth {
    guard exitCode == 0 else {
        throw AuthError.protocolError("external auth provider exited with \(exitCode)")
    }
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AuthError.protocolError("external auth provider produced no output")
    }

    if let data = trimmed.data(using: .utf8),
       let parsed = try? JSONDecoder().decode(ExternalAuthOutput.self, from: data) {
        let expiresAt = parsed.expiresIn.map {
            now.addingTimeInterval(TimeInterval($0))
        }
        var issuer: String? = nil
        if let raw = parsed.issuer {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { issuer = t }
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

    return GrokAuth(
        key: trimmed,
        authMode: .external,
        createTime: now
    )
}

/// Default runner using `/bin/sh -c` with timeout. Not used in hermetic tests.
public func runExternalAuthCommand(
    _ command: String,
    isRefresh: Bool,
    timeout: TimeInterval? = nil
) -> GrokAuth? {
    let timeoutSecs = timeout ?? (isRefresh ? 5 : 60)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardInput = FileHandle.nullDevice
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    if isRefresh {
        var env = ProcessInfo.processInfo.environment
        env["GROK_AUTH_EXPIRED"] = "1"
        process.environment = env
    }
    do {
        try process.run()
    } catch {
        return nil
    }
    let deadline = Date().addingTimeInterval(timeoutSecs)
    while process.isRunning {
        if Date() > deadline {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: data, encoding: .utf8) ?? ""
    return try? parseExternalAuthOutput(stdout: stdout, exitCode: process.terminationStatus)
}
