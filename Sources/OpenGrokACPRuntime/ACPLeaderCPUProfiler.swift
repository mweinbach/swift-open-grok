// ACPLeaderCPUProfiler.swift
//
// The leader-wide, process-local sampling lifecycle. The native backend owns
// signal-safe sampling and descriptor-relative artifact confinement; this
// manager owns the wire-visible inactive/active/stopping state and moves
// blocking finalization off Swift's cooperative executor.
//
// Rust reference: xai-grok-shell-base/src/cpu_profile.rs:177-398 and
// xai-grok-shell/src/leader/server.rs:950-1003,1253-1272,1302-1358.

import Foundation
import OpenGrokCrashHandlerC

/// A genuine native CPU profiler scoped to one explicitly resolved state
/// root. Construction does not inspect or create filesystem state.
public final class ACPLeaderCPUProfiler: @unchecked Sendable {
    static let minimumFrequencyHz = 1
    static let maximumFrequencyHz = 4_000
    static let defaultFrequencyHz = 1_000

    /// Injection keeps lifecycle and failure tests deterministic without
    /// weakening the production backend's descriptor-relative confinement.
    struct Backend: Sendable {
        var isSupported: Bool
        var start: @Sendable (_ home: String, _ output: String?, _ frequencyHz: Int32) throws -> String
        var stop: @Sendable () throws -> UInt64
    }

    private struct ActiveProfile: Sendable {
        var startedAt: String
        var artifactPath: String
        var frequencyHz: Int32
    }

    private enum Phase: Sendable {
        case inactive
        case active(ActiveProfile)
        case stopping(ActiveProfile)
    }

    private let home: URL
    private let backend: Backend
    private let now: @Sendable () -> String
    private let lock = NSLock()
    private var phase: Phase = .inactive
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// One process-global sampler can only have one finalization in flight;
    /// a dedicated serial queue also prevents a malicious client from growing
    /// an unbounded worker pool through repeated stop frames.
    private static let finalizationQueue = DispatchQueue(
        label: "org.opengrok.leader.cpu-profile.finalization",
        qos: .utility
    )

    /// Platform/backend availability, independent of whether a profile is
    /// currently active. This query performs no filesystem work.
    public var isSupported: Bool { backend.isSupported }

    public init(openGrokHome: URL) {
        self.home = openGrokHome
        self.backend = Self.nativeBackend()
        self.now = Self.timestamp
    }

    init(
        openGrokHome: URL,
        backend: Backend,
        now: @escaping @Sendable () -> String
    ) {
        self.home = openGrokHome
        self.backend = backend
        self.now = now
    }

    /// `server.rs:950-980`: stopping deliberately means `active == false`,
    /// while its original timestamp, path and frequency remain observable.
    public func status() -> ACPLeaderCpuProfileStatus {
        lock.withLock {
            switch phase {
            case .inactive:
                return ACPLeaderCpuProfileStatus()
            case .active(let active):
                return ACPLeaderCpuProfileStatus(
                    active: true,
                    stopping: false,
                    startedAt: active.startedAt,
                    svgPath: active.artifactPath,
                    frequencyHz: active.frequencyHz
                )
            case .stopping(let active):
                return ACPLeaderCpuProfileStatus(
                    active: false,
                    stopping: true,
                    startedAt: active.startedAt,
                    svgPath: active.artifactPath,
                    frequencyHz: active.frequencyHz
                )
            }
        }
    }

    func start(
        pid: UInt32,
        output: String?,
        frequencyHz: Int?
    ) throws -> ACPLeaderCpuProfileStarted {
        try lock.withLock {
            guard backend.isSupported else {
                throw Self.unsupportedError
            }

            switch phase {
            case .active:
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.profileAlreadyActive,
                    message: "CPU profile is already active"
                )
            case .stopping:
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.profileStopInProgress,
                    message: "CPU profile stop is still in progress"
                )
            case .inactive:
                break
            }

