// LiveAntigravityRunner.swift
//
// Bounded `agy --print` subprocess + the LiveSubagentHost extension that
// replaces `runChild` for `antigravity:*` models.
//
// Rust reference at pin 650c1db7:
//   * `build_command` / concurrent pipe drain — antigravity.rs:549-590
//   * spawn gates + skip_permissions clamp —
//     antigravity_runner.rs:100-127, :259-271
//
// Process.waitUntilExit() is forbidden here (AGENTS.md §2): it parks on a
// death notification that may already be spent. Pattern copied from
// BoundedProcess.swift — terminationHandler + DispatchSemaphore +
// terminate/SIGKILL escalation. Cost of reading pipes concurrently via
// readabilityHandler rather than after exit: more bookkeeping, but agy
// final reports can fill a pipe buffer and deadlock a sequential drain
// (antigravity.rs:588-590).

import Foundation
import OpenGrokAgentCoordinator
import OpenGrokConfig
import OpenGrokSubagentResolution

enum LiveAntigravityProcessOutcome: Sendable, Equatable {
    case exited(status: Int32, stdout: String, stderr: String)
    case timedOut
    case failedToStart(String)
}

/// How `runBoundedAntigravityProcess` should launch the configured binary.
enum AntigravityExecutableResolution: Sendable, Equatable {
    /// A concrete path to hand `Process.executableURL`.
    case path(String)
    /// A bare name POSIX `/usr/bin/env` should resolve at exec time.
    case viaEnv
    /// No launchable form on this platform; reported as a start failure.
    case unsupported(String)
}

/// Decide how to launch `executable`.
///
/// `/usr/bin/env` does not exist on Windows, so the old "bare name → env"
/// branch made the feature unlaunchable there even when `agy.exe` was on
/// `PATH` and the availability probe had already advertised it. Explicit
/// Windows paths landed in the same branch because the old test recognized
/// only `/` as a separator.
///
/// PATH resolution is attempted first on every platform and `/usr/bin/env` is
/// kept only as the POSIX fallback. Cost of that ordering: a bare name is now
/// resolved by our own `PATH` walk rather than by `env`, so a caller who
/// relies on `env` seeing a `PATH` we did not pass through `environment` loses
/// that — which is why the fallback stays instead of erroring.
func resolveAntigravityExecutable(
    _ executable: String,
    environment: [String: String]
) -> AntigravityExecutableResolution {
    if executable.contains("/") || executable.contains("\\") {
        return .path(executable)
    }
    #if os(Windows)
    // A drive-qualified path with no separator (`C:agy.exe`) is still a path.
    if executable.count >= 2, executable.dropFirst().hasPrefix(":") {
        return .path(executable)
    }
    #endif
    if let resolved = resolveExecutablePath(executable, environment: environment) {
        return .path(resolved)
    }
    #if os(Windows)
    return .unsupported(
        "Antigravity CLI (`\(executable)`) was not found on PATH, and there is "
            + "no `/usr/bin/env` on Windows to resolve it at exec time."
    )
    #else
    return .viaEnv
    #endif
}

/// Reaches into a running bounded child so an async caller can kill it.
///
/// The blocking wait has to live on a detached task (it parks a thread), and a
/// detached task does not inherit cancellation — awaiting its nonthrowing
/// `.value` just keeps waiting. Without this handle, `kill_task`, foreground
/// cancellation, and session teardown all returned "cancelled" while an `agy`
/// launched with `--dangerously-skip-permissions` kept editing the workspace
/// until it finished on its own or hit the hard deadline.
final class AntigravityProcessCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Register the child. Returns `false` when cancellation already arrived,
    /// in which case the caller must not start it — otherwise a cancel that
    /// lands between spawn and adoption is lost.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        return true
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        process = nil
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        let pid = running.processIdentifier
        running.terminate()
        // Escalate rather than trust SIGTERM: an agy that traps or ignores it
        // would otherwise keep the workspace mutable until the hard deadline,
        // which is the whole failure this handle exists to close.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if running.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Bounded child with optional cwd, full argv, and concurrent pipe draining.
