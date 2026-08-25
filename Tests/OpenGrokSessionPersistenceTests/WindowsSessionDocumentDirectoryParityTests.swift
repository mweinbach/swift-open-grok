import Foundation
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokSessionPersistence

#if os(Windows)
private struct WindowsSessionDocumentDirectoryFixture {
    let root: URL
    let state: URL
    let sessions: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-session-directory-document-\(UUID().uuidString)",
            isDirectory: true
        )
        state = root.appendingPathComponent("state", isDirectory: true)
        sessions = state.appendingPathComponent("sessions", isDirectory: true)
        try RelocationFS.createDirectoryDurable(sessions, stateRoot: state)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeDocument(named name: String) throws -> URL {
        let document = sessions.appendingPathComponent(name)
        try RelocationFS.writeAtomicDurable(
            path: document,
            data: Data("{}\n".utf8),
            stateRoot: state
        )
        return document
    }
}

@Suite("Windows session discovery distinguishes documents from directory attacks")
struct WindowsSessionDocumentDirectoryParityTests {
    @Test("legacy session documents are skipped while real canonical sessions stay discoverable")
    func looseLegacyDocumentDoesNotBreakSessionDiscovery() throws {
        let fixture = try WindowsSessionDocumentDirectoryFixture()
        defer { fixture.cleanup() }
        let legacy = try fixture.writeDocument(named: "shared-profile-live.json")
        let workspace = fixture.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let sessionID = "canonical-private-session"
        let store = SessionDocumentStore(grokHome: fixture.state)

        #expect(try WindowsSessionDirectoryTraversal.directoryExists(
            at: legacy,
            stateRoot: fixture.state
        ) == false)
        #expect(try store.list().isEmpty)

        try store.save(PersistedSessionState(
            summary: SessionSummary(
                sessionID: SessionID(sessionID),
                cwd: workspace.path,
                currentModelID: "grok-code-fast-1"
            )
        ))

        #expect(try store.load(sessionID: sessionID, cwd: workspace.path) != nil)
        #expect(try store.load(sessionID: sessionID) != nil)
        #expect(try store.list().map(\.sessionID.rawValue) == [sessionID])
    }

    @Test("regular files in an ancestor position still fail closed")
    func regularFileAncestorCannotBecomeDirectory() throws {
        let fixture = try WindowsSessionDocumentDirectoryFixture()
        defer { fixture.cleanup() }
        let document = try fixture.writeDocument(named: "blocked-ancestor.json")
        let impossibleChild = document.appendingPathComponent("redirected-session")

        #expect(throws: SessionDocumentStoreError.self) {
            try WindowsSessionDirectoryTraversal.directoryExists(
                at: impossibleChild,
                stateRoot: fixture.state
            )
        }
    }

    @Test("a reparse-point target remains rejected instead of being skipped")
    func directoryReparsePointCannotEscapeState() throws {
        let fixture = try WindowsSessionDocumentDirectoryFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let redirect = fixture.sessions.appendingPathComponent("redirected-workspace")
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: outside)

        #expect(throws: SessionDocumentStoreError.self) {
            try WindowsSessionDirectoryTraversal.directoryExists(
                at: redirect,
                stateRoot: fixture.state
            )
        }
    }

    @Test("a regular file cannot act as the owner-private state root")
    func regularStateRootRemainsInvalid() throws {
        let fixture = try WindowsSessionDocumentDirectoryFixture()
        defer { fixture.cleanup() }
        let document = try fixture.writeDocument(named: "not-a-state-root.json")

        #expect(throws: SessionDocumentStoreError.self) {
            try WindowsSessionDirectoryTraversal.directoryExists(
                at: document,
                stateRoot: document
            )
        }
    }
}
#endif
