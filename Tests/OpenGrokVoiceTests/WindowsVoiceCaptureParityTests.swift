#if os(Windows)

import Foundation
import Testing
import WinSDK

@testable import OpenGrokVoice

private final class WindowsVoiceCapabilityProbeGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)

    func waitForRelease() -> Bool {
        entered.signal()
        return released.wait(timeout: .now() + .seconds(3)) == .success
    }
}

private final class WindowsVoiceCapabilityProbeObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedResults: [Bool] = []
    private var currentTime: UInt64 = 0
    private var workerThreadIdentifiers: [DWORD] = []

    var results: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedResults
    }

    var time: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    var threadIdentifiers: [DWORD] {
        lock.lock()
        defer { lock.unlock() }
        return workerThreadIdentifiers
    }

    func record(_ result: Bool) {
        lock.lock()
        recordedResults.append(result)
        lock.unlock()
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        currentTime += nanoseconds
        lock.unlock()
    }

    func recordWorkerThread() -> Int {
        lock.lock()
        workerThreadIdentifiers.append(GetCurrentThreadId())
        let count = workerThreadIdentifiers.count
        lock.unlock()
        return count
    }
}

@Suite("Native Windows microphone parity", .serialized)
struct WindowsVoiceCaptureParityTests {
    @Test("a stalled COM capability probe fails closed before its explicit deadline")
    func capabilityProbeTimeoutIsBounded() {
        let gate = WindowsVoiceCapabilityProbeGate()
        let probe = WindowsVoiceCapabilityProbe(deadlineMilliseconds: 25) {
            gate.waitForRelease()
        }
        defer { gate.released.signal() }

        let started = ContinuousClock.now
        #expect(!probe.hasDefaultInputDevice())
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(gate.entered.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(probe.workerLaunchCount == 1)
    }

    @Test("concurrent and repeated capability checks never multiply a stalled native worker")
    func stalledCapabilityProbeRemainsSingleFlight() {
        let gate = WindowsVoiceCapabilityProbeGate()
        let observations = WindowsVoiceCapabilityProbeObservations()
        let probe = WindowsVoiceCapabilityProbe(deadlineMilliseconds: 40) {
            gate.waitForRelease()
        }
        defer { gate.released.signal() }

        let callers = DispatchGroup()
        for _ in 0..<12 {
            callers.enter()
            Thread {
                observations.record(probe.hasDefaultInputDevice())
                callers.leave()
            }.start()
        }

        #expect(gate.entered.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(callers.wait(timeout: .now() + .seconds(2)) == .success)
        #expect(observations.results.count == 12)
        #expect(observations.results.allSatisfy { !$0 })

        for _ in 0..<20 {
            #expect(!probe.hasDefaultInputDevice())
        }
        #expect(probe.workerLaunchCount == 1)
    }

    @Test("a late native success updates the bounded capability cache without spawning another worker")
    func lateCapabilityProbeCompletionBecomesVisible() {
        let gate = WindowsVoiceCapabilityProbeGate()
        let probe = WindowsVoiceCapabilityProbe(
            deadlineMilliseconds: 25,
            onCompletion: { _ in gate.completed.signal() }
        ) {
            gate.waitForRelease()
        }

        #expect(!probe.hasDefaultInputDevice())
        #expect(gate.entered.wait(timeout: .now() + .seconds(1)) == .success)
        gate.released.signal()
        #expect(gate.completed.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(probe.hasDefaultInputDevice())
        #expect(probe.hasDefaultInputDevice())
        #expect(probe.workerLaunchCount == 1)
    }

    @Test("successful default-device detection stays native-thread confined and refreshes expired cache")
    func successfulCapabilityProbeAndCacheRefresh() {
        let observations = WindowsVoiceCapabilityProbeObservations()
        let callerThreadIdentifier = GetCurrentThreadId()
        let probe = WindowsVoiceCapabilityProbe(
            deadlineMilliseconds: 250,
            cacheLifetimeMilliseconds: 20,
            clock: { observations.time }
        ) {
            observations.recordWorkerThread() == 1
        }

        #expect(probe.hasDefaultInputDevice())
        #expect(probe.hasDefaultInputDevice())
        #expect(probe.workerLaunchCount == 1)
        #expect(observations.threadIdentifiers.count == 1)
        #expect(observations.threadIdentifiers.allSatisfy { $0 != callerThreadIdentifier })

        observations.advance(by: 20_000_000)
        #expect(!probe.hasDefaultInputDevice())
        #expect(probe.workerLaunchCount == 2)
        #expect(observations.threadIdentifiers.count == 2)
        #expect(observations.threadIdentifiers.allSatisfy { $0 != callerThreadIdentifier })
    }

    @Test("native capability failures remain unavailable and reuse their bounded negative cache")
    func failedCapabilityProbeStaysFailClosed() {
        let probe = WindowsVoiceCapabilityProbe {
            throw VoiceError.configuration("microphone access denied")
        }

        #expect(!probe.hasDefaultInputDevice())
        #expect(!probe.hasDefaultInputDevice())
        #expect(probe.workerLaunchCount == 1)
    }

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
