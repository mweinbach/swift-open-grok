#if os(Windows)
import COpenGrokSockets
import Dispatch
import Foundation
import OpenGrokHTTP
import Testing
@testable import OpenGrokCLI

private actor WindowsSessionBusInbox {
    private(set) var messages: [LiveSessionBusPeerMessage] = []

    func receive(_ message: LiveSessionBusPeerMessage) {
        messages.append(message)
    }
}

@Suite("Secure Windows named-pipe session bus", .serialized)
struct LiveSessionBusWindowsTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func runPowerShell(_ script: String, arguments: [String]) async throws -> (Int32, Data) {
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let executable = URL(fileURLWithPath: systemRoot)
            .appendingPathComponent("System32")
            .appendingPathComponent("WindowsPowerShell")
            .appendingPathComponent("v1.0")
            .appendingPathComponent("powershell.exe")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-NoProfile", "-NonInteractive", "-Command", script] + arguments
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

    @Test("Independent PowerShell process interoperates using Rust's exact pipe name")
    func independentProcessUsesRustPipe() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { request in
            let object = try JSONSerialization.jsonObject(with: request) as? [String: Any]
            guard object?["type"] as? String == "ping" else {
                throw LiveSessionBusTransportError.invalidFrame("expected ping")
            }
            return Data(#"{"type":"pong"}"#.utf8)
        }
        let socket = try await transport.start(
            socketName: "p\(ProcessInfo.processInfo.processIdentifier)-cafebabe.sock"
        )
        let fullName = WindowsNamedPipeName.fullName(forPath: socket.path, namespace: .sessionBus)
        let leaf = String(fullName.dropFirst(#"\\.\pipe\"#.count))
        let script = """
        $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', '\(leaf)', [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(5000)
        $writer = [System.IO.StreamWriter]::new($pipe)
        $writer.AutoFlush = $true
        $writer.WriteLine('{"type":"ping"}')
        $reader = [System.IO.StreamReader]::new($pipe)
        [Console]::Out.WriteLine($reader.ReadLine())
        $pipe.Dispose()
        """
        let (status, output) = try await runPowerShell(script, arguments: [])
        await transport.stop()
        #expect(status == 0)
        let response = try #require(String(data: output, encoding: .utf8))
        #expect(response.contains(#""type":"pong""#))
    }

    @Test("Presence and directory use current-user-only DACLs without phantom socket files")
    func securePresenceAndNamedPipeDiscovery() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bus = LiveSessionBus(openGrokHome: home, cwd: project, sessionID: "windows-live")
        try await bus.start { _ in .accepted }
        try await bus.registerRootSession(sessionID: "windows-live", cwd: project)

        let directory = LiveSessionBusPresenceStore.directory(openGrokHome: home)
        let identifier = await bus.busInstanceID
        let file = directory.appendingPathComponent("\(identifier).json")
        let pseudoSocket = directory.appendingPathComponent("\(identifier).sock")
        #expect(directory.path.withCString {
            og_path_is_private_to_current_user($0, 1)
        } == 1)
        #expect(file.path.withCString {
            og_path_is_private_to_current_user($0, 0)
        } == 1)
        #expect(!FileManager.default.fileExists(atPath: pseudoSocket.path))
        #expect(try await bus.listSessions().sessions.map(\.sessionID) == ["windows-live"])

        await bus.stop()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Independent session-bus hosts discover and deliver untrusted peer messages")
    func peerSessionDeliveryThroughNamedPipes() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = home.appendingPathComponent("alpha", isDirectory: true)
        let second = home.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let inbox = WindowsSessionBusInbox()
        let source = LiveSessionBus(openGrokHome: home, cwd: first, sessionID: "windows-source")
        let target = LiveSessionBus(openGrokHome: home, cwd: second, sessionID: "windows-target")
        try await source.start { _ in .accepted }
        try await target.start { message in
            await inbox.receive(message)
            return .accepted
        }
        try await source.registerRootSession(sessionID: "windows-source", cwd: first)
        try await target.registerRootSession(sessionID: "windows-target", cwd: second)

        #expect(try await source.listSessions().sessions.count == 2)
        #expect(try await source.messageSession(
            sessionID: "windows-target",
            message: "hello from an independent named-pipe host"
        ) == .accepted)
        #expect(try await source.messageSession(
            sessionID: "windows-target",
            message: String(repeating: "é", count: 16_384)
        ) == .accepted)
        await #expect(throws: LiveSessionBusError.self) {
            _ = try await source.messageSession(
                sessionID: "windows-target",
                message: String(repeating: "é", count: 16_385)
            )
        }
        let delivered = await inbox.messages
        #expect(delivered.count == 2)
        #expect(delivered.first?.sourceSession == "windows-source")
        #expect(delivered.first?.body == "hello from an independent named-pipe host")

        await target.stop()
        await source.stop()
    }

    @Test("Named pipes enforce bounded frames, exclusive ownership, and cancellation")
    func boundedExclusiveCancellableNamedPipe() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = LiveSessionBusTransport(homeURL: home) { payload in
            try await Task.sleep(nanoseconds: 200_000_000)
            return payload
        }
        let name = "p\(ProcessInfo.processInfo.processIdentifier)-feedface.sock"
        let socket = try await transport.start(socketName: name)
        let rival = LiveSessionBusTransport(homeURL: home) { $0 }
        await #expect(throws: LiveSessionBusTransportError.self) {
            _ = try await rival.start(socketName: name)
        }

        let oversized = try JSONSerialization.data(withJSONObject: [
            "body": String(repeating: "x", count: 65_536),
        ])
        await #expect(throws: LiveSessionBusTransportError.self) {
            _ = try await LiveSessionBusTransport.request(socketURL: socket, payload: oversized)
        }

        let request = Task {
            try await LiveSessionBusTransport.request(
                socketURL: socket,
                payload: Data(#"{"type":"ping"}"#.utf8)
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let cancelledAt = DispatchTime.now().uptimeNanoseconds
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("cancelled named-pipe request unexpectedly succeeded")
        } catch {
            #expect(request.isCancelled)
        }
        #expect(DispatchTime.now().uptimeNanoseconds - cancelledAt < 500_000_000)

        await rival.stop()
        await transport.stop()
    }

    @Test("Forged, misplaced, and stale presence cannot route cross-user messages")
    func malformedAndStalePresenceFailClosed() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bus = LiveSessionBus(openGrokHome: home, cwd: home, sessionID: "stale-windows")
        try await bus.start { _ in .accepted }
        try await bus.registerRootSession(sessionID: "stale-windows", cwd: home)

        let directory = LiveSessionBusPresenceStore.directory(openGrokHome: home)
        let identifier = await bus.busInstanceID
        let file = directory.appendingPathComponent("\(identifier).json")
        var presence = try JSONDecoder().decode(
            LiveSessionBusPresenceFile.self,
            from: Data(contentsOf: file)
        )
        presence.heartbeatAtMS = LiveSessionBusPresenceStore.nowMilliseconds() - 20_001
        try LiveSessionBusPresenceStore.write(presence, directory: directory)
        #expect(LiveSessionBusPresenceStore.liveSessions(directory: directory).isEmpty)
        #expect(LiveSessionBusPresenceStore.collectStale(directory: directory) == [identifier])

        presence.socketPath = home.appendingPathComponent("outside.sock").path
        #expect(throws: LiveSessionBusError.self) {
            try LiveSessionBusPresenceStore.write(presence, directory: directory)
        }
        await bus.stop()
    }
}
#endif
