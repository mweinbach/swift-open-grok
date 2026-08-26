import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokSessionPersistence

#if os(Windows)
import COpenGrokSockets
import WinSDK
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

        #if os(Windows)
        let written = try PathSecurity.readNoFollow(
            destination,
            maximumBytes: 128,
            requireOwnerOnly: true
        )
        #expect(String(data: written, encoding: .utf8) == "second\n")
        try expectOwnerPrivateWindowsFile(destination)
        let siblings = try WindowsSecurePath.contentsOfDirectory(
            at: directory,
            maximumEntries: 16,
            skipsHiddenFiles: false
        )
        #else
        #expect(try String(contentsOf: destination, encoding: .utf8) == "second\n")
        let siblings = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #endif
        #expect(siblings.map(\.lastPathComponent) == ["chat_history.jsonl"])
    }

    @Test("encoded cwd and UUID sessions preserve long-path chat history across saves")
    func canonicalSessionStoreUsesExtendedLengthAtomicReplacement() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent(String(repeating: "s", count: 120), isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let sessionID = UUID().uuidString
        let store = SessionDocumentStore(grokHome: home)
        let directory = try store.sessionDirectory(sessionID: sessionID, cwd: workspace.path)
        #expect(directory.path.utf16.count > 260)
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
        #expect(try store.load(sessionID: sessionID)?.chatHistory == [first, second])
        #expect(try store.list().map(\.sessionID.rawValue) == [sessionID])
        #expect(try store.list(cwd: workspace.path).map(\.sessionID.rawValue) == [sessionID])

        let third = try JSONValue.encode(ConversationItem.user("appended native history"))
        try store.appendChatItem(third, sessionID: sessionID, cwd: workspace.path)
        let update = try SessionUpdateEnvelope(
            timestamp: 123,
            method: "session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": .object([
                    "sessionUpdate": .string("user_message_chunk"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("native replay beyond MAX_PATH"),
                    ]),
                ]),
            ])
        )
        try store.appendUpdate(update, sessionID: sessionID, cwd: workspace.path)
        let event: JSONValue = .object(["type": .string("native-long-path-event")])
        try store.appendEvent(event, sessionID: sessionID, cwd: workspace.path)

        let replay = try #require(try store.load(sessionID: sessionID))
        #expect(replay.chatHistory == [first, second, third])
        #expect(replay.updates == [update])
        #expect(replay.summary.chatMessageCount == 3)
        #expect(replay.summary.messageCount == 1)
        #expect(try store.readEvents(sessionID: sessionID, cwd: workspace.path) == [event])

        #if os(Windows)
        for filename in ["chat_history.jsonl", "updates.jsonl", "state.json", "summary.json", "events.jsonl"] {
            let document = directory.appendingPathComponent(filename)
            #expect(document.path.utf16.count > 260)
            try expectOwnerPrivateWindowsFile(document)
        }
        let entries = try WindowsSecurePath.contentsOfDirectory(
            at: directory,
            maximumEntries: 32,
            skipsHiddenFiles: false
        )
        #else
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #endif
        let temporarySiblings = entries.filter { $0.lastPathComponent.hasSuffix(".tmp") }
        #expect(temporarySiblings.isEmpty)
    }

    #if os(Windows)
    @Test("canonical session discovery refuses permissive state ownership and reparse-point workspaces")
    func longPathDiscoveryRejectsUntrustedAncestors() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let broadHome = root.appendingPathComponent("broad-state", isDirectory: true)
        let broadSessions = broadHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: broadSessions, withIntermediateDirectories: true)
        let broadNative = try WindowsSecurePath.extendedLengthPath(broadSessions.path)
        guard broadNative.withCString({ og_path_is_private_to_current_user($0, 1) }) == 0 else {
            Issue.record("negative session-discovery fixture did not create a permissive state directory")
            return
        }
        #expect(throws: SessionDocumentStoreError.self) {
            try SessionDocumentStore(grokHome: broadHome).list()
        }

        let secureHome = root.appendingPathComponent("secure-state", isDirectory: true)
        let sessions = secureHome.appendingPathComponent("sessions", isDirectory: true)
        try RelocationFS.createDirectoryDurable(sessions, stateRoot: secureHome)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let redirect = sessions.appendingPathComponent(
            RelocationFS.encodeCwdDirname(workspace.path),
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: outside)

        #expect(throws: SessionDocumentStoreError.self) {
            try SessionDocumentStore(grokHome: secureHome).load(
                sessionID: "redirected",
                cwd: workspace.path
            )
        }
        #expect(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("redirected").path
        ) == false)
    }

    @Test("durable session creation hardens the state, sessions, workspace, and session chain")
    func durableDirectoryCreationProtectsEveryAncestor() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let sessions = state.appendingPathComponent("sessions", isDirectory: true)
        let workspace = sessions.appendingPathComponent("workspace", isDirectory: true)
        let session = workspace.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        #expect(state.path.withCString { og_path_is_private_to_current_user($0, 1) } != 1)

        try RelocationFS.createDirectoryDurable(session, stateRoot: state)

        for directory in [state, sessions, workspace, session] {
            let extended = try RelocationFS.windowsExtendedLengthPath(directory.standardizedFileURL.path)
            #expect(extended.withCString { og_path_is_private_to_current_user($0, 1) } == 1)
        }
        let history = session.appendingPathComponent("chat_history.jsonl")
        try RelocationFS.writeAtomicDurable(
            path: history,
            data: Data("private\n".utf8),
            stateRoot: state
        )
        try expectOwnerPrivateWindowsFile(history)
    }

    @Test("a directly constructed session store hardens its explicit preexisting home before persistence")
    func directSessionStoreHardensBroadExistingAncestors() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.appendingPathComponent("unregistered-state", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let sessionID = UUID().uuidString
        let store = SessionDocumentStore(grokHome: stateRoot)
        let session = try store.sessionDirectory(sessionID: sessionID, cwd: workspace.path)
        let directories = [
            stateRoot,
            stateRoot.appendingPathComponent("sessions"),
            session.deletingLastPathComponent(),
            session,
        ]
        // Inherit the parent's broad DACL: an owner-private creation helper
        // would remove the preexisting-ancestor negative control.
        for directory in directories {
            let native = try WindowsSecurePath.extendedLengthPath(directory.path)
            let failure = native.withCString(encodedAs: UTF16.self) { path -> DWORD? in
                guard CreateDirectoryW(path, nil) else { return GetLastError() }
                return nil
            }
            if let failure {
                throw NSError(
                    domain: "WindowsLongPathPersistenceFixture",
                    code: Int(failure),
                    userInfo: [NSFilePathErrorKey: directory.path]
                )
            }
        }
        #expect(stateRoot.path.withCString { og_path_is_private_to_current_user($0, 1) } != 1)

        let history = try JSONValue.encode(ConversationItem.user("owner-private session history"))
        try store.save(PersistedSessionState(
            summary: SessionSummary(
                sessionID: SessionID(sessionID),
                cwd: workspace.path,
                currentModelID: "grok-code-fast-1"
            ),
            chatHistory: [history]
        ))

        for directory in directories {
            let extended = try RelocationFS.windowsExtendedLengthPath(directory.standardizedFileURL.path)
            #expect(extended.withCString { og_path_is_private_to_current_user($0, 1) } == 1)
        }
        for filename in ["chat_history.jsonl", "updates.jsonl", "state.json", "summary.json"] {
            try expectOwnerPrivateWindowsFile(session.appendingPathComponent(filename))
        }
    }

    @Test("a directly constructed relocation journal protects its explicit home before opening the lease")
    func directRelocationJournalHardensExistingAncestorsBeforeLease() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.appendingPathComponent("unregistered-journal-state", isDirectory: true)
        let relocations = stateRoot.appendingPathComponent("relocations", isDirectory: true)
        try FileManager.default.createDirectory(at: relocations, withIntermediateDirectories: true)
        #expect(stateRoot.path.withCString { og_path_is_private_to_current_user($0, 1) } != 1)

        let sessionID = UUID().uuidString
        let journal = RelocationJournal(grokHome: stateRoot)
        try await journal.acquireLease(sessionID: sessionID)

        for directory in [stateRoot, relocations] {
            let extended = try RelocationFS.windowsExtendedLengthPath(directory.standardizedFileURL.path)
            #expect(extended.withCString { og_path_is_private_to_current_user($0, 1) } == 1)
        }
        try expectOwnerPrivateWindowsFile(
            RelocationFS.lockPath(grokHome: stateRoot, sessionID: sessionID)
        )
        await journal.releaseLease(sessionID: sessionID)
    }

    @Test("an explicit state root cannot authorize directory creation outside its boundary")
    func explicitStateRootRejectsUnrelatedDirectories() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(outside.path.withCString { og_path_is_private_to_current_user($0, 1) } != 1)

        #expect(throws: (any Error).self) {
            try RelocationFS.createDirectoryDurable(
                outside.appendingPathComponent("session"),
                stateRoot: stateRoot
            )
        }

        #expect(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("session").path
        ) == false)
        #expect(outside.path.withCString { og_path_is_private_to_current_user($0, 1) } != 1)
    }

    @Test("durable session creation refuses a reparse-point workspace before writing through it")
    func durableDirectoryRejectsReparsePoint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("state/sessions")
        let outside = root.appendingPathComponent("outside")
        for directory in [sessions, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let redirected = sessions.appendingPathComponent("workspace")
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            try RelocationFS.createDirectoryDurable(redirected.appendingPathComponent("session"))
        }
        #expect(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("session").path
        ) == false)
    }

    @Test("validation refuses inherited broad session files until their owner ACL is secured")
    func validationRejectsBroadSessionDocuments() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let broad = root.appendingPathComponent("broad.json")
        try Data("{}".utf8).write(to: broad)
        #expect(broad.path.withCString { og_path_is_private_to_current_user($0, 0) } != 1)

        #expect(throws: RelocationError.self) {
            try RelocationFS.requireRegularFile(broad)
        }
    }

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
