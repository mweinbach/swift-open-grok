import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private struct SessionSearchIndexFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let otherWorkspace: URL
    let gate = SessionSearchGate()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-session-search-index-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        otherWorkspace = root.appendingPathComponent("other-workspace", isDirectory: true)
        for directory in [home, workspace, otherWorkspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    var environment: [String: String] {
        ["HOME": home.path, "OPENGROK_HOME": home.path, "GROK_SESSION_SEARCH": "1"]
    }

    var indexPath: URL {
        home.appendingPathComponent("sessions/session_search.sqlite")
    }

    func document(
        id: String,
        title: String? = nil,
        content: String,
        workspace: URL? = nil,
        timestamp: TimeInterval = 1_000
    ) -> LiveSessionDocument {
        LiveSessionDocument(
            sessionID: id,
            workingDirectory: (workspace ?? self.workspace).path,
            title: title,
            updatedAt: Date(timeIntervalSince1970: timestamp),
            content: content
        )
    }

    func search(
        _ query: String,
        workspace: URL? = nil,
        limit: Int = 20,
        offset: Int = 0,
        includeContent: Bool = true,
        sources: (() throws -> [LiveSessionSearchIndexSource])? = nil
    ) throws -> LiveSessionSearchPage {
        try LiveSessionSearchIndex.search(
            openGrokHome: home,
            environment: environment,
            query: query,
            workingDirectory: workspace,
            limit: limit,
            offset: offset,
            includeContent: includeContent,
            gate: gate,
            sources: sources
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SessionSearchLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

#if canImport(SQLite3)
@Suite("Durable session SQLite FTS5 parity")
struct LiveSessionSearchIndexParityTests {
    @Test("the actual 10001st session is indexed and exact SQL totals and pagination survive")
    func fullCorpusBeyondFormerTenThousandCutoff() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let loads = SessionSearchLoadCounter()
        let documents = (0...10_000).map { offset in
            fixture.document(
                id: "session-\(offset)",
                title: "indexed session \(offset)",
                content: offset == 10_000
                    ? "sharedcorpus phosphorescentneedle"
                    : "sharedcorpus ordinaryentry",
                timestamp: TimeInterval(offset + 1)
            )
        }
        let sources = documents.map { document in
            LiveSessionSearchIndexSource(
                sessionID: document.sessionID,
                workingDirectory: document.workingDirectory,
                updatedAt: document.updatedAt,
                load: {
                    loads.increment()
                    return document
                }
            )
        }

        let rare = try fixture.search("phosphorescentneedle", sources: { sources })
        #expect(rare.total == 1)
        #expect(rare.hits.map(\.sessionID) == ["session-10000"])
        #expect(loads.count == 10_001)
        let indexIsOwnerPrivate = try SecureFile.isOwnerOnly(at: fixture.indexPath)
        #expect(indexIsOwnerPrivate)
        let sqliteHeader = try Data(contentsOf: fixture.indexPath).prefix(16)
        #expect(sqliteHeader == Data("SQLite format 3\u{0}".utf8))

        let penultimate = try fixture.search(
            "sharedcorpus",
            limit: 2,
            offset: 9_999,
            sources: { sources }
        )
        #expect(penultimate.total == 10_001)
        #expect(penultimate.hits.count == 2)
        #expect(penultimate.nextOffset == nil)
        #expect(loads.count == 10_001)

        let first = try fixture.search("sharedcorpus", limit: 2, sources: { sources })
        #expect(first.total == 10_001)
        #expect(first.nextOffset == 2)
        #expect(loads.count == 10_001)
    }

    @Test("reopening the database loads only changed documents and deletes stale rows")
    func restartUpdatesAndDeletesIncrementally() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let loads = SessionSearchLoadCounter()
        let original = fixture.document(
            id: "durable-session",
            title: "Original architecture",
            content: "outdatedkeyword",
            timestamp: 100
        )
        let initial = LiveSessionSearchIndexSource(
            sessionID: original.sessionID,
            workingDirectory: original.workingDirectory,
            updatedAt: original.updatedAt,
            load: {
                loads.increment()
                return original
            }
        )

        let firstMatch = try fixture.search("outdatedkeyword", sources: { [initial] })
        #expect(firstMatch.total == 1)
        #expect(loads.count == 1)
        let reopenedMatch = try fixture.search("architecture", sources: { [initial] })
        #expect(reopenedMatch.total == 1)
        #expect(loads.count == 1)

        let revised = fixture.document(
            id: "durable-session",
            title: "Revised architecture",
            content: "replacementkeyword",
            timestamp: 200
        )
        let changed = LiveSessionSearchIndexSource(
            sessionID: revised.sessionID,
            workingDirectory: revised.workingDirectory,
            updatedAt: revised.updatedAt,
            load: {
                loads.increment()
                return revised
            }
        )

        let updatedMatch = try fixture.search("replacementkeyword", sources: { [changed] })
        let staleMatch = try fixture.search("outdatedkeyword", sources: { [changed] })
        #expect(updatedMatch.total == 1)
        #expect(staleMatch.total == 0)
        #expect(loads.count == 2)
        let deletedMatch = try fixture.search("replacementkeyword", sources: { [] })
        #expect(deletedMatch.total == 0)
        #expect(loads.count == 2)
    }

    @Test("workspace-scoped indexing never loads another workspace's transcript")
    func workspaceIsolationPrecedesTranscriptLoading() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let localLoads = SessionSearchLoadCounter()
        let foreignLoads = SessionSearchLoadCounter()
        let local = fixture.document(id: "owned-session", content: "sharedphrase localprivate")
        let foreign = fixture.document(
            id: "foreign-session",
            content: "sharedphrase foreignsecret",
            workspace: fixture.otherWorkspace
        )
        let candidates = [
            LiveSessionSearchIndexSource(
                sessionID: local.sessionID,
                workingDirectory: local.workingDirectory,
                updatedAt: local.updatedAt,
                load: { localLoads.increment(); return local }
            ),
            LiveSessionSearchIndexSource(
                sessionID: foreign.sessionID,
                workingDirectory: foreign.workingDirectory,
                updatedAt: foreign.updatedAt,
                load: { foreignLoads.increment(); return foreign }
            ),
        ]

        let owned = try fixture.search("sharedphrase", workspace: fixture.workspace, sources: { candidates })
        #expect(owned.hits.map(\.sessionID) == ["owned-session"])
        #expect(localLoads.count == 1)
        #expect(foreignLoads.count == 0)

        let other = try fixture.search(
            "sharedphrase",
            workspace: fixture.otherWorkspace,
            sources: { candidates }
        )
        #expect(other.hits.map(\.sessionID) == ["foreign-session"])
        #expect(localLoads.count == 1)
        #expect(foreignLoads.count == 1)
        let foreignLeak = try fixture.search(
            "foreignsecret",
            workspace: fixture.workspace,
            sources: { candidates }
        )
        #expect(foreignLeak.total == 0)
    }

    @Test("a closed search gate never opens SQLite or enumerates transcript sources")
    func disabledGatePrecedesAllDiskAndTranscriptAccess() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        fixture.gate.applyGate(Resolved(value: false, source: .requirement))
        let enumerations = SessionSearchLoadCounter()

        let page = try fixture.search("secret") {
            enumerations.increment()
            return []
        }

        #expect(page.hits.isEmpty)
        #expect(page.total == 0)
        #expect(enumerations.count == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.indexPath.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("sessions").path
        ))
    }

    @Test("real canonical session documents bootstrap without an injected source")
    func canonicalDurableSessionsBootstrapLazily() async throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let store = LiveConversationStore(openGrokHome: fixture.home)
        var record = LiveConversationRecord.new(
            sessionID: "real-durable-session",
            workingDirectory: fixture.workspace
        )
        record.items = [.user("Find the real persistentsessionneedle in the transcript")]
        record.title = "Real durable session"
        try await store.save(record)

        let result = try fixture.search("persistentsessionneedle")

        #expect(result.total == 1)
        #expect(result.hits.first?.sessionID == "real-durable-session")
        #expect(result.documentsByID["real-durable-session"]?.content
            .contains("persistentsessionneedle") == true)
        let indexIsOwnerPrivate = try SecureFile.isOwnerOnly(at: fixture.indexPath)
        #expect(indexIsOwnerPrivate)
    }

    @Test("title-weighted BM25, OR fallback, UUID lookup and SQL snippets match Rust")
    func fullTextRankingAndIdentityParity() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let identifier = "019f870d-6976-7123-8123-abcdef123456"
        let titleMatch = fixture.document(
            id: identifier,
            title: "spectrograph architecture",
            content: "other topic",
            timestamp: 10
        )
        let contentMatch = fixture.document(
            id: "content-session",
            title: "unrelated title",
            content: "we documented the spectrograph clearly",
            timestamp: 20
        )
        let candidates = [titleMatch, contentMatch].map(LiveSessionSearchIndexSource.init(document:))

        let ranked = try fixture.search("spectrograph", sources: { candidates })
        #expect(ranked.total == 2)
        #expect(ranked.hits.first?.sessionID == identifier)
        #expect(ranked.documentsByID.count == 2)

        let fallback = try fixture.search("spectrograph nonexistent", sources: { candidates })
        #expect(fallback.total == 2)

        let byID = try fixture.search("019f870d-6976", sources: { candidates })
        #expect(byID.hits.map(\.sessionID) == [identifier])
        #expect(byID.hits.first?.snippet == "")

        let missingUUID = try fixture.search(
            "019f870d-6976-7123-8123-000000000000",
            sources: { candidates }
        )
        #expect(missingUUID.total == 0)

        let withoutContent = try fixture.search(
            "spectrograph",
            includeContent: false,
            sources: { candidates }
        )
        #expect(withoutContent.hits.allSatisfy { $0.snippet.isEmpty })
    }

    @Test("mismatched owner documents are rejected and never become searchable")
    func mismatchedCandidateOwnerFailsClosed() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let foreign = fixture.document(id: "different-owner", content: "privatesessionsecret")
        let candidate = LiveSessionSearchIndexSource(
            sessionID: "claimed-owner",
            workingDirectory: fixture.workspace.path,
            updatedAt: foreign.updatedAt,
            load: { foreign }
        )

        #expect(throws: LiveSessionSearchIndexError.self) {
            try fixture.search("privatesessionsecret", sources: { [candidate] })
        }
        let rejected = try fixture.search("privatesessionsecret", sources: { [] })
        #expect(rejected.total == 0)
    }

    #if !os(Windows)
    @Test("a trusted home ancestor alias opens the owner-private database without following its filename")
    func trustedAncestorSymlinkPreservesSecureSQLiteOpen() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let alias = fixture.root.appendingPathComponent("trusted-state-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.home)
        let document = fixture.document(id: "aliased-session", content: "trustedparentneedle")

        let result = try LiveSessionSearchIndex.search(
            openGrokHome: alias,
            environment: fixture.environment,
            query: "trustedparentneedle",
            limit: 20,
            gate: fixture.gate,
            sources: { [LiveSessionSearchIndexSource(document: document)] }
        )

        #expect(result.hits.map(\.sessionID) == ["aliased-session"])
        #expect(try SecureFile.isOwnerOnly(at: fixture.indexPath))
    }

    @Test("a symlinked sessions directory remains untrusted and never receives a database")
    func sessionsDirectorySymlinkFailsClosed() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let sessions = fixture.home.appendingPathComponent("sessions", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("foreign-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            try fixture.search("private", sources: { [] })
        }
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("session_search.sqlite").path
        ))
    }

    @Test("a symlinked SQLite destination is refused without modifying its target")
    func databaseSymlinkFailsClosed() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }
        let sessions = fixture.home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("foreign.sqlite")
        try SecureFile.write(at: outside, contents: "do-not-modify")
        try FileManager.default.createSymbolicLink(at: fixture.indexPath, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            try fixture.search("private", sources: { [] })
        }
        let preserved = try String(contentsOf: outside, encoding: .utf8)
        #expect(preserved == "do-not-modify")
    }
    #endif
}
#else
@Suite("Durable session SQLite availability")
struct LiveSessionSearchIndexParityTests {
    @Test("platforms without SQLite refuse session search instead of pretending to index")
    func missingSQLiteFailsClosed() throws {
        let fixture = try SessionSearchIndexFixture()
        defer { fixture.cleanup() }

        #expect(throws: LiveSessionSearchIndexError.self) {
            try fixture.search("unavailable")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.indexPath.path))
    }
}
#endif
