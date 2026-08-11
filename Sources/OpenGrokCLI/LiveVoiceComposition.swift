// LiveVoiceComposition.swift
//
// Makes `OpenGrokVoice` reachable from the live CLI without touching
// `LiveComposition.swift`. The lead wires these helpers into the pager event
// loop, slash registry, and settings overlay.
//
// Rust reference: `xai-grok-pager/src/voice/mod.rs` and
// `xai-grok-pager/src/app/dispatch/voice.rs` (650c1db7).

import Foundation
import OpenGrokVoice

// MARK: - Capability surface

public struct LiveVoiceCapabilities: Sendable, Equatable {
    public let detected: VoiceCapabilities

    public init(detected: VoiceCapabilities = .detect()) {
        self.detected = detected
    }

    public var isAvailable: Bool {
        detected.audioCaptureSupported
    }

    /// Settings rows that must stay hidden until voice capture is live.
    public static let settingsKeys: [String] = [
        "voice_keybind_enabled",
        "voice_capture_mode",
        "voice_stt_language",
    ]

    public static func hiddenSettingsKeys(when capabilities: LiveVoiceCapabilities) -> Set<String> {
        capabilities.isAvailable ? [] : Set(settingsKeys)
    }
}

// MARK: - Pipeline handle

public struct LiveVoicePipelineHandle: Sendable {
    public let pipeline: VoicePipeline

    public init(
        auth: any VoiceAuthProvider,
        config: VoiceConfig = VoiceConfig(),
        capture: any VoiceAudioCapture = SystemVoiceAudioCapture()
    ) {
        self.pipeline = VoicePipeline(config: config, auth: auth, capture: capture)
    }

    public func shutdown() async {
        await pipeline.send(.shutdown)
    }
}

public enum LiveVoiceMainIntercept {
    /// Call at the very top of `main` before TUI initialization.
    public static func maybeRunCaptureSubprocess() -> Int? {
        OpenGrokVoice.maybeRunCaptureSubprocess()
    }
}

public enum LiveVoiceComposition {
    public static func resolveCapabilities(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LiveVoiceCapabilities {
        LiveVoiceCapabilities(
            detected: VoiceCapabilities.detect(environment: environment)
        )
    }

    public static func makePipeline(
        auth: any VoiceAuthProvider,
        config: VoiceConfig = VoiceConfig(),
        capabilities: LiveVoiceCapabilities
    ) -> LiveVoicePipelineHandle? {
        guard capabilities.isAvailable else { return nil }
        return LiveVoicePipelineHandle(auth: auth, config: config)
    }
}

// MARK: - /voice command

public struct LiveVoiceCommandResult: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case startedListening
        case stoppedListening
        case unavailable(reason: String)
        case ignored
    }

    public let action: Action
    public let message: String?

    public init(action: Action, message: String? = nil) {
        self.action = action
        self.message = message
    }
}

public struct LiveVoiceSessionState: Sendable {
    public var capabilities: LiveVoiceCapabilities
    public var pipeline: LiveVoicePipelineHandle?
    public var isListening: Bool

    public init(
        capabilities: LiveVoiceCapabilities = LiveVoiceComposition.resolveCapabilities(),
        pipeline: LiveVoicePipelineHandle? = nil,
        isListening: Bool = false
    ) {
        self.capabilities = capabilities
        self.pipeline = pipeline
        self.isListening = isListening
    }
}

public enum LiveVoiceCommands {
    /// Toggle dictation for `/voice` and the Ctrl+Space toggle chord.
    ///
    /// Returns a status the pager can surface; never `_ =` this result.
    public static func toggle(state: inout LiveVoiceSessionState) async -> LiveVoiceCommandResult {
        guard state.capabilities.isAvailable else {
            return LiveVoiceCommandResult(
                action: .unavailable(
                    reason: "Voice dictation is unavailable in this build."
                ),
                message: unsupportedMessage(for: state.capabilities)
            )
        }

        if state.isListening {
            if let pipeline = state.pipeline {
                await pipeline.pipeline.send(.pttRelease)
            }
            state.isListening = false
            return LiveVoiceCommandResult(action: .stoppedListening)
        }

        if state.pipeline == nil {
            guard let auth = StaticVoiceAuth.shared(
                ProcessInfo.processInfo.environment["XAI_API_KEY"] ?? ""
            ) else {
                return LiveVoiceCommandResult(
                    action: .unavailable(reason: "not signed in"),
                    message: "Voice dictation requires `open-grok login` or XAI_API_KEY."
                )
            }
            state.pipeline = LiveVoiceComposition.makePipeline(
                auth: auth,
                capabilities: state.capabilities
            )
        }
        guard let pipeline = state.pipeline else {
            return LiveVoiceCommandResult(
                action: .unavailable(reason: "pipeline unavailable"),
                message: "Voice dictation could not start."
            )
        }
        await pipeline.pipeline.send(.pttPress)
        state.isListening = true
        return LiveVoiceCommandResult(action: .startedListening)
    }

    public static func unsupportedMessage(for capabilities: LiveVoiceCapabilities) -> String {
        if capabilities.detected.microphoneCapture {
            return micFixHelp()
        }
        #if os(Linux)
        return """
        Voice dictation needs a microphone recorder on PATH \
        (pw-record, parec, or arecord).
        """
        #else
        return "Voice dictation is unavailable in this build."
        #endif
    }
}

// MARK: - Event helpers for the pager lead

public enum LiveVoiceEventHandling {
    /// Apply a pipeline event to prompt text. Returns `true` when the caller
    /// should redraw.
    public static func apply(
        _ event: VoiceEvent,
        interim: inout String,
        prompt: inout String
    ) -> Bool {
        switch event {
        case .interimTranscript(let text):
            interim = text
            return true
        case .utteranceFinal(let text):
            prompt = combinePrompt(prompt: prompt, voiceText: text)
            interim = ""
            return true
        case .error(let message, _):
            interim = ""
            return !message.isEmpty
        }
    }

    public static func combinePrompt(prompt: String, voiceText: String) -> String {
        let trimmedVoice = voiceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVoice.isEmpty else { return prompt }
        if prompt.isEmpty { return trimmedVoice }
        if prompt.hasSuffix(" ") || prompt.hasSuffix("\n") {
            return prompt + trimmedVoice
        }
        return prompt + " " + trimmedVoice
    }
}
