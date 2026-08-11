#if os(macOS)
import Foundation

enum MicCaptureSubprocess {
    static let readyTimeout: TimeInterval = 5
    static let readChunkSize = 2048

    static func currentExecutableURL(
        arguments: [String] = CommandLine.arguments,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let raw = arguments.first, !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        guard fileManager.isExecutableFile(atPath: url.path) else { return nil }
        return url.resolvingSymlinksInPath()
    }

    static func spawnHelper(
        arguments: [String],
        executableURL: URL? = currentExecutableURL()
    ) throws -> (process: Process, stdout: FileHandle) {
        guard let executableURL else {
            throw VoiceError.configuration("current_exe for mic helper unavailable")
        }
        let output = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [MIC_CAPTURE_SUBCOMMAND] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw VoiceError.configuration("spawn mic helper: \(error)")
        }
        drainStandardError(from: errorPipe.fileHandleForReading)
        return (process, output.fileHandleForReading)
    }

    enum HandshakeFailure: Error, Equatable {
        case reported(VoiceError)
        case broken(VoiceError)
    }

    static func handshake(
        process: Process,
        stdout: FileHandle,
        timeoutWhat: String
    ) throws -> (process: Process, payload: String, stdout: FileHandle) {
        final class HandshakeState: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Result<(String, FileHandle), HandshakeFailure>?

            func store(_ result: Result<(String, FileHandle), HandshakeFailure>) {
                lock.lock()
                value = result
                lock.unlock()
            }

            func take() -> Result<(String, FileHandle), HandshakeFailure>? {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        let state = HandshakeState()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue(label: "opengrok.voice.mic-helper-handshake").async {
            defer { group.leave() }
            do {
                let header = try VoiceCaptureProtocol.readHeader(from: stdout)
                switch header {
                case .ready(let device):
                    state.store(.success((device, stdout)))
                case .info(let name, let detail):
                    let payload = detail.isEmpty ? name : "\(name)\t\(detail)"
                    state.store(.success((payload, stdout)))
                case .error(let message):
                    state.store(.failure(.reported(.configuration(message))))
                }
            } catch VoiceCaptureProtocol.ParseError.eofBeforeHeader {
                state.store(.failure(.broken(.configuration("mic helper exited before ready"))))
            } catch {
                state.store(.failure(.broken(.configuration("read mic helper header: \(error)"))))
            }
        }
        let deadline = DispatchTime.now() + readyTimeout
        if group.wait(timeout: deadline) == .timedOut {
            terminate(process)
            throw HandshakeFailure.reported(
                .configuration("\(timeoutWhat) did not start within \(Int(readyTimeout))s")
            )
        }
        guard let outcome = state.take() else {
            terminate(process)
            throw HandshakeFailure.broken(.configuration("mic helper handshake produced no result"))
        }
        switch outcome {
        case .success(let payload):
            return (process, payload.0, payload.1)
        case .failure(let failure):
            terminate(process)
            throw failure
        }
    }

    static func inputDeviceInfo(
        executableURL: URL? = currentExecutableURL()
    ) async throws -> InputDeviceInfo {
        let spawned = try spawnHelper(arguments: ["--device-info"], executableURL: executableURL)
        do {
            let handshaken = try handshake(
                process: spawned.process,
                stdout: spawned.stdout,
                timeoutWhat: "mic device lookup"
            )
            terminate(handshaken.process)
            if let tab = handshaken.payload.firstIndex(of: VoiceCaptureProtocol.infoFieldSeparator) {
                let name = String(handshaken.payload[..<tab])
                let detail = String(handshaken.payload[handshaken.payload.index(after: tab)...])
                return InputDeviceInfo(name: name, detail: detail)
            }
            return InputDeviceInfo(name: handshaken.payload, detail: "")
        } catch let failure as HandshakeFailure {
            switch failure {
            case .reported(let error):
                throw error
            case .broken(let error):
                throw error
            }
        }
    }

    static func startCapture(
        sampleRate: UInt32,
        executableURL: URL? = currentExecutableURL()
    ) async throws -> MacSubprocessVoiceCaptureSession {
        let spawned = try spawnHelper(
            arguments: ["--rate", String(sampleRate)],
            executableURL: executableURL
        )
        do {
            let handshaken = try handshake(
                process: spawned.process,
                stdout: spawned.stdout,
                timeoutWhat: "voice capture"
            )
            return MacSubprocessVoiceCaptureSession(
                process: handshaken.process,
                stdout: handshaken.stdout,
                deviceName: handshaken.payload
            )
        } catch let failure as HandshakeFailure {
            switch failure {
            case .reported(let error):
                throw error
            case .broken(let error):
                throw error
            }
        }
    }

    private static func drainStandardError(from handle: FileHandle) {
        Task.detached {
            _ = try? handle.readToEnd()
        }
    }
}

final class MacSubprocessVoiceCaptureSession: VoiceCaptureSession, @unchecked Sendable {
    let pcm: AsyncThrowingStream<Data, Error>

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var process: Process?
    private var reader: Task<Void, Never>?
    private var stopped = false

    init(process: Process, stdout: FileHandle, deviceName: String) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        pcm = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
        self.process = process
        reader = Task.detached { [weak self] in
            await self?.read(output: stdout, deviceName: deviceName)
        }
    }

    func stop() async {
        guard let claimed = claimStop() else { return }
        continuation.finish()
        if let process = claimed.process {
            terminate(process)
        }
        if let reader = claimed.reader {
            await reader.value
        }
    }

    private func claimStop() -> (process: Process?, reader: Task<Void, Never>?)? {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return nil }
        stopped = true
        let claimedProcess = process
        process = nil
        let claimedReader = reader
        reader = nil
        return (claimedProcess, claimedReader)
    }

    private func read(output: FileHandle, deviceName: String) async {
        do {
            while !isStopped {
                guard let chunk = try output.read(upToCount: MicCaptureSubprocess.readChunkSize),
                      !chunk.isEmpty else {
                    break
                }
                if !isStopped {
                    continuation.yield(chunk)
                }
            }
            continuation.finish()
        } catch {
            if !isStopped {
                continuation.finish(
                    throwing: VoiceError.configuration("microphone read failed (\(deviceName)): \(error)")
                )
            } else {
                continuation.finish()
            }
        }
        reapIfExited()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func reapIfExited() {
        lock.lock()
        defer { lock.unlock() }
        if let process, !process.isRunning {
            self.process = nil
        }
    }
}

private func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(2.0)
    while process.isRunning, Date() < deadline {
        usleep(5_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(1.0)
        while process.isRunning, Date() < killDeadline {
            usleep(5_000)
        }
    }
}
#endif