            let frequency = frequencyHz ?? Self.defaultFrequencyHz
            guard (Self.minimumFrequencyHz...Self.maximumFrequencyHz).contains(frequency) else {
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.invalidFrequency,
                    message: "CPU profile frequency must be between 1 and 4000 Hz"
                )
            }
            if let output {
                try Self.validateOutput(output)
            }

            let canonicalHome = try canonicalHome()
            let startedAt = now()
            let artifactPath = try backend.start(canonicalHome.path, output, Int32(frequency))
            let artifactURL = URL(fileURLWithPath: artifactPath).standardizedFileURL
            let expectedDirectory = canonicalHome.appendingPathComponent("profiles").path
            guard artifactURL.deletingLastPathComponent().path == expectedDirectory,
                  !artifactURL.lastPathComponent.isEmpty
            else {
                // A compromised or incorrectly injected backend cannot turn
                // a remote output name into an escape hatch.
                _ = try? backend.stop()
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.artifactWriteFailed,
                    message: "CPU profile artifact escaped its private profile directory"
                )
            }

            let active = ActiveProfile(
                startedAt: startedAt,
                artifactPath: artifactURL.path,
                frequencyHz: Int32(frequency)
            )
            phase = .active(active)
            return ACPLeaderCpuProfileStarted(
                pid: pid,
                svgPath: active.artifactPath,
                frequencyHz: active.frequencyHz,
                startedAt: active.startedAt
            )
        }
    }

    /// `server.rs:1302-1322`: state becomes stopping before the blocking
    /// engine finalization starts and is restored even when finalization fails.
    func stop(pid: UInt32) async throws -> ACPLeaderCpuProfileStopped {
        guard backend.isSupported else { throw Self.unsupportedError }
        let active = try beginStopping()
        let stoppedAt = now()
        defer { completeStop() }

        let backend = self.backend
        let result: Result<UInt64, ACPLeaderControlError> = await withCheckedContinuation {
            continuation in
            Self.finalizationQueue.async {
                do {
                    continuation.resume(returning: .success(try backend.stop()))
                } catch let error as ACPLeaderControlError {
                    continuation.resume(returning: .failure(error))
                } catch {
                    continuation.resume(
                        returning: .failure(
                            ACPLeaderControlError(
                                code: ACPLeaderControlErrorCode.internalError,
                                message: "CPU profile stop task failed: \(error)"
                            )
                        )
                    )
                }
            }
        }

        let sampleCount = try result.get()
        guard sampleCount > 0 else {
            throw ACPLeaderControlError(
                code: ACPLeaderControlErrorCode.artifactWriteFailed,
                message: "CPU profile did not capture any samples"
            )
        }
        return ACPLeaderCpuProfileStopped(
            pid: pid,
            svgPath: active.artifactPath,
            startedAt: active.startedAt,
            stoppedAt: stoppedAt
        )
    }

    /// Shutdown finalizes an active profile and joins an already-running
    /// finalization rather than releasing its private artifact early.
    public func finalize() async {
        guard backend.isSupported else { return }

        let wasStopping = lock.withLock { () -> Bool in
            if case .stopping = phase { return true }
            return false
        }
        if wasStopping {
            await awaitStopCompletion()
            return
        }

        do {
            _ = try await stop(pid: UInt32(clamping: ProcessInfo.processInfo.processIdentifier))
        } catch let error as ACPLeaderControlError {
            if error.code == ACPLeaderControlErrorCode.profileStopInProgress {
                await awaitStopCompletion()
            }
        } catch {
            // Shutdown remains best-effort, matching the upstream warning
            // path; the native backend has already released its reservation.
        }
    }

    private func beginStopping() throws -> ActiveProfile {
        try lock.withLock {
            switch phase {
            case .inactive:
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.profileNotActive,
                    message: "CPU profile is not active"
                )
            case .stopping:
                throw ACPLeaderControlError(
                    code: ACPLeaderControlErrorCode.profileStopInProgress,
                    message: "CPU profile stop is already in progress"
                )
            case .active(let active):
                phase = .stopping(active)
                return active
            }
        }
    }

    private func completeStop() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            phase = .inactive
            let waiters = stopWaiters
            stopWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func awaitStopCompletion() async {
        await withCheckedContinuation { continuation in
            let alreadyCompleted = lock.withLock { () -> Bool in
                guard case .stopping = phase else { return true }
                stopWaiters.append(continuation)
                return false
            }
            if alreadyCompleted {
                continuation.resume()
            }
        }
    }

    private func canonicalHome() throws -> URL {
        guard home.isFileURL, !home.path.isEmpty, !home.path.contains("\0") else {
            throw Self.invalidHomeError
        }

        // `/var` is a legitimate symlink to `/private/var` on Darwin. Resolve
        // ancestors only, retain the final authority component, and let the
        // native openat walk reject any replacement or final-component link.
        let canonicalParent = home.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonicalHome = canonicalParent.appendingPathComponent(home.lastPathComponent)
        do {
            let values = try canonicalHome.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw Self.invalidHomeError
            }
            return canonicalHome
        } catch let error as ACPLeaderControlError {
            throw error
        } catch {
            throw ACPLeaderControlError(
                code: ACPLeaderControlErrorCode.artifactWriteFailed,
                message: "CPU profile state root is not an existing private directory: \(error)"
            )
        }
    }

    private static func validateOutput(_ output: String) throws {
        guard !output.isEmpty,
              output != ".",
              output != "..",
              !output.contains("\0"),
              !output.contains("/"),
              !output.contains("\\"),
              output.utf8.count <= 255,
              output.utf8.allSatisfy({ byte in
                  (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || (48...57).contains(byte)
                      || byte == 45
                      || byte == 46
                      || byte == 95
              })
        else {
            throw ACPLeaderControlError(
                code: ACPLeaderControlErrorCode.artifactWriteFailed,
                message: "CPU profile output must be one relative filename in the private profiles directory"
            )
        }
    }

    private static var unsupportedError: ACPLeaderControlError {
        ACPLeaderControlError(
            code: ACPLeaderControlErrorCode.unsupportedCommand,
            message: "runtime CPU profiling is not supported in this build"
        )
    }

    private static var invalidHomeError: ACPLeaderControlError {
        ACPLeaderControlError(
            code: ACPLeaderControlErrorCode.artifactWriteFailed,
            message: "CPU profile state root must be an existing non-symlink directory"
        )
    }

    private static func nativeBackend() -> Backend {
        Backend(
            isSupported: og_cpu_profile_supported() != 0,
            start: { home, output, frequency in
                var artifact = [CChar](repeating: 0, count: 4_096)
                let code: Int32 = home.withCString { homePointer in
                    if let output {
                        return output.withCString { outputPointer in
                            artifact.withUnsafeMutableBufferPointer { buffer in
                                og_cpu_profile_start(
                                    homePointer,
                                    outputPointer,
                                    frequency,
                                    buffer.baseAddress,
                                    buffer.count
                                )
                            }
                        }
                    }
                    return artifact.withUnsafeMutableBufferPointer { buffer in
                        og_cpu_profile_start(
                            homePointer,
                            nil,
                            frequency,
                            buffer.baseAddress,
                            buffer.count
                        )
                    }
                }
                guard code == 0 else {
                    throw nativeError(code)
                }
                return artifact.withUnsafeBufferPointer { buffer in
                    String(cString: buffer.baseAddress!)
                }
            },
            stop: {
                var sampleCount: UInt64 = 0
                let code = og_cpu_profile_stop(&sampleCount)
                guard code == 0 else {
                    throw nativeError(code)
                }
                return sampleCount
            }
        )
    }

    /// Native diagnostics are thread-local and must be copied immediately on
    /// the same thread as the failed start/stop call.
    private static func nativeError(_ code: Int32) -> ACPLeaderControlError {
        let details: String
        if let message = og_cpu_profile_last_error_message() {
            details = String(cString: message)
        } else {
            details = "native CPU profiler failed (\(code))"
        }

        let mapped: Int
        switch code {
        case 1:
            mapped = ACPLeaderControlErrorCode.unsupportedCommand
        case 2:
            mapped = ACPLeaderControlErrorCode.invalidFrequency
        case 3:
            mapped = ACPLeaderControlErrorCode.profileAlreadyActive
        case 4:
            mapped = ACPLeaderControlErrorCode.profileNotActive
        case 6:
            mapped = ACPLeaderControlErrorCode.outputPathCollision
        case 8:
            mapped = ACPLeaderControlErrorCode.internalError
        default:
            mapped = ACPLeaderControlErrorCode.artifactWriteFailed
        }
        return ACPLeaderControlError(code: mapped, message: details)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSSSSS'Z'"
        return formatter.string(from: Date())
    }
}
