#if os(Windows)

import Foundation
import Testing

@testable import OpenGrokVoice

@Suite("Native Windows microphone parity", .serialized)
struct WindowsVoiceCaptureParityTests {
    @Test("native Windows microphone failures are explicit and actionable")
    func nativeFailureClassification() {
        let scenarios: [(Int32, String)] = [
            (WindowsVoiceCaptureFailure.noDevice, "no default input audio device"),
            (WindowsVoiceCaptureFailure.accessDenied, "Privacy & security"),
            (WindowsVoiceCaptureFailure.deviceInvalidated, "disconnected"),
            (WindowsVoiceCaptureFailure.unsupportedFormat, "16-bit mono PCM"),
            (WindowsVoiceCaptureFailure.serviceNotRunning, "Windows Audio service"),
            (WindowsVoiceCaptureFailure.timeout, "deadline"),
            (WindowsVoiceCaptureFailure.invalidArgument, "invalid microphone"),
        ]

        for (status, expected) in scenarios {
            let error = WindowsVoiceCaptureFailure.classify(status: status, detail: "unused")
            guard case .configuration(let detail) = error else {
                Issue.record("expected a typed microphone configuration error")
                continue
            }
            #expect(detail.contains(expected))
        }
    }

    @Test("disabled microphone capability cannot begin capture")
    func unavailableMicrophoneFailsClosed() async {
        let capture = SystemVoiceAudioCapture(
            capabilities: VoiceCapabilities(
                microphoneCapture: false,
                microphonePermission: false,
                transcription: true,
                playback: false
            )
        )

        do {
            _ = try await capture.start(sampleRate: DEFAULT_SAMPLE_RATE)
            Issue.record("disabled microphone capture unexpectedly opened a device")
        } catch let error as VoiceError {
            guard case .unsupported(let capability, _) = error else {
                Issue.record("expected unsupported microphone capture, got \(error)")
                return
            }
            #expect(capability == .microphoneCapture)
        } catch {
            Issue.record("unexpected microphone failure: \(error)")
        }
    }

    @Test("invalid capture rates fail without opening the microphone")
    func invalidSampleRatesAreRejected() async {
        for sampleRate in [UInt32(0), 7999, 384_001] {
            do {
                _ = try await WindowsVoiceCaptureSession.start(sampleRate: sampleRate)
                Issue.record("invalid microphone sample rate unexpectedly succeeded")
            } catch let error as VoiceError {
                guard case .configuration(let detail) = error else {
                    Issue.record("expected microphone configuration error, got \(error)")
                    continue
                }
                #expect(detail.contains("sample rate"))
            } catch {
                Issue.record("unexpected microphone sample-rate failure: \(error)")
            }
        }
    }

    @Test("native silence packets become bounded PCM16 silence")
    func silentPacketsProducePCM() async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let callbacks = WindowsVoiceCaptureCallbacks(continuation: continuation)
        callbacks.receiveAudio(bytes: nil, length: 6, isSilence: true)
        callbacks.finish()

        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == Data(repeating: 0, count: 6))
        #expect(try await iterator.next() == nil)
    }

    @Test("bounded microphone buffering drops oldest chunks without blocking")
    func boundedBufferDropsOldestChunks() async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        let callbacks = WindowsVoiceCaptureCallbacks(continuation: continuation)

        for sample in [UInt8(1), 2, 3] {
            let bytes = [sample, 0]
            bytes.withUnsafeBufferPointer { buffer in
                callbacks.receiveAudio(
                    bytes: buffer.baseAddress,
                    length: buffer.count,
                    isSilence: false
                )
            }
        }
        #expect(callbacks.droppedChunks == 1)
        callbacks.finish()

        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == Data([2, 0]))
        #expect(try await iterator.next() == Data([3, 0]))
        #expect(try await iterator.next() == nil)
    }

    @Test(
        "default Windows microphone yields actual 16-kHz PCM through the live probe",
        .enabled(if: WindowsVoiceCaptureSupport.hasDefaultInputDevice()),
        .timeLimit(.minutes(1))
    )
    func realMicrophoneProducesPCM() async throws {
        let capabilities = VoiceCapabilities.detect()
        #expect(capabilities.microphoneCapture)
        #expect(capabilities.microphonePermission)
        #expect(capabilities.audioCaptureSupported)

        let capture = SystemVoiceAudioCapture(capabilities: capabilities)
        let information = try await capture.inputDeviceInfo()
        #expect(!information.name.isEmpty)
        #expect(information.detail.contains("Hz"))

        let recorded = try await runMicOnlyProbe(
            sampleRate: DEFAULT_SAMPLE_RATE,
            seconds: 1,
            capture: capture
        )
        #expect(recorded.pcmBytes > 0)
        #expect(recorded.pcmBytes.isMultiple(of: 2))
        #expect(recorded.chunks > 0)

        let session = try await capture.start(sampleRate: DEFAULT_SAMPLE_RATE)
        await session.stop()
        await session.stop()
    }
}

#endif
