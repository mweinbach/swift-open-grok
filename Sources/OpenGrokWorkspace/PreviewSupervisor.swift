// PreviewSupervisor.swift
//
// One-child supervisor for the in-sandbox preview-proxy.
// Ported from `xai-grok-workspace-daemon/src/preview_supervisor.rs`.
//
// After the workspace-server self-daemonizes it spawns the preview-proxy
// child process and supervises exactly that one child: spawn -> wait ->
// restart-on-exit with capped backoff that resets after a healthy run.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Constants

/// Absolute path of the preview-proxy binary the supervisor execs.
public let PREVIEW_PROXY_BIN_PATH: String = "/usr/local/bin/xai-grok-preview-proxy"

/// WS-owned, per-restart-truncated log capturing the proxy's stdout+stderr.
public let PREVIEW_PROXY_LOG_PATH: String = "/var/tmp/workspace-server/tmp/preview-proxy.log"

/// A child that ran at least this long is treated as a healthy run, resetting
/// the restart backoff.
public let PREVIEW_PROXY_HEALTHY_RUN_SECS: UInt64 = 30

/// First/base restart delay; doubled on each consecutive unhealthy restart.
public let PREVIEW_PROXY_RESTART_BACKOFF_BASE_SECS: UInt64 = 1

/// Ceiling on the restart backoff so a crash-loop pins at this interval rather
/// than growing unbounded.
public let PREVIEW_PROXY_RESTART_BACKOFF_CAP_SECS: UInt64 = 30

// MARK: - Metrics

public enum RestartReason: String, Sendable {
    case exit = "exit"
    case spawnError = "spawn_error"

    public var asStr: String { rawValue }
}

private final class PreviewSupervisorMetrics: @unchecked Sendable {
    static let shared = PreviewSupervisorMetrics()
    private let lock = NSLock()
    private var exitCount = 0
    private var spawnErrorCount = 0

    func record(reason: RestartReason) {
        lock.withLock {
            switch reason {
            case .exit:
                exitCount += 1
            case .spawnError:
                spawnErrorCount += 1
            }
        }
    }

    func counts() -> (exit: Int, spawnError: Int) {
        lock.withLock {
            (exitCount, spawnErrorCount)
        }
    }
}

public func recordPreviewRestart(reason: RestartReason) {
    PreviewSupervisorMetrics.shared.record(reason: reason)
}

public func previewRestartCounts() -> (exit: Int, spawnError: Int) {
    PreviewSupervisorMetrics.shared.counts()
}

// MARK: - Configuration

/// Access policy forwarded to the proxy's `--visibility`.
public enum PreviewVisibility: String, Sendable, Codable, Equatable, CaseIterable {
    case owner = "owner"
    case publicVisibility = "public"

    public var asStr: String {
        switch self {
        case .owner: return "owner"
        case .publicVisibility: return "public"
        }
    }
}

/// Supervisor config forwarded to the proxy child.
public struct PreviewArgs: Sendable, Equatable {
    /// Gate: the supervisor is started only when this is true. Not forwarded.
    public var enabled: Bool
    /// -> proxy `--preview-port`.
    public var port: UInt16?
    /// -> proxy `--control-port`.
    public var controlPort: UInt16?
    /// -> proxy `--visibility` (`owner` | `public`).
    public var visibility: PreviewVisibility?
    /// -> proxy `--instance-suffix`.
    public var instanceSuffix: String?
    /// -> proxy `--auth-redirect`.
    public var authRedirect: String?
    /// -> proxy `--allow-public`.
    public var allowPublic: Bool
    /// -> proxy `--workspace-server-port`.
    public var workspaceServerPort: UInt16?
    /// `currentDirectoryURL` for the spawned child. Not forwarded as an arg.
    public var workspaceDir: URL

