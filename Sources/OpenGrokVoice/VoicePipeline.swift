import Foundation

public enum VoiceTransition: Equatable, Sendable {
    case start(generation: UInt64)
    case restart(generation: UInt64)
    case cancelStart
    case finish
    case stop
    case shutdown
    case ignore
}

public struct VoiceStateMachine: Sendable {
    public private(set) var snapshot: VoicePipelineSnapshot

    public init() {
        snapshot = VoicePipelineSnapshot(state: .idle, generation: 0)
    }

    public mutating func apply(_ command: VoiceCommand) -> VoiceTransition {
        switch command {
        case .pttPress:
            snapshot = VoicePipelineSnapshot(
                state: .starting,
                generation: snapshot.generation &+ 1
            )
            return snapshot.generation == 1 ? .start(generation: snapshot.generation) : .restart(generation: snapshot.generation)
        case .pttRelease:
            switch snapshot.state {
            case .starting:
                snapshot = VoicePipelineSnapshot(state: .idle, generation: snapshot.generation)
                return .cancelStart
            case .listening:
                snapshot = VoicePipelineSnapshot(state: .stopping, generation: snapshot.generation)
                return .stop
            case .stopping, .idle, .failed:
                return .ignore
            }
        case .shutdown:
            snapshot = VoicePipelineSnapshot(state: .idle, generation: snapshot.generation)
            return .shutdown
        }
    }

    public mutating func markListening(generation: UInt64) {
        guard snapshot.generation == generation else { return }
        snapshot = VoicePipelineSnapshot(state: .listening, generation: generation)
    }

    public mutating func markFinished(generation: UInt64) {
        guard snapshot.generation == generation else { return }
        if case .failed = snapshot.state { return }
        snapshot = VoicePipelineSnapshot(state: .idle, generation: generation)
    }

    public mutating func markFailed(generation: UInt64, message: String) {
        guard snapshot.generation == generation else { return }
        snapshot = VoicePipelineSnapshot(state: .failed(message), generation: generation)
    }
}

public struct VoiceTranscriptAssembler: Sendable {
    private var lockedPrefix = ""

    public init() {}

    public mutating func consume(_ event: StreamingSttEvent) -> VoiceEvent? {
        switch event {
        case .ready:
            return nil
        case .partial(let partial):
            let text = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if partial.speechFinal {
                lockedPrefix = ""
                return .utteranceFinal(text: partial.text)
            }
            if partial.isFinal {
                if !lockedPrefix.isEmpty { lockedPrefix += " " }
                lockedPrefix += text
                return .interimTranscript(text: lockedPrefix)
            }
            if lockedPrefix.isEmpty {
                return .interimTranscript(text: text)
            }
            return .interimTranscript(text: "\(lockedPrefix) \(text)")
        case .done(let text):
            lockedPrefix = ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .utteranceFinal(text: text)
        case .error(let message):
            return .error(message: message, hint: nil)
        }
    }
}

