import Foundation
import OpenGrokPagerRender
import OpenGrokPTY
import OpenGrokShared
import OpenGrokTerminalCore
import OpenGrokTTY
import OpenGrokWebMediaTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct LiveWrapSpawnPlan: Sendable, Equatable {
    var executable: String
    var arguments: [String]
}

enum LiveWrapShellMode: Sendable, Equatable {
    case interactive
    case plain
}

struct LiveWrapExecutionDependencies: Sendable {
    var pty: any PTYAdapter
    var terminal: any TTYAdapter
    var interactive: @Sendable () -> Bool
    var writeOutput: @Sendable (Data) -> Void
    var writeError: @Sendable (Data) -> Void
    var writeClipboard: @Sendable (Data) async -> Void
    var readClipboardImage: @Sendable () async -> ClipboardImageData?
    var appearance: @Sendable () -> String?
    var input: Data?
    var forwardStandardInput: Bool

    static func live(
        environment: [String: String],
        streams: CLIStreams
    ) -> LiveWrapExecutionDependencies {
        let terminal = PlatformTTYAdapter(fd: 0)
        let interactive: @Sendable () -> Bool = {
            #if os(macOS) || os(Linux)
            isatty(STDIN_FILENO) != 0
                && isatty(STDOUT_FILENO) != 0
                && isatty(STDERR_FILENO) != 0
            #elseif os(Windows)
            PlatformTTYAdapter(fd: 0).isATTY()
                && PlatformTTYAdapter(fd: 1).isATTY()
                && PlatformTTYAdapter(fd: 2).isATTY()
            #else
            false
            #endif
        }
        return LiveWrapExecutionDependencies(
            pty: PlatformPTYAdapter(),
            terminal: terminal,
            interactive: interactive,
            writeOutput: { bytes in
                guard !bytes.isEmpty else { return }
                if let rawOutput = streams.rawOutput {
                    rawOutput(bytes)
                } else {
                    streams.out(String(decoding: bytes, as: UTF8.self))
                }
            },
            writeError: { bytes in
                guard !bytes.isEmpty else { return }
                if let rawError = streams.rawError {
                    rawError(bytes)
                } else {
                    streams.err(String(decoding: bytes, as: UTF8.self))
                }
            },
            writeClipboard: { data in
                guard let text = String(data: data, encoding: .utf8) else { return }
                try? await SystemClipboardProvider(environment: environment).write(.text(text))
            },
            readClipboardImage: {
                guard let image = try? await SystemClipboardProvider(environment: environment).readImage()
                else { return nil }
                return ClipboardImageData(data: image.data, mimeType: image.mimeType)
            },
            appearance: {
                switch PagerSystemAppearance.detect() {
                case .dark: "dark"
                case .light: "light"
                case nil: nil
                }
            },
            input: nil,
            forwardStandardInput: true
        )
    }
}