    public init(
        enabled: Bool = true,
        port: UInt16? = nil,
        controlPort: UInt16? = nil,
        visibility: PreviewVisibility? = nil,
        instanceSuffix: String? = nil,
        authRedirect: String? = nil,
        allowPublic: Bool = false,
        workspaceServerPort: UInt16? = nil,
        workspaceDir: URL
    ) {
        self.enabled = enabled
        self.port = port
        self.controlPort = controlPort
        self.visibility = visibility
        self.instanceSuffix = instanceSuffix
        self.authRedirect = authRedirect
        self.allowPublic = allowPublic
        self.workspaceServerPort = workspaceServerPort
        self.workspaceDir = workspaceDir
    }

    /// Map the forwarded fields to the proxy's exact CLI flag names.
    public func toArgv() -> [String] {
        var argv: [String] = []
        if let port {
            argv.append("--preview-port")
            argv.append(String(port))
        }
        if let controlPort {
            argv.append("--control-port")
            argv.append(String(controlPort))
        }
        if let visibility {
            argv.append("--visibility")
            argv.append(visibility.asStr)
        }
        if let instanceSuffix {
            argv.append("--instance-suffix")
            argv.append(instanceSuffix)
        }
        if let authRedirect {
            argv.append("--auth-redirect")
            argv.append(authRedirect)
        }
        if allowPublic {
            argv.append("--allow-public")
        }
        if let workspaceServerPort {
            argv.append("--workspace-server-port")
            argv.append(String(workspaceServerPort))
        }
        return argv
    }
}

// MARK: - Backoff Policy

/// Exponential restart backoff with a hard ceiling.
public struct BackoffPolicy: Sendable, Equatable {
    public var base: TimeInterval
    public var cap: TimeInterval

    public init(
        base: TimeInterval = Double(PREVIEW_PROXY_RESTART_BACKOFF_BASE_SECS),
        cap: TimeInterval = Double(PREVIEW_PROXY_RESTART_BACKOFF_CAP_SECS)
    ) {
        self.base = base
        self.cap = cap
    }

    /// `base * 2^step`, saturating to `cap`.
    public func delay(step: UInt32) -> TimeInterval {
        let factor: Double
        if step >= 31 {
            factor = Double(UInt32.max)
        } else {
            factor = Double(1 << step)
        }
        let calculated = base * factor
        return min(calculated, cap)
    }

    /// Delay before next spawn and next step counter.
    public func nextStep(healthy: Bool, step: UInt32) -> (delay: TimeInterval, nextStep: UInt32) {
        if healthy {
            return (delay(step: 0), 0)
        } else {
            let currentDelay = delay(step: step)
            let next = step == UInt32.max ? UInt32.max : step + 1
            return (currentDelay, next)
        }
    }
}

/// Healthy once the run reached `healthyRun` (inclusive).
public func isHealthy(
    elapsed: TimeInterval,
    healthyRun: TimeInterval = Double(PREVIEW_PROXY_HEALTHY_RUN_SECS)
) -> Bool {
    elapsed >= healthyRun
}

/// Open the WS-owned proxy log, truncating it on every (re)start.
public func openTruncatedLog(path: String = PREVIEW_PROXY_LOG_PATH) throws -> FileHandle {
    let fd = try daemonFileOpen(path: path, flags: O_CREAT | O_WRONLY | O_TRUNC, mode: S_IRUSR | S_IWUSR)
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

// MARK: - Shutdown Token

/// Cooperative shutdown coordination token.
public final class PreviewSupervisorShutdownToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isShutDown = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    public init(isShutDown: Bool = false) {
        self._isShutDown = isShutDown
    }

    public var isShutDown: Bool {
        lock.withLock { _isShutDown }
    }

    public func signalShutdown() {
        let list: [CheckedContinuation<Void, Never>] = lock.withLock {
            _isShutDown = true
            let current = continuations
            continuations.removeAll()
            return current
        }
        for cont in list {
            cont.resume()
        }
    }

    public func waitUntilShutdown() async {
        if isShutDown { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let alreadyShutDown: Bool = lock.withLock {
                if _isShutDown {
                    return true
                }
                continuations.append(cont)
                return false
            }
            if alreadyShutDown {
                cont.resume()
            }
        }
    }
}

