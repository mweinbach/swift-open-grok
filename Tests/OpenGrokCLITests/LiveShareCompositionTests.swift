// LiveShareCompositionTests.swift
//
// Coverage for the `open-grok share` route.
//
// Every test drives the route from a parsed argv — the live seam
// (AGENTS.md §3): a route can be perfectly implemented and still be
// unreachable because the parser hands it a shape it does not recognise.
//
// The security invariant under test: a session that touched a non-xAI
// provider must be refused BEFORE any upload path, with upstream's exact
// refusal string, and no share URL may be printed. The two hard blockers
// (no persisted boundary marker in the session record; no ported upload
// path) are asserted to refuse with messages that name the gap and state
// that nothing left the process.

import Foundation
import Testing
@testable import OpenGrokCLI
import OpenGrokAuth
import OpenGrokConfigTypes
import OpenGrokSamplingTypes
import OpenGrokShellSessionSupport

// MARK: - Mock clients

/// Records whether `uploadShareData` was called, and with what arguments.
private final class MockShareSignedUploadClient: ShareSignedUploadClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(sessionID: String, itemCount: Int)] = []

    var calls: [(sessionID: String, itemCount: Int)] {
        snapshotCalls()
    }

    func uploadShareData(
        sessionID: String,
        items: [ConversationItem],
        boundary: ExportBoundary?
    ) async {
        // NSLock is sync-only under Swift 6 / macOS 27 SDK.
        recordCall(sessionID: sessionID, itemCount: items.count)
    }

    private func snapshotCalls() -> [(sessionID: String, itemCount: Int)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    private func recordCall(sessionID: String, itemCount: Int) {
        lock.lock()
        _calls.append((sessionID: sessionID, itemCount: itemCount))
        lock.unlock()
    }
}

/// Returns a canned share URL, or throws a canned error.
private final class MockShareBackendClient: ShareBackendClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(sessionID: String, itemCount: Int)] = []
    let result: Result<String, ShareBackendError>

    var calls: [(sessionID: String, itemCount: Int)] {
        snapshotCalls()
    }

    init(url: String) {
        self.result = .success(url)
    }

    init(error: ShareBackendError) {
        self.result = .failure(error)
    }

    func shareSession(
        sessionID: String,
        items: [ConversationItem],
        title: String?,
        cwd: String
    ) async throws -> String {
        recordCall(sessionID: sessionID, itemCount: items.count)
        return try result.get()
    }

    private func snapshotCalls() -> [(sessionID: String, itemCount: Int)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    private func recordCall(sessionID: String, itemCount: Int) {
        lock.lock()
        _calls.append((sessionID: sessionID, itemCount: itemCount))
        lock.unlock()
    }
}

@Suite("Live share composition")
struct LiveShareCompositionTests {
    // MARK: Fixtures

    private func shareOptions(_ argv: [String]) throws -> CLIUtilityOptions {
        let command = try CLICommandParser.parseOrThrow(argv)
        guard case .utility(let options) = command, options.name == "share" else {
            throw CLIApplicationError.failed("argv did not parse to the share route: \(argv)")
        }
        return options
    }

