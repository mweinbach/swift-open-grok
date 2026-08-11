#if os(macOS)
import AVFoundation
import Foundation

enum MicCaptureChildMode: Equatable, Sendable {
    case capture(rate: UInt32)
    case deviceInfo
}

enum MicCaptureChildParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

enum MicCaptureChildArgs {
    static func parse(_ args: [String]) -> Result<MicCaptureChildMode, MicCaptureChildParseError> {
        var rate = DEFAULT_SAMPLE_RATE
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--device-info":
                return .success(.deviceInfo)
            case "--rate":
                index += 1
                guard index < args.count,
                      let parsed = UInt32(args[index]),
                      parsed > 0 else {
                    return .failure(.message("bad --rate"))
                }
                rate = parsed
            case let other:
                return .failure(.message("unknown mic-capture arg: \(other)"))
            }
            index += 1
        }
        return .success(.capture(rate: rate))
    }
}

enum MicCaptureChild {
    static func runCLI(args: [String], output: @escaping (String) -> Void = VoiceCaptureProtocol.emitHeaderLine) -> Int {
        switch MicCaptureChildArgs.parse(args) {
        case .success(.deviceInfo):
            return runDeviceInfo(output: output)
        case .success(.capture(let rate)):
            return runCapture(rate: rate, output: output)
        case .failure(let error):
            output(VoiceCaptureProtocol.errLine(message: error.description))
            return 2
        }
    }

    private static func runDeviceInfo(output: (String) -> Void) -> Int {
        guard microphoneAuthorized() else {
            output(VoiceCaptureProtocol.errLine(message: "microphone permission denied"))
            return 1
        }
        guard let info = defaultInputDeviceInfo() else {
            output(VoiceCaptureProtocol.errLine(message: "no default input audio device"))
            return 1
        }
        output(VoiceCaptureProtocol.infoLine(name: info.name, detail: info.detail))
        return 0
    }

    private static func runCapture(rate: UInt32, output: (String) -> Void) -> Int {
        guard microphoneAuthorized() else {
            output(VoiceCaptureProtocol.errLine(message: "microphone permission denied"))
            return 1
        }

        let session = MicCaptureChildSession(sampleRate: rate)
        let started = session.start()
        if let error = started.error {
            output(VoiceCaptureProtocol.errLine(message: error))
            return 1
        }
        output(VoiceCaptureProtocol.readyLine(device: started.deviceName))
        return session.runUntilStopped()
    }

    private static func defaultInputDeviceInfo() -> InputDeviceInfo? {
        guard microphoneAuthorized() else { return nil }
        guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
        let name = device.localizedName
        let format = device.activeFormat.formatDescription
        let sampleRate: Int
        let channels: Int
        if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            sampleRate = Int(basic.pointee.mSampleRate)
            channels = Int(basic.pointee.mChannelsPerFrame)
        } else {
            sampleRate = 0
            channels = 1
        }
        let detail = sampleRate > 0 ? "\(sampleRate) Hz, \(channels) ch" : "default input device"
        return InputDeviceInfo(name: name, detail: detail)
    }

    private static func microphoneAuthorized() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            final class AccessResult: @unchecked Sendable {
                var granted = false
            }
            let result = AccessResult()
            let gate = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                result.granted = allowed
                gate.signal()
            }
            gate.wait()
            return result.granted
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

private final class MicCaptureChildSession: @unchecked Sendable {
    private let sampleRate: UInt32
    private let engine = AVAudioEngine()
    private let stopLock = NSLock()
    private var stopped = false

    init(sampleRate: UInt32) {
        self.sampleRate = sampleRate
    }

    func start() -> (deviceName: String, error: String?) {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            return ("", "no default input audio device")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            return ("", "unsupported capture format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return ("", "failed to configure audio converter")
        }

        let deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default Input"

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, !self.isStopped else { return }
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate + 1
            )
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                return
            }
            var conversionError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: converted, error: &conversionError, withInputFrom: inputBlock)
            if conversionError != nil {
                self.markStopped()
                return
            }
            guard let channelData = converted.int16ChannelData else { return }
            let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
            let bytes = Data(bytes: channelData[0], count: byteCount)
            if !self.writePCM(bytes) {
                self.markStopped()
            }
        }

        do {
            try engine.start()
            return (deviceName, nil)
        } catch {
            input.removeTap(onBus: 0)
            return ("", "failed to start audio engine: \(error.localizedDescription)")
        }
    }

    func runUntilStopped() -> Int {
        while !isStopped {
            if getppid() == 1 {
                markStopped()
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return 0
    }

    private func writePCM(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
            try FileHandle.standardOutput.synchronize()
            return true
        } catch {
            return false
        }
    }

    private var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func markStopped() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }
}
#endif