/// Sleep for `delay`, returning early with `true` if `shutdown` is signaled or task is cancelled.
public func sleepOrShutdown(delay: TimeInterval, shutdown: PreviewSupervisorShutdownToken) async -> Bool {
    if shutdown.isShutDown || Task.isCancelled { return true }
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            let delayNs = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            return false
        }
        group.addTask {
            await shutdown.waitUntilShutdown()
            return true
        }
        let firstResult = await group.next() ?? false
        group.cancelAll()
        return firstResult || shutdown.isShutDown || Task.isCancelled
    }
}

// MARK: - Process Supervision

/// Build the unspawned proxy command.
public func buildPreviewCommand(cfg: PreviewArgs) throws -> Process {
    let logHandle = try openTruncatedLog(path: PREVIEW_PROXY_LOG_PATH)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: PREVIEW_PROXY_BIN_PATH)
    process.arguments = cfg.toArgv()
    process.currentDirectoryURL = cfg.workspaceDir
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = logHandle
    process.standardError = logHandle
    return process
}

/// Supervise the preview-proxy child until `shutdown` flips.
public func supervisePreview(
    cfg: PreviewArgs,
    shutdown: PreviewSupervisorShutdownToken = PreviewSupervisorShutdownToken()
) async {
    let policy = BackoffPolicy(
        base: Double(PREVIEW_PROXY_RESTART_BACKOFF_BASE_SECS),
        cap: Double(PREVIEW_PROXY_RESTART_BACKOFF_CAP_SECS)
    )
    let healthyRun = Double(PREVIEW_PROXY_HEALTHY_RUN_SECS)
    await superviseLoop(
        makeCommand: { try buildPreviewCommand(cfg: cfg) },
        policy: policy,
        healthyRun: healthyRun,
        shutdown: shutdown
    )
}

/// Core supervise loop, generic over the command factory for testing.
public func superviseLoop(
    makeCommand: @Sendable () throws -> Process,
    policy: BackoffPolicy,
    healthyRun: TimeInterval,
    shutdown: PreviewSupervisorShutdownToken
) async {
    var step: UInt32 = 0
    while !shutdown.isShutDown && !Task.isCancelled {
        let started = Date()
        let process: Process
        do {
            process = try makeCommand()
        } catch {
            recordPreviewRestart(reason: .spawnError)
            let (delay, next) = policy.nextStep(healthy: false, step: step)
            step = next
            if await sleepOrShutdown(delay: delay, shutdown: shutdown) {
                return
            }
            continue
        }

        let exitNotifier = AsyncExitNotifier()
        process.terminationHandler = { _ in
            Task {
                await exitNotifier.signalExit()
            }
        }

        do {
            try process.run()
        } catch {
            recordPreviewRestart(reason: .spawnError)
            let (delay, next) = policy.nextStep(healthy: false, step: step)
            step = next
            if await sleepOrShutdown(delay: delay, shutdown: shutdown) {
                return
            }
            continue
        }

        let didExit = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exitNotifier.wait()
                return true
            }
            group.addTask {
                await shutdown.waitUntilShutdown()
                return false
            }
            let exited = await group.next() ?? false
            group.cancelAll()
            return exited
        }

        if !didExit || shutdown.isShutDown || Task.isCancelled {
            // Shutdown received while process running: kill it.
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                #if !os(Windows)
                if pid > 0 {
                    kill(pid, SIGKILL)
                }
                #endif
            }
            return
        }

        // Child exited normally.
        let elapsed = Date().timeIntervalSince(started)
        let healthy = isHealthy(elapsed: elapsed, healthyRun: healthyRun)
        recordPreviewRestart(reason: .exit)
        let (delay, next) = policy.nextStep(healthy: healthy, step: step)
        step = next

        if await sleepOrShutdown(delay: delay, shutdown: shutdown) {
            return
        }
    }
}

/// Helper for asynchronous notification of process exit without `waitUntilExit()`.
private actor AsyncExitNotifier {
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func signalExit() {
        exited = true
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    func wait() async {
        if exited { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if exited {
                cont.resume()
                return
            }
            continuation = cont
        }
    }
}
