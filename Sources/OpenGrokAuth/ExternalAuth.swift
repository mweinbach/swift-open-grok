// ExternalAuth.swift
//
// External auth-provider binary: parse stdout as JSON or bare token.

import Foundation
import OpenGrokConfig

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// Bounded, synchronous process adapter used by named auth providers.
public struct DefaultExternalAuthProcessRunner: ExternalAuthProcessRunner, Sendable {
    static let maximumStdoutBytes = 1 << 20
    static let maximumStderrBytes = 64 << 10

    // Keep this independently audited against the security parity suite: a
    // provider-specific API key remains usable, but host-provider credentials
    // and stale handback tokens must never cross the subprocess boundary.
    static let firstPartyCredentialEnvironmentKeys: Set<String> = [
        "XAI_API_KEY",
        "XAI_ACCESS_TOKEN",
        "XAI_REFRESH_TOKEN",
        "XAI_AUTH",
        "GROK_CODE_XAI_API_KEY",
        "GROK_API_KEY",
        "GROK_AUTH",
        "GROK_AUTH_PATH",
        "GROK_AUTH_TOKEN",
        "GROK_ACCESS_TOKEN",
        "GROK_REFRESH_TOKEN",
        "GROK_DEPLOYMENT_KEY",
        "GROK_EXTRA_AUTH_KEY",
        "GROK_TRACE_UPLOAD_CREDENTIALS_FILE",
        "GROK_INTERNAL_OTLP_HEADERS",
        "GROK_OAUTH2_CLIENT_SECRET",
        "OTEL_EXPORTER_OTLP_HEADERS",
        "OTEL_EXPORTER_OTLP_TRACES_HEADERS",
        "OTEL_EXPORTER_OTLP_METRICS_HEADERS",
        "OTEL_EXPORTER_OTLP_LOGS_HEADERS",
        "OPENGROK_CODE_XAI_API_KEY",
        "OPENGROK_API_KEY",
        "OPENGROK_AUTH",
        "OPENGROK_AUTH_PATH",
        "OPENGROK_AUTH_TOKEN",
        "OPENGROK_ACCESS_TOKEN",
        "OPENGROK_REFRESH_TOKEN",
        "OPENGROK_DEPLOYMENT_KEY",
        "OPENGROK_EXTRA_AUTH_KEY",
        "OPENGROK_TRACE_UPLOAD_CREDENTIALS_FILE",
        "OPENGROK_INTERNAL_OTLP_HEADERS",
        "OPENGROK_OAUTH2_CLIENT_SECRET",
        "OPENAI_API_KEY",
        "OPENAI_ACCESS_TOKEN",
        "OPENAI_REFRESH_TOKEN",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "CODEX_REFRESH_TOKEN",
        "CHATGPT_ACCESS_TOKEN",
        "CHATGPT_REFRESH_TOKEN",
        "GROK_AUTH_PROVIDER_ACCESS_TOKEN",
        "GROK_AUTH_PROVIDER_REFRESH_TOKEN",
        "GROK_AUTH_PROVIDER_EXPIRES_AT",
        "GROK_AUTH_REFRESH_TOKEN",
    ]

    public var maxOutputBytes: Int
    private let inheritedEnvironment: [String: String]?

    public init(
        maxOutputBytes: Int = 1 << 20,
        environment: [String: String]? = nil
    ) {
        self.maxOutputBytes = min(Self.maximumStdoutBytes, max(1, maxOutputBytes))
        self.inheritedEnvironment = environment
    }