public actor VoicePipeline {
    public nonisolated let events: AsyncStream<VoiceEvent>

    private let config: VoiceConfig
    private let auth: any VoiceAuthProvider
    private let capture: any VoiceAudioCapture
    private let transcription: any VoiceTranscriptionTransport
    private let noSpeechTimeout: TimeInterval
    private let eventContinuation: AsyncStream<VoiceEvent>.Continuation
    private var machine = VoiceStateMachine()
    private var runTask: Task<Void, Never>?
    private var runTaskGeneration: UInt64?
    private var activeCapture: (any VoiceCaptureSession)?
    private var activeTranscription: (any VoiceTranscriptionSession)?
    private var activeGeneration: UInt64?
    private var speechSeen = Set<UInt64>()

    public init(
        config: VoiceConfig = VoiceConfig(),
        auth: any VoiceAuthProvider,
        capture: any VoiceAudioCapture = SystemVoiceAudioCapture(),
        transcription: any VoiceTranscriptionTransport = URLSessionVoiceTranscriptionTransport(),
        noSpeechTimeout: TimeInterval = 10
    ) {
        self.config = config
        self.auth = auth
        self.capture = capture
        self.transcription = transcription
        self.noSpeechTimeout = noSpeechTimeout
        var continuation: AsyncStream<VoiceEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func snapshot() -> VoicePipelineSnapshot {
        machine.snapshot
    }

    public func send(_ command: VoiceCommand) async {
        let transition = machine.apply(command)
        switch transition {
        case .start(let generation), .restart(let generation):
            runTask?.cancel()
            await cancelActiveSession()
            runTaskGeneration = generation
            runTask = Task { [weak self] in
                await self?.runSession(generation: generation)
            }
        case .cancelStart:
            runTask?.cancel()
            runTaskGeneration = nil
            await cancelActiveSession()
        case .stop:
            if let capture = activeCapture {
                await capture.stop()
            }
            if let transcription = activeTranscription {
                try? await transcription.finishAudio()
            }
        case .shutdown:
            runTask?.cancel()
            runTaskGeneration = nil
            await cancelActiveSession()
            eventContinuation.finish()
        case .finish, .ignore:
            break
        }
    }

    private func runSession(generation: UInt64) async {
        do {
            async let captureSession = capture.start(sampleRate: config.sampleRate)
            let bearer = try await requireVoiceBearer(auth)
            let request = try config.makeTranscriptionRequest(bearer: bearer)
            async let transcriptionSession = transcription.connect(request: request)
            let (openedCapture, openedTranscription) = try await (captureSession, transcriptionSession)
            guard machine.snapshot.generation == generation, machine.snapshot.state == .starting else {
                await openedCapture.stop()
                await openedTranscription.cancel()
                return
            }
            activeCapture = openedCapture
            activeTranscription = openedTranscription
            activeGeneration = generation
            machine.markListening(generation: generation)
            speechSeen.remove(generation)
            let watchdogTimeout = noSpeechTimeout
            let watchdog = Task { [weak self] in
                do {
                    try await voiceSleep(seconds: watchdogTimeout)
                    await self?.handleNoSpeechTimeout(generation: generation)
                } catch {
                    return
                }
            }
            let audioTask = Task {
                do {
                    for try await chunk in openedCapture.pcm {
                        try Task.checkCancellation()
                        try await openedTranscription.sendAudio(chunk)
                    }
                } catch {
                    return
                }
                try? await openedTranscription.finishAudio()
            }
            var assembler = VoiceTranscriptAssembler()
            while !Task.isCancelled {
                guard let event = try await openedTranscription.receive() else { break }
                if case .partial(let partial) = event,
                   !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    speechSeen.insert(generation)
                    watchdog.cancel()
                }
                if let output = assembler.consume(event) {
                    eventContinuation.yield(output)
                    if case .error = output { break }
                    if case .utteranceFinal = output, machine.snapshot.state == .stopping { break }
                }
                if case .done = event { break }
            }
            audioTask.cancel()
            watchdog.cancel()
            await openedCapture.stop()
            await audioTask.value
            try? await openedTranscription.finishAudio()
            await openedTranscription.cancel()
            clearActiveSession(generation: generation)
            if runTaskGeneration == generation {
                runTask = nil
                runTaskGeneration = nil
            }
            speechSeen.remove(generation)
            machine.markFinished(generation: generation)
        } catch is CancellationError {
            await finishCancelledSession(generation: generation)
        } catch let error as VoiceError {
            if error == .cancelled {
                await finishCancelledSession(generation: generation)
            } else {
                await finishFailedSession(generation: generation, error: error)
            }
        } catch {
            await finishFailedSession(
                generation: generation,
                error: VoiceError.transcription(String(describing: error))
            )
        }
    }

    private func handleNoSpeechTimeout(generation: UInt64) async {
        guard machine.snapshot.generation == generation,
              machine.snapshot.state == .listening,
              !speechSeen.contains(generation) else { return }
        let message = "No speech was detected. Voice stopped."
        machine.markFailed(generation: generation, message: message)
        eventContinuation.yield(.error(message: message, hint: micFixHelp()))
        if runTaskGeneration == generation {
            runTask?.cancel()
            runTask = nil
            runTaskGeneration = nil
        }
        await cancelActiveSession(ifGeneration: generation)
        speechSeen.remove(generation)
    }

    private func finishCancelledSession(generation: UInt64) async {
        await cancelActiveSession(ifGeneration: generation)
        guard machine.snapshot.generation == generation else { return }
        if case .failed = machine.snapshot.state { return }
        speechSeen.remove(generation)
        machine.markFinished(generation: generation)
        if runTaskGeneration == generation {
            runTask = nil
            runTaskGeneration = nil
        }
    }

    private func finishFailedSession(generation: UInt64, error: VoiceError) async {
        await cancelActiveSession(ifGeneration: generation)
        guard machine.snapshot.generation == generation else { return }
        guard machine.snapshot.state != .idle else { return }
        machine.markFailed(generation: generation, message: error.description)
        eventContinuation.yield(.error(message: error.description, hint: nil))
        speechSeen.remove(generation)
        if runTaskGeneration == generation {
            runTask = nil
            runTaskGeneration = nil
        }
    }

    private func clearActiveSession(generation: UInt64) {
        guard activeGeneration == generation else { return }
        activeCapture = nil
        activeTranscription = nil
        activeGeneration = nil
    }

    private func cancelActiveSession(ifGeneration generation: UInt64? = nil) async {
        guard let activeGeneration,
              (generation == nil || activeGeneration == generation),
              let capture = activeCapture,
              let transcription = activeTranscription else {
            return
        }
        activeCapture = nil
        activeTranscription = nil
        self.activeGeneration = nil
        await capture.stop()
        await transcription.cancel()
    }
}

public func runVoicePipeline(
    config: VoiceConfig,
    auth: any VoiceAuthProvider,
    commands: AsyncStream<VoiceCommand>,
    capture: any VoiceAudioCapture = SystemVoiceAudioCapture(),
    transcription: any VoiceTranscriptionTransport = URLSessionVoiceTranscriptionTransport()
) async -> AsyncStream<VoiceEvent> {
    let pipeline = VoicePipeline(
        config: config,
        auth: auth,
        capture: capture,
        transcription: transcription
    )
    let events = pipeline.events
    Task {
        for await command in commands {
            await pipeline.send(command)
            if command == .shutdown { break }
        }
    }
    return events
}
