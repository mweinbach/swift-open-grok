import Foundation
import OpenGrokAuth
import OpenGrokHTTP
import Testing
@testable import OpenGrokCLI
import OpenGrokVoice

@Suite("Live voice command wiring")
struct LiveVoiceCommandTests {
    @Test("/voice toggle reports unavailable without capability")
    func voiceUnavailableWithoutCapability() async {
        var state = LiveVoiceSessionState(
            capabilities: LiveVoiceCapabilities(
                detected: VoiceCapabilities(
                    microphoneCapture: false,
                    microphonePermission: false,
                    transcription: true,
                    playback: false
                )
            )
        )
        let result = await LiveVoiceCommands.toggle(state: &state)
        guard case .unavailable = result.action else {
            Issue.record("expected unavailable action, got \(result.action)")
            return
        }
        #expect(result.message?.isEmpty == false)
        #expect(!state.isListening)
        #expect(state.pipeline == nil)
    }

    @Test("/voice toggle starts and stops with injected capture")
    func voiceToggleWithInjectedPipeline() async {
        let capabilities = LiveVoiceCapabilities(
            detected: VoiceCapabilities(
                microphoneCapture: true,
                microphonePermission: true,
                transcription: true,
                playback: false
            )
        )
        var state = LiveVoiceSessionState(capabilities: capabilities)
        state.pipeline = LiveVoicePipelineHandle(
            auth: StaticVoiceAuth("test-key"),
            capture: BufferedVoiceAudioCapture(chunks: [])
        )

        let started = await LiveVoiceCommands.toggle(state: &state)
        #expect(started.action == .startedListening)
        #expect(state.isListening)

        let stopped = await LiveVoiceCommands.toggle(state: &state)
        #expect(stopped.action == .stoppedListening)
        #expect(!state.isListening)
    }

    @Test("voice reuses the session's stored OAuth credential and follows rotation")
    func voiceAuthUsesStoredOAuthAndFollowsRotation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-voice-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = ["HOME": root.path, "OPENGROK_HOME": root.path]
        let manager = AuthManager(grokHome: root, environment: environment)
        try await manager.loginWithSession(GrokAuth(
            key: "session-oauth-first",
            authMode: .oidc,
            expiresAt: Date().addingTimeInterval(3_600)
        ))

        let auth = LiveVoiceAuth(openGrokHome: root, environment: environment)
        #expect(await auth.bearer() == "session-oauth-first")

        try await manager.loginWithSession(GrokAuth(
            key: "session-oauth-rotated",
            authMode: .oidc,
            expiresAt: Date().addingTimeInterval(3_600)
        ))
        #expect(await auth.bearer() == "session-oauth-rotated")

        let capabilities = LiveVoiceCapabilities(
            detected: VoiceCapabilities(
                microphoneCapture: true,
                microphonePermission: true,
                transcription: true,
                playback: false
            )
        )
        var state = LiveVoiceSessionState(capabilities: capabilities, auth: auth)
        let started = await LiveVoiceCommands.toggle(
            state: &state,
            capture: BufferedVoiceAudioCapture(chunks: []),
            transcription: UnsupportedVoiceTranscriptionTransport(reason: "test fixture")
        )
        #expect(started.action == .startedListening)
        #expect(state.pipeline != nil)
        await state.pipeline?.shutdown()
    }

    @Test("voice credentials never escape their owner home or injected environment")
    func voiceAuthIsSessionIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-voice-isolation-\(UUID().uuidString)",
            isDirectory: true
        )
        let owner = root.appendingPathComponent("owner", isDirectory: true)
        let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownerEnvironment = ["HOME": owner.path, "OPENGROK_HOME": owner.path]
        let unrelatedEnvironment = ["HOME": unrelated.path, "OPENGROK_HOME": unrelated.path]
        let manager = AuthManager(grokHome: owner, environment: ownerEnvironment)
        try await manager.loginWithSession(GrokAuth(
            key: "owner-only-oauth",
            authMode: .oidc,
            expiresAt: Date().addingTimeInterval(3_600)
        ))

        let ownerAuth = LiveVoiceAuth(openGrokHome: owner, environment: ownerEnvironment)
        let unrelatedAuth = LiveVoiceAuth(openGrokHome: unrelated, environment: unrelatedEnvironment)
        let scopedAPIKeyAuth = LiveVoiceAuth(
            openGrokHome: unrelated,
            environment: unrelatedEnvironment.merging(
                ["XAI_API_KEY": "session-scoped-api-key"],
                uniquingKeysWith: { _, scoped in scoped }
            )
        )

        #expect(await ownerAuth.bearer() == "owner-only-oauth")
        #expect(await unrelatedAuth.bearer() == nil)
        #expect(await scopedAPIKeyAuth.bearer() == "session-scoped-api-key")

        var deniedState = LiveVoiceSessionState(
            capabilities: LiveVoiceCapabilities(
                detected: VoiceCapabilities(
                    microphoneCapture: true,
                    microphonePermission: true,
                    transcription: true,
                    playback: false
                )
            ),
            auth: unrelatedAuth
        )
        let result = await LiveVoiceCommands.toggle(state: &deniedState)
        #expect(result.action == .unavailable(reason: "not signed in"))
        #expect(deniedState.pipeline == nil)
    }

    @Test("settings keys stay hidden until voice is live")
    func settingsHiddenUntilLive() {
        let unavailable = LiveVoiceCapabilities(
            detected: VoiceCapabilities(
                microphoneCapture: false,
                microphonePermission: false,
                transcription: true,
                playback: false
            )
        )
        let hidden = LiveVoiceCapabilities.hiddenSettingsKeys(when: unavailable)
        #expect(hidden == Set(LiveVoiceCapabilities.settingsKeys))

        let available = LiveVoiceCapabilities(
            detected: VoiceCapabilities(
                microphoneCapture: true,
                microphonePermission: true,
                transcription: true,
                playback: false
            )
        )
        #expect(LiveVoiceCapabilities.hiddenSettingsKeys(when: available).isEmpty)
    }

    @Test("voice finals append into the prompt box")
    func voiceFinalsAppendIntoPrompt() {
        var prompt = "hello"
        var interim = "world"
        let redraw = LiveVoiceEventHandling.apply(
            .utteranceFinal(text: "world"),
            interim: &interim,
            prompt: &prompt
        )
        #expect(redraw)
        #expect(prompt == "hello world")
        #expect(interim.isEmpty)
    }
}

