import Foundation
import OpenGrokShared
import Testing
@testable import OpenGrokShellSessionSupport

@Suite("Owner-private shell session-state persistence")
struct SessionStateSecurityParityTests {
    @Test("new transcript state is private, atomic, recoverable, and removable")
    func privateRoundTripAndDeletion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = SessionID("private-session")
        let initial = state(sessionID: sessionID, transcript: "private transcript")
        let store = SessionStateStore(root: root)

        try await store.save(initial)
        #expect(try await store.load(sessionID: sessionID) == initial)

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let directory = sessions.appendingPathComponent(sessionID.rawValue, isDirectory: true)
        let document = directory.appendingPathComponent(SessionStateStore.fileName)

        #if !os(Windows)
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(sessions) == 0o700)
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(document) == 0o600)
        #endif

        let updated = state(sessionID: sessionID, transcript: "replaced transcript")
        try await store.save(updated)
        #expect(try await store.load(sessionID: sessionID) == updated)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["state.json"])

        try await store.delete(sessionID: sessionID)
        #expect(try await store.load(sessionID: sessionID) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("missing reads and deletes never create application-state directories")
    func missingStateDoesNotCreateDirectories() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStateStore(root: root)

        #expect(try await store.load(sessionID: SessionID("missing")) == nil)
        try await store.delete(sessionID: SessionID("missing"))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("session identifiers cannot traverse beyond the application-state root")
    func hostileSessionIdentifiersAreRejected() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStateStore(root: root)

        for rawValue in ["", ".", "..", "../escaped", "nested/escaped", "nested\\escaped", "a:b", "a b", "a\0b"] {
            let sessionID = SessionID(rawValue)
            await #expect(throws: ShellSessionSupportError.self) {
                try await store.save(state(sessionID: sessionID, transcript: "secret"))
            }
            await #expect(throws: ShellSessionSupportError.self) {
                try await store.load(sessionID: sessionID)
            }
            await #expect(throws: ShellSessionSupportError.self) {
                try await store.delete(sessionID: sessionID)
            }
        }

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    #if !os(Windows)
    @Test("legacy readable state migrates to owner-private permissions without data loss")
    func readableLegacyStateMigratesSafely() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = SessionID("legacy-session")
        let original = state(sessionID: sessionID, transcript: "legacy private transcript")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let directory = sessions.appendingPathComponent(sessionID.rawValue, isDirectory: true)
        let document = directory.appendingPathComponent(SessionStateStore.fileName)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(original).write(to: document)
        for path in [root, sessions, directory] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path)

        #expect(try await SessionStateStore(root: root).load(sessionID: sessionID) == original)
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(sessions) == 0o700)
        #expect(try permissions(directory) == 0o700)
        #expect(try permissions(document) == 0o600)
    }

    @Test("user-owned parent, root, sessions, and session symlinks cannot receive transcript data")
    func symlinkedAncestorsFailClosed() async throws {
        for position in ["parent", "root", "sessions", "session"] {
            let parent = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: parent) }
            let external = parent.appendingPathComponent("external", isDirectory: true)
            let root = position == "parent"
                ? parent.appendingPathComponent("alias").appendingPathComponent("home", isDirectory: true)
                : parent.appendingPathComponent("home", isDirectory: true)
            let sessionID = SessionID("private-session")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

            switch position {
            case "parent":
                try FileManager.default.createDirectory(
                    at: external.appendingPathComponent("home", isDirectory: true),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    at: parent.appendingPathComponent("alias"),
                    withDestinationURL: external
                )
            case "root":
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: external)
            case "sessions":
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: root.appendingPathComponent("sessions"),
                    withDestinationURL: external
                )
            default:
                let sessions = root.appendingPathComponent("sessions", isDirectory: true)
                try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: sessions.appendingPathComponent(sessionID.rawValue),
                    withDestinationURL: external
                )
            }

            let store = SessionStateStore(root: root)
            await #expect(throws: ShellSessionSupportError.self) {
                try await store.save(state(sessionID: sessionID, transcript: "secret"))
            }
            await #expect(throws: ShellSessionSupportError.self) {
                try await store.load(sessionID: sessionID)
            }
            await #expect(throws: ShellSessionSupportError.self) {
                try await store.delete(sessionID: sessionID)
            }
            let expected = position == "parent" ? ["home"] : []
            #expect(try FileManager.default.contentsOfDirectory(atPath: external.path) == expected)
            if position == "parent" {
                #expect(try FileManager.default.contentsOfDirectory(
                    atPath: external.appendingPathComponent("home").path
                ).isEmpty)
            }
        }
    }

    @Test("a symlink replacing state.json cannot read, overwrite, or delete its target")
    func finalSymlinkFailsClosed() async throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("home", isDirectory: true)
        let sessionID = SessionID("private-session")
        let directory = root.appendingPathComponent("sessions").appendingPathComponent(sessionID.rawValue)
        let external = parent.appendingPathComponent("external.json")
        let document = directory.appendingPathComponent(SessionStateStore.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("do not modify".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: document, withDestinationURL: external)
        let store = SessionStateStore(root: root)

        await #expect(throws: ShellSessionSupportError.self) {
            try await store.save(state(sessionID: sessionID, transcript: "secret"))
        }
        await #expect(throws: ShellSessionSupportError.self) {
            try await store.load(sessionID: sessionID)
        }
        await #expect(throws: ShellSessionSupportError.self) {
            try await store.delete(sessionID: sessionID)
        }

        #expect(try String(contentsOf: external, encoding: .utf8) == "do not modify")
        let attributes = try FileManager.default.attributesOfItem(atPath: document.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test("hard-linked state is rejected before another path can expose or mutate its transcript")
    func hardLinkedStateFailsClosed() async throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("home", isDirectory: true)
        let sessionID = SessionID("private-session")
        let directory = root.appendingPathComponent("sessions").appendingPathComponent(sessionID.rawValue)
        let external = parent.appendingPathComponent("external.json")
        let document = directory.appendingPathComponent(SessionStateStore.fileName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state(sessionID: sessionID, transcript: "linked secret")).write(to: external)
        try FileManager.default.linkItem(at: external, to: document)
        let store = SessionStateStore(root: root)

        await #expect(throws: ShellSessionSupportError.self) {
            try await store.save(state(sessionID: sessionID, transcript: "replacement"))
        }
        await #expect(throws: ShellSessionSupportError.self) {
            try await store.load(sessionID: sessionID)
        }
        await #expect(throws: ShellSessionSupportError.self) {
            try await store.delete(sessionID: sessionID)
        }

        let retained = try JSONDecoder().decode(PersistedSessionState.self, from: Data(contentsOf: external))
        #expect(retained.chatHistory == [.string("linked secret")])
        #expect(FileManager.default.fileExists(atPath: document.path))
    }

    @Test("owner directories writable by a group cannot be silently repaired after attacker access")
    func groupWritableDirectoriesFailClosed() async throws {
        for position in ["root", "sessions", "session"] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let sessionID = SessionID("private-session")
            let sessions = root.appendingPathComponent("sessions", isDirectory: true)
            let directory = sessions.appendingPathComponent(sessionID.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let unsafe = position == "root" ? root : position == "sessions" ? sessions : directory
            try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: unsafe.path)
            let store = SessionStateStore(root: root)

            await #expect(throws: ShellSessionSupportError.self) {
                try await store.save(state(sessionID: sessionID, transcript: "secret"))
            }
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(SessionStateStore.fileName).path
            ))
            #expect(try permissions(unsafe) == 0o775)
        }
    }

    @Test("swapping an established session directory for a symlink never redirects later saves")
    func swappedSessionDirectoryFailsClosed() async throws {
        let parent = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("home", isDirectory: true)
        let external = parent.appendingPathComponent("external", isDirectory: true)
        let sessionID = SessionID("private-session")
        let store = SessionStateStore(root: root)
        try await store.save(state(sessionID: sessionID, transcript: "original"))
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)

        let directory = root.appendingPathComponent("sessions").appendingPathComponent(sessionID.rawValue)
        let displaced = root.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: displaced)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: external)

        await #expect(throws: ShellSessionSupportError.self) {
            try await store.save(state(sessionID: sessionID, transcript: "replacement"))
        }
        await #expect(throws: ShellSessionSupportError.self) {
            try await store.load(sessionID: sessionID)
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        let retained = try JSONDecoder().decode(
            PersistedSessionState.self,
            from: Data(contentsOf: displaced.appendingPathComponent(SessionStateStore.fileName))
        )
        #expect(retained.chatHistory == [.string("original")])
    }

    private func permissions(_ path: URL) throws -> UInt16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let value = try #require(attributes[.posixPermissions] as? NSNumber)
        return value.uint16Value & 0o777
    }
    #endif

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-state-security-\(UUID().uuidString)", isDirectory: true)
    }

    private func state(sessionID: SessionID, transcript: String) -> PersistedSessionState {
        PersistedSessionState(
            summary: SessionSummary(sessionID: sessionID, cwd: "/workspace/project"),
            chatHistory: [.string(transcript)]
        )
    }
}
