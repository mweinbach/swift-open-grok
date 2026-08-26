import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private actor ACPResumeRecordingStore: ACPSessionStore {
    private var sessions: [AcpSessionId: ACPSessionSnapshot]
    private var readCount = 0
    private var updateCount = 0
    private var createCount = 0

    init(sessions: [ACPSessionSnapshot]) {
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    }

    func create(_ session: ACPSessionSnapshot) throws {
        createCount += 1
        guard sessions[session.sessionId] == nil else {
            throw ACPRuntimeError.sessionBusy(session.sessionId)
        }
        sessions[session.sessionId] = session
    }

    func read(_ sessionId: AcpSessionId) -> ACPSessionSnapshot? {
        readCount += 1
        return sessions[sessionId]
    }

    func update(_ session: ACPSessionSnapshot) throws {
        updateCount += 1
        guard sessions[session.sessionId] != nil else {
            throw ACPRuntimeError.sessionNotFound(session.sessionId)
        }
        sessions[session.sessionId] = session
    }

    func list(cwd: String?) -> [ACPSessionSnapshot] {
        sessions.values.filter { cwd == nil || $0.cwd == cwd }
    }

    func counters() -> (reads: Int, updates: Int, creates: Int) {
        (readCount, updateCount, createCount)
    }

    func snapshot(_ sessionId: AcpSessionId) -> ACPSessionSnapshot? {
        sessions[sessionId]
    }

    func resetCounters() {
        readCount = 0
        updateCount = 0
        createCount = 0
    }
}

private actor ACPResumeWorkspaceProbe: ACPWorkspaceBoundary {
    private var paths: [String] = []

    func validate(cwd: String) async throws -> String {
        paths.append(cwd)
        return cwd
    }

    func readTextFile(
        sessionId: AcpSessionId,
        path: String,
        line: UInt32?,
        limit: UInt32?
    ) async throws -> String {
        throw ACPRuntimeError.workspace("resume parity fixture does not expose file reads")
    }

    func writeTextFile(
        sessionId: AcpSessionId,
        path: String,
        content: String
    ) async throws {
        throw ACPRuntimeError.workspace("resume parity fixture does not expose file writes")
    }

    func validatedPaths() -> [String] {
        paths
    }

    func reset() {
        paths.removeAll()
    }
}

private actor ACPResumeNotificationProbe {
    private var messages: [ACPMessage] = []

    func append(_ message: ACPMessage) {
        messages.append(message)
    }

    func snapshot() -> [ACPMessage] {
        messages
    }

    func clear() {
        messages.removeAll()
    }
}

private actor ACPResumeLifecycleProbe {
    private var openings: [(AcpSessionId, AcpMeta?)] = []

    func opened(_ sessionId: AcpSessionId, meta: AcpMeta?) {
        openings.append((sessionId, meta))
    }

    func count() -> Int {
        openings.count
    }

    func latestMetadata() -> AcpMeta? {
        openings.last?.1
    }
}

private struct ACPResumeParityFixture: Sendable {
    static let defaultSessionID = AcpSessionId("resume-parity-private-session")
    static let originalDirectory = "resume-original-private-directory"
    static let userSecret = "PRIVATE_RESUME_USER_TRANSCRIPT_93caa7"
    static let assistantSecret = "PRIVATE_RESUME_ASSISTANT_TRANSCRIPT_601aef"

    let sessionID: AcpSessionId
    let workspace: String
    let store: ACPResumeRecordingStore
    let boundary: ACPResumeWorkspaceProbe
    let notifications: ACPResumeNotificationProbe
    let lifecycle: ACPResumeLifecycleProbe
    let runtime: ACPAgentRuntime

