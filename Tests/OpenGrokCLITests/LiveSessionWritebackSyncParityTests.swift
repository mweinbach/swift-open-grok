import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing

@testable import OpenGrokCLI

private typealias WritebackJSON = OpenGrokShared.JSONValue

private enum WritebackMockFailure: Error {
    case requested
}

private actor WritebackRemoteCapture: LiveSessionWritebackRemote {
    struct Call: Sendable {
        let method: String
        let sessionID: String
        let updates: [SessionUpdateEnvelope]
        let metadata: LiveSessionWritebackMetadata?
        let agentID: String?
    }

    private var calls: [Call] = []
    private var saveFailures = 0
    private var upsertFailures = 0

    func failSaves(_ count: Int) { saveFailures = count }
    func failUpserts(_ count: Int) { upsertFailures = count }
    func snapshot() -> [Call] { calls }

    func saveSessionData(
        sessionID: String,
        updates: [SessionUpdateEnvelope],
        metadata: LiveSessionWritebackMetadata?
    ) async throws {
        calls.append(Call(
            method: "POST",
            sessionID: sessionID,
            updates: updates,
            metadata: metadata,
            agentID: nil
        ))
        if saveFailures > 0 {
            saveFailures -= 1
            throw WritebackMockFailure.requested
        }
    }

    func upsertSession(
        sessionID: String,
        metadata: LiveSessionWritebackMetadata,
        agentID: String
    ) async throws {
        calls.append(Call(
            method: "PUT",
            sessionID: sessionID,
            updates: [],
            metadata: metadata,
            agentID: agentID
        ))
        if upsertFailures > 0 {
            upsertFailures -= 1
            throw WritebackMockFailure.requested
        }
    }
}

private struct WritebackSyncFixture: Sendable {
    let root: URL
    let home: URL
    let workspace: URL
    let sessionID: String

    var environment: [String: String] {
        ["HOME": root.path, "OPENGROK_HOME": home.path]
    }

