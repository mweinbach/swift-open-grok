import Foundation
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
        #expect(result.message?.contains("unavailable") == true)
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