    init(sessionExists: Bool = true, closed: Bool = false) async throws {
        sessionID = Self.defaultSessionID
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-acp-resume-\(UUID().uuidString)")
            .path

        let updates = [
            SessionNotification(
                sessionId: sessionID,
                update: .userMessageChunk(ContentChunk(
                    content: .text(TextContent(text: Self.userSecret))
                )),
                meta: ["origin": .string("private-user")]
            ),
            SessionNotification(
                sessionId: sessionID,
                update: .agentMessageChunk(ContentChunk(
                    content: .text(TextContent(text: Self.assistantSecret))
                )),
                meta: ["origin": .string("private-assistant")]
            ),
            SessionNotification(
                sessionId: sessionID,
                update: .agentThoughtChunk(ContentChunk(
                    content: .text(TextContent(text: "PRIVATE_RESUME_REASONING"))
                ))
            ),
        ]
        let persisted = ACPSessionSnapshot(
            sessionId: sessionID,
            cwd: workspace,
            additionalDirectories: [Self.originalDirectory],
            modeId: SessionModeId("secure"),
            modelId: ModelId("grok-4.5"),
            closed: closed,
            createdAt: "2026-08-25T12:00:00Z",
            updatedAt: "2026-08-25T12:01:00Z",
            durableUpdates: updates
        )

        let store = ACPResumeRecordingStore(sessions: sessionExists ? [persisted] : [])
        let boundary = ACPResumeWorkspaceProbe()
        let notifications = ACPResumeNotificationProbe()
        let lifecycle = ACPResumeLifecycleProbe()
        let modes = SessionModeState(
            currentModeId: SessionModeId("secure"),
            availableModes: [SessionMode(id: SessionModeId("secure"), name: "Secure")]
        )
        let models = SessionModelState(
            currentModelId: ModelId("grok-4.5"),
            availableModels: [ModelInfo(modelId: ModelId("grok-4.5"), name: "Grok 4.5")]
        )
        let runtime = ACPAgentRuntime(
            configuration: ACPAgentConfiguration(modes: modes, models: models),
            store: store,
            workspaceBoundary: boundary,
            onSessionOpened: { id, meta in
                await lifecycle.opened(id, meta: meta)
            },
            timestamp: { "2026-08-25T12:15:00Z" }
        )
        await runtime.setNotificationSink { message in
            await notifications.append(message)
        }
        let initialized = await runtime.handle(.request(
            id: .string("initialize-resume-parity"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _?, nil)? = initialized.last else {
            throw ACPRuntimeError.transport("resume parity runtime failed to initialize")
        }

        self.store = store
        self.boundary = boundary
        self.notifications = notifications
        self.lifecycle = lifecycle
        self.runtime = runtime
    }

    func request(
        method: String,
        params: JSONValue,
        authority: String? = nil
    ) async -> (result: JSONValue?, error: AcpError?) {
        let message = ACPMessage.request(
            id: .string("resume-parity-\(UUID().uuidString)"),
            method: method,
            params: params
        )
        let response: [ACPMessage]
        if let authority {
            response = await ACPLeaderRequestAuthority.$clientID.withValue(authority) {
                await runtime.handle(message)
            }
        } else {
            response = await runtime.handle(message)
        }
        guard case .response(_, let result, let error)? = response.last else {
            return (nil, AcpError.internalError("resume parity runtime sent no response"))
        }
        return (result, error)
    }

    func resume(
        sessionID: AcpSessionId? = nil,
        cwd: String? = nil,
        additionalDirectories: [String] = [],
        metadata: AcpMeta? = nil,
        authority: String? = nil
    ) async throws -> (result: JSONValue?, error: AcpError?) {
        await request(
            method: AgentMethodNames.sessionResume,
            params: try JSONValue.encode(ResumeSessionRequest(
                sessionId: sessionID ?? self.sessionID,
                cwd: cwd ?? workspace,
                additionalDirectories: additionalDirectories,
                meta: metadata
            )),
            authority: authority
        )
    }

    func load(
        metadata: AcpMeta? = nil,
        cwd: String? = nil,
        additionalDirectories: [String] = [],
        authority: String? = nil
    ) async throws -> (result: JSONValue?, error: AcpError?) {
        await request(
            method: AgentMethodNames.sessionLoad,
            params: try JSONValue.encode(LoadSessionRequest(
                sessionId: sessionID,
                cwd: cwd ?? workspace,
                additionalDirectories: additionalDirectories,
                meta: metadata
            )),
            authority: authority
        )
    }

    func prepareOwnerAndObserver() async throws {
        await runtime.setSessionOwnerVerifier { id, clientID in
            id == Self.defaultSessionID && clientID == "resume-owner"
        }
        let (result, error) = try await load(
            metadata: ["noReplay": .bool(true)],
            authority: "resume-owner"
        )
        guard result != nil, error == nil else {
            throw ACPRuntimeError.transport("resume parity owner could not open lifecycle")
        }
        await store.resetCounters()
        await boundary.reset()
        await notifications.clear()
        _ = await runtime.pollNotifications()
    }

    func queuedUpdates() async -> [ACPMessage] {
        let messages = await runtime.pollNotifications()
        return messages.filter { $0.method == ClientMethodNames.sessionUpdate }
    }

    func receivedUpdates() async -> [ACPMessage] {
        let messages = await notifications.snapshot()
        return messages.filter { $0.method == ClientMethodNames.sessionUpdate }
    }

    func cleanup() async {
        await runtime.close()
    }
}

@Suite("ACP resume and load replay privacy parity", .serialized)
struct ACPResumeSemanticsParityTests {
    @Test("resume rejects additionalDirectories with the exact upstream ACP error before lookup")
    func resumeRejectsAdditionalDirectoriesBeforeSessionLookup() async throws {
        let fixture = try await ACPResumeParityFixture()
        let before = try #require(await fixture.store.snapshot(fixture.sessionID))

        let (result, error) = try await fixture.resume(
            additionalDirectories: ["/attacker/private-root"]
        )

        #expect(result == nil)
        #expect(error?.code == .invalidParams)
        #expect(error?.message == "Invalid params")
        #expect(error?.data == .string("session/resume does not support additionalDirectories"))
        let counters = await fixture.store.counters()
        #expect(counters.reads == 0)
        #expect(counters.updates == 0)
        #expect(await fixture.boundary.validatedPaths().isEmpty)
        #expect(await fixture.lifecycle.count() == 0)
        #expect(await fixture.store.snapshot(fixture.sessionID) == before)
        #expect(await fixture.queuedUpdates().isEmpty)
        await fixture.cleanup()
    }

    @Test("resume refuses extra roots even when the claimed session does not exist")
    func extraDirectoriesTakePrecedenceOverMissingSession() async throws {
        let fixture = try await ACPResumeParityFixture(sessionExists: false)

        let (result, error) = try await fixture.resume(
            sessionID: AcpSessionId("missing-private-session"),
            additionalDirectories: ["/attacker/first", "/attacker/second"]
        )

        #expect(result == nil)
        #expect(error?.code == .invalidParams)
        #expect(error?.data == .string("session/resume does not support additionalDirectories"))
        #expect(await fixture.store.counters().reads == 0)
        #expect(await fixture.boundary.validatedPaths().isEmpty)
        #expect(await fixture.lifecycle.count() == 0)
        await fixture.cleanup()
    }

    @Test("observer-supplied extra roots are refused before ownership lookup or store mutation")
    func observerAdditionalDirectoriesAreRejectedBeforeLookup() async throws {
        let fixture = try await ACPResumeParityFixture()
        try await fixture.prepareOwnerAndObserver()

        let (result, error) = try await fixture.resume(
            additionalDirectories: ["/observer/unauthorized-root"],
            authority: "resume-observer"
        )

        #expect(result == nil)
        #expect(error?.code == .invalidParams)
        #expect(error?.message == "Invalid params")
        #expect(error?.data == .string("session/resume does not support additionalDirectories"))
        #expect(await fixture.store.counters().reads == 0)
        #expect(await fixture.store.counters().updates == 0)
        #expect(await fixture.boundary.validatedPaths().isEmpty)
        #expect(await fixture.receivedUpdates().isEmpty)
        await fixture.cleanup()
    }

    @Test("owner resume never replays any user, assistant, or reasoning transcript")
    func ownerResumeNeverReplaysDurableTranscript() async throws {
        let fixture = try await ACPResumeParityFixture()

        let (result, error) = try await fixture.resume()

        #expect(error == nil)
        let response = try #require(result).decode(ResumeSessionResponse.self)
        #expect(response.modes?.currentModeId == SessionModeId("secure"))
        #expect(response.models?.currentModelId == ModelId("grok-4.5"))
        #expect(await fixture.queuedUpdates().isEmpty)
        #expect(await fixture.receivedUpdates().isEmpty)
        #expect(await fixture.boundary.validatedPaths() == [fixture.workspace])
        let snapshot = try #require(await fixture.store.snapshot(fixture.sessionID))
        #expect(snapshot.additionalDirectories == [ACPResumeParityFixture.originalDirectory])
        #expect(snapshot.durableUpdates.count == 3)
        #expect(snapshot.updatedAt == "2026-08-25T12:15:00Z")
        await fixture.cleanup()
    }

    @Test("resume ignores hostile false replay flags and restore-code metadata")
    func hostileResumeMetadataCannotReenableReplayOrRestore() async throws {
        let fixture = try await ACPResumeParityFixture()

        let (result, error) = try await fixture.resume(metadata: [
            "noReplay": .bool(false),
            "x.ai/restore_code": .bool(true),
            "restoreCode": .bool(true),
            "isReplay": .bool(false),
            ACPLeaderCapabilityInjection.clientIDKey: .number(.uint64(404)),
        ])

        #expect(error == nil)
        #expect(result != nil)
        #expect(await fixture.queuedUpdates().isEmpty)
        #expect(await fixture.receivedUpdates().isEmpty)
        #expect(await fixture.lifecycle.count() == 1)
        #expect(await fixture.boundary.validatedPaths() == [fixture.workspace])
        #expect(await fixture.store.counters().updates == 1)
        await fixture.cleanup()
    }

    @Test("every hostile noReplay metadata type remains unable to force resume replay")
    func resumeIgnoresAllReplayMetadataShapes() async throws {
        let values: [JSONValue] = [
            .bool(false),
            .bool(true),
            .string("false"),
            .number(.int64(0)),
            .null,
            .object(["value": .bool(false)]),
        ]
        for value in values {
            let fixture = try await ACPResumeParityFixture()
            let (result, error) = try await fixture.resume(metadata: ["noReplay": value])

            #expect(error == nil)
            #expect(result != nil)
            #expect(await fixture.queuedUpdates().isEmpty)
            #expect(await fixture.receivedUpdates().isEmpty)
            await fixture.cleanup()
        }
    }

    @Test("an observer resume returns its valid response without leaking owner transcript")
    func observerResumeNeverReplaysOrMutatesOwnerSession() async throws {
        let fixture = try await ACPResumeParityFixture()
        try await fixture.prepareOwnerAndObserver()
        let original = try #require(await fixture.store.snapshot(fixture.sessionID))

        let (result, error) = try await fixture.resume(
            cwd: "/observer/foreign-workspace",
            metadata: [
                "noReplay": .bool(false),
                "x.ai/restore_code": .bool(true),
                ACPLeaderCapabilityInjection.clientIDKey: .number(.uint64(2)),
            ],
            authority: "resume-observer"
        )

        #expect(error == nil)
        let response = try #require(result).decode(ResumeSessionResponse.self)
        #expect(response.modes?.currentModeId == SessionModeId("secure"))
        #expect(response.models?.currentModelId == ModelId("grok-4.5"))
        #expect(await fixture.receivedUpdates().isEmpty)
        #expect(await fixture.queuedUpdates().isEmpty)
        #expect(await fixture.boundary.validatedPaths().isEmpty)
        #expect(await fixture.store.counters().updates == 0)
        #expect(await fixture.store.snapshot(fixture.sessionID) == original)
        await fixture.cleanup()
    }

    @Test("missing resume cwd is refused before any session lookup")
    func resumeRequiresExplicitWorkspace() async throws {
        let fixture = try await ACPResumeParityFixture()

        let (result, error) = await fixture.request(
            method: AgentMethodNames.sessionResume,
            params: .object(["sessionId": .string(fixture.sessionID.rawValue)])
        )

        #expect(result == nil)
        #expect(error?.code == .invalidParams)
        #expect(await fixture.store.counters().reads == 0)
        #expect(await fixture.boundary.validatedPaths().isEmpty)
        await fixture.cleanup()
    }

    @Test("resume validates its mandatory requested cwd and preserves persisted extra roots")
    func resumeValidatesRequestedWorkspaceWithoutReplacingApprovedRoots() async throws {
        let fixture = try await ACPResumeParityFixture()
        let requested = fixture.workspace + "-relocated"

        let (result, error) = try await fixture.resume(cwd: requested)

        #expect(error == nil)
        #expect(result != nil)
        #expect(await fixture.boundary.validatedPaths() == [requested])
        let persisted = try #require(await fixture.store.snapshot(fixture.sessionID))
        #expect(persisted.cwd == requested)
        #expect(persisted.additionalDirectories == [ACPResumeParityFixture.originalDirectory])
        #expect(await fixture.receivedUpdates().isEmpty)
        await fixture.cleanup()
    }

    @Test("a normal session/load replays every durable transcript update")
    func loadReplaysDurableTranscriptByDefault() async throws {
        let fixture = try await ACPResumeParityFixture()

        let (result, error) = try await fixture.load()

        #expect(error == nil)
        let response = try #require(result).decode(LoadSessionResponse.self)
        #expect(response.modes?.currentModeId == SessionModeId("secure"))
        #expect(response.models?.currentModelId == ModelId("grok-4.5"))
        let queued = await fixture.queuedUpdates()
        let received = await fixture.receivedUpdates()
        #expect(queued.count == 3)
        #expect(received.count == 3)
        #expect(queued.allSatisfy { $0.params?["_meta"]?["isReplay"]?.boolValue == true })
        #expect(queued.contains {
            $0.params?["update"]?["content"]?["text"]?.stringValue
                == ACPResumeParityFixture.userSecret
        })
        #expect(queued.contains {
            $0.params?["update"]?["content"]?["text"]?.stringValue
                == ACPResumeParityFixture.assistantSecret
        })
        await fixture.cleanup()
    }

    @Test("load noReplay suppresses both live sink and queued transcript updates")
    func loadNoReplaySuppressesTranscriptButRetainsResponseAndLifecycle() async throws {
        let fixture = try await ACPResumeParityFixture()

        let (result, error) = try await fixture.load(metadata: [
            "noReplay": .bool(true),
            "lifecycle-marker": .string("retain-lifecycle"),
        ])

        #expect(error == nil)
        let response = try #require(result).decode(LoadSessionResponse.self)
        #expect(response.modes?.currentModeId == SessionModeId("secure"))
        #expect(response.models?.currentModelId == ModelId("grok-4.5"))
        #expect(await fixture.queuedUpdates().isEmpty)
        #expect(await fixture.receivedUpdates().isEmpty)
        #expect(await fixture.lifecycle.count() == 1)
        #expect(await fixture.lifecycle.latestMetadata()?["lifecycle-marker"]
            == .string("retain-lifecycle"))
        #expect(await fixture.boundary.validatedPaths() == [fixture.workspace])
        #expect(await fixture.store.counters().updates == 1)
        #expect(await fixture.store.snapshot(fixture.sessionID)?.durableUpdates.count == 3)
        await fixture.cleanup()
    }

    @Test("load noReplay false retains normal transcript replay")
    func loadExplicitFalseStillReplays() async throws {
        let fixture = try await ACPResumeParityFixture()

        let (result, error) = try await fixture.load(metadata: ["noReplay": .bool(false)])

        #expect(error == nil)
        #expect(result != nil)
        #expect(await fixture.queuedUpdates().count == 3)
        #expect(await fixture.receivedUpdates().count == 3)
        await fixture.cleanup()
    }

    @Test("only the exact boolean noReplay spelling suppresses load replay")
    func loadRejectsSpoofedReplayMetadataTypesAndKeys() async throws {
        let hostileMetadata: [AcpMeta] = [
            ["noReplay": .string("true")],
            ["noReplay": .number(.int64(1))],
            ["noReplay": .null],
            ["noReplay": .object(["value": .bool(true)])],
            ["no_replay": .bool(true)],
            ["x.ai/noReplay": .bool(true)],
            ["NoReplay": .bool(true)],
        ]
        for metadata in hostileMetadata {
            let fixture = try await ACPResumeParityFixture()
            let (result, error) = try await fixture.load(metadata: metadata)

            #expect(error == nil)
            #expect(result != nil)
            #expect(await fixture.queuedUpdates().count == 3)
            #expect(await fixture.receivedUpdates().count == 3)
            await fixture.cleanup()
        }
    }

    @Test("observer noReplay load preserves owner privacy without mutating its workspace")
    func observerNoReplayLoadSuppressesOwnerTranscript() async throws {
        let fixture = try await ACPResumeParityFixture()
        try await fixture.prepareOwnerAndObserver()
        let before = try #require(await fixture.store.snapshot(fixture.sessionID))

        let (result, error) = try await fixture.load(
            metadata: [
                "noReplay": .bool(true),
                ACPLeaderCapabilityInjection.clientIDKey: .number(.uint64(2)),
            ],
            cwd: "/observer/untrusted-workspace",
            additionalDirectories: ["/observer/untrusted-root"],
            authority: "resume-observer"
        )

        #expect(error == nil)
        let response = try #require(result).decode(LoadSessionResponse.self)
        #expect(response.models?.currentModelId == ModelId("grok-4.5"))
        #expect(await fixture.queuedUpdates().isEmpty)
        #expect(await fixture.receivedUpdates().isEmpty)
        #expect(await fixture.boundary.validatedPaths().isEmpty)
        #expect(await fixture.store.counters().updates == 0)
        #expect(await fixture.store.snapshot(fixture.sessionID) == before)
        await fixture.cleanup()
    }

    @Test("ordinary observer load still receives owner-scoped replay routing")
    func observerDefaultLoadStillReplaysToItsClaimedClient() async throws {
        let fixture = try await ACPResumeParityFixture()
        try await fixture.prepareOwnerAndObserver()

        let (result, error) = try await fixture.load(
            metadata: [ACPLeaderCapabilityInjection.clientIDKey: .number(.uint64(7))],
            authority: "resume-observer"
        )

        #expect(error == nil)
        #expect(result != nil)
        let messages = await fixture.receivedUpdates()
        #expect(messages.count == 3)
        #expect(messages.allSatisfy {
            $0.params?["_meta"]?["isReplay"]?.boolValue == true
                && $0.params?["_meta"]?[ACPLeaderCapabilityInjection.clientIDKey]?.uint64Value == 7
        })
        #expect(await fixture.store.counters().updates == 0)
        #expect(await fixture.boundary.validatedPaths().isEmpty)
        await fixture.cleanup()
    }

    @Test("a missing session still returns its real resource-not-found response")
    func missingResumeStillReturnsLegitimateFailureWithoutReplay() async throws {
        let fixture = try await ACPResumeParityFixture(sessionExists: false)

        let (result, error) = try await fixture.resume()

        #expect(result == nil)
        #expect(error?.code == .resourceNotFound)
        #expect(error?.data?["uri"]?.stringValue == "session://\(fixture.sessionID.rawValue)")
        #expect(await fixture.store.counters().reads == 1)
        #expect(await fixture.receivedUpdates().isEmpty)
        await fixture.cleanup()
    }

    @Test("replay policy remains method-owned across sequential load and resume attachments")
    func sequentialAttachMethodsDoNotInheritReplayPolicy() async throws {
        let fixture = try await ACPResumeParityFixture()

        let first = try await fixture.load(metadata: ["noReplay": .bool(true)])
        #expect(first.error == nil)
        #expect(await fixture.queuedUpdates().isEmpty)
        #expect(await fixture.receivedUpdates().isEmpty)

        let second = try await fixture.resume(metadata: ["noReplay": .bool(false)])
        #expect(second.error == nil)
        #expect(await fixture.queuedUpdates().isEmpty)
        #expect(await fixture.receivedUpdates().isEmpty)

        let third = try await fixture.load(metadata: ["noReplay": .bool(false)])
        #expect(third.error == nil)
        #expect(await fixture.queuedUpdates().count == 3)
        #expect(await fixture.receivedUpdates().count == 3)
        await fixture.cleanup()
    }
}
