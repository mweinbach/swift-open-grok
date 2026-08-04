import Foundation
import OpenGrokHTTP

public enum VoiceAudioEncoding: String, Codable, Equatable, Sendable {
    case pcm16LittleEndian = "pcm_s16le"
}

public struct VoiceAudioFormat: Codable, Equatable, Sendable {
    public let sampleRate: UInt32
    public let channels: UInt16
    public let encoding: VoiceAudioEncoding

    public init(
        sampleRate: UInt32 = DEFAULT_SAMPLE_RATE,
        channels: UInt16 = 1,
        encoding: VoiceAudioEncoding = .pcm16LittleEndian
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
    }
}

public struct VoiceTranscriptionRequest: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let format: VoiceAudioFormat

    public init(url: URL, headers: [String: String], format: VoiceAudioFormat) {
        self.url = url
        self.headers = headers
        self.format = format
    }

    public var audioDoneMessage: WebSocketMessage {
        .text("{\"type\":\"audio.done\"}")
    }
}

public enum SttServerEvent: Equatable, Sendable {
    case created
    case partial(text: String, isFinal: Bool, speechFinal: Bool)
    case done(text: String, duration: Double?)
    case error(message: String)
    case unknown

    public static func decode(_ data: Data) throws -> SttServerEvent {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw VoiceError.transcription("invalid STT event JSON: \(error)")
        }
        guard let dictionary = object as? [String: Any], let type = dictionary["type"] as? String else {
            throw VoiceError.transcription("STT event is not an object")
        }
        switch type {
        case "transcript.created":
            return .created
        case "transcript.partial":
            return .partial(
                text: dictionary["text"] as? String ?? "",
                isFinal: dictionary["is_final"] as? Bool ?? false,
                speechFinal: dictionary["speech_final"] as? Bool ?? false
            )
        case "transcript.done":
            return .done(
                text: dictionary["text"] as? String ?? "",
                duration: (dictionary["duration"] as? NSNumber)?.doubleValue
            )
        case "error":
            return .error(message: dictionary["message"] as? String ?? "")
        default:
            return .unknown
        }
    }
}

public struct SttTranscriptPartial: Equatable, Sendable {
    public let text: String
    public let isFinal: Bool
    public let speechFinal: Bool

    public init(text: String, isFinal: Bool, speechFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
        self.speechFinal = speechFinal
    }
}

public enum StreamingSttEvent: Equatable, Sendable {
    case ready
    case partial(SttTranscriptPartial)
    case done(text: String)
    case error(message: String)
}

public protocol VoiceTranscriptionSession: Sendable {
    func sendAudio(_ chunk: Data) async throws
    func receive() async throws -> StreamingSttEvent?
    func finishAudio() async throws
    func cancel() async
}

public protocol VoiceTranscriptionTransport: Sendable {
    func connect(request: VoiceTranscriptionRequest) async throws -> any VoiceTranscriptionSession
}

public struct UnsupportedVoiceTranscriptionTransport: VoiceTranscriptionTransport {
    public let reason: String

    public init(reason: String = "no WebSocket transcription adapter is configured") {
        self.reason = reason
    }

    public func connect(request _: VoiceTranscriptionRequest) async throws -> any VoiceTranscriptionSession {
        throw VoiceError.unsupported(capability: .transcription, reason: reason)
    }
}

public actor URLSessionVoiceTranscriptionSession: VoiceTranscriptionSession {
    private let client: any WebSocketClient
    private var finished = false

    public init(client: any WebSocketClient) {
        self.client = client
    }

    public func sendAudio(_ chunk: Data) async throws {
        guard !finished else { throw VoiceError.invalidState(expected: "open", actual: "finished") }
        try Task.checkCancellation()
        try await client.send(.data(chunk))
    }

    public func receive() async throws -> StreamingSttEvent? {
        while true {
            do {
                try Task.checkCancellation()
                let message = try await client.receive()
                guard case .text(let text) = message else { continue }
                guard let data = text.data(using: .utf8) else {
                    throw VoiceError.transcription("STT event was not UTF-8")
                }
                switch try SttServerEvent.decode(data) {
                case .created:
                    return .ready
                case .partial(let text, let isFinal, let speechFinal):
                    return .partial(SttTranscriptPartial(text: text, isFinal: isFinal, speechFinal: speechFinal))
                case .done(let text, _):
                    return .done(text: text)
                case .error(let message):
                    return .error(message: message)
                case .unknown:
                    continue
                }
            } catch is CancellationError {
                throw VoiceError.cancelled
            } catch let error as VoiceError {
                throw error
            } catch {
                throw VoiceError.webSocket("receive: \(error)")
            }
        }
    }

    public func finishAudio() async throws {
        guard !finished else { return }
        try Task.checkCancellation()
        try await client.send(.text("{\"type\":\"audio.done\"}"))
        finished = true
    }

    public func cancel() async {
        finished = true
        await client.close(code: 1000, reason: "voice session cancelled")
    }
}

public struct URLSessionVoiceTranscriptionTransport: VoiceTranscriptionTransport {
    public init() {}

    public func connect(request: VoiceTranscriptionRequest) async throws -> any VoiceTranscriptionSession {
        do {
            let client = try URLSessionWebSocketClient.connect(
                url: request.url,
                headers: request.headers
            )
            let session = URLSessionVoiceTranscriptionSession(client: client)
            guard let event = try await withVoiceTimeout(
                10,
                timeoutError: VoiceError.transcription("timed out waiting for transcript.created"),
                operation: {
                    try await session.receive()
                }
            ) else {
                await session.cancel()
                throw VoiceError.transcription("STT connection closed before transcript.created")
            }
            switch event {
            case .ready:
                return session
            case .error(let message):
                await session.cancel()
                throw VoiceError.transcription(message)
            case .partial, .done:
                await session.cancel()
                throw VoiceError.transcription("unexpected STT event before transcript.created")
            }
        } catch let error as VoiceError {
            throw error
        } catch is CancellationError {
            throw VoiceError.cancelled
        } catch {
            throw VoiceError.webSocket("connect: \(error)")
        }
    }
}

private func withVoiceTimeout<Value: Sendable>(
    _ timeout: TimeInterval,
    timeoutError: VoiceError,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await voiceSleep(seconds: timeout)
            throw timeoutError
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw VoiceError.transcription("timed out waiting for STT response")
        }
        return value
    }
}
