import Foundation
import OpenGrokConfig
import OpenGrokTTY
import OpenGrokWorkflow

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LiveWorkflowGitDiff {
    static let timeoutSeconds: TimeInterval = 20
    static let maximumOutputBytes = 256 * 1024
    static let truncationMarker = "\n… [diff truncated]"

    static func run(_ commit: String, _ workingDirectory: URL) async throws -> String {
        try await run(
            commit,
            workingDirectory,
            environment: ProcessInfo.processInfo.environment,
            timeout: timeoutSeconds
        )
    }

    static func run(
        _ commit: String,
        _ workingDirectory: URL,
        environment: [String: String],
        timeout: TimeInterval = timeoutSeconds
    ) async throws -> String {
        guard !commit.isEmpty,
              commit.utf8.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
              })
        else {
            throw RhaiHostError.failed("git_diff_since expects a commit hash, got: \(commit)")
        }
        guard !Task.isCancelled else { throw RhaiHostError.cancelled }

        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, sessionValue in sessionValue }
        processEnvironment.merge(pagerEnvironment()) { _, safeValue in safeValue }
        guard let executable = resolveExecutablePath("git", environment: processEnvironment) else {
            throw RhaiHostError.failed("git diff: git executable was not found on PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["diff", commit]
        process.currentDirectoryURL = workingDirectory.standardizedFileURL
        process.environment = processEnvironment
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let execution = LiveWorkflowGitExecution(
            process: process,
            stdout: stdout,
            stderr: stderr,
            timeout: timeout
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }

    fileprivate static func boundedOutput(_ data: Data, overflowed: Bool) -> String {
        let decoded = String(decoding: data, as: UTF8.self)
        let normalized = Data(decoded.utf8)
        guard overflowed || normalized.count > maximumOutputBytes else { return decoded }

        var prefix = normalized.prefix(maximumOutputBytes)
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix = prefix.dropLast()
        }
        return String(decoding: prefix, as: UTF8.self) + truncationMarker
    }
}

private final class LiveWorkflowGitCapture: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var bytes = Data()
    private var overflowed = false
    private var failure: String?

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - bytes.count)
        if remaining > 0 {
            bytes.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            overflowed = true
        }
    }

    func failed(_ error: any Error) {
        lock.lock()
        failure = String(describing: error)
        lock.unlock()
    }

    func snapshot() -> (data: Data, overflowed: Bool, failure: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (bytes, overflowed, failure)
    }
}

/// Owns child termination, two simultaneous bounded pipe drains, and exactly
/// one continuation completion across launch/exit/deadline/cancellation races.
private final class LiveWorkflowGitExecution: @unchecked Sendable {
    private let process: Process
    private let stdout: Pipe
    private let stderr: Pipe
    private let timeout: TimeInterval
    private let stdoutCapture = LiveWorkflowGitCapture(
        limit: LiveWorkflowGitDiff.maximumOutputBytes + 4
    )
    private let stderrCapture = LiveWorkflowGitCapture(limit: 64 * 1024)
    private let drains = DispatchGroup()
    private let lock = NSLock()

    private var continuation: CheckedContinuation<String, any Error>?
    private var timeoutItem: DispatchWorkItem?
    private var completed = false
    private var cancellationRequested = false

    init(process: Process, stdout: Pipe, stderr: Pipe, timeout: TimeInterval) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
        self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<String, any Error>) {
        lock.lock()
        if cancellationRequested {
            completed = true
            lock.unlock()
            continuation.resume(throwing: RhaiHostError.cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()

        process.terminationHandler = { [weak self] process in
            self?.terminated(status: process.terminationStatus)
        }
        drain(stdout.fileHandleForReading, into: stdoutCapture)
        drain(stderr.fileHandleForReading, into: stderrCapture)

        lock.lock()
        let shouldLaunch = !completed && !cancellationRequested
        lock.unlock()
        guard shouldLaunch else {
            closeWriteHandles()
            return
        }

        do {
            try process.run()
        } catch {
            closeWriteHandles()
            finish(.failure(.failed("git diff: \(error)")), terminate: false)
            return
        }
        closeWriteHandles()

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.failed("git diff timed out")), terminate: true)
        }
        lock.lock()
        if completed {
            lock.unlock()
            terminateProcess()
            timeoutItem.cancel()
            return
        }
        self.timeoutItem = timeoutItem
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, timeout),
            execute: timeoutItem
        )
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let hasContinuation = continuation != nil
        lock.unlock()
        if hasContinuation {
            finish(.failure(.cancelled), terminate: true)
        }
    }

    private func drain(_ handle: FileHandle, into capture: LiveWorkflowGitCapture) {
        drains.enter()
        DispatchQueue.global(qos: .utility).async { [drains] in
            defer {
                try? handle.close()
                drains.leave()
            }
            do {
                while let data = try handle.read(upToCount: 16 * 1024), !data.isEmpty {
                    capture.append(data)
                }
            } catch {
                capture.failed(error)
            }
        }
    }

    private func closeWriteHandles() {
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }

    private func terminated(status: Int32) {
        drains.notify(queue: .global(qos: .utility)) { [weak self] in
            guard let self else { return }
            let standardOutput = self.stdoutCapture.snapshot()
            let standardError = self.stderrCapture.snapshot()
            if let failure = standardOutput.failure ?? standardError.failure {
                self.finish(.failure(.failed("git diff: \(failure)")), terminate: false)
                return
            }
            if status != 0 {
                let errorText = String(decoding: standardError.data, as: UTF8.self)
                self.finish(
                    .failure(.failed("git diff exited with \(status): \(errorText)")),
                    terminate: false
                )
                return
            }
            let text = LiveWorkflowGitDiff.boundedOutput(
                standardOutput.data,
                overflowed: standardOutput.overflowed
            )
            self.finish(.success(text), terminate: false)
        }
    }

    private func finish(_ result: Result<String, RhaiHostError>, terminate: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let pending = continuation
        continuation = nil
        let timer = timeoutItem
        timeoutItem = nil
        lock.unlock()

        timer?.cancel()
        if terminate {
            terminateProcess()
        }
        pending?.resume(with: result.mapError { $0 as any Error })
    }

    private func terminateProcess() {
        guard process.isRunning else { return }
        #if os(Windows)
        process.terminate()
        #else
        kill(process.processIdentifier, SIGKILL)
        #endif
    }
}
