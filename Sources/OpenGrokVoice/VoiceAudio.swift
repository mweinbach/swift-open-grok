import Foundation

#if canImport(Glibc)
import Glibc
#endif

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
        #elseif os(macOS)
        guard capabilities.microphoneCapture else {
            throw VoiceError.unsupported(
                capability: .microphoneCapture,
                reason: "microphone capture helper is unavailable for this executable"
            )
        }
        return try await MicCaptureSubprocess.inputDeviceInfo()
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
        #elseif os(macOS)
        guard capabilities.microphoneCapture else {
            throw VoiceError.unsupported(
                capability: .microphoneCapture,
                reason: "microphone capture helper is unavailable for this executable"
            )
        }
        return try await MicCaptureSubprocess.startCapture(sampleRate: sampleRate)
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
            // No `waitUntilExit()` here: `isRunning == false` means Foundation
            // already reaped the child, so `terminationStatus` is final and the
            // wait would park on a spent notification (AGENTS.md §2).
            throw VoiceError.configuration(
                "\(name) exited immediately with status \(process.terminationStatus)"
            )
        }
        return LinuxVoiceCaptureSession(process: process, output: output.fileHandleForReading)
    }

    /// Claim the stop transition and hand back what needs tearing down, all in
    /// one synchronous critical section. Separate from `stop()` because
    /// `NSLock.lock()` is `noasync` on swift-corelibs-foundation — and the
    /// section must not span an await regardless.
    private func claimStop() -> (process: Process?, reader: Task<Void, Never>?)? {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return nil }
        stopped = true
        let claimedProcess = process
        process = nil
        let claimedReader = reader
        reader = nil
        return (claimedProcess, claimedReader)
    }

    func stop() async {
        guard let claimed = claimStop() else { return }

        continuation.finish()
        if let process = claimed.process {
            terminate(process)
        }
        if let reader = claimed.reader {
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

    /// Drop the reference to a recorder that has already exited.
    ///
    /// Deliberately does not call `waitUntilExit()`: `isRunning == false` means
    /// Foundation already observed and reaped the child, and waiting on a
    /// process whose death notification is already spent parks the calling
    /// thread's run loop forever (AGENTS.md §2).
    private func reapIfExited() {
        lock.lock()
        defer { lock.unlock() }
        if let process, !process.isRunning {
            self.process = nil
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

/// Signal the recorder and wait, bounded, for it to go away.
///
/// Polls `isRunning` rather than calling `waitUntilExit()`: the recorder
/// usually dies before we get here, and waiting on an already-spent death
/// notification never returns (AGENTS.md §2). A recorder that ignores SIGTERM
/// gets SIGKILL; either way this returns.
private func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(2.0)
    while process.isRunning, Date() < deadline {
        usleep(5_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(1.0)
        while process.isRunning, Date() < killDeadline {
            usleep(5_000)
        }
    }
}
#endif