@Suite("Live voice WebSocket transport", .serialized)
struct LiveVoiceWebSocketTransportTests {
    @Test("transcription dials the portable client and carries authenticated audio", .timeLimit(.minutes(1)))
    func liveWebSocketTranscription() async throws {
        let server = WebSocketServer(
            configuration: WebSocketServerConfiguration(
                host: "127.0.0.1",
                port: 0,
                policy: WebSocketUpgradePolicy(path: "/v1/stt")
            )
        )
        let port = try await server.start()
        let serving = Task<(String?, String?, WebSocketMessage?, WebSocketMessage?), Error> {
            for await accepted in await server.connections {
                try await accepted.connection.send(
                    .text("{\"type\":\"transcript.created\"}")
                )
                let audio = try await accepted.connection.receive()
                try await accepted.connection.send(
                    .text("{\"type\":\"transcript.partial\",\"text\":\"hello\"}")
                )
                let finished = try await accepted.connection.receive()
                return (
                    accepted.request.bearerToken,
                    accepted.request.header("x-grok-client-identifier"),
                    audio,
                    finished
                )
            }
            throw VoiceError.transcription("test server closed before the voice handshake")
        }
        defer {
            serving.cancel()
            Task { await server.stop() }
        }

        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/v1/stt?sample_rate=16000"))
        let request = VoiceTranscriptionRequest(
            url: url,
            headers: [
                "Authorization": "Bearer session-private-token",
                "x-grok-client-identifier": "voice-parity",
            ],
            format: VoiceAudioFormat()
        )
        let session = try await URLSessionVoiceTranscriptionTransport().connect(request: request)
        let audio = Data([0x01, 0x02, 0x03, 0x04])
        try await session.sendAudio(audio)

        #expect(try await session.receive() == .partial(
            SttTranscriptPartial(text: "hello", isFinal: false, speechFinal: false)
        ))
        try await session.finishAudio()

        let observed = try await serving.value
        #expect(observed.0 == "session-private-token")
        #expect(observed.1 == "voice-parity")
        #expect(observed.2 == .data(audio))
        #expect(observed.3 == .text("{\"type\":\"audio.done\"}"))
        await session.cancel()
        await server.stop()
    }

    @Test("transcription refuses header injection and reserved upgrade fields")
    func unsafeHandshakeHeadersAreRejected() async throws {
        let url = try #require(URL(string: "ws://127.0.0.1:9/v1/stt"))
        let invalidHeaders: [[String: String]] = [
            ["Authorization": "Bearer safe\r\nInjected: hostile"],
            ["Bad\r\nInjected": "hostile"],
            ["Host": "attacker.example"],
            ["Sec-WebSocket-Key": "attacker-controlled"],
        ]

        for headers in invalidHeaders {
            let request = VoiceTranscriptionRequest(
                url: url,
                headers: headers,
                format: VoiceAudioFormat()
            )
            do {
                _ = try await URLSessionVoiceTranscriptionTransport().connect(request: request)
                Issue.record("unsafe voice WebSocket header was accepted")
            } catch let error as VoiceError {
                guard case .configuration(let message) = error else {
                    Issue.record("expected a configuration refusal, got \(error)")
                    continue
                }
                #expect(message == "invalid WebSocket transcription request header")
                #expect(!message.contains("hostile"))
            }
        }
    }
}

private struct BufferedVoiceAudioCapture: VoiceAudioCapture {
    let chunks: [Data]

    func inputDeviceInfo() async throws -> InputDeviceInfo {
        InputDeviceInfo(name: "buffered", detail: "test")
    }

    func start(sampleRate _: UInt32) async throws -> any VoiceCaptureSession {
        BufferedVoiceCaptureSession(chunks: chunks)
    }
}

private final class BufferedVoiceCaptureSession: VoiceCaptureSession, @unchecked Sendable {
    let pcm: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(chunks: [Data]) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        pcm = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()
    }

    func stop() async {
        continuation.finish()
    }
}
