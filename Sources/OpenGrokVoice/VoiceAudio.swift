import Foundation

public struct InputDeviceInfo: Codable, Equatable, Sendable {
    public let name: String
    public let detail: String

    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }
}

public protocol VoiceCaptureSession: Sendable {
    var pcm: AsyncThrowingStream<Data, Error> { get }
    func stop() async
}

public protocol VoiceAudioCapture: Sendable {
    func inputDeviceInfo() async throws -> InputDeviceInfo
    func start(sampleRate: UInt32) async throws -> any VoiceCaptureSession
}

public struct UnsupportedVoiceAudioCapture: VoiceAudioCapture {
    public let reason: String

    public init(reason: String = "no Foundation-only microphone adapter is configured") {
        self.reason = reason
    }

    public func inputDeviceInfo() async throws -> InputDeviceInfo {
        throw VoiceError.unsupported(capability: .microphoneCapture, reason: reason)
    }

    public func start(sampleRate _: UInt32) async throws -> any VoiceCaptureSession {
        throw VoiceError.unsupported(capability: .microphoneCapture, reason: reason)
    }
}

public struct SystemVoiceAudioCapture: VoiceAudioCapture {
    public let capabilities: VoiceCapabilities

    public init(capabilities: VoiceCapabilities = .detect()) {
        self.capabilities = capabilities
    }

    public func inputDeviceInfo() async throws -> InputDeviceInfo {
        #if os(Linux)
        guard capabilities.microphoneCapture, let recorder = capabilities.microphoneRecorder else {
            throw VoiceError.configuration(
                "no microphone recorder found on PATH: install pipewire (pw-record), pulseaudio-utils (parec), or alsa-utils (arecord)"
            )
        }
        return InputDeviceInfo(
            name: recorder,
            detail: "system recorder; uses the audio server's default input"
        )
        #else
        throw VoiceError.unsupported(
            capability: .microphoneCapture,
            reason: "input device lookup requires a platform adapter; AVFoundation and other audio frameworks are intentionally not linked"
        )
        #endif
    }

    public func start(sampleRate: UInt32) async throws -> any VoiceCaptureSession {
        #if os(Linux)
        guard capabilities.microphoneCapture, let recorder = capabilities.microphoneRecorder else {
            throw VoiceError.configuration(
                "no microphone recorder found on PATH: install pipewire (pw-record), pulseaudio-utils (parec), or alsa-utils (arecord)"
            )
        }
        return try await LinuxVoiceCaptureSession.start(
            recorder: recorder,
            sampleRate: sampleRate
        )
        #else
        throw VoiceError.unsupported(
            capability: .microphoneCapture,
            reason: "microphone capture requires a platform adapter; AVFoundation and other audio frameworks are intentionally not linked"
        )
        #endif
    }
}

public struct BufferedVoiceAudioCapture: VoiceAudioCapture {
    public let chunks: [Data]

    public init(chunks: [Data]) {
        self.chunks = chunks
    }

    public func inputDeviceInfo() async throws -> InputDeviceInfo {
        InputDeviceInfo(name: "buffered-test-input", detail: "deterministic PCM source")
    }

    public func start(sampleRate _: UInt32) async throws -> any VoiceCaptureSession {
        BufferedVoiceCaptureSession(chunks: chunks)
    }
}

public final class BufferedVoiceCaptureSession: VoiceCaptureSession, @unchecked Sendable {
    public let pcm: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    public init(chunks: [Data]) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.pcm = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }

    public func stop() async {
        continuation.finish()
    }
}

#if os(Linux)
private enum LinuxVoiceRecorder: String, CaseIterable, Sendable {
    case pipeWire = "pw-record"
    case pulseAudio = "parec"
    case alsa = "arecord"

    var arguments: (UInt32) -> [String] {
        switch self {
        case .pipeWire:
            return { rate in
                [
                    "--raw",
                    "--rate", String(rate),
                    "--channels", "1",
                    "--format", "s16",
                    "-"
                ]
            }
        case .pulseAudio:
            return { rate in
                [
                    "--raw",
                    "--format=s16le",
                    "--rate=\(rate)",
                    "--channels=1"
                ]
            }
        case .alsa:
            return { rate in
                [
                    "-q", "-t", "raw",
                    "-f", "S16_LE",
                    "-c", "1",
                    "-r", String(rate),
                    "-"
                ]
            }
        }
    }

    static func named(_ value: String) -> LinuxVoiceRecorder? {
        allCases.first { $0.rawValue == value }
    }
}

private final class LinuxVoiceCaptureSession: VoiceCaptureSession, @unchecked Sendable {
    let pcm: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var process: Process?
    private var reader: Task<Void, Never>?
    private var stopped = false

    private init(process: Process, output: FileHandle) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        pcm = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
        self.process = process
        reader = Task.detached { [weak self] in
            await self?.read(output: output)
        }
    }

    static func start(recorder name: String, sampleRate: UInt32) async throws -> LinuxVoiceCaptureSession {
        guard let recorder = LinuxVoiceRecorder.named(name),
              let executable = executableURL(named: recorder.rawValue) else {
            throw VoiceError.configuration("voice recorder \(name.debugDescription) is no longer executable")
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = recorder.arguments(sampleRate)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            try await voiceSleep(seconds: 0.3)
        } catch is CancellationError {
            terminate(process)
            throw VoiceError.cancelled
        } catch {
            terminate(process)
            throw VoiceError.configuration("failed to start \(name): \(error)")
        }

        guard process.isRunning else {
            process.waitUntilExit()
            throw VoiceError.configuration(
                "\(name) exited immediately with status \(process.terminationStatus)"
            )
        }
        return LinuxVoiceCaptureSession(process: process, output: output.fileHandleForReading)
    }

    func stop() async {
        let process: Process?
        let reader: Task<Void, Never>?
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        process = self.process
        self.process = nil
        reader = self.reader
        self.reader = nil
        lock.unlock()

        continuation.finish()
        if let process {
            terminate(process)
        }
        if let reader {
            await reader.value
        }
    }

    private func read(output: FileHandle) async {
        do {
            while !isStopped {
                guard let chunk = try output.read(upToCount: 2048), !chunk.isEmpty else {
                    break
                }
                if !isStopped {
                    continuation.yield(chunk)
                }
            }
            continuation.finish()
        } catch {
            if !isStopped {
                continuation.finish(throwing: VoiceError.configuration("microphone read failed: \(error)"))
            } else {
                continuation.finish()
            }
        }
        reapIfExited()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func reapIfExited() {
        lock.lock()
        let process = self.process
        lock.unlock()
        if let process, !process.isRunning {
            process.waitUntilExit()
        }
    }
}

private func executableURL(named name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func terminate(_ process: Process) {
    if process.isRunning {
        process.terminate()
    }
    process.waitUntilExit()
}
#endif
