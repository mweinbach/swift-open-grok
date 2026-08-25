#if os(Windows)

import COpenGrokWASAPI
import Foundation

enum WindowsVoiceCaptureFailure {
    static let noDevice = Int32(bitPattern: 0x8007_0490)
    static let accessDenied = Int32(bitPattern: 0x8007_0005)
    static let invalidArgument = Int32(bitPattern: 0x8007_0057)
    static let deviceInvalidated = Int32(bitPattern: 0x8889_0004)
    static let unsupportedFormat = Int32(bitPattern: 0x8889_0008)
    static let serviceNotRunning = Int32(bitPattern: 0x8889_0010)
    static let timeout = Int32(bitPattern: 0x8007_0102)

    static func classify(status: Int32, detail: String) -> VoiceError {
        switch status {
        case noDevice:
            return .configuration("no default input audio device")
        case accessDenied:
            return .configuration("microphone access denied; \(micFixHelp())")
        case deviceInvalidated:
            return .configuration("the default microphone was disconnected or disabled")
        case unsupportedFormat:
            return .configuration("the default microphone cannot provide 16-bit mono PCM audio")
        case serviceNotRunning:
            return .configuration("the Windows Audio service is not running")
        case timeout:
            return .configuration("microphone capture did not start or stop before its deadline")
        case invalidArgument:
            return .configuration("invalid microphone capture configuration")
        default:
            let fallback = detail.isEmpty ? "unknown Windows microphone failure" : detail
            return .configuration(fallback)
        }
    }
}

enum WindowsVoiceCaptureSupport {
    static func hasDefaultInputDevice() -> Bool {
        guard og_wasapi_is_available() == 1 else { return false }
        do {
            return !(try probe(includeFormat: false)).name.isEmpty
        } catch {
            return false
        }
    }

    static func probe(includeFormat: Bool) throws -> InputDeviceInfo {
        var name = [CChar](repeating: 0, count: 512)
        var detail = [CChar](repeating: 0, count: 256)
        var status: Int32 = 0
        let result = name.withUnsafeMutableBufferPointer { name in
            detail.withUnsafeMutableBufferPointer { detail in
                og_wasapi_probe(
                    includeFormat ? 1 : 0,
                    name.baseAddress,
                    name.count,
                    detail.baseAddress,
                    detail.count,
                    &status
                )
            }
        }
        guard result == 0 else {
            throw WindowsVoiceCaptureFailure.classify(status: status, detail: lastError())
        }
        return InputDeviceInfo(name: String(cString: name), detail: String(cString: detail))
    }

    static func lastError() -> String {
        guard let detail = og_wasapi_last_error_message() else {
            return "unknown Windows microphone failure"
        }
        let message = String(cString: detail)
        return message.isEmpty ? "unknown Windows microphone failure" : message
    }
}

private enum WindowsVoiceBlockingExecutor {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let worker = Thread {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            worker.name = "opengrok-wasapi-control"
            worker.start()
        }
    }
}

final class WindowsVoiceCaptureCallbacks: @unchecked Sendable {
    private struct State {
        var stopped = false
        var droppedChunks = 0
    }

    private let lock = NSLock()
    private var state = State()
    let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    var droppedChunks: Int {
        withState { $0.droppedChunks }
    }

    func receiveAudio(
        bytes: UnsafePointer<UInt8>?,
        length: Int,
        isSilence: Bool
    ) {
        guard length > 0, length <= 1024 * 1024 else { return }
        guard !withState({ $0.stopped }) else { return }

        let chunk: Data
        if isSilence {
            chunk = Data(count: length)
        } else {
            guard let bytes else { return }
            chunk = Data(bytes: bytes, count: length)
        }

        switch continuation.yield(chunk) {
        case .enqueued:
            break
        case .dropped:
            withState { $0.droppedChunks += 1 }
        case .terminated:
            withState { $0.stopped = true }
        @unknown default:
            withState { $0.stopped = true }
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        let shouldFinish = withState { state in
            guard !state.stopped else { return false }
            state.stopped = true
            return true
        }
        guard shouldFinish else { return }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private func withState<Value>(_ action: (inout State) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return action(&state)
    }
}

private enum WindowsVoiceNativeCallbacks {
    static let audio: @convention(c) (
        UnsafePointer<UInt8>?,
        Int,
        Int32,
        UnsafeMutableRawPointer?
    ) -> Void = { bytes, length, silence, context in
        guard let context else { return }
        let callbacks = Unmanaged<WindowsVoiceCaptureCallbacks>
            .fromOpaque(context)
            .takeUnretainedValue()
        callbacks.receiveAudio(bytes: bytes, length: length, isSilence: silence != 0)
    }

    static let failure: @convention(c) (
        Int32,
        UnsafePointer<CChar>?,
        UnsafeMutableRawPointer?
    ) -> Void = { status, message, context in
        guard let context else { return }
        let callbacks = Unmanaged<WindowsVoiceCaptureCallbacks>
            .fromOpaque(context)
            .takeUnretainedValue()
        let detail = message.map { String(cString: $0) } ?? "microphone capture failed"
        callbacks.finish(
            throwing: WindowsVoiceCaptureFailure.classify(status: status, detail: detail)
        )
    }

    static let release: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
        guard let context else { return }
        Unmanaged<WindowsVoiceCaptureCallbacks>.fromOpaque(context).release()
    }
}

final class WindowsVoiceCaptureSession: VoiceCaptureSession, @unchecked Sendable {
    let pcm: AsyncThrowingStream<Data, Error>