    public func run(
        command: String,
        args: [String]?,
        cwd: String?,
        timeout: TimeInterval,
        refreshToken: String?
    ) -> ExternalAuthExecution? {
        let stdoutLimit = min(Self.maximumStdoutBytes, max(1, maxOutputBytes))
        var environment = inheritedEnvironment ?? ProcessInfo.processInfo.environment
        for key in Array(environment.keys)
            where Self.firstPartyCredentialEnvironmentKeys.contains(key.uppercased()) {
            environment.removeValue(forKey: key)
        }
        environment["GROK_AUTH_EXPIRED"] = refreshToken == nil ? nil : "1"
        if let refreshToken, !refreshToken.isEmpty {
            environment["GROK_AUTH_PROVIDER_REFRESH_TOKEN"] = refreshToken
            environment["GROK_AUTH_REFRESH_TOKEN"] = refreshToken
        }

        let effectiveTimeout = timeout.isFinite ? min(max(0, timeout), 600) : 600
        #if canImport(Darwin) || canImport(Glibc)
        return runIsolatedPOSIXProcess(
            command: command,
            args: args,
            cwd: cwd,
            timeout: effectiveTimeout,
            environment: environment,
            stdoutLimit: stdoutLimit
        )
        #else
        return runPortableProcess(
            command: command,
            args: args,
            cwd: cwd,
            timeout: effectiveTimeout,
            environment: environment,
            stdoutLimit: stdoutLimit
        )
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private func runIsolatedPOSIXProcess(
        command: String,
        args: [String]?,
        cwd: String?,
        timeout: TimeInterval,
        environment: [String: String],
        stdoutLimit: Int
    ) -> ExternalAuthExecution? {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let processGroup = ExternalAuthProcessGroup()
        let stdoutCapture = ExternalAuthBoundedPipeCapture(
            limit: stdoutLimit,
            failOnOverflow: true,
            onOverflow: { processGroup.terminate() }
        )
        let stderrCapture = ExternalAuthBoundedPipeCapture(
            limit: Self.maximumStderrBytes,
            failOnOverflow: false
        )

        stdoutCapture.install(on: stdoutPipe.fileHandleForReading)
        stderrCapture.install(on: stderrPipe.fileHandleForReading)
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        }

        guard let processID = spawnIsolatedProcess(
            command: command,
            args: args,
            cwd: cwd,
            environment: environment,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        ) else {
            return nil
        }
        processGroup.adopt(processID)
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let waiter = ExternalAuthChildWaiter(processID: processID)
        let deadline = DispatchTime.now() + timeout
        guard let status = waiter.wait(until: deadline) else {
            processGroup.terminate()
            _ = waiter.wait(until: .now() + 1)
            return nil
        }

        guard stdoutCapture.waitUntilFinished(deadline),
              stderrCapture.waitUntilFinished(deadline) else {
            processGroup.terminate()
            return nil
        }

        if stdoutCapture.overflowed {
            return ExternalAuthExecution(
                stdout: "",
                stderr: "external auth provider stdout exceeded \(stdoutLimit) bytes",
                exitCode: 1
            )
        }

        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return ExternalAuthExecution(
            stdout: String(decoding: stdoutCapture.capturedData, as: UTF8.self),
            stderr: String(decoding: stderrCapture.capturedData, as: UTF8.self),
            exitCode: exitCode
        )
    }

    private func spawnIsolatedProcess(
        command: String,
        args: [String]?,
        cwd: String?,
        environment: [String: String],
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) -> pid_t? {
        #if canImport(Darwin)
        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        var attributes = posix_spawnattr_t(bitPattern: 0)
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif

        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }

