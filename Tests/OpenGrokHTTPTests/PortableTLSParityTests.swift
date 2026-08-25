#if os(Linux)
import Foundation
import Glibc
import Testing

@testable import OpenGrokHTTP

@Suite("Portable verified WebSocket TLS", .serialized)
struct PortableTLSParityTests {
    @Test("additional roots are appended without replacing system trust")
    func additionalRootsPreserveSystemTrust() throws {
        let systemRoots = Data("SYSTEM ROOT\n".utf8)
        let additionalRoot = Data([0x30, 0x03, 0x02, 0x01, 0x01])

        let bundle = try #require(
            try PortableTLSConnector.makeTrustBundle(
                systemRootPEM: systemRoots,
                extraRootCertificates: [additionalRoot]
            )
        )
        let text = String(decoding: bundle, as: UTF8.self)

        #expect(text.hasPrefix("SYSTEM ROOT\n"))
        #expect(text.contains("-----BEGIN CERTIFICATE-----\nMAMCAQE=\n"))
        #expect(text.hasSuffix("-----END CERTIFICATE-----\n"))
    }

    @Test("custom roots fail closed when system roots cannot be preserved")
    func additionalRootsRequireSystemTrust() {
        #expect(throws: PortableTLSError.self) {
            try PortableTLSConnector.makeTrustBundle(
                systemRootPEM: nil,
                extraRootCertificates: [Data([0x30, 0x00])]
            )
        }
    }

    @Test("ordinary connections keep libcurl's native system trust")
    func emptyAdditionalRootsKeepNativeTrust() throws {
        #expect(
            try PortableTLSConnector.makeTrustBundle(
                systemRootPEM: nil,
                extraRootCertificates: []
            ) == nil
        )
    }

    @Test("URL authority injection is refused before network access")
    func invalidHostsFailClosed() async {
        for host in [
            "",
            "localhost/other",
            "localhost@example.com",
            "localhost\r\nHost: bad",
            "localhost%0d%0aHost:bad",
            "localhost\0hidden",
        ] {
            do {
                _ = try await PortableTLSConnector.connect(
                    host: host,
                    port: 443,
                    timeoutSeconds: 1,
                    extraRootCertificates: []
                )
                Issue.record("expected invalid TLS hostname to be rejected")
            } catch let error as PortableTLSError {
                #expect(error.description == "invalid secure socket host")
            } catch {
                Issue.record("unexpected TLS failure: \(error)")
            }
        }
    }

    @Test("a closed loopback port fails at TLS connect time", .timeLimit(.minutes(1)))
    func closedLoopbackPortFailsClosed() async throws {
        let listener = try PortableSocketListener.tcp(host: "127.0.0.1", port: 0)
        let port = try #require(listener.port)
        listener.close()

        do {
            _ = try await PortableTLSConnector.connect(
                host: "127.0.0.1",
                port: port,
                timeoutSeconds: 1,
                extraRootCertificates: []
            )
            Issue.record("expected the refused TLS connection to fail")
        } catch is PortableTLSError {
        }
    }

    @Test("plaintext peers can never impersonate verified TLS", .timeLimit(.minutes(1)))
    func plaintextLoopbackPeerFailsClosed() async throws {
        let listener = try PortableSocketListener.tcp(host: "127.0.0.1", port: 0)
        let port = try #require(listener.port)
        let peer = Task {
            do {
                let channel = try await listener.accept()
                defer { Task { await channel.close() } }
                guard try await channel.read() != nil else { return }
                try await channel.write(Array("HTTP/1.1 200 OK\r\n\r\n".utf8))
            } catch {
                return
            }
        }
        defer {
            listener.close()
            peer.cancel()
        }

        do {
            _ = try await PortableTLSConnector.connect(
                host: "127.0.0.1",
                port: port,
                timeoutSeconds: 2,
                extraRootCertificates: []
            )
            Issue.record("expected the plaintext peer to fail certificate and TLS validation")
        } catch is PortableTLSError {
        }

        await peer.value
    }

    @Test("trusted localhost TLS exchanges encrypted bytes and rejects invalid certificates", .timeLimit(.minutes(1)))
    func trustedLocalhostTLSAndCertificateBoundaries() async throws {
        let fixture = try PortableTLSServerFixture()
        defer { fixture.stop() }

        let channel = try await fixture.connectTrusted()
        try await channel.write(
            Array("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        )
        let response = try #require(try await channel.read())
        let responseText = String(decoding: response, as: UTF8.self)
        #expect(responseText.hasPrefix("HTTP/1.0 200") || responseText.hasPrefix("HTTP/1.1 200"))
        await channel.close()

        do {
            _ = try await PortableTLSConnector.connect(
                host: "127.0.0.1",
                port: fixture.port,
                timeoutSeconds: 3,
                extraRootCertificates: [fixture.certificateDER]
            )
            Issue.record("expected strict certificate hostname verification to reject the IP address")
        } catch is PortableTLSError {
        }

        do {
            _ = try await PortableTLSConnector.connect(
                host: "localhost",
                port: fixture.port,
                timeoutSeconds: 3,
                extraRootCertificates: []
            )
            Issue.record("expected system trust to reject the fixture's untrusted self-signed root")
        } catch is PortableTLSError {
        }
    }
}

private struct PortableTLSFixtureError: Error, CustomStringConvertible {
    let description: String
}

private final class PortableTLSServerFixture: @unchecked Sendable {
    private static let openssl = "/usr/bin/openssl"

    let certificateDER: Data
    let port: UInt16

    private let directory: URL
    private let process: Process
    private let finished: DispatchSemaphore

    init() throws {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: Self.openssl) else {
            throw PortableTLSFixtureError(description: "verified TLS regression requires /usr/bin/openssl")
        }

        let directory = manager.temporaryDirectory
            .appendingPathComponent("opengrok-portable-tls-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let certificate = directory.appendingPathComponent("localhost.pem")
            let key = directory.appendingPathComponent("localhost.key")
            try Self.runOpenSSL([
                "req",
                "-x509",
                "-newkey", "rsa:2048",
                "-noenc",
                "-days", "1",
                "-subj", "/CN=localhost",
                "-addext", "subjectAltName=DNS:localhost",
                "-keyout", key.path,
                "-out", certificate.path,
            ])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificate.path)

            let pem = String(decoding: try Data(contentsOf: certificate), as: UTF8.self)
            let encoded = pem
                .split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("-----") }
                .joined()
            guard let certificateDER = Data(base64Encoded: encoded), !certificateDER.isEmpty else {
                throw PortableTLSFixtureError(description: "could not decode the generated localhost certificate")
            }

            let reservation = try PortableSocketListener.tcp(host: "127.0.0.1", port: 0)
            guard let port = reservation.port else {
                reservation.close()
                throw PortableTLSFixtureError(description: "could not reserve a localhost TLS port")
            }
            reservation.close()

            let finished = DispatchSemaphore(value: 0)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.openssl)
            process.arguments = [
                "s_server",
                "-accept", "127.0.0.1:\(port)",
                "-cert", certificate.path,
                "-key", key.path,
                "-www",
                "-quiet",
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in finished.signal() }
            try process.run()

            self.directory = directory
            self.certificateDER = certificateDER
            self.port = port
            self.process = process
            self.finished = finished
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func connectTrusted() async throws -> PortableTLSChannel {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var lastFailure = "TLS listener did not become ready"

        while clock.now < deadline {
            guard process.isRunning else {
                throw PortableTLSFixtureError(description: "localhost TLS server exited before becoming ready")
            }

            do {
                return try await PortableTLSConnector.connect(
                    host: "localhost",
                    port: port,
                    timeoutSeconds: 1,
                    extraRootCertificates: [certificateDER]
                )
            } catch {
                lastFailure = String(describing: error)
                try await Task.sleep(for: .milliseconds(30))
            }
        }

        throw PortableTLSFixtureError(description: "localhost TLS readiness timed out: \(lastFailure)")
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                let killStatus = Glibc.kill(process.processIdentifier, SIGKILL)
                if killStatus != 0 {
                    Issue.record("could not kill the localhost TLS fixture process")
                }
                if finished.wait(timeout: .now() + 2) == .timedOut {
                    Issue.record("localhost TLS fixture process did not stop")
                }
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openssl)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        guard finished.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                guard Glibc.kill(process.processIdentifier, SIGKILL) == 0 else {
                    throw PortableTLSFixtureError(description: "OpenSSL certificate generator could not be killed")
                }
                if finished.wait(timeout: .now() + 2) == .timedOut {
                    throw PortableTLSFixtureError(description: "OpenSSL certificate generator could not be stopped")
                }
            }
            throw PortableTLSFixtureError(description: "OpenSSL certificate generation timed out")
        }

        guard process.terminationStatus == 0 else {
            throw PortableTLSFixtureError(
                description: "OpenSSL certificate generator failed with status \(process.terminationStatus)"
            )
        }
    }
}
#endif
