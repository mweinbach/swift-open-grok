import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokSessionPersistence

#if os(Windows)
import COpenGrokSockets
#endif

@Suite("Windows extended-length durable session persistence")
struct WindowsLongPathPersistenceParityTests {
    @Test("durable history replacement survives an extended-length temporary sibling")
    func longTemporarySiblingReplacement() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let filename = "chat_history.jsonl"
        let segmentLength = max(1, 270 - root.path.utf16.count - filename.utf16.count - 2)
        let directory = root.appendingPathComponent(
            String(repeating: "s", count: segmentLength),
            isDirectory: true
        )
        let destination = directory.appendingPathComponent("chat_history.jsonl")
        let representativeTemporarySibling = directory.appendingPathComponent(
            ".chat_history.jsonl.\(UUID().uuidString).tmp"
        )
        #expect(destination.path.utf16.count > 260)
        #expect(representativeTemporarySibling.path.utf16.count > 260)

        try RelocationFS.writeAtomicDurable(path: destination, data: Data("first\n".utf8))
        try RelocationFS.writeAtomicDurable(path: destination, data: Data("second\n".utf8))

        #expect(try String(contentsOf: destination, encoding: .utf8) == "second\n")
        #if os(Windows)
        try expectOwnerPrivateWindowsFile(destination)
        #endif
        let siblings = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(siblings.map(\.lastPathComponent) == ["chat_history.jsonl"])
    }

    @Test("encoded cwd and UUID sessions preserve long-path chat history across saves")
    func canonicalSessionStoreUsesExtendedLengthAtomicReplacement() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let sessionID = UUID().uuidString
        let store = SessionDocumentStore(grokHome: home)
        let directory = try store.sessionDirectory(sessionID: sessionID, cwd: workspace.path)
        let temporaryHistory = directory.appendingPathComponent(
            ".chat_history.jsonl.\(UUID().uuidString).tmp"
        )
        #expect(temporaryHistory.path.utf16.count > 260)

        let first = try JSONValue.encode(ConversationItem.user("original history"))
        let second = try JSONValue.encode(ConversationItem.assistant("replacement history"))
        var state = PersistedSessionState(
            summary: SessionSummary(
                sessionID: SessionID(sessionID),
                cwd: workspace.path,
                currentModelID: "grok-code-fast-1"
            ),
            chatHistory: [first]
        )

        try store.save(state)
        state.chatHistory.append(second)
        try store.save(state)

        let recovered = try #require(try store.load(sessionID: sessionID, cwd: workspace.path))
        #expect(recovered.chatHistory == [first, second])
        #expect(recovered.summary.chatMessageCount == 2)

        #if os(Windows)
        for filename in ["chat_history.jsonl", "updates.jsonl", "state.json", "summary.json"] {
            try expectOwnerPrivateWindowsFile(directory.appendingPathComponent(filename))
        }
        #endif

        let temporarySiblings = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".tmp") }
        #expect(temporarySiblings.isEmpty)
    }

    #if os(Windows)
    @Test("drive and UNC session paths use idempotent canonical verbatim namespaces")
    func verbatimWindowsPathNamespaces() throws {
        #expect(
            try RelocationFS.windowsExtendedLengthPath("C:/workspace/session/chat_history.jsonl")
                == "\\\\?\\C:\\workspace\\session\\chat_history.jsonl"
        )
        #expect(
            try RelocationFS.windowsExtendedLengthPath("\\\\server\\share\\sessions\\chat_history.jsonl")
                == "\\\\?\\UNC\\server\\share\\sessions\\chat_history.jsonl"
        )
        #expect(
            try RelocationFS.windowsExtendedLengthPath("\\\\?\\C:\\sessions\\chat_history.jsonl")
                == "\\\\?\\C:\\sessions\\chat_history.jsonl"
        )
        #expect(
            try RelocationFS.windowsExtendedLengthPath("\\\\?\\UNC\\server\\share\\chat_history.jsonl")
                == "\\\\?\\UNC\\server\\share\\chat_history.jsonl"
        )
    }

    @Test("relative, device, traversal, and incomplete UNC paths fail closed")
    func unsafeWindowsPathNamespacesAreRejected() throws {
        for path in [
            "relative\\chat_history.jsonl",
            "C:relative\\chat_history.jsonl",
            "C:\\workspace\\..\\chat_history.jsonl",
            "\\\\.\\GLOBALROOT\\Device\\HarddiskVolume1\\chat_history.jsonl",
            "\\\\server",
        ] {
            #expect(throws: RelocationError.self) {
                try RelocationFS.windowsExtendedLengthPath(path)
            }
        }
    }

    private func expectOwnerPrivateWindowsFile(_ path: URL) throws {
        let extendedPath = try RelocationFS.windowsExtendedLengthPath(path.standardizedFileURL.path)
        #expect(extendedPath.withCString { og_file_is_owner_only($0) } == 1)
        #expect(extendedPath.withCString { og_path_is_private_to_current_user($0, 0) } == 1)
    }
    #endif

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-long-session-events-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
