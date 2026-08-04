import Foundation

public enum VoiceCapability: String, Codable, CaseIterable, Equatable, Sendable {
    case microphoneCapture
    case microphonePermission
    case transcription
    case playback
}

public struct VoiceCapabilities: Codable, Equatable, Sendable {
    public let microphoneCapture: Bool
    public let microphonePermission: Bool
    public let transcription: Bool
    public let playback: Bool
    public let microphoneRecorder: String?

    public init(
        microphoneCapture: Bool,
        microphonePermission: Bool,
        transcription: Bool,
        playback: Bool,
        microphoneRecorder: String? = nil
    ) {
        self.microphoneCapture = microphoneCapture
        self.microphonePermission = microphonePermission
        self.transcription = transcription
        self.playback = playback
        self.microphoneRecorder = microphoneRecorder
    }

    public var audioCaptureSupported: Bool {
        microphoneCapture && microphonePermission
    }

    public static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> VoiceCapabilities {
        #if os(Linux)
        let recorder = ["pw-record", "parec", "arecord"].first { executable in
            executableOnPath(executable, environment: environment, fileManager: fileManager)
        }
        return VoiceCapabilities(
            microphoneCapture: recorder != nil,
            microphonePermission: recorder != nil,
            transcription: true,
            playback: false,
            microphoneRecorder: recorder
        )
        #else
        return VoiceCapabilities(
            microphoneCapture: false,
            microphonePermission: false,
            transcription: true,
            playback: false
        )
        #endif
    }

    private static func executableOnPath(
        _ name: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> Bool {
        guard let path = environment["PATH"] else { return false }
        return path.split(separator: ":").contains { directory in
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            return fileManager.isExecutableFile(atPath: candidate.path)
        }
    }
}

public let AUDIO_SUPPORTED = VoiceCapabilities.detect().audioCaptureSupported
public let MIC_CAPTURE_SUBCOMMAND = "__mic-capture"

public enum VoiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case configuration(String)
    case transcription(String)
    case authentication(String)
    case webSocket(String)
    case unsupported(capability: VoiceCapability, reason: String)
    case cancelled
    case invalidState(expected: String, actual: String)

    public var description: String {
        switch self {
        case .configuration(let message): return "configuration: \(message)"
        case .transcription(let message): return "STT: \(message)"
        case .authentication(let message): return "auth: \(message)"
        case .webSocket(let message): return "WebSocket: \(message)"
        case .unsupported(let capability, let reason):
            return "unsupported \(capability.rawValue): \(reason)"
        case .cancelled: return "cancelled"
        case .invalidState(let expected, let actual):
            return "invalid state: expected \(expected), got \(actual)"
        }
    }
}

public protocol VoiceAuthProvider: Sendable {
    func bearer() async -> String?
}

public struct StaticVoiceAuth: VoiceAuthProvider, Sendable {
    private let value: String

    public init(_ key: String) {
        self.value = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func shared(_ key: String) -> StaticVoiceAuth? {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : StaticVoiceAuth(value)
    }

    public func bearer() async -> String? {
        value.isEmpty ? nil : value
    }
}

public func requireVoiceBearer(_ auth: any VoiceAuthProvider) async throws -> String {
    guard let bearer = await auth.bearer(), !bearer.isEmpty else {
        throw VoiceError.authentication(
            "not signed in — run `open-grok login` or set XAI_API_KEY"
        )
    }
    return bearer
}

func voiceSleep(seconds: TimeInterval) async throws {
    guard seconds.isFinite, seconds > 0 else {
        try Task.checkCancellation()
        return
    }
    let maximumSeconds = Double(UInt64.max) / 1_000_000_000
    let nanoseconds = UInt64(min(seconds, maximumSeconds) * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanoseconds)
}

public enum VoiceEvent: Equatable, Sendable {
    case interimTranscript(text: String)
    case utteranceFinal(text: String)
    case error(message: String, hint: String?)
}

public enum VoiceCommand: Equatable, Sendable {
    case pttPress
    case pttRelease
    case shutdown
}

public enum VoicePipelineState: Equatable, Sendable {
    case idle
    case starting
    case listening
    case stopping
    case failed(String)
}

public struct VoicePipelineSnapshot: Equatable, Sendable {
    public let state: VoicePipelineState
    public let generation: UInt64

    public init(state: VoicePipelineState, generation: UInt64) {
        self.state = state
        self.generation = generation
    }
}

public func maybeRunCaptureSubprocess(
    arguments: [String] = CommandLine.arguments,
    output: (String) -> Void = { _ in }
) -> Int? {
    guard arguments.dropFirst().first == MIC_CAPTURE_SUBCOMMAND else { return nil }
    output("ERR mic-capture helper unavailable in this build")
    return 2
}

public func micFixHelp() -> String {
    #if os(macOS)
    return "Allow microphone access for your terminal in System Settings → Privacy & Security → Microphone, then restart the terminal. If access is already on, check the input device and level in System Settings → Sound → Input."
    #elseif os(Windows)
    return "Allow microphone access in Settings → Privacy & security → Microphone, and check the input device and level in Settings → System → Sound."
    #else
    return "Check the default input device and its volume in your sound settings (for example, `pavucontrol` or `wpctl status` on PipeWire)."
    #endif
}
