import Foundation
import Testing
@testable import OpenGrokVoice

@Suite("Open Grok voice configuration")
struct VoiceConfigurationTests {
    @Test("defaults build the secure STT endpoint")
    func defaultsBuildSecureEndpoint() throws {
        let config = VoiceConfig()
        #expect(try config.sttWebSocketURL().absoluteString == "wss://api.x.ai/v1/stt")
        let request = try config.makeTranscriptionRequest(bearer: "sk-test")
        #expect(request.url.scheme == "wss")
        #expect(request.url.query?.contains("sample_rate=16000") == true)
        #expect(request.url.query?.contains("encoding=pcm") == true)
        #expect(request.url.query?.contains("language=en") == true)
        #expect(request.headers["Authorization"] == "Bearer sk-test")
        #expect(request.audioDoneMessage == .text("{\"type\":\"audio.done\"}"))
    }

    @Test("rejects plaintext endpoints and deduplicates v1")
    func rejectsPlaintextAndDeduplicatesV1() throws {
        let proxy = VoiceConfig(apiBase: "https://proxy.example.com/xai/v1")
        #expect(try proxy.sttWebSocketURL().absoluteString == "wss://proxy.example.com/xai/v1/stt")

        for base in ["http://localhost:8080", "Ws://localhost:8080"] {
            let insecure = VoiceConfig(apiBase: base)
            #expect(throws: VoiceError.self) {
                try insecure.sttWebSocketURL()
            }
        }
    }

    @Test("configuration precedence ignores identity spoofing")
    func configurationPrecedence() throws {
        let root = [
            "endpoints": ["xai_api_base_url": "https://config.example/v1"],
            "voice": [
                "api_base": " ",
                "language": "es",
                "client_identifier": "spoofed",
                "sample_rate": "8000"
            ]
        ]
        let config = VoiceConfig.fromConfigTable(root, resolvedEndpointsBase: "https://env.example")
        #expect(config.apiBase == "https://config.example/v1")
        #expect(config.language == "es")
        #expect(config.sampleRate == 8000)
        #expect(config.clientIdentifier.isEmpty)
        #expect(config.userAgent.isEmpty)
        #expect(config.sttWebSocketPath == "/v1/stt")
    }

    @Test("invalid bearer is rejected before request construction")
    func invalidBearer() {
        let config = VoiceConfig()
        #expect(throws: VoiceError.self) {
            try config.makeTranscriptionRequest(bearer: "  ")
        }
        #expect(throws: VoiceError.self) {
            try config.makeTranscriptionRequest(bearer: "key\nvalue")
        }
    }

    @Test("static auth trims keys and rejects empty values")
    func staticAuthTrimsKeys() async {
        let auth = StaticVoiceAuth("  sk-test  ")
        #expect(await auth.bearer() == "sk-test")
        #expect(StaticVoiceAuth.shared(" \n ") == nil)
    }
}

@Suite("Open Grok voice language catalog")
struct VoiceLanguageTests {
    @Test("catalog is complete, unique, and sorted")
    func catalogShape() {
        #expect(STT_LANGUAGES.count == 25)
        #expect(Set(STT_LANGUAGES.map(\.code)).count == STT_LANGUAGES.count)
        #expect(STT_LANGUAGES.map(\.name) == STT_LANGUAGES.map(\.name).sorted())
    }

    @Test("canonicalization handles locale forms and aliases")
    func canonicalization() {
        #expect(canonicalizeSttLanguage(nil) == "en")
        #expect(canonicalizeSttLanguage("ES") == "es")
        #expect(canonicalizeSttLanguage("pt_BR.UTF-8") == "pt")
        #expect(canonicalizeSttLanguage("tl-PH") == "fil")
        #expect(canonicalizeSttLanguage("AUTO") == "auto")
        #expect(canonicalizeSttLanguage("zh-Hans") == "en")
        #expect(languageForAPI("auto") != "auto")
        #expect(sttLanguageByCode("EN") == nil)
    }
}

