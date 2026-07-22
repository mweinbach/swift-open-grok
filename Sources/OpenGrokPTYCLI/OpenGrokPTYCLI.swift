// OpenGrokPTYCLI.swift
//
// PTY diagnostic/control library surface ported from `ptyctl-cli`.
// Provides spawn-and-collect diagnostics for interactive and non-TTY streams,
// signal forwarding, resize, UTF-8, large output, broken pipes, cancellation,
// and leak-free repeated launches. Full HTTP control server remains a later
// composition concern; this target is the reusable diagnostic core.

import Foundation
import OpenGrokPTY
import OpenGrokTTY

// MARK: - Configuration

/// Configuration for a diagnostic PTY run (mirrors `ptyctl run` flags).
public struct PTYCLIRunConfig: Sendable, Equatable {
    public var command: [String]
    public var width: Int
    public var height: Int
    public var workingDirectory: String?
    public var environment: [String: String]
    /// Timeout in seconds. `nil` waits indefinitely.
    public var timeoutSeconds: TimeInterval?
    public var usePTY: Bool

    public init(
        command: [String],
        width: Int = 80,
        height: Int = 24,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: TimeInterval? = nil,
        usePTY: Bool = true
    ) {
        self.command = command
        self.width = width
        self.height = height
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.usePTY = usePTY
    }

    /// Parse `KEY=VAL` environment entries (repeatable CLI form).
    public static func parseEnv(_ entries: [String]) -> [String: String] {
        var env: [String: String] = [:]
        for entry in entries {
            if let idx = entry.firstIndex(of: "=") {
                let key = String(entry[..<idx])
                let val = String(entry[entry.index(after: idx)...])
                env[key] = val
            }
        }
        return env
    }
}

/// Result of a diagnostic run.
public struct PTYCLIRunResult: Sendable, Equatable {
    public var exit: ProcessExit
    public var output: Data
    public var pid: Int32?
    public var timedOut: Bool

    public init(exit: ProcessExit, output: Data, pid: Int32?, timedOut: Bool = false) {
        self.exit = exit
        self.output = output
        self.pid = pid
        self.timedOut = timedOut
    }

    public var outputString: String {
        String(data: output, encoding: .utf8)
            ?? String(decoding: output, as: UTF8.self)
    }
}

// MARK: - Runner

/// Spawns a process under a PTY (or pipes), collects output, supports
/// interactive write/resize/signal, and waits for exit with optional timeout.
public actor PTYCLIRunner {
    private let adapter: any PTYAdapter
    private let scope: ProcessScope

    public init(adapter: (any PTYAdapter)? = nil, scope: ProcessScope = ProcessScope()) {
        self.scope = scope
        #if os(macOS) || os(Linux)
        self.adapter = adapter ?? PosixPTYAdapter(scope: scope)
        #else
        self.adapter = adapter ?? PlatformPTYAdapter(scope: scope)
        #endif
    }

    /// Run a command to completion, collecting all output.
    public func run(_ config: PTYCLIRunConfig) async throws -> PTYCLIRunResult {
        guard let program = config.command.first else {
            throw PTYError.spawnFailed("empty command")
        }
        let args = Array(config.command.dropFirst())
        let spec = ProcessSpec(
            command: program,
            arguments: args,
            environment: config.environment,
            workingDirectory: config.workingDirectory,
            usePTY: config.usePTY,
            initialSize: TerminalSize(width: config.width, height: config.height),
            newProcessGroup: true,
            applyPagerEnvironment: false
        )

        let process = try await adapter.spawn(spec)
        let stream = process.output()

        let collector = Task { () -> Data in
            var buf = Data()
            do {
                for try await chunk in stream {
                    buf.append(chunk)
                }
            } catch {
                // cancelled / EOF / broken pipe — return what we have
            }
            return buf
        }

        let exit: ProcessExit
        var timedOut = false
        if let timeout = config.timeoutSeconds {
            do {
                exit = try await withThrowingTaskGroup(of: ProcessExit.self) { group in
                    group.addTask {
                        try await process.waitForExit()
                    }
                    group.addTask {
                        let ns = UInt64(timeout * 1_000_000_000)
                        try await Task.sleep(nanoseconds: ns)
                        throw PTYError.timeout
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
            } catch PTYError.timeout {
                timedOut = true
                await process.cancel()
                // Wait for termination after cancel.
                exit = (try? await process.waitForExit()) ?? .signal(9)
            }
        } else {
            exit = try await process.waitForExit()
        }

        let output = await collector.value
        return PTYCLIRunResult(
            exit: exit,
            output: output,
            pid: process.processID,
            timedOut: timedOut
        )
    }

    /// Interactive session handle for multi-step diagnostics.
    public func start(_ config: PTYCLIRunConfig) async throws -> PTYCLISession {
        guard let program = config.command.first else {
            throw PTYError.spawnFailed("empty command")
        }
        let args = Array(config.command.dropFirst())
        let spec = ProcessSpec(
            command: program,
            arguments: args,
            environment: config.environment,
            workingDirectory: config.workingDirectory,
            usePTY: config.usePTY,
            initialSize: TerminalSize(width: config.width, height: config.height),
            newProcessGroup: true
        )
        let process = try await adapter.spawn(spec)
        let session = PTYCLISession(process: process)
        await session.startCollecting()
        return session
    }

    /// Kill any residual process groups enrolled in this runner's scope.
    public func shutdown() {
        scope.killAll()
    }
}

/// Interactive diagnostic session.
public actor PTYCLISession {
    private let process: any PTYProcess
    private var collected = Data()
    private var collectorTask: Task<Void, Never>?
    private var collecting = false

    init(process: any PTYProcess) {
        self.process = process
    }

    /// Begin draining process output into the session buffer. Idempotent.
    public func startCollecting() {
        guard !collecting else { return }
        collecting = true
        let stream = process.output()
        collectorTask = Task {
            do {
                for try await chunk in stream {
                    self.append(chunk)
                }
            } catch {
                // stream ended
            }
        }
    }

    private func append(_ data: Data) {
        collected.append(data)
    }

    public var pid: Int32? { process.processID }

    public func write(_ data: Data) async throws {
        startCollecting()
        try await process.write(data)
    }

    public func writeKeys(_ text: String) async throws {
        try await write(Data(text.utf8))
    }

    public func resize(width: Int, height: Int) async throws {
        try await process.resize(to: TerminalSize(width: width, height: height))
    }

    public func signal(_ signal: ProcessSignal) async throws {
        try await process.signal(signal)
    }

    public func outputSnapshot() -> Data {
        startCollecting()
        return collected
    }

    public func outputString() -> String {
        String(decoding: outputSnapshot(), as: UTF8.self)
    }

    public func waitForExit() async throws -> ProcessExit {
        startCollecting()
        return try await process.waitForExit()
    }

    public func cancel() async {
        await process.cancel()
    }
}

// MARK: - CLI argument helpers

/// Subcommand surface for a future `ptyctl`-compatible executable.
public enum PTYCLICommand: Sendable, Equatable {
    case run(PTYCLIRunConfig)
    case send(keys: String, enter: Bool)
    case screen
    case resize(width: Int, height: Int)
    case signal(ProcessSignal)
    case status
}

/// Minimal help text for diagnostics.
public enum PTYCLIHelp {
    public static let summary = """
    Open Grok PTY diagnostics (ptyctl-compatible surface)

    Commands:
      run <cmd...>     Spawn a command in a PTY and collect output
      send <keys>      Send keystrokes to a running session
      screen           Query screen content
      resize -W -H     Resize the PTY
      signal <name>    Deliver a signal to the process group
      status           Session status
    """
}
