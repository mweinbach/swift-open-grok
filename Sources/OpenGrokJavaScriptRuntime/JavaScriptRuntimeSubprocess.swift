import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum JavaScriptWorkerInbound: Codable, Sendable {
    case start(configuration: JavaScriptCellConfiguration, pendingMode: JavaScriptPendingMode)
    case command(JavaScriptRuntimeCommand)
    case control(JavaScriptRuntimeControlCommand)
}

enum JavaScriptWorkerOutbound: Codable, Sendable {
    case ready
    case startupFailure(String)
    case event(JavaScriptRuntimeEvent)
}

final class JavaScriptRuntimeSubprocess: @unchecked Sendable {
    static let workerFlag = "--open-grok-code-mode-worker"
    static let executableOverrideEnvironmentKey = "OPENGROK_CODE_MODE_WORKER_EXECUTABLE"

    private let process: Process
    private let input: FileHandle
    private let continuation: AsyncStream<JavaScriptRuntimeEvent>.Continuation
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var readBuffer = Data()
    private var startupError: JavaScriptRuntimeError?
    private var startupResolved = false
    private var finished = false
    private let ready = DispatchSemaphore(value: 0)

    private init(
        process: Process,
        input: FileHandle,
        continuation: AsyncStream<JavaScriptRuntimeEvent>.Continuation
    ) {
        self.process = process
        self.input = input
        self.continuation = continuation
    }

    static func workerExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> URL? {
        if let override = environment[executableOverrideEnvironmentKey], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override)
        {
            return URL(fileURLWithPath: override)
        }
        guard let first = arguments.first, !first.isEmpty else { return nil }
        let rawURL = URL(fileURLWithPath: first)
        let executable = rawURL.path.hasPrefix("/")
            ? rawURL.standardizedFileURL
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(first).standardizedFileURL
        let name = executable.lastPathComponent.lowercased()
        guard name == "open-grok" || name == "opengrokexecutable",
              FileManager.default.isExecutableFile(atPath: executable.path)
        else { return nil }
        return executable
    }

    static func start(
        executable: URL,
        configuration: JavaScriptCellConfiguration,
        pendingMode: JavaScriptPendingMode,
        continuation: AsyncStream<JavaScriptRuntimeEvent>.Continuation
    ) throws -> JavaScriptRuntimeSubprocess {
        let process = Process()
        process.executableURL = executable
        process.arguments = [workerFlag]
        process.standardError = FileHandle.nullDevice
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        let worker = JavaScriptRuntimeSubprocess(
            process: process,
            input: inputPipe.fileHandleForWriting,
            continuation: continuation
        )
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            worker.consume(handle.availableData)
        }
        process.terminationHandler = { _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            worker.finish()
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw JavaScriptRuntimeError.initializationFailed(
                "failed to launch isolated code mode worker: \(error)"
            )
        }
        worker.send(.start(configuration: configuration, pendingMode: pendingMode))
        guard worker.ready.wait(timeout: .now() + 5) == .success else {
            worker.terminate()
            throw JavaScriptRuntimeError.initializationFailed(
                "isolated code mode worker did not become ready"
            )
        }
        if let error = worker.readStartupError() {
            worker.terminate()
            throw error
        }
        return worker
    }

    func send(_ message: JavaScriptWorkerInbound) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try input.write(contentsOf: data + Data([0x0A]))
        } catch {
            finish()
        }
    }

    func terminate() {
        guard process.isRunning else {
            finish()
            return
        }
        process.terminate()
        #if os(Windows)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            if self.process.isRunning {
                self.process.terminate()
            }
        }
        #else
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            if self.process.isRunning {
                _ = kill(pid, SIGKILL)
            }
        }
        #endif
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        stateLock.lock()
        readBuffer.append(data)
        var lines: [Data] = []
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            lines.append(readBuffer[..<newline])
            readBuffer.removeSubrange(...newline)
        }
        stateLock.unlock()
        for line in lines where !line.isEmpty {
            guard let message = try? JSONDecoder().decode(JavaScriptWorkerOutbound.self, from: line) else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: JavaScriptWorkerOutbound) {
        switch message {
        case .ready:
            resolveStartup(nil)
        case .startupFailure(let message):
            resolveStartup(.initializationFailed(message))
        case .event(let event):
            continuation.yield(event)
        }
    }

    private func resolveStartup(_ error: JavaScriptRuntimeError?) {
        stateLock.lock()
        guard !startupResolved else {
            stateLock.unlock()
            return
        }
        startupResolved = true
        startupError = error
        stateLock.unlock()
        ready.signal()
    }

    private func readStartupError() -> JavaScriptRuntimeError? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return startupError
    }

    private func finish() {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        let mustResolveStartup = !startupResolved
        if mustResolveStartup {
            startupResolved = true
            startupError = .initializationFailed("isolated code mode worker exited during startup")
        }
        stateLock.unlock()
        try? input.close()
        continuation.finish()
        if mustResolveStartup { ready.signal() }
    }
}

public enum JavaScriptRuntimeWorkerMain {
    public static func runIfRequested(
        arguments: [String] = CommandLine.arguments
    ) async -> Int32? {
        guard arguments.dropFirst().first == JavaScriptRuntimeSubprocess.workerFlag else {
            return nil
        }
        guard let line = readLine(),
              let data = line.data(using: .utf8),
              let first = try? JSONDecoder().decode(JavaScriptWorkerInbound.self, from: data),
              case .start(let configuration, let pendingMode) = first
        else {
            write(.startupFailure("missing code mode worker start message"))
            return 2
        }
        let started: (runtime: JavaScriptCellRuntime, events: AsyncStream<JavaScriptRuntimeEvent>)
        do {
            started = try JavaScriptCellRuntime.startInProcess(
                configuration: configuration,
                pendingMode: pendingMode
            )
        } catch let error as JavaScriptRuntimeError {
            write(.startupFailure(error.message))
            return 2
        } catch {
            write(.startupFailure("\(error)"))
            return 2
        }
        write(.ready)
        let runtime = started.runtime
        let inputTask = Task.detached {
            while let line = readLine(), let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(JavaScriptWorkerInbound.self, from: data)
            {
                switch message {
                case .start:
                    continue
                case .command(let command):
                    runtime.send(command)
                case .control(let control):
                    runtime.sendControl(control)
                }
            }
            runtime.beginTermination()
        }
        for await event in started.events {
            write(.event(event))
        }
        inputTask.cancel()
        return 0
    }

    private static func write(_ message: JavaScriptWorkerOutbound) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
    }
}