    private func makeHome() throws -> (url: URL, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, { try? FileManager.default.removeItem(at: url) })
    }

    /// First-party xAI credential (`isXAIAuth`): OIDC against the production
    /// issuer — upstream `is_xai_auth`, auth/model.rs:152-159.
    private func xaiAuth(teamBlockedReasons: [String] = []) -> GrokAuth {
        GrokAuth(
            key: "test-key",
            authMode: .oidc,
            userID: "user-1",
            teamBlockedReasons: teamBlockedReasons,
            codingDataRetentionOptOut: false,
            oidcIssuer: "https://auth.x.ai"
        )
    }

    /// `OPENGROK_AUTH` inline-env encoding. `AuthJSON`'s decoder accepts
    /// ISO8601 with or without fractional seconds (OpenGrokAuth
    /// Storage.swift:24-43), so a stock ISO8601 writer round-trips.
    private func inlineAuth(_ auth: GrokAuth) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = enc.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        let data = try encoder.encode(auth)
        return String(decoding: data, as: UTF8.self)
    }

    private func sharingSettings(_ enabled: Bool) throws -> RemoteSettings {
        try JSONDecoder().decode(
            RemoteSettings.self,
            from: Data(#"{"sharing_enabled": \#(enabled)}"#.utf8)
        )
    }

    private func environment(home: URL, auth: GrokAuth?) throws -> [String: String] {
        var environment = ["OPENGROK_HOME": home.path]
        if let auth {
            environment["OPENGROK_AUTH"] = try inlineAuth(auth)
        }
        return environment
    }

    private func saveRecord(
        sessionID: String,
        items: [ConversationItem],
        home: URL,
        everUsedNonXAI: Bool? = false
    ) async throws {
        var record = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        record.items = items
        record.everUsedNonXAI = everUsedNonXAI
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    private func expectFailure(
        _ expected: String,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("expected a refusal containing \(expected), but the route succeeded")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains(expected))
        } catch {
            Issue.record("expected CLIApplicationError, got \(error)")
        }
    }

    private var nullStreams: CLIStreams {
        CLIStreams(out: { _ in }, err: { _ in })
    }

    @Test("conversation record marker distinguishes false, true, and legacy nil")
    func recordMarkerCodec() throws {
        let fresh = LiveConversationRecord.new(
            sessionID: "codec",
            workingDirectory: URL(fileURLWithPath: "/tmp/project")
        )
        let freshData = try JSONEncoder().encode(fresh)
        let freshObject = try #require(
            JSONSerialization.jsonObject(with: freshData) as? [String: Any]
        )
        #expect((freshObject["ever_used_codex"] as? Bool) == false)

        var marked = fresh
        marked.everUsedNonXAI = true
        let markedRoundTrip = try JSONDecoder().decode(
            LiveConversationRecord.self,
            from: JSONEncoder().encode(marked)
        )
        #expect(markedRoundTrip.everUsedNonXAI == true)

        var legacyObject = freshObject
        legacyObject.removeValue(forKey: "ever_used_codex")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(LiveConversationRecord.self, from: legacyData)
        #expect(legacy.everUsedNonXAI == nil)
    }

    // MARK: Reachability

    @Test("handles matches the share route and nothing else")
    func handles() throws {
        #expect(LiveShareComposition.handles(try CLICommandParser.parseOrThrow(["share", "sess-1"])))
        #expect(!LiveShareComposition.handles(try CLICommandParser.parseOrThrow(["sessions", "list"])))
        #expect(!LiveShareComposition.handles(try CLICommandParser.parseOrThrow(["export", "f.md"])))
    }

    // MARK: Usage

    @Test("a missing session id is a usage error")
    func missingSessionID() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        await expectFailure("share requires a session id") {
            try await LiveShareComposition.run(
                options: shareOptions(["share"]),
                environment: ["OPENGROK_HOME": home.path],
                streams: nullStreams
            )
        }
    }

    // MARK: Account checks (share.rs:34-57)

    @Test("no credential refuses as authentication required, before any session I/O")
    func noAuth() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        // The session exists on disk; upstream still refuses on auth first
        // (share.rs:35 precedes the lookup at :60-67).
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: nil
        )
        await expectFailure("Authentication required to share session") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: nil),
                streams: nullStreams,
                remoteSettings: sharingSettings(true)
            )
        }
    }

    @Test("a non-xAI credential refuses with the login hint")
    func nonXaiAuth() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        let apiKeyAuth = GrokAuth(key: "sk-test", authMode: .apiKey, userID: "user-1")
        await expectFailure("Share session is disabled. Run `open-grok login` to authenticate.") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: apiKeyAuth),
                streams: nullStreams,
                remoteSettings: sharingSettings(true)
            )
        }
    }

    @Test("absent remote settings refuse as unavailable for the account — upstream's fail-closed default")
    func absentRemoteSettings() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        // share.rs:44-45 `.unwrap_or(false)`: with no `/v1/settings` payload,
        // `sharing_enabled` resolves false. This is the route's production
        // posture today — there is no settings fetch in this port.
        await expectFailure("Session sharing is not available for your account.") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: nullStreams
            )
        }
    }

    @Test("a ZDR team refuses on retention policy")
    func zdrTeam() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        let zdr = xaiAuth(teamBlockedReasons: ["BLOCKED_REASON_NO_LOGS"])
        await expectFailure("Session sharing is disabled for your team's data retention policy") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: zdr),
                streams: nullStreams,
                remoteSettings: sharingSettings(true)
            )
        }
    }

    // MARK: Lookup (share.rs:59-67)

    @Test("an unknown session refuses as not found, after the account checks")
    func sessionNotFound() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        await expectFailure("Session not found") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "missing-session"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: nullStreams,
                remoteSettings: sharingSettings(true)
            )
        }
    }

    // MARK: The boundary (share.rs:69-80)

    @Test("a session with no boundary marker and no live boundary is unverifiable, not clean")
    func unverifiableBoundary() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: nil
        )
        // Blocker 1: the live record persists no provider observation, so
        // the production route ALWAYS refuses here today — fail-closed.
        await expectFailure("cannot share session sess-1") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: nullStreams,
                remoteSettings: sharingSettings(true)
            )
        }
    }

    @Test("a Codex-marked session refuses as Codex-backed and prints no share URL")
    func codexMarkedSessionNeverUploads() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: true
        )
        let (streams, out, _) = CLIStreams.buffered()
        await expectFailure("Codex-backed sessions cannot be shared through xAI services.") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: streams,
                remoteSettings: sharingSettings(true),
            )
        }
        #expect(!out.contents.contains("http"))
    }

    @Test("a session whose live boundary closed refuses as Codex-backed")
    func liveClosedBoundaryRefuses() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: false
        )
        let boundary = ExportBoundary()
        boundary.observe(.codex)
        await expectFailure("Codex-backed sessions cannot be shared through xAI services.") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: nullStreams,
                remoteSettings: sharingSettings(true),
                liveBoundaries: { _ in boundary }
            )
        }
    }

    // MARK: Empty transcript (share.rs:96-98)

    @Test("an empty session refuses as nothing to share")
    func emptySession() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(sessionID: "sess-1", items: [], home: home, everUsedNonXAI: false)
        await expectFailure("No messages to share yet") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: nullStreams,
                remoteSettings: sharingSettings(true),
            )
        }
    }

    // MARK: No backend client (fail-closed)

    @Test("a fully authorized session still stops when no backend client is configured")
    func uploadBlocker() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: false
        )
        let (streams, out, _) = CLIStreams.buffered()
        do {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: streams,
                remoteSettings: sharingSettings(true)
            )
            Issue.record("the route succeeded, which means something claims to have uploaded")
        } catch let error as CLIApplicationError {
            #expect(error.description.contains("passed every share authorization check"))
            #expect(error.description.contains("no session-sharing backend client"))
            #expect(error.description.contains("No transcript bytes left this process"))
        }
        #expect(!out.contents.contains("http"))
    }

    @Test("an open live boundary cannot rescue a legacy record")
    func openLiveBoundaryCannotRescueLegacyRecord() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: nil
        )
        await expectFailure("cannot share session sess-1") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: nullStreams,
                remoteSettings: sharingSettings(true),
                liveBoundaries: { _ in ExportBoundary() }
            )
        }
    }

    // MARK: Successful share (share.rs:108-141)

    @Test("a fully authorized session with backend client returns the share URL")
    func successfulShare() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: false
        )
        let (streams, out, _) = CLIStreams.buffered()
        let upload = MockShareSignedUploadClient()
        let backend = MockShareBackendClient(url: "https://grok.com/build/share/perm-123")

        try await LiveShareComposition.run(
            options: shareOptions(["share", "sess-1"]),
            environment: environment(home: home, auth: xaiAuth()),
            streams: streams,
            remoteSettings: sharingSettings(true),
            signedUploadClient: upload,
            backendClient: backend
        )

        #expect(out.contents.contains("https://grok.com/build/share/perm-123"))
        #expect(upload.calls.count == 1)
        #expect(upload.calls.first?.sessionID == "sess-1")
        #expect(upload.calls.first?.itemCount == 1)
        #expect(backend.calls.count == 1)
        #expect(backend.calls.first?.sessionID == "sess-1")
    }

    @Test("share works without a signed-upload client — backend-only path")
    func shareWithoutSignedUpload() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: false
        )
        let (streams, out, _) = CLIStreams.buffered()
        let backend = MockShareBackendClient(url: "https://grok.com/build/share/perm-456")

        try await LiveShareComposition.run(
            options: shareOptions(["share", "sess-1"]),
            environment: environment(home: home, auth: xaiAuth()),
            streams: streams,
            remoteSettings: sharingSettings(true),
            backendClient: backend
        )

        #expect(out.contents.contains("https://grok.com/build/share/perm-456"))
        #expect(backend.calls.count == 1)
    }

    // MARK: Backend failure (share.rs:130-137)

    @Test("backend failure produces no share URL")
    func backendFailure() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: false
        )
        let (streams, out, _) = CLIStreams.buffered()
        let backend = MockShareBackendClient(error: .network("connection refused"))

        await expectFailure("Failed to share session") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: streams,
                remoteSettings: sharingSettings(true),
                backendClient: backend
            )
        }
        #expect(!out.contents.contains("http"))
        #expect(backend.calls.count == 1)
    }

    // MARK: Mid-flight boundary recheck (share.rs:117-123)

    @Test("mid-share boundary closure refuses after upload, before backend call")
    func midShareBoundaryClosure() async throws {
        let (home, cleanup) = try makeHome()
        defer { cleanup() }
        try await saveRecord(
            sessionID: "sess-1",
            items: [.user("hello")],
            home: home,
            everUsedNonXAI: false
        )
        let boundary = ExportBoundary()
        let (streams, out, _) = CLIStreams.buffered()

        // The upload client closes the boundary during upload, simulating
        // a provider switch that arrives while data is in flight.
        let closingUpload = ClosingShareSignedUploadClient(boundary: boundary)
        let backend = MockShareBackendClient(url: "https://grok.com/build/share/should-not-reach")

        await expectFailure("Session crossed the Codex provider boundary while sharing.") {
            try await LiveShareComposition.run(
                options: shareOptions(["share", "sess-1"]),
                environment: environment(home: home, auth: xaiAuth()),
                streams: streams,
                remoteSettings: sharingSettings(true),
                liveBoundaries: { _ in boundary },
                signedUploadClient: closingUpload,
                backendClient: backend
            )
        }

        #expect(!out.contents.contains("http"))
        // The upload was called (it's best-effort), but the backend was NOT.
        #expect(closingUpload.called)
        #expect(backend.calls.isEmpty)
    }
}

/// An upload client that closes the boundary during upload, simulating a
/// provider switch mid-share (share.rs:117-123).
private final class ClosingShareSignedUploadClient: ShareSignedUploadClient, @unchecked Sendable {
    let boundary: ExportBoundary
    private let lock = NSLock()
    private var _called = false

    var called: Bool {
        snapshotCalled()
    }

    init(boundary: ExportBoundary) {
        self.boundary = boundary
    }

    func uploadShareData(
        sessionID: String,
        items: [ConversationItem],
        boundary: ExportBoundary?
    ) async {
        self.boundary.observe(.codex)
        markCalled()
    }

    private func snapshotCalled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _called
    }

    private func markCalled() {
        lock.lock()
        _called = true
        lock.unlock()
    }
}