    init(auth: GrokAuth? = Self.authentication()) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-writeback-sync-\(UUID().uuidString)",
            isDirectory: true
        )
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(temporary, stateRoot: temporary)
        #else
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        #endif
        let resolved = temporary.standardizedFileURL.resolvingSymlinksInPath()
        #if os(macOS)
        if resolved.path.hasPrefix("/var/") {
            root = URL(fileURLWithPath: "/private\(resolved.path)", isDirectory: true)
        } else {
            root = resolved
        }
        #else
        root = resolved
        #endif
        home = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        sessionID = UUID().uuidString.lowercased()
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        try OpenGrokConfig.createDirAllOwnerOnly(workspace, stateRoot: root)
        #else
        try OpenGrokConfig.createDirAllOwnerOnly(home)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        #endif
        if let auth {
            try persist(auth)
        }
    }

    static func authentication(
        userID: String = "writeback-user",
        token: String = "writeback-token",
        mode: AuthMode = .oidc,
        zdr: Bool = false,
        optedOut: Bool = true,
        issuer: String = "https://auth.x.ai"
    ) -> GrokAuth {
        GrokAuth(
            key: token,
            authMode: mode,
            userID: userID,
            principalID: "principal-1",
            teamID: "team-1",
            organizationID: "organization-1",
            teamBlockedReasons: zdr ? ["BLOCKED_REASON_NO_LOGS"] : [],
            codingDataRetentionOptOut: optedOut,
            refreshToken: mode == .oidc ? "refresh-writeback-token" : nil,
            expiresAt: Date().addingTimeInterval(3_600),
            oidcIssuer: issuer
        )
    }

    func persist(_ auth: GrokAuth) throws {
        let configuration = liveManagedAuthenticationConfiguration(environment: environment)
        try writeAuthJSON(
            at: home.appendingPathComponent("auth.json"),
            store: [configuration.authScope: auth]
        )
    }

    func record(
        provider: ModelProvider = .xai,
        exportAllowed: Bool? = false,
        title: String? = nil,
        knownTransportIDs: [String]? = nil
    ) -> LiveConversationRecord {
        var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        record.currentModelID = provider == .xai ? "grok-test" : "codex-test"
        record.currentProvider = provider
        record.everUsedNonXAI = exportAllowed
        record.title = title
        record.codeModeTransportCallIDs = knownTransportIDs
        return record
    }

    func publish(_ record: LiveConversationRecord) async throws {
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func append(_ envelopes: [SessionUpdateEnvelope]) throws {
        let store = SessionDocumentStore(grokHome: home)
        guard var state = try store.load(sessionID: sessionID, cwd: workspace.path) else {
            throw CLIApplicationError.failed("test session was not published")
        }
        state.updates.append(contentsOf: envelopes)
        state.summary.updatedAt = Date()
        try store.save(state)
    }

    func envelope(
        _ text: String,
        owner: String? = nil,
        method: String = "session/update"
    ) throws -> SessionUpdateEnvelope {
        try SessionUpdateEnvelope(
            timestamp: 123,
            method: method,
            params: .object([
                "sessionId": .string(owner ?? sessionID),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)]),
                ]),
            ])
        )
    }

    func tool(
        id: String,
        title: String? = nil,
        input: WritebackJSON? = nil,
        output: WritebackJSON? = nil,
        marked: Bool = false,
        terminal: Bool = false
    ) throws -> SessionUpdateEnvelope {
        var update: [String: WritebackJSON] = [
            "sessionUpdate": .string(terminal ? "tool_call_update" : "tool_call"),
            "toolCallId": .string(id),
        ]
        if let title { update["title"] = .string(title) }
        if let input { update["rawInput"] = input }
        if let output { update["rawOutput"] = output }
        if !terminal { update["kind"] = .string("other") }
        var params: [String: WritebackJSON] = [
            "sessionId": .string(sessionID),
            "update": .object(update),
        ]
        if marked {
            params["_meta"] = .object(["open-grok/codeModeTransport": .bool(true)])
        }
        return try SessionUpdateEnvelope(timestamp: 123, method: "session/update", params: .object(params))
    }

    func start(
        _ record: LiveConversationRecord,
        remote: WritebackRemoteCapture,
        mode: LiveSessionWritebackSync.Mode = .writeback,
        createdFresh: Bool = false,
        boundary: ExportBoundary? = nil,
        publishFirst: Bool = true
    ) async throws -> LiveSessionWritebackSync? {
        if publishFirst {
            try await publish(record)
        }
        return try await LiveSessionWritebackSync.start(
            mode: mode,
            home: home,
            environment: environment,
            record: record,
            boundary: boundary ?? ExportBoundary(everUsedNonXAI: false),
            transport: URLSessionHTTPTransport(),
            createdFresh: createdFresh,
            remote: remote
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Secure durable remote session writeback parity", .serialized)
struct LiveSessionWritebackSyncParityTests {
    @Test("storage mode defaults to local and CLI outranks injected environment")
    func storageModePrecedence() throws {
        #expect(try LiveSessionWritebackSync.resolveMode(cli: nil, environment: [:]) == .local)
        #expect(try LiveSessionWritebackSync.resolveMode(
            cli: nil,
            environment: ["GROK_STORAGE_MODE": "writeback"]
        ) == .writeback)
        #expect(try LiveSessionWritebackSync.resolveMode(
            cli: "local",
            environment: ["GROK_STORAGE_MODE": "writeback"]
        ) == .local)
        #expect(try LiveSessionWritebackSync.resolveMode(
            cli: "writeback",
            environment: ["GROK_STORAGE_MODE": "local"]
        ) == .writeback)
    }

    @Test("malformed explicit CLI and environment storage modes fail closed")
    func malformedModes() {
        #expect(throws: CLIApplicationError.self) {
            try LiveSessionWritebackSync.resolveMode(cli: "WRITEBACK", environment: [:])
        }
        #expect(throws: CLIApplicationError.self) {
            try LiveSessionWritebackSync.resolveMode(
                cli: nil,
                environment: ["GROK_STORAGE_MODE": "writeback "]
            )
        }
    }

    @Test("local mode remains local even without an authenticated account")
    func localRequiresNoAuthentication() async throws {
        let fixture = try WritebackSyncFixture(auth: nil)
        defer { fixture.dispose() }
        let remote = WritebackRemoteCapture()
        let result = try await fixture.start(fixture.record(), remote: remote, mode: .local)
        #expect(result == nil)
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("missing first-party session authentication is visibly refused")
    func missingAuthentication() async throws {
        let fixture = try WritebackSyncFixture(auth: nil)
        defer { fixture.dispose() }
        let remote = WritebackRemoteCapture()
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.start(fixture.record(), remote: remote)
        }
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("API-key authentication never authorizes session export")
    func apiKeyRefused() async throws {
        let fixture = try WritebackSyncFixture(auth: WritebackSyncFixture.authentication(mode: .apiKey))
        defer { fixture.dispose() }
        let remote = WritebackRemoteCapture()
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.start(fixture.record(), remote: remote)
        }
    }

    @Test("OIDC sessions without a usable refresh token fail before export begins")
    func nonRefreshableOIDCRefused() async throws {
        var legacy = WritebackSyncFixture.authentication()
        legacy.refreshToken = "  "
        let fixture = try WritebackSyncFixture(auth: legacy)
        defer { fixture.dispose() }
        let remote = WritebackRemoteCapture()
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.start(fixture.record(), remote: remote)
        }
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("a non-first-party OIDC issuer never authorizes session export")
    func foreignIssuerRefused() async throws {
        let fixture = try WritebackSyncFixture(auth: WritebackSyncFixture.authentication(
            issuer: "https://foreign.example"
        ))
        defer { fixture.dispose() }
        let remote = WritebackRemoteCapture()
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.start(fixture.record(), remote: remote)
        }
    }

    @Test("a genuine first-party external session is permitted")
    func firstPartyExternalPermitted() async throws {
        let fixture = try WritebackSyncFixture(auth: WritebackSyncFixture.authentication(mode: .external))
        defer { fixture.dispose() }
        let sync = try #require(try await fixture.start(fixture.record(), remote: WritebackRemoteCapture()))
        #expect(await sync.isPermanentlyClosed == false)
    }

    @Test("zero-data-retention teams are refused before any backend request")
    func zeroDataRetentionRefused() async throws {
        let fixture = try WritebackSyncFixture(auth: WritebackSyncFixture.authentication(zdr: true))
        defer { fixture.dispose() }
        let remote = WritebackRemoteCapture()
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.start(fixture.record(), remote: remote)
        }
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("non-ZDR coding-data retention opt-out does not disable upstream writeback")
    func retentionOptOutRemainsAllowed() async throws {
        let fixture = try WritebackSyncFixture(auth: WritebackSyncFixture.authentication(optedOut: true))
        defer { fixture.dispose() }
        let sync = try #require(try await fixture.start(fixture.record(), remote: WritebackRemoteCapture()))
        #expect(await sync.isPermanentlyClosed == false)
    }

    @Test("missing or previously closed durable provider boundaries are refused")
    func missingAndClosedBoundaryRefused() async throws {
        for marker in [Optional<Bool>.none, true] {
            let fixture = try WritebackSyncFixture()
            defer { fixture.dispose() }
            let record = fixture.record(exportAllowed: marker)
            await #expect(throws: CLIApplicationError.self) {
                try await fixture.start(record, remote: WritebackRemoteCapture())
            }
        }
    }

    @Test("Codex and a closed shared provider boundary cannot start writeback")
    func nonXAIAndClosedSharedBoundaryRefused() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.start(fixture.record(provider: .codex), remote: WritebackRemoteCapture())
        }
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.start(
                fixture.record(),
                remote: WritebackRemoteCapture(),
                boundary: ExportBoundary(everUsedNonXAI: true)
            )
        }
    }

    @Test("fresh durable history backfills as ACP POST followed by session-row PUT")
    func freshSessionBackfill() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        try await fixture.publish(record)
        try fixture.append([fixture.envelope("durable first")])
        let remote = WritebackRemoteCapture()
        _ = try #require(try await fixture.start(
            record,
            remote: remote,
            createdFresh: true,
            publishFirst: false
        ))

        let calls = await remote.snapshot()
        #expect(calls.map(\.method) == ["POST", "PUT"])
        #expect(calls.first?.updates.count == 1)
        #expect(calls.first?.sessionID == fixture.sessionID)
        #expect(calls.first?.metadata?.cwd == record.workingDirectory)
        #expect(calls.last?.agentID?.isEmpty == false)
    }

    @Test("resumed sessions never resend pre-existing backend history")
    func resumedSessionForwardOnly() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        try await fixture.publish(record)
        try fixture.append([fixture.envelope("already synced")])
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(
            record,
            remote: remote,
            createdFresh: false,
            publishFirst: false
        ))
        #expect(await remote.snapshot().isEmpty)

        try fixture.append([fixture.envelope("new durable message")])
        await sync.recordDurableCommit(record)
        await sync.flush()
        let calls = await remote.snapshot()
        #expect(calls.map(\.method) == ["POST", "PUT"])
        #expect(calls.first?.updates.first?.params["update"]?["content"]?["text"]?.stringValue
            == "new durable message")
    }

    @Test("xAI extension notifications never cross the ACP-only writeback boundary")
    func xaiExtensionsExcluded() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        try await fixture.publish(record)
        try fixture.append([
            fixture.envelope("private extension", method: "_x.ai/session/update"),
            fixture.envelope("safe ACP"),
        ])
        let remote = WritebackRemoteCapture()
        _ = try #require(try await fixture.start(
            record,
            remote: remote,
            createdFresh: true,
            publishFirst: false
        ))
        let sent = await remote.snapshot().first?.updates ?? []
        #expect(sent.count == 1)
        #expect(sent.first?.method == "session/update")
    }

    @Test("marked Code Mode secrets are removed while legitimate plugin exec survives")
    func markedTransportFilteringPreservesPlugin() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record(knownTransportIDs: ["secret-exec"])
        try await fixture.publish(record)
        try fixture.append([
            fixture.tool(id: "secret-exec", title: "exec", input: .string("PRIVATE_TOKEN"), marked: true),
            fixture.tool(id: "secret-exec", output: .object(["token": .string("PRIVATE_RESULT")]), terminal: true),
            fixture.tool(id: "plugin-exec", title: "exec", input: .object(["command": .string("safe")])),
        ])
        let remote = WritebackRemoteCapture()
        _ = try #require(try await fixture.start(
            record,
            remote: remote,
            createdFresh: true,
            publishFirst: false
        ))
        let sent = await remote.snapshot().first?.updates ?? []
        #expect(sent.count == 1)
        #expect(sent.first?.params["update"]?["toolCallId"]?.stringValue == "plugin-exec")
        let encoded = try JSONEncoder().encode(sent)
        #expect(String(decoding: encoded, as: UTF8.self).contains("PRIVATE_") == false)
    }

    @Test("legacy exec string provenance hides its derived wait without hiding plugin wait")
    func legacyTransportProvenance() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        try await fixture.publish(record)
        try fixture.append([
            fixture.tool(
                id: "legacy-exec",
                title: "exec",
                input: .string("SECRET_PROGRAM"),
                output: .object(["cell_id": .string("private-cell")])
            ),
            fixture.tool(
                id: "legacy-wait",
                title: "wait",
                input: .object(["cell_id": .string("private-cell")])
            ),
            fixture.tool(
                id: "plugin-wait",
                title: "wait",
                input: .object(["cell_id": .string("unrelated-plugin")])
            ),
        ])
        let remote = WritebackRemoteCapture()
        _ = try #require(try await fixture.start(
            record,
            remote: remote,
            createdFresh: true,
            publishFirst: false
        ))
        let sent = await remote.snapshot().first?.updates ?? []
        #expect(sent.count == 1)
        #expect(sent.first?.params["update"]?["toolCallId"]?.stringValue == "plugin-wait")
    }

    @Test("a later marked terminal update hides its earlier secret-bearing wrapper")
    func fullSnapshotMarkerPreventsSecretLeak() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        try await fixture.publish(record)
        try fixture.append([
            fixture.tool(id: "late-marker", title: "wait", input: .object(["secret": .string("PRIVATE")])),
            fixture.tool(id: "late-marker", marked: true, terminal: true),
            fixture.envelope("visible"),
        ])
        let remote = WritebackRemoteCapture()
        _ = try #require(try await fixture.start(
            record,
            remote: remote,
            createdFresh: true,
            publishFirst: false
        ))
        let updates = await remote.snapshot().first?.updates ?? []
        #expect(updates.count == 1)
        #expect(updates.first?.params["update"]?["content"]?["text"]?.stringValue == "visible")
    }

    @Test("a marker arriving after queue insertion removes the earlier wrapper before flushing")
    func laterMarkerReclassifiesPendingSecret() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append([
            fixture.tool(id: "late-secret", title: "wait", input: .object(["token": .string("PRIVATE")]))
        ])
        await sync.recordDurableCommit(record)
        #expect(await sync.pendingCount == 1)

        try fixture.append([fixture.tool(id: "late-secret", marked: true, terminal: true)])
        await sync.flush()
        #expect(await sync.pendingCount == 0)
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("cross-session ACP identity fails closed before backend synchronization")
    func crossSessionEnvelopeRefused() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        try await fixture.publish(record)
        try fixture.append([fixture.envelope("stolen", owner: UUID().uuidString)])
        let remote = WritebackRemoteCapture()
        await #expect(throws: CLIApplicationError.self) {
            try await fixture.start(record, remote: remote, createdFresh: true, publishFirst: false)
        }
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("account replacement permanently drops pending local session data")
    func accountSwitchClosesPermanently() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append([fixture.envelope("private")])
        await sync.recordDurableCommit(record)
        #expect(await sync.pendingCount == 1)

        try fixture.persist(WritebackSyncFixture.authentication(userID: "foreign-account"))
        await sync.flush()
        #expect(await sync.isPermanentlyClosed)
        #expect(await sync.pendingCount == 0)
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("a rotated bearer for the same immutable account remains authorized")
    func sameAccountTokenRotationAllowed() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append([fixture.envelope("safe")])
        await sync.recordDurableCommit(record)
        try fixture.persist(WritebackSyncFixture.authentication(token: "rotated-bearer"))
        await sync.flush()
        #expect(await remote.snapshot().map(\.method) == ["POST", "PUT"])
        #expect(await sync.isPermanentlyClosed == false)
    }

    @Test("logout closes export before a queued session update can leave the device")
    func logoutClosesPermanently() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append([fixture.envelope("private")])
        await sync.recordDurableCommit(record)
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("auth.json"))
        await sync.flush()
        #expect(await sync.isPermanentlyClosed)
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("a later ZDR account policy permanently closes session export")
    func accountBecomesZDR() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append([fixture.envelope("private")])
        await sync.recordDurableCommit(record)
        try fixture.persist(WritebackSyncFixture.authentication(zdr: true))
        await sync.flush()
        #expect(await sync.isPermanentlyClosed)
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("switching to Codex closes the shared boundary and cannot reopen on xAI")
    func providerBoundaryMonotonic() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let boundary = ExportBoundary(everUsedNonXAI: false)
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote, boundary: boundary))
        try fixture.append([fixture.envelope("private")])
        await sync.recordDurableCommit(record)
        var codex = fixture.record(provider: .codex)
        codex.everUsedNonXAI = true
        await sync.observeRoute(record: codex)
        #expect(boundary.allowsXaiExport == false)
        #expect(await sync.isPermanentlyClosed)
        await sync.observeRoute(record: record)
        await sync.flush()
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("changing the resident session identity permanently detaches old writeback")
    func replacementSessionCannotUseOldAccountQueue() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        var replacement = record
        replacement.sessionID = UUID().uuidString.lowercased()
        await sync.observeRoute(record: replacement)
        #expect(await sync.isPermanentlyClosed)
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("512 buffered messages do not trigger an emergency network flush")
    func exactMaximumDoesNotFlush() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append(try (0..<512).map { try fixture.envelope("entry-\($0)") })
        await sync.recordDurableCommit(record)
        #expect(await sync.pendingCount == 512)
        #expect(await remote.snapshot().isEmpty)
    }

    @Test("message 513 emergency-flushes the first 512 before buffering the newest")
    func successfulOverflowFlush() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append(try (0..<513).map { try fixture.envelope("entry-\($0)") })
        await sync.recordDurableCommit(record)
        let calls = await remote.snapshot()
        #expect(calls.map(\.method) == ["POST", "PUT"])
        #expect(calls.first?.updates.count == 512)
        #expect(await sync.pendingCount == 1)
    }

    @Test("failed overflow flush drops the oldest 64 then retains the newest 449")
    func failedOverflowDropsExactBatch() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        await remote.failSaves(1)
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append(try (0..<513).map { try fixture.envelope("entry-\($0)") })
        await sync.recordDurableCommit(record)
        #expect(await sync.pendingCount == 449)
        await sync.flush()
        let calls = await remote.snapshot()
        #expect(calls.map(\.method) == ["POST", "POST", "PUT"])
        let retry = try #require(calls.dropFirst().first)
        #expect(retry.updates.count == 449)
        #expect(retry.updates.first?.params["update"]?["content"]?["text"]?.stringValue
            == "entry-64")
    }

    @Test("failed POST preserves its pending local notifications for a later flush")
    func failedPostPreservesQueue() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        await remote.failSaves(1)
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append([fixture.envelope("retryable")])
        await sync.recordDurableCommit(record)
        await sync.flush()
        #expect(await sync.pendingCount == 1)
        await sync.flush()
        #expect(await sync.pendingCount == 0)
        #expect(await remote.snapshot().map(\.method) == ["POST", "POST", "PUT"])
    }

    @Test("a failed best-effort row PUT never duplicates an already appended POST")
    func failedPutDoesNotReplayPost() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        await remote.failUpserts(1)
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append([fixture.envelope("append exactly once")])
        await sync.recordDurableCommit(record)
        await sync.flush()
        await sync.flush()
        #expect(await sync.pendingCount == 0)
        #expect(await remote.snapshot().map(\.method) == ["POST", "PUT"])
    }

    @Test("manual rename immediately posts metadata and upserts the session title")
    func manualTitleImmediateSync() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        var record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        record.title = "Pinned session"
        try await fixture.publish(record)
        await sync.setManualTitle("Pinned session", record: record)
        let calls = await remote.snapshot()
        #expect(calls.map(\.method) == ["POST", "PUT"])
        let post = try #require(calls.first)
        #expect(post.updates.isEmpty)
        #expect(post.metadata?.title == "Pinned session")
        #expect(post.metadata?.titleIsManual == true)
    }

    @Test("clearing a manual title sends empty title and explicit false manual marker")
    func clearManualTitleUsesExplicitFalse() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        var record = fixture.record(title: "Pinned")
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        record.title = ""
        try await fixture.publish(record)
        await sync.setManualTitle("", record: record)
        let calls = await remote.snapshot()
        #expect(calls.map(\.method) == ["POST", "PUT"])
        let post = try #require(calls.first)
        #expect(post.metadata?.title == "")
        #expect(post.metadata?.titleIsManual == false)
    }

    @Test("a first-party model switch posts metadata without an unnecessary row PUT")
    func modelChangeMetadataOnly() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        var record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        record.currentModelID = "grok-replacement"
        try await fixture.publish(record)
        await sync.observeRoute(record: record)
        let calls = await remote.snapshot()
        #expect(calls.map(\.method) == ["POST"])
        let post = try #require(calls.first)
        #expect(post.updates.isEmpty)
        #expect(post.metadata?.modelID == "grok-replacement")
    }

    @Test("shutdown flushes pending durable data once and closes idempotently")
    func shutdownFlushesAndCloses() async throws {
        let fixture = try WritebackSyncFixture()
        defer { fixture.dispose() }
        let record = fixture.record()
        let remote = WritebackRemoteCapture()
        let sync = try #require(try await fixture.start(record, remote: remote))
        try fixture.append([fixture.envelope("final durable update")])
        await sync.recordDurableCommit(record)
        await sync.shutdown()
        await sync.shutdown()
        #expect(await sync.isPermanentlyClosed)
        #expect(await remote.snapshot().map(\.method) == ["POST", "PUT"])
    }
}