/// Blocking: callers MUST hop off the actor (Task.detached) before waiting.
func runBoundedAntigravityProcess(
    executable: String,
    arguments: [String],
    currentDirectory: URL?,
    environment: [String: String],
    timeout: TimeInterval,
    canceller: AntigravityProcessCanceller? = nil
) -> LiveAntigravityProcessOutcome {
    let process = Process()
    switch resolveAntigravityExecutable(executable, environment: environment) {
    case .path(let resolved):
        process.executableURL = URL(fileURLWithPath: resolved)
        process.arguments = arguments
    case .viaEnv:
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    case .unsupported(let message):
        return .failedToStart(message)
    }
    if let currentDirectory {
        process.currentDirectoryURL = currentDirectory
    }
    process.environment = environment
    process.standardInput = FileHandle.nullDevice

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Class boxes so readabilityHandler captures are Sendable under Swift 6
    // (mutating a captured `var [Data]` is a concurrent-capture error).
    final class PipeBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            chunks.append(data)
            lock.unlock()
        }

        func combined() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return chunks.reduce(into: Data()) { $0.append($1) }
        }
    }
    let stdoutBuffer = PipeBuffer()
    let stderrBuffer = PipeBuffer()

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        stdoutBuffer.append(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        stderrBuffer.append(handle.availableData)
    }

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }

    if let canceller, !canceller.adopt(process) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return .failedToStart("cancelled before launch")
    }

    do {
        try process.run()
    } catch {
        canceller?.finish()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return .failedToStart(String(describing: error))
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 0.3) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1.0)
        }
        canceller?.finish()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return .timedOut
    }

    canceller?.finish()
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil

    // Drain any bytes that arrived between the last readability callback and
    // handler teardown — without this, a short final chunk can vanish.
    stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
    stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

    let outData = stdoutBuffer.combined()
    let errData = stderrBuffer.combined()
    let stdout = String(data: outData, encoding: .utf8)
        ?? String(decoding: outData, as: UTF8.self)
    let stderr = String(data: errData, encoding: .utf8)
        ?? String(decoding: errData, as: UTF8.self)
    return .exited(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

// MARK: - Host extension

extension LiveSubagentHost {
    /// Shell-out replacement for `runChild` when the resolved model is
    /// `antigravity:<id>`. Same coordinator lifecycle; no in-process sampler.
    func runAntigravityChild(
        childID: String,
        prompt: String,
        model: String,
        runtime: EffectiveRuntimeConfig,
        cwd: URL
    ) async -> OpenGrokChildResult {
        let startedAt = Date()
        let services = context.antigravityServices
        let config = services.loadConfig(context.environment)
        // Full access by default: headless agy auto-denies mutating tools
        // without its skip-permissions flag. A caller-pinned ReadOnly
        // capability mode always stays read-only (antigravity_runner.rs:259-271).
        let skipPermissions = config.skipPermissions
            && runtime.capabilityMode != .readOnly

        let metaDir = context.openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(context.sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(childID, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: metaDir,
            withIntermediateDirectories: true
        )
        let logFile = metaDir.appendingPathComponent("agy.log")
        let timeout = antigravityRunTimeout(environment: context.environment)
        let run = LiveAntigravityRun(
            binary: config.binary,
            model: model,
            prompt: prompt,
            workspaceDirectory: cwd,
            logFile: logFile,
            timeout: timeout,
            skipPermissions: skipPermissions
        )

        let outcome = await services.runPrint(run)
        bookkeeping[childID]?.terminalToolCalls = 0
        bookkeeping[childID]?.terminalTurns = 1
        bookkeeping[childID]?.model =
            LiveAntigravityComposition.modelPrefix + model

        let elapsed = Date().timeIntervalSince(startedAt)
        let durationMS = UInt64(max(0, elapsed * 1000.0).rounded(.down))
        switch outcome {
        case .success(let output):
            return OpenGrokChildResult(
                id: childID,
                success: true,
                output: output,
                durationMS: durationMS
            )
        case .failure(let message):
            return OpenGrokChildResult(
                id: childID,
                success: false,
                error: message,
                durationMS: durationMS
            )
        case .cancelled:
            return OpenGrokChildResult(
                id: childID,
                success: false,
                cancelled: true,
                error: "Subagent was cancelled",
                durationMS: durationMS
            )
        }
    }
}