@Suite("Open Grok voice protocol contracts")
struct VoiceProtocolTests {
    @Test("server events preserve defaults and ignore unknown event types")
    func serverEventDefaults() throws {
        let partial = try SttServerEvent.decode(Data(#"{"type":"transcript.partial","text":"hello"}"#.utf8))
        #expect(partial == .partial(text: "hello", isFinal: false, speechFinal: false))

        let done = try SttServerEvent.decode(Data(#"{"type":"transcript.done","text":"hello","duration":1.5}"#.utf8))
        #expect(done == .done(text: "hello", duration: 1.5))

        let unknown = try SttServerEvent.decode(Data(#"{"type":"future.event"}"#.utf8))
        #expect(unknown == .unknown)
    }

    @Test("server event decoding wraps malformed JSON and accepts integer durations")
    func malformedJSONAndIntegerDurations() throws {
        #expect(throws: VoiceError.self) {
            try SttServerEvent.decode(Data("not-json".utf8))
        }
        let done = try SttServerEvent.decode(Data(#"{"type":"transcript.done","duration":2}"#.utf8))
        #expect(done == .done(text: "", duration: 2))
    }

    @Test("malformed server events fail loudly")
    func malformedServerEventsFail() {
        #expect(throws: VoiceError.self) {
            try SttServerEvent.decode(Data(#"["not-an-object"]"#.utf8))
        }
    }

    @Test("transcript assembler stitches final chunks and commits speech final")
    func transcriptAssemblerStitchesChunks() {
        var assembler = VoiceTranscriptAssembler()
        #expect(assembler.consume(.partial(SttTranscriptPartial(text: "hello", isFinal: true, speechFinal: false))) == .interimTranscript(text: "hello"))
        #expect(assembler.consume(.partial(SttTranscriptPartial(text: "world", isFinal: true, speechFinal: false))) == .interimTranscript(text: "hello world"))
        #expect(assembler.consume(.partial(SttTranscriptPartial(text: "hello world", isFinal: true, speechFinal: true))) == .utteranceFinal(text: "hello world"))
        #expect(assembler.consume(.done(text: "")) == nil)
    }

    @Test("optional identity headers omit empty and invalid values")
    func optionalIdentityHeaders() throws {
        let valid = VoiceConfig(clientIdentifier: "grok-shell", userAgent: "open-grok/1")
        let request = try valid.makeTranscriptionRequest(bearer: "key")
        #expect(request.headers["x-grok-client-identifier"] == "grok-shell")
        #expect(request.headers["User-Agent"] == "open-grok/1")

        let invalid = VoiceConfig(userAgent: "bad\nvalue")
        let invalidRequest = try invalid.makeTranscriptionRequest(bearer: "key")
        #expect(invalidRequest.headers["User-Agent"] == nil)
    }
}

@Suite("Open Grok voice state and cancellation")
struct VoiceStateTests {
    @Test("state machine cancels a quick press-release and restarts old sessions")
    func stateMachineTransitions() {
        var machine = VoiceStateMachine()
        #expect(machine.apply(.pttPress) == .start(generation: 1))
        #expect(machine.snapshot.state == .starting)
        #expect(machine.apply(.pttRelease) == .cancelStart)
        #expect(machine.snapshot.state == .idle)
        #expect(machine.apply(.pttPress) == .restart(generation: 2))
        machine.markListening(generation: 2)
        #expect(machine.apply(.pttPress) == .restart(generation: 3))
        #expect(machine.snapshot.state == .starting)
    }

    @Test("stale state-machine completions cannot change a newer generation")
    func staleCompletionsAreIgnored() {
        var machine = VoiceStateMachine()
        #expect(machine.apply(.pttPress) == .start(generation: 1))
        #expect(machine.apply(.pttPress) == .restart(generation: 2))
        machine.markListening(generation: 1)
        #expect(machine.snapshot.state == .starting)
        machine.markFailed(generation: 1, message: "stale")
        #expect(machine.snapshot.state == .starting)
        machine.markListening(generation: 2)
        #expect(machine.snapshot.state == .listening)
    }

    @Test("pipeline release finishes audio without requiring a second press")
    func pipelineReleaseFinishesAudio() async throws {
        let auth = StaticVoiceAuth("key")
        let capture = BlockingVoiceAudioCapture()
        let transcription = ScriptedTranscriptionTransport(events: [.partial(SttTranscriptPartial(text: "hi", isFinal: true, speechFinal: true))])
        let pipeline = VoicePipeline(
            auth: auth,
            capture: capture,
            transcription: transcription,
            noSpeechTimeout: 30
        )
        await pipeline.send(.pttPress)
        try await waitUntil { await pipeline.snapshot().state == .listening }
        await pipeline.send(.pttRelease)
        try await waitUntil { await pipeline.snapshot().state == .idle }
        guard let session = await transcription.session() else {
            Issue.record("expected a scripted transcription session")
            return
        }
        #expect(await session.finishCount() >= 1)
        #expect(await capture.session.stopCount() >= 1)
    }

    @Test("unsupported audio is surfaced as a typed error event")
    func unsupportedAudioIsTyped() async throws {
        let pipeline = VoicePipeline(
            auth: StaticVoiceAuth("key"),
            capture: UnsupportedVoiceAudioCapture(reason: "test adapter missing"),
            transcription: UnsupportedVoiceTranscriptionTransport()
        )
        let events = pipeline.events
        await pipeline.send(.pttPress)
        var iterator = events.makeAsyncIterator()
        let event = try await iterator.next()
        guard case .error(let message, _) = event else {
            Issue.record("expected a typed unsupported error event")
            return
        }
        #expect(message.contains("unsupported microphoneCapture"))
    }

    @Test("no-speech watchdog emits a fix hint and fails only the active generation")
    func noSpeechWatchdogFailsActiveGeneration() async throws {
        let pipeline = VoicePipeline(
            auth: StaticVoiceAuth("key"),
            capture: BlockingVoiceAudioCapture(),
            transcription: ScriptedTranscriptionTransport(events: []),
            noSpeechTimeout: 0.005
        )
        let events = pipeline.events
        await pipeline.send(.pttPress)
        var iterator = events.makeAsyncIterator()
        let event = try await iterator.next()
        guard case .error(let message, let hint) = event else {
            Issue.record("expected no-speech error event")
            return
        }
        #expect(message == "No speech was detected. Voice stopped.")
        #expect(hint?.contains("microphone") == true)
        #expect(await pipeline.snapshot().state == .failed(message))
    }
}

@Suite("Open Grok voice capability boundaries")
struct VoiceCapabilityTests {
    @Test("empty PATH reports no Linux recorder without mutating process state")
    func deterministicCapabilityProbe() {
        let capabilities = VoiceCapabilities.detect(environment: ["PATH": ""])
        #expect(capabilities.microphoneRecorder == nil)
        #expect(!capabilities.microphoneCapture || capabilities.microphoneRecorder == nil)
        #expect(capabilities.transcription)
        #expect(!capabilities.playback)
    }

    @Test("probe formatting preserves Open Grok branding and no-speech warning")
    func probeFormatting() {
        let report = VoiceProbeReport(pcmBytes: 0, sttLog: [], transcript: nil)
        let formatted = formatProbeReport(report)
        #expect(formatted.contains("=== Open Grok voice probe ==="))
        #expect(formatted.contains("WARNING: no PCM captured"))
        #expect(formatted.contains("(none — STT returned no text)"))
    }

    @Test("hidden capture helper reports explicit unsupported status")
    func hiddenCaptureHelperUnsupported() {
        var output = ""
        #expect(maybeRunCaptureSubprocess(arguments: ["open-grok"]) == nil)
        let exitCode = maybeRunCaptureSubprocess(
            arguments: ["open-grok", MIC_CAPTURE_SUBCOMMAND],
            output: { output = $0 }
        )
        #expect(exitCode == 2)
        #expect(output == "ERR mic-capture helper unavailable in this build")
    }
}

private actor ScriptedTranscriptionTransport: VoiceTranscriptionTransport {
    private let scriptedEvents: [StreamingSttEvent]
    private var storedSession: ScriptedTranscriptionSession?

    init(events: [StreamingSttEvent]) {
        self.scriptedEvents = events
    }

    func connect(request _: VoiceTranscriptionRequest) async throws -> any VoiceTranscriptionSession {
        let session = ScriptedTranscriptionSession(events: scriptedEvents)
        storedSession = session
        return session
    }

    func session() -> ScriptedTranscriptionSession? {
        storedSession
    }
}

private actor ScriptedTranscriptionSession: VoiceTranscriptionSession {
    private var events: [StreamingSttEvent]
    private var index = 0
    private var finishedAudio = false
    private(set) var finishCountValue = 0
    private(set) var cancelled = false

    init(events: [StreamingSttEvent]) {
        self.events = events
    }

    func sendAudio(_: Data) async throws {}

    func receive() async throws -> StreamingSttEvent? {
        if index < events.count {
            let event = events[index]
            index += 1
            return event
        }
        while !finishedAudio && !cancelled {
            do {
                try await Task.sleep(nanoseconds: 1_000_000)
            } catch {
                return nil
            }
        }
        return nil
    }

    func finishAudio() async throws {
        finishedAudio = true
        finishCountValue += 1
    }

    func cancel() async {
        cancelled = true
    }

    func finishCount() -> Int {
        finishCountValue
    }
}

private actor BlockingVoiceCaptureSession: VoiceCaptureSession {
    let pcm: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private(set) var stopCountValue = 0

    init() {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        pcm = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func stop() async {
        stopCountValue += 1
        continuation.finish()
    }

    func stopCount() -> Int {
        stopCountValue
    }
}

private struct BlockingVoiceAudioCapture: VoiceAudioCapture {
    let session = BlockingVoiceCaptureSession()

    func inputDeviceInfo() async throws -> InputDeviceInfo {
        InputDeviceInfo(name: "test", detail: "blocking")
    }

    func start(sampleRate _: UInt32) async throws -> any VoiceCaptureSession {
        session
    }
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw TestTimeout()
}

private struct TestTimeout: Error {}
