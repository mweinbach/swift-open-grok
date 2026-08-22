import Dispatch
import Foundation
import Testing
@testable import OpenGrokCLI

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Live session-bus cross-process transport")
struct LiveSessionBusTransportTests {
    #if os(macOS) || os(Linux)
    private func makeHome() throws -> URL {
        #if os(macOS)
        let temporaryRoot = "/private/tmp"
        #else
        let temporaryRoot = "/tmp"
        #endif
        let home = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("ogb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        return home
    }

    private func json(_ value: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func frameType(_ payload: Data) throws -> String {
        let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        return try #require(object["type"] as? String)
    }

    private func runPython(_ source: String, arguments: [String]) async throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", source] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, bytes))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    @Test("Independent OS process exchanges upstream-compatible newline JSON")
    func independentProcessRoundTrip() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { payload in
            let object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            guard object["type"] as? String == "ping" else {
                throw LiveSessionBusTransportError.invalidFrame("expected ping")
            }
            return try JSONSerialization.data(withJSONObject: ["type": "pong"])
        }
        let socket = try await transport.start(socketName: "p\(getpid())-cafebabe.sock")

        let child = """
        import json, socket, sys
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(sys.argv[1])
        connection.sendall(json.dumps({'type': 'ping'}).encode() + b'\\n')
        response = b''
        while not response.endswith(b'\\n'):
            chunk = connection.recv(4096)
            if not chunk:
                raise RuntimeError('peer closed before response')
            response += chunk
        sys.stdout.buffer.write(response)
        """
        let (exitCode, output) = try await runPython(child, arguments: [socket.path])
        await transport.stop()

        #expect(exitCode == 0)
        #expect(output.last == 0x0a)
        #expect(try frameType(Data(output.dropLast())) == "pong")
        #expect(!FileManager.default.fileExists(atPath: socket.path))
    }

    @Test("Swift clients round-trip concurrently over actual Unix sockets")
    func concurrentSocketRoundTrips() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { payload in payload }
        let socket = try await transport.start(socketName: "p\(getpid())-12345678.sock")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let request = try JSONSerialization.data(withJSONObject: ["index": index])
                    let response = try await LiveSessionBusTransport.request(
                        socketURL: socket,
                        payload: request
                    )
                    #expect(response == request)
                }
            }
            try await group.waitForAll()
        }

        await transport.stop()
    }

    @Test("Session-bus directory and socket are owner-only")
    func permissionsAreOwnerOnly() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { $0 }
        let socket = try await transport.start(socketName: "p\(getpid())-abcdef01.sock")

        var directory = stat()
        var socketInfo = stat()
        #expect(lstat(socket.deletingLastPathComponent().path, &directory) == 0)
        #expect(lstat(socket.path, &socketInfo) == 0)
        #expect(directory.st_uid == geteuid())
        #expect((directory.st_mode & 0o777) == 0o700)
        #expect(socketInfo.st_uid == geteuid())
        #expect((socketInfo.st_mode & 0o777) == 0o600)
        #expect(socket.deletingLastPathComponent().lastPathComponent == "session-bus")

        await transport.stop()
    }

    @Test("Existing permissive owned bus directories are hardened before binding")
    func existingDirectoryIsHardened() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("session-bus", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(chmod(directory.path, 0o777) == 0)

        let transport = LiveSessionBusTransport(homeURL: home) { $0 }
        _ = try await transport.start(socketName: "p\(getpid())-87654321.sock")
        var metadata = stat()
        #expect(lstat(directory.path, &metadata) == 0)
        #expect((metadata.st_mode & 0o777) == 0o700)

        await transport.stop()
    }

    @Test("Socket-name traversal, embedded separators, and oversized paths are rejected")
    func invalidNamesAndLongPaths() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { $0 }

        for name in ["", ".", "..", "../peer.sock", "nested/peer.sock"] {
            await #expect(throws: LiveSessionBusTransportError.self) {
                _ = try await transport.start(socketName: name)
            }
        }

        let oversized = String(repeating: "p", count: 120) + ".sock"
        do {
            _ = try await transport.start(socketName: oversized)
            Issue.record("overlong Unix socket path should fail before bind")
        } catch LiveSessionBusTransportError.socketPathTooLong {
        }

        await transport.stop()
    }

    @Test("Symlinked session-bus directories and socket paths fail closed")
    func symlinkPathsAreRejected() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let outside = home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let bus = home.appendingPathComponent("session-bus", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: bus, withDestinationURL: outside)

        let throughDirectory = LiveSessionBusTransport(homeURL: home) { $0 }
        await #expect(throws: LiveSessionBusTransportError.self) {
            _ = try await throughDirectory.start(socketName: "p1-12345678.sock")
        }
        try FileManager.default.removeItem(at: bus)
        try FileManager.default.createDirectory(at: bus, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("unrelated")
        try Data("untouched".utf8).write(to: target)
        let socket = bus.appendingPathComponent("p1-12345678.sock")
        try FileManager.default.createSymbolicLink(at: socket, withDestinationURL: target)

        let throughSocket = LiveSessionBusTransport(homeURL: home) { $0 }
        await #expect(throws: LiveSessionBusTransportError.self) {
            _ = try await throughSocket.start(socketName: "p1-12345678.sock")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }

    @Test("Owned abandoned Unix sockets are removed and rebound safely")
    func abandonedSocketIsRecovered() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent("session-bus", isDirectory: true)
        try LiveSessionBusSocketSupport.secureDirectory(at: directory)
        let name = "p\(getpid())-deadbeef.sock"
        let socketURL = directory.appendingPathComponent(name)
        let abandoned = try LiveSessionBusSocketSupport.makeSocket()
        var address = try LiveSessionBusSocketSupport.makeAddress(path: socketURL.path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(abandoned, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(result == 0)
        #expect(close(abandoned) == 0)

        var stale = stat()
        #expect(lstat(socketURL.path, &stale) == 0)
        let transport = LiveSessionBusTransport(homeURL: home) { $0 }
        let recovered: URL
        do {
            recovered = try await transport.start(socketName: name)
        } catch {
            Issue.record("owned abandoned socket was not recovered: \(error)")
            throw error
        }
        #expect(recovered.resolvingSymlinksInPath() == socketURL.resolvingSymlinksInPath())
        var replacement = stat()
        #expect(lstat(socketURL.path, &replacement) == 0)
        #expect((replacement.st_mode & 0o777) == 0o600)
        let ping = try json(["type": "ping"])
        #expect(try await LiveSessionBusTransport.request(socketURL: socketURL, payload: ping) == ping)

        await transport.stop()
    }

    @Test("Full JSON frames are bounded at 64 KiB and newline injection is rejected")
    func frameLimitsAndInjection() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { $0 }
        let socket = try await transport.start(socketName: "p\(getpid())-10203040.sock")

        let accepted = try json(["body": String(repeating: "x", count: 32_768)])
        #expect(try await LiveSessionBusTransport.request(socketURL: socket, payload: accepted) == accepted)

        let oversized = try json(["body": String(repeating: "x", count: 65_536)])
        do {
            _ = try await LiveSessionBusTransport.request(socketURL: socket, payload: oversized)
            Issue.record("oversized wire frame should fail")
        } catch LiveSessionBusTransportError.frameTooLarge(let count) {
            #expect(count > 65_536)
        }

        let injected = Data("{\"type\":\"ping\"}\n{\"type\":\"ping\"}".utf8)
        await #expect(throws: LiveSessionBusTransportError.self) {
            _ = try await LiveSessionBusTransport.request(socketURL: socket, payload: injected)
        }

        await transport.stop()
    }

    @Test("Client deadlines expire and later requests still succeed")
    func deadlinesDoNotPoisonListener() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { payload in
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            if object?["slow"] as? Bool == true {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            return payload
        }
        let socket = try await transport.start(socketName: "p\(getpid())-55667788.sock")
        let slow = try JSONSerialization.data(withJSONObject: ["slow": true])

        do {
            _ = try await LiveSessionBusTransport.request(
                socketURL: socket,
                payload: slow,
                timeout: 0.03
            )
            Issue.record("slow request should time out")
        } catch LiveSessionBusTransportError.timedOut {
        }

        let quick = try json(["type": "ping"])
        #expect(try await LiveSessionBusTransport.request(socketURL: socket, payload: quick) == quick)
        await transport.stop()
    }

    @Test("Cancelling an in-flight request closes its socket without stopping the host")
    func requestCancellation() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { payload in
            try await Task.sleep(nanoseconds: 200_000_000)
            return payload
        }
        let socket = try await transport.start(socketName: "p\(getpid())-99887766.sock")
        let payload = try json(["type": "ping"])
        let request = Task {
            try await LiveSessionBusTransport.request(socketURL: socket, payload: payload)
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        let cancelledAt = DispatchTime.now().uptimeNanoseconds
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("cancelled session-bus request should fail")
        } catch {
            #expect(request.isCancelled)
        }
        let cancellationElapsed = DispatchTime.now().uptimeNanoseconds - cancelledAt
        #expect(cancellationElapsed < 500_000_000)

        #expect(try await LiveSessionBusTransport.request(socketURL: socket, payload: payload) == payload)
        await transport.stop()
    }

    @Test("Repeated starts are idempotent and foreign active sockets are never removed")
    func idempotenceAndActiveSocketProtection() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "p\(getpid())-fedcba98.sock"
        let primary = LiveSessionBusTransport(homeURL: home) { $0 }
        let socket = try await primary.start(socketName: name)
        #expect(try await primary.start(socketName: name) == socket)

        let rival = LiveSessionBusTransport(homeURL: home) { $0 }
        do {
            _ = try await rival.start(socketName: name)
            Issue.record("active socket must not be unlinked")
        } catch LiveSessionBusTransportError.addressInUse {
        }
        let ping = try json(["type": "ping"])
        #expect(try await LiveSessionBusTransport.request(socketURL: socket, payload: ping) == ping)

        await rival.stop()
        await primary.stop()
    }
    #endif

    #if os(Windows)
    @Test("Windows fails closed until its named-pipe session-bus transport exists")
    func windowsFailsClosed() async {
        let transport = LiveSessionBusTransport(homeURL: URL(fileURLWithPath: "C:/Temp")) { $0 }
        await #expect(throws: LiveSessionBusTransportError.unsupportedPlatform) {
            _ = try await transport.start(socketName: "p1-12345678.sock")
        }
    }
    #endif
}
