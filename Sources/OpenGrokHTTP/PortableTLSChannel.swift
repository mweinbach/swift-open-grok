#if os(Linux)
import Foundation
import COpenGrokSockets
import OpenGrokExtraCA

enum PortableTLSError: Error, Sendable, CustomStringConvertible {
    case operationFailed(String)
    case connectTimedOut(Double)
    case invalidTrustConfiguration(String)

    var description: String {
        switch self {
        case .operationFailed(let detail), .invalidTrustConfiguration(let detail):
            return detail
        case .connectTimedOut(let seconds):
            return "secure connection timed out after \(seconds)s"
        }
    }
}

private enum PortableTLSBlockingExecutor {
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
            worker.name = "opengrok-tls-io"
            worker.start()
        }
    }
}

final class PortableTLSChannel: WebSocketByteChannel, @unchecked Sendable {
    private let stateLock = NSLock()
    private var handle: OGTLSHandle
    private var activeOperations = 0
    private var closed = false

    init(handle: OGTLSHandle) {
        self.handle = handle
    }

    deinit {
        stateLock.lock()
        let retainedHandle = handle
        handle = 0
        closed = true
        stateLock.unlock()

        if retainedHandle != 0 {
            og_tls_interrupt(retainedHandle)
            og_tls_destroy(retainedHandle)
        }
    }

    func read() async throws -> [UInt8]? {
        guard let retainedHandle = beginOperation() else { return nil }

        return try await PortableTLSBlockingExecutor.run { [self] in
            defer { endOperation() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                og_tls_read(retainedHandle, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return nil }
            guard count > 0 else {
                throw PortableTLSError.operationFailed(Self.lastError())
            }
            return Array(buffer.prefix(Int(count)))
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        guard let retainedHandle = beginOperation() else {
            throw WebSocketChannelError.closed
        }

        try await PortableTLSBlockingExecutor.run { [self] in
            defer { endOperation() }
            let count = bytes.withUnsafeBytes { rawBuffer in
                og_tls_write_all(retainedHandle, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count == Int64(bytes.count) else {
                throw PortableTLSError.operationFailed(Self.lastError())
            }
        }
    }

    func close() async {
        guard let releasedHandle = interruptAndReleaseIdleHandle() else { return }
        guard releasedHandle != 0 else { return }

        do {
            try await PortableTLSBlockingExecutor.run {
                og_tls_destroy(releasedHandle)
            }
        } catch {
            assertionFailure("secure socket cleanup unexpectedly threw: \(error)")
        }
    }

    private func interruptAndReleaseIdleHandle() -> OGTLSHandle? {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return nil
        }
        closed = true
        og_tls_interrupt(handle)
        let releasedHandle: OGTLSHandle
        if activeOperations == 0 {
            releasedHandle = handle
            handle = 0
        } else {
            releasedHandle = 0
        }
        stateLock.unlock()
        return releasedHandle
    }

    private func beginOperation() -> OGTLSHandle? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed, handle != 0 else { return nil }
        activeOperations += 1
        return handle
    }

    private func endOperation() {
        stateLock.lock()
        activeOperations -= 1
        let releasedHandle: OGTLSHandle
        if closed, activeOperations == 0 {
            releasedHandle = handle
            handle = 0
        } else {
            releasedHandle = 0
        }
        stateLock.unlock()

        if releasedHandle != 0 {
            og_tls_destroy(releasedHandle)
        }
    }

    static func lastError() -> String {
        let detail = String(cString: og_tls_last_error_message())
        return detail.isEmpty ? "secure socket operation failed" : detail
    }
}

enum PortableTLSConnector {
    static let maximumSystemTrustBundleBytes = 16 * 1024 * 1024

    static func connect(
        host: String,
        port: UInt16,
        timeoutSeconds: Double,
        extraRootCertificates: [Data] = OpenGrokExtraCA.processRootCertificates
    ) async throws -> PortableTLSChannel {
        guard !host.isEmpty,
              !host.contains(where: { character in
                  character.isWhitespace
                      || "/\\?#@[]%".contains(character)
                      || character.unicodeScalars.contains(where: {
                          $0.value < 0x20 || $0.value == 0x7F
                      })
              })
        else {
            throw PortableTLSError.operationFailed("invalid secure socket host")
        }

        let authority = host.contains(":") ? "[\(host)]" : host
        let url = "https://\(authority):\(port)/"
        let trustBundle = try resolvedTrustBundle(extraRootCertificates: extraRootCertificates)

        return try await PortableTLSBlockingExecutor.run {
            var handle: OGTLSHandle = 0
            let result = url.withCString { urlPointer in
                if let trustBundle {
                    return trustBundle.withUnsafeBytes { rawBuffer in
                        og_tls_connect(
                            urlPointer,
                            timeoutSeconds,
                            rawBuffer.baseAddress,
                            rawBuffer.count,
                            &handle
                        )
                    }
                }
                return og_tls_connect(urlPointer, timeoutSeconds, nil, 0, &handle)
            }

            guard result == 0, handle != 0 else {
                let code = og_tls_last_error_code()
                let detail = PortableTLSChannel.lastError()
                if code == 28 {
                    throw PortableTLSError.connectTimedOut(timeoutSeconds)
                }
                throw PortableTLSError.operationFailed(detail)
            }

            return PortableTLSChannel(handle: handle)
        }
    }

    static func makeTrustBundle(
        systemRootPEM: Data?,
        extraRootCertificates: [Data]
    ) throws -> Data? {
        guard !extraRootCertificates.isEmpty else { return nil }
        guard let systemRootPEM, !systemRootPEM.isEmpty else {
            throw PortableTLSError.invalidTrustConfiguration(
                "configured additional TLS trust roots require an available system trust bundle"
            )
        }
        return FoundationTrustStoreBridge.combinedPEMBundle(
            systemPEM: systemRootPEM,
            extraRootCertificates: extraRootCertificates
        )
    }

    static func resolvedTrustBundle(extraRootCertificates: [Data]) throws -> Data? {
        guard !extraRootCertificates.isEmpty else { return nil }
        guard let url = FoundationTrustStoreBridge.systemBundleURL(
            environment: ProcessInfo.processInfo.environment
        ) else {
            return try makeTrustBundle(systemRootPEM: nil, extraRootCertificates: extraRootCertificates)
        }

        let systemRootPEM: Data
        do {
            systemRootPEM = try OpenGrokExtraCALoader.readCappedFile(
                at: url,
                limit: maximumSystemTrustBundleBytes
            )
        } catch {
            throw PortableTLSError.invalidTrustConfiguration(
                "configured additional TLS trust roots require a readable, bounded system trust bundle"
            )
        }
        return try makeTrustBundle(
            systemRootPEM: systemRootPEM,
            extraRootCertificates: extraRootCertificates
        )
    }
}
#endif