enum LiveWrapComposition {
    static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams
    ) async -> Int32 {
        await run(
            options: options,
            environment: environment,
            streams: streams,
            dependencies: .live(environment: environment, streams: streams)
        )
    }

    static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        dependencies: LiveWrapExecutionDependencies
    ) async -> Int32 {
        guard let first = options.values.first else {
            streams.err("open-grok wrap: no command given\n")
            return CLIRunner.ExitCode.usage.rawValue
        }

        let shell = resolveShell(environment["SHELL"])
        let available = executableAvailable(first, environment: environment)
        let wrapped = deriveSpawn(
            command: options.values,
            shell: shell,
            executableAvailable: available,
            mode: .interactive
        )
        let fallback = deriveSpawn(
            command: options.values,
            shell: shell,
            executableAvailable: available,
            mode: .plain
        )

        do {
            if dependencies.interactive() {
                do {
                    return try await runWrapped(
                        plan: wrapped,
                        environment: environment,
                        dependencies: dependencies
                    )
                } catch is CancellationError {
                    return CLIRunner.ExitCode.cancelled.rawValue
                } catch let error as PTYError where error == .cancelled {
                    return CLIRunner.ExitCode.cancelled.rawValue
                } catch {
                    guard !Task.isCancelled else {
                        return CLIRunner.ExitCode.cancelled.rawValue
                    }
                    streams.err(
                        "open-grok wrap: wrapped mode failed, running without PTY wrapping: \(error)\n"
                    )
                }
            }
            return try await runFallback(
                plan: fallback,
                environment: environment,
                dependencies: dependencies
            )
        } catch is CancellationError {
            return CLIRunner.ExitCode.cancelled.rawValue
        } catch {
            streams.err("open-grok wrap: failed to run \(fallback.executable): \(error)\n")
            return CLIRunner.ExitCode.failure.rawValue
        }
    }

    static func deriveSpawn(
        command: [String],
        shell: String,
        executableAvailable: Bool,
        mode: LiveWrapShellMode
    ) -> LiveWrapSpawnPlan {
        guard let first = command.first else {
            return LiveWrapSpawnPlan(executable: "", arguments: [])
        }

        #if os(Windows)
        return LiveWrapSpawnPlan(executable: first, arguments: Array(command.dropFirst()))
        #else
        let shellArguments: (String) -> [String] = { line in
            mode == .interactive ? ["-i", "-c", line] : ["-c", line]
        }

        if command.count == 1, first.contains(where: \.isWhitespace) {
            return LiveWrapSpawnPlan(executable: shell, arguments: shellArguments(first))
        }

        if !first.isEmpty,
           !first.contains("/"),
           !first.contains(where: \.isWhitespace),
           !executableAvailable {
            let quoted = ([first] + command.dropFirst().map(quoteShellWord)).joined(separator: " ")
            return LiveWrapSpawnPlan(executable: shell, arguments: shellArguments(quoted))
        }

        return LiveWrapSpawnPlan(executable: first, arguments: Array(command.dropFirst()))
        #endif
    }

    static func quoteShellWord(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func resolveShell(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "/bin/sh" }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &directory),
              !directory.boolValue
        else { return "/bin/sh" }
        return value
    }

    private static func executableAvailable(
        _ executable: String,
        environment: [String: String]
    ) -> Bool {
        guard !executable.isEmpty else { return false }
        if executable.contains("/") {
            return FileManager.default.isExecutableFile(atPath: executable)
        }
        let directories = (environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":", omittingEmptySubsequences: false)
        return directories.contains { directory in
            let root = directory.isEmpty ? "." : String(directory)
            return FileManager.default.isExecutableFile(atPath: "\(root)/\(executable)")
        }
    }

    private static func runWrapped(
        plan: LiveWrapSpawnPlan,
        environment: [String: String],
        dependencies: LiveWrapExecutionDependencies
    ) async throws -> Int32 {
        var childEnvironment = environment
        childEnvironment["GROK_OSC52_SINK"] = "1"
        childEnvironment["LC_GROK_OSC52_SINK"] = "1"
        if let appearance = dependencies.appearance() {
            childEnvironment["GROK_APPEARANCE"] = appearance
            childEnvironment["LC_GROK_APPEARANCE"] = appearance
        }

        let child = try await dependencies.pty.spawn(ProcessSpec(
            command: plan.executable,
            arguments: plan.arguments,
            environment: childEnvironment,
            usePTY: true,
            initialSize: dependencies.terminal.size()
        ))
        let lease: any RawModeLease
        do {
            lease = try await dependencies.terminal.enterRawMode()
        } catch {
            await child.cancel()
            throw error
        }

        let writer = LiveWrapChildWriter(child)
        let resize = LiveWrapResizePump(child: child)
        let tracker = LiveWrapTrackedModes()
        var input: LiveWrapInputPump?
        do {
            if dependencies.forwardStandardInput {
                input = try LiveWrapInputPump(writer: writer)
            }
            if let initialInput = dependencies.input, !initialInput.isEmpty {
                try await writer.write(initialInput)
            }
            let status = try await withTaskCancellationHandler {
                var filter = WrapOSC52Filter()
                for try await chunk in child.output() {
                    let output = filter.consume(chunk)
                    dependencies.writeOutput(output.passthrough)
                    for sequence in output.controlSequences {
                        tracker.observe(sequence)
                    }
                    for payload in output.clipboardPayloads {
                        await dependencies.writeClipboard(payload)
                    }
                    for _ in 0..<output.hostImageRequests {
                        let image = await dependencies.readClipboardImage()
                        var response = encodeWrapImageResponse(image: image)
                        response.append(0x0a)
                        try await writer.write(response)
                    }
                }
                try Task.checkCancellation()
                return try await child.waitForExit()
            } onCancel: {
                Task { await child.cancel() }
            }

            input?.cancel()
            resize.cancel()
            dependencies.writeOutput(tracker.restoreBytes)
            await lease.release()
            return exitCode(status)
        } catch {
            input?.cancel()
            resize.cancel()
            await child.cancel()
            dependencies.writeOutput(tracker.restoreBytes)
            await lease.release()
            throw error
        }
    }

    private static func runFallback(
        plan: LiveWrapSpawnPlan,
        environment: [String: String],
        dependencies: LiveWrapExecutionDependencies
    ) async throws -> Int32 {
        let process = Process()
        #if os(Windows)
        guard let executable = windowsExecutablePath(plan.executable, environment: environment) else {
            throw CLIApplicationError.failed("executable not found: \(plan.executable)")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = plan.arguments
        #else
        if plan.executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: plan.executable)
            process.arguments = plan.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [plan.executable] + plan.arguments
        }
        #endif
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = dependencies.input.map { _ in Pipe() }
        if let input {
            process.standardInput = input
        } else if dependencies.forwardStandardInput {
            process.standardInput = FileHandle.standardInput
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let outputDrain = LiveWrapPipeDrain(handle: output.fileHandleForReading, write: dependencies.writeOutput)
        let errorDrain = LiveWrapPipeDrain(handle: errors.fileHandleForReading, write: dependencies.writeError)
        let completion = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            let code = finished.terminationReason == .uncaughtSignal
                ? 128 + finished.terminationStatus
                : finished.terminationStatus
            completion.continuation.yield(code)
            completion.continuation.finish()
        }

        outputDrain.start()
        errorDrain.start()
        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            completion.continuation.finish()
            await outputDrain.finish()
            await errorDrain.finish()
            throw error
        }
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()

        if let input, let bytes = dependencies.input {
            let writer = input.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: bytes)
                try? writer.close()
            }
        }

        let cancellation = LiveWrapProcessCancellation(process)
        do {
            let status = try await withTaskCancellationHandler {
                var iterator = completion.stream.makeAsyncIterator()
                guard let code = await iterator.next() else {
                    throw CLIApplicationError.failed("wrapped child exited without a status")
                }
                try Task.checkCancellation()
                return code
            } onCancel: {
                cancellation.terminate()
            }
            await outputDrain.finish()
            await errorDrain.finish()
            return status
        } catch {
            await outputDrain.finish()
            await errorDrain.finish()
            throw error
        }
    }

    private static func exitCode(_ exit: ProcessExit) -> Int32 {
        switch exit {
        case .code(let code): code
        case .signal(let signal): 128 + signal
        case .stillRunning: CLIRunner.ExitCode.failure.rawValue
        }
    }

    #if os(Windows)
    private static func windowsExecutablePath(
        _ executable: String,
        environment: [String: String]
    ) -> String? {
        if executable.contains("/") || executable.contains("\\") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        let extensions = (environment["PATHEXT"] ?? ".COM;.EXE;.BAT;.CMD")
            .split(separator: ";")
            .map(String.init)
        for directory in (environment["PATH"] ?? "").split(separator: ";") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(executable)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            for suffix in extensions {
                let suffixed = candidate + suffix
                if FileManager.default.isExecutableFile(atPath: suffixed) { return suffixed }
            }
        }
        return nil
    }
    #endif
}