    private let callbacks: WindowsVoiceCaptureCallbacks
    private let stateLock = NSLock()
    private var nativeHandle: Int64?

    private init(
        stream: AsyncThrowingStream<Data, Error>,
        callbacks: WindowsVoiceCaptureCallbacks,
        nativeHandle: Int64
    ) {
        self.pcm = stream
        self.callbacks = callbacks
        self.nativeHandle = nativeHandle
        callbacks.continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
    }

    deinit {
        guard let handle = claimNativeHandle() else { return }
        callbacks.finish()
        let worker = Thread {
            Self.terminate(handle)
        }
        worker.name = "opengrok-wasapi-release"
        worker.start()
    }

    var droppedChunks: Int {
        callbacks.droppedChunks
    }

    static func start(sampleRate: UInt32) async throws -> WindowsVoiceCaptureSession {
        guard (8_000...384_000).contains(sampleRate) else {
            throw VoiceError.configuration("microphone sample rate must be between 8,000 and 384,000 Hz")
        }
        if Task.isCancelled { throw VoiceError.cancelled }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        let callbacks = WindowsVoiceCaptureCallbacks(continuation: continuation)
        let context = Unmanaged.passRetained(callbacks).toOpaque()
        let contextAddress = Int(bitPattern: context)

        let handle = try await WindowsVoiceBlockingExecutor.run {
            var resultHandle: Int64 = -1
            var status: Int32 = 0
            let result = og_wasapi_start(
                sampleRate,
                WindowsVoiceNativeCallbacks.audio,
                WindowsVoiceNativeCallbacks.failure,
                WindowsVoiceNativeCallbacks.release,
                UnsafeMutableRawPointer(bitPattern: contextAddress),
                &resultHandle,
                &status
            )
            guard result == 0 else {
                throw WindowsVoiceCaptureFailure.classify(
                    status: status,
                    detail: WindowsVoiceCaptureSupport.lastError()
                )
            }
            return resultHandle
        }

        if Task.isCancelled {
            callbacks.finish()
            do {
                try await WindowsVoiceBlockingExecutor.run {
                    Self.terminate(handle)
                }
            } catch {
                // The worker still owns and releases its COM apartment.
            }
            throw VoiceError.cancelled
        }

        return WindowsVoiceCaptureSession(
            stream: stream,
            callbacks: callbacks,
            nativeHandle: handle
        )
    }

    func stop() async {
        guard let handle = claimNativeHandle() else { return }
        callbacks.finish()
        do {
            try await WindowsVoiceBlockingExecutor.run {
                Self.terminate(handle)
            }
        } catch {
            // VoiceCaptureSession.stop has no throwing channel. Native destroy
            // still releases its owner share even if COM teardown is delayed.
        }
    }

    private func claimNativeHandle() -> Int64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        defer { nativeHandle = nil }
        return nativeHandle
    }

    private static func terminate(_ handle: Int64) {
        var status: Int32 = 0
        let stopped = og_wasapi_stop(handle, 2_000, &status)
        if stopped != 0 {
            let failure = WindowsVoiceCaptureFailure.classify(
                status: status,
                detail: WindowsVoiceCaptureSupport.lastError()
            )
            FileHandle.standardError.write(Data("warning: \(failure)\n".utf8))
        }
        og_wasapi_destroy(handle)
    }

    static func inputDeviceInfo() async throws -> InputDeviceInfo {
        try await WindowsVoiceBlockingExecutor.run {
            try WindowsVoiceCaptureSupport.probe(includeFormat: true)
        }
    }
}

#endif
