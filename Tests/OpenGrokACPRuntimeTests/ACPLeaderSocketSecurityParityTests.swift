#if os(macOS) || os(Linux)

import Foundation
import OpenGrokACPRuntime
import Testing

@Suite("Owner-private ACP leader socket authority", .serialized)
struct ACPLeaderSocketSecurityParityTests {
    @Test("leader sockets secure both their parent directory and bound socket")
    func leaderSocketAndDirectoryAreOwnerPrivate() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: directory.path
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let socket = directory.appendingPathComponent("leader.sock")
        let listener = ACPLeaderSocketListener(path: socket)
        let channels = try await listener.start()
        let accepted = Task {
            var iterator = channels.makeAsyncIterator()
            return await iterator.next()
        }
        defer {
            accepted.cancel()
            Task { await listener.stop() }
        }

        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(socket) == 0o600)

        let client = try await ACPLeaderSocketDialer.connect(path: socket)
        let server = try #require(await accepted.value)
        try await client.write(Array("private-leader".utf8))
        let received = try #require(try await server.read())
        #expect(String(decoding: received, as: UTF8.self) == "private-leader")
        await client.close()
        await server.close()
        await listener.stop()
    }

    @Test("leader sockets reject a symbolic-link authority directory")
    func leaderSocketRejectsSymlinkParent() async throws {
        let directory = temporaryDirectory()
        let target = directory.appendingPathComponent("target", isDirectory: true)
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: directory) }

        let listener = ACPLeaderSocketListener(path: alias.appendingPathComponent("leader.sock"))
        do {
            _ = try await listener.start()
            Issue.record("leader listener accepted a symbolic-link authority directory")
            await listener.stop()
        } catch {
            #expect(!FileManager.default.fileExists(
                atPath: target.appendingPathComponent("leader.sock").path
            ))
        }
    }

    private func temporaryDirectory() -> URL {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        #if os(macOS)
        return URL(fileURLWithPath: "/private/tmp/ogls-\(identifier)", isDirectory: true)
        #else
        return URL(fileURLWithPath: "/tmp/ogls-\(identifier)", isDirectory: true)
        #endif
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        return mode.intValue & 0o777
    }
}

#endif