private actor LiveWrapChildWriter {
    private let child: any PTYProcess
    private var lastWrite: Task<Void, any Error>?

    init(_ child: any PTYProcess) {
        self.child = child
    }

    func write(_ bytes: Data) async throws {
        let previous = lastWrite
        let child = child
        let next = Task {
            if let previous {
                _ = try? await previous.value
            }
            try await child.write(bytes)
        }
        lastWrite = next
        try await next.value
    }
}

private final class LiveWrapTrackedModes: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = WrapTerminalModeTracker()

    func observe(_ sequence: Data) {
        lock.lock()
        tracker.observe(sequence)
        lock.unlock()
    }

    var restoreBytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return tracker.restoreBytes
    }
}

private final class LiveWrapProcessCancellation: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

private final class LiveWrapPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let write: @Sendable (Data) -> Void
    private let completion = DispatchGroup()

    init(handle: FileHandle, write: @escaping @Sendable (Data) -> Void) {
        self.handle = handle
        self.write = write
    }

    func start() {
        completion.enter()
        let thread = Thread { [self] in
            defer { completion.leave() }
            while let bytes = try? handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
                write(bytes)
            }
        }
        thread.name = "open-grok.wrap.output"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            let deadline = LiveWrapDrainDeadline(handle: handle, continuation: continuation)
            completion.notify(queue: .global(qos: .userInitiated)) {
                deadline.complete(close: false)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                deadline.complete(close: true)
            }
        }
    }
}

