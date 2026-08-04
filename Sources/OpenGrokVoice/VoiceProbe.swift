import Foundation

public struct VoiceProbeOptions: Sendable {
    public let config: VoiceConfig
    public let auth: any VoiceAuthProvider
    public let captureSeconds: UInt32
    public let capture: any VoiceAudioCapture
    public let transcription: any VoiceTranscriptionTransport

    public init(
        config: VoiceConfig = VoiceConfig(),
        auth: any VoiceAuthProvider,
        captureSeconds: UInt32 = 1,
        capture: any VoiceAudioCapture = SystemVoiceAudioCapture(),
        transcription: any VoiceTranscriptionTransport = URLSessionVoiceTranscriptionTransport()
    ) {
        self.config = config
        self.auth = auth
        self.captureSeconds = max(1, captureSeconds)
        self.capture = capture
        self.transcription = transcription
    }
}

public struct VoiceProbeReport: Equatable, Sendable {
    public let pcmBytes: Int
    public let sttLog: [String]
    public let transcript: String?

    public init(pcmBytes: Int, sttLog: [String], transcript: String?) {
        self.pcmBytes = pcmBytes
        self.sttLog = sttLog
        self.transcript = transcript
    }
}

public func runMicOnlyProbe(
    sampleRate: UInt32,
    seconds: UInt32,
    capture: any VoiceAudioCapture = SystemVoiceAudioCapture()
) async throws -> (pcmBytes: Int, chunks: UInt32) {
    let session = try await capture.start(sampleRate: sampleRate)
    let collector = Task { () -> (Int, UInt32) in
        var bytes = 0
        var chunks: UInt32 = 0
        do {
            for try await chunk in session.pcm {
                bytes += chunk.count
                chunks += 1
            }
        } catch {
            return (bytes, chunks)
        }
        return (bytes, chunks)
    }
    do {
        try await voiceSleep(seconds: TimeInterval(max(1, seconds)))
    } catch is CancellationError {
        await session.stop()
        collector.cancel()
        _ = await collector.value
        throw VoiceError.cancelled
    }
    await session.stop()
    return await collector.value
}

public func runStreamingProbe(_ options: VoiceProbeOptions) async throws -> VoiceProbeReport {
    let bearer = try await requireVoiceBearer(options.auth)
    let request = try options.config.makeTranscriptionRequest(bearer: bearer)
    let stt = try await options.transcription.connect(request: request)
    let capture: any VoiceCaptureSession
    do {
        capture = try await options.capture.start(sampleRate: options.config.sampleRate)
    } catch {
        await stt.cancel()
        throw error
    }
    let audioTask = Task { () -> Int in
        var pcmBytes = 0
        do {
            for try await chunk in capture.pcm {
                pcmBytes += chunk.count
                try await stt.sendAudio(chunk)
            }
        } catch {
            return pcmBytes
        }
        return pcmBytes
    }

    do {
        try await voiceSleep(seconds: TimeInterval(options.captureSeconds))
        await capture.stop()
        let pcmBytes = await audioTask.value
        try await stt.finishAudio()

        var sttLog: [String] = []
        var transcript: String?
        let receiveTimeout = VoiceError.transcription("STT recv timed out (30s)")
        while true {
            let event: StreamingSttEvent?
            do {
                event = try await withProbeTimeout(
                    30,
                    timeoutError: receiveTimeout
                ) {
                    try await stt.receive()
                }
            } catch let error as VoiceError where error == receiveTimeout {
                sttLog.append("STT recv timed out (30s)")
                break
            }
            guard let event else {
                sttLog.append("STT channel closed")
                break
            }
            switch event {
            case .ready:
                sttLog.append("STT: ready (transcript.created)")
            case .partial(let partial):
                sttLog.append("STT: partial is_final=\(partial.isFinal) speech_final=\(partial.speechFinal) text=\(partial.text.debugDescription)")
                if partial.speechFinal || partial.isFinal,
                   !partial.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    transcript = partial.text
                }
            case .done(let text):
                sttLog.append("STT: done text=\(text.debugDescription)")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    transcript = text
                }
                break
            case .error(let message):
                sttLog.append("STT: error \(message)")
                break
            }
            if case .done = event { break }
            if case .error = event { break }
        }
        await stt.cancel()
        return VoiceProbeReport(pcmBytes: pcmBytes, sttLog: sttLog, transcript: transcript)
    } catch is CancellationError {
        await capture.stop()
        audioTask.cancel()
        _ = await audioTask.value
        await stt.cancel()
        throw VoiceError.cancelled
    } catch {
        await capture.stop()
        audioTask.cancel()
        _ = await audioTask.value
        await stt.cancel()
        throw error
    }
}

private func withProbeTimeout<Value: Sendable>(
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
            throw timeoutError
        }
        return value
    }
}

public func formatProbeReport(_ report: VoiceProbeReport) -> String {
    var output = "=== Open Grok voice probe ===\n\n"
    output += "Mic capture (streamed)\n  pcm_bytes: \(report.pcmBytes)\n"
    if report.pcmBytes == 0 {
        output += "  WARNING: no PCM captured — check mic permission / default input device\n"
    } else {
        let seconds = Double(report.pcmBytes) / Double(DEFAULT_SAMPLE_RATE * 2)
        output += String(format: "  approx duration: %.2fs @ 16kHz mono PCM16\n", seconds)
    }
    output += "\nSTT events\n"
    output += report.sttLog.isEmpty ? "  (none)\n" : report.sttLog.map { "  \($0)\n" }.joined()
    output += "\nTranscript\n"
    if let transcript = report.transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        output += "  \(transcript)\n"
    } else if report.transcript != nil {
        output += "  (empty string)\n"
    } else {
        output += "  (none — STT returned no text)\n"
    }
    return output
}