        let actionResults = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(
                &actions,
                stdoutPipe.fileHandleForWriting.fileDescriptor,
                STDOUT_FILENO
            ),
            posix_spawn_file_actions_adddup2(
                &actions,
                stderrPipe.fileHandleForWriting.fileDescriptor,
                STDERR_FILENO
            ),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe.fileHandleForReading.fileDescriptor),
            posix_spawn_file_actions_addclose(&actions, stderrPipe.fileHandleForReading.fileDescriptor),
            posix_spawn_file_actions_addclose(&actions, stdoutPipe.fileHandleForWriting.fileDescriptor),
            posix_spawn_file_actions_addclose(&actions, stderrPipe.fileHandleForWriting.fileDescriptor),
        ]
        guard actionResults.allSatisfy({ $0 == 0 }),
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return nil
        }

        let arguments = shellArguments(command: command, args: args, cwd: cwd)
        guard arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
              }) else {
            return nil
        }

        var argumentPointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        guard argumentPointers.allSatisfy({ $0 != nil }) else {
            for pointer in argumentPointers {
                if let pointer { free(pointer) }
            }
            return nil
        }
        argumentPointers.append(nil)
        defer {
            for pointer in argumentPointers {
                if let pointer { free(pointer) }
            }
        }

        var environmentPointers: [UnsafeMutablePointer<CChar>?] = environment.map { key, value in
            strdup("\(key)=\(value)")
        }
        guard environmentPointers.allSatisfy({ $0 != nil }) else {
            for pointer in environmentPointers {
                if let pointer { free(pointer) }
            }
            return nil
        }
        environmentPointers.append(nil)
        defer {
            for pointer in environmentPointers {
                if let pointer { free(pointer) }
            }
        }

        var processID: pid_t = 0
        let result = posix_spawn(
            &processID,
            "/bin/sh",
            &actions,
            &attributes,
            &argumentPointers,
            &environmentPointers
        )
        return result == 0 && processID > 1 ? processID : nil
    }

    private func shellArguments(command: String, args: [String]?, cwd: String?) -> [String] {
        if let cwd, !cwd.isEmpty {
            let directory = expandedCWD(cwd).path
            if let args {
                return [
                    "/bin/sh",
                    "-c",
                    "cd \"$1\" || exit 125; shift; exec \"$@\"",
                    "opengrok-auth",
                    directory,
                    command,
                ] + args
            }
            return [
                "/bin/sh",
                "-c",
                "cd \"$1\" || exit 125; shift; exec /bin/sh -c \"$1\"",
                "opengrok-auth",
                directory,
                command,
            ]
        }
        if let args {
            return ["/bin/sh", "-c", "exec \"$@\"", "opengrok-auth", command] + args
        }
        return ["/bin/sh", "-c", command]
    }
    #else
    private func runPortableProcess(
        command: String,
        args: [String]?,
        cwd: String?,
        timeout: TimeInterval,
        environment: [String: String],
        stdoutLimit: Int
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
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutCapture = ExternalAuthBoundedPipeCapture(limit: stdoutLimit, failOnOverflow: true)
        let stderrCapture = ExternalAuthBoundedPipeCapture(
            limit: Self.maximumStderrBytes,
            failOnOverflow: false
        )
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutCapture.install(on: stdoutPipe.fileHandleForReading)
        stderrCapture.install(on: stderrPipe.fileHandleForReading)
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let deadline = DispatchTime.now() + timeout
        guard done.wait(timeout: deadline) == .success else {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            return nil
        }

        guard stdoutCapture.waitUntilFinished(deadline),
              stderrCapture.waitUntilFinished(deadline) else {
            process.terminate()
            return nil
        }
        if stdoutCapture.overflowed {
            return ExternalAuthExecution(
                stdout: "",
                stderr: "external auth provider stdout exceeded \(stdoutLimit) bytes",
                exitCode: 1
            )
        }
        return ExternalAuthExecution(
            stdout: String(decoding: stdoutCapture.capturedData, as: UTF8.self),
            stderr: String(decoding: stderrCapture.capturedData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }
    #endif

    private func expandedCWD(_ value: String) -> URL {
        if value == "~" { return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
        if value.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(String(value.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }
}

private final class ExternalAuthBoundedPipeCapture: @unchecked Sendable {
    private let limit: Int
    private let failOnOverflow: Bool
    private let onOverflow: (@Sendable () -> Void)?
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var didOverflow = false
    private var reachedEnd = false

    init(
        limit: Int,
        failOnOverflow: Bool,
        onOverflow: (@Sendable () -> Void)? = nil
    ) {
        self.limit = limit
        self.failOnOverflow = failOnOverflow
        self.onOverflow = onOverflow
    }

    func install(on handle: FileHandle) {
        handle.readabilityHandler = { [self] readable in
            let chunk = readable.availableData
            guard !chunk.isEmpty else {
                markFinished()
                readable.readabilityHandler = nil
                return
            }
            append(chunk)
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        let remaining = max(0, limit - buffer.count)
        if remaining > 0 {
            buffer.append(contentsOf: chunk.prefix(remaining))
        }
        let newlyOverflowed = failOnOverflow && chunk.count > remaining && !didOverflow
        if newlyOverflowed {
            didOverflow = true
        }
        lock.unlock()

        if newlyOverflowed {
            onOverflow?()
        }
    }

    private func markFinished() {
        lock.lock()
        let shouldSignal = !reachedEnd
        reachedEnd = true
        lock.unlock()
        if shouldSignal {
            finished.signal()
        }
    }

    func waitUntilFinished(_ deadline: DispatchTime) -> Bool {
        lock.lock()
        let alreadyFinished = reachedEnd
        lock.unlock()
        return alreadyFinished || finished.wait(timeout: deadline) == .success
    }

    var overflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOverflow
    }

    var capturedData: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

#if canImport(Darwin) || canImport(Glibc)
private final class ExternalAuthProcessGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?
    private var terminationRequested = false

    func adopt(_ processID: pid_t) {
        lock.lock()
        self.processID = processID
        let shouldTerminate = terminationRequested
        lock.unlock()
        if shouldTerminate {
            signalProcessGroup(processID)
        }
    }

    func terminate() {
        lock.lock()
        terminationRequested = true
        let processID = self.processID
        lock.unlock()
        if let processID {
            signalProcessGroup(processID)
        }
    }

    private func signalProcessGroup(_ processID: pid_t) {
        guard processID > 1 else { return }
        #if canImport(Darwin)
        _ = Darwin.kill(-processID, SIGKILL)
        #else
        _ = Glibc.kill(-processID, SIGKILL)
        #endif
    }
}

private final class ExternalAuthChildWaiter: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exitStatus: Int32?

    init(processID: pid_t) {
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            while true {
                let result = waitpid(processID, &status, 0)
                if result == processID {
                    lock.lock()
                    exitStatus = status
                    lock.unlock()
                    finished.signal()
                    return
                }
                if result == -1 && errno == EINTR {
                    continue
                }
                finished.signal()
                return
            }
        }
    }

    func wait(until deadline: DispatchTime) -> Int32? {
        guard finished.wait(timeout: deadline) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return exitStatus
    }
}
#endif

public final class NamedAuthProviderResolver: @unchecked Sendable {
    private let configuration: AuthProviderConfig
    private let runner: any ExternalAuthProcessRunner
    private let lock = NSCondition()
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
                lock.broadcast()
                lock.unlock()
                return result?.accessToken
            }
            lock.wait()
            lock.unlock()
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