private final class LiveWrapDrainDeadline: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(handle: FileHandle, continuation: CheckedContinuation<Void, Never>) {
        self.handle = handle
        self.continuation = continuation
    }

    func complete(close: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        if close {
            try? handle.close()
        }
        continuation.resume()
    }
}

private final class LiveWrapResizePump: @unchecked Sendable {
    #if os(macOS) || os(Linux)
    private let monitor: PlatformTerminalResizeMonitor
    private let task: Task<Void, Never>

    init(child: any PTYProcess) {
        let monitor = PlatformTerminalResizeMonitor(fd: STDOUT_FILENO)
        self.monitor = monitor
        let events = monitor.events()
        self.task = Task {
            for await size in events {
                do {
                    try await child.resize(to: size)
                } catch {
                    break
                }
            }
        }
    }

    func cancel() {
        monitor.stop()
        task.cancel()
    }
    #else
    init(child: any PTYProcess) {
        _ = child
    }

    func cancel() {}
    #endif
}

private final class LiveWrapInputPump: @unchecked Sendable {
    #if os(macOS) || os(Linux)
    private let source: any DispatchSourceRead
    private let continuation: AsyncStream<Data>.Continuation
    private let task: Task<Void, Never>

    init(writer: LiveWrapChildWriter) throws {
        let stream = AsyncStream<Data>.makeStream()
        continuation = stream.continuation
        task = Task {
            for await bytes in stream.stream {
                do {
                    try await writer.write(bytes)
                } catch {
                    break
                }
            }
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: STDIN_FILENO,
            queue: DispatchQueue(label: "open-grok.wrap.stdin")
        )
        self.source = source
        let continuation = stream.continuation
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(STDIN_FILENO, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                continuation.yield(Data(buffer.prefix(count)))
            } else {
                continuation.finish()
            }
        }
        source.resume()
    }

    func cancel() {
        source.cancel()
        continuation.finish()
        task.cancel()
    }
    #elseif os(Windows)
    private let input: PlatformTerminalInput
    private let task: Task<Void, Never>

    init(writer: LiveWrapChildWriter) throws {
        let input = try PlatformTerminalInput(fd: 0, swallowXtversionReply: false)
        self.input = input
        self.task = Task {
            do {
                while !Task.isCancelled, let byte = try await input.readByte() {
                    try await writer.write(Data([byte]))
                }
            } catch {
                await input.close()
            }
        }
    }

    func cancel() {
        task.cancel()
        Task { await input.close() }
    }
    #else
    init(writer: LiveWrapChildWriter) throws {
        _ = writer
    }

    func cancel() {}
    #endif
}
