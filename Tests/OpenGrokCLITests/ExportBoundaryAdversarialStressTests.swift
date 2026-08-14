// ExportBoundaryAdversarialStressTests.swift
//
// Adversarial stress test suite for Export Boundary monotonic enforcement,
// rapid model switching, reference identity preservation, registry updates,
// subagent propagation, refusal behavior across CLI/ACP, and session fork inheritance.
//
// Challenger 2 verification harness for Milestone 3.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

// MARK: - Mocks & Test Fixtures

private final class AdversarialShareBackendClient: ShareBackendClient, @unchecked Sendable {
    let returnURL: String
    var shareCallCount = 0
    var lastSharedSessionID: String?

    init(returnURL: String = "https://grok.com/build/share/adversarial-123") {
        self.returnURL = returnURL
    }

    func shareSession(
        sessionID: String,
        items: [ConversationItem],
        title: String?,
        cwd: String
    ) async throws -> String {
        shareCallCount += 1
        lastSharedSessionID = sessionID
        return returnURL
    }
}

private final class AdversarialShareSignedUploadClient: ShareSignedUploadClient, @unchecked Sendable {
    var uploadCallCount = 0
    var midUploadMutation: (@Sendable (ExportBoundary?) -> Void)?

    init(midUploadMutation: (@Sendable (ExportBoundary?) -> Void)? = nil) {
        self.midUploadMutation = midUploadMutation
    }

    func uploadShareData(
        sessionID: String,
        items: [ConversationItem],
        boundary: ExportBoundary?
    ) async {
        uploadCallCount += 1
        midUploadMutation?(boundary)
    }
}

private struct AdversarialHarness {
    let root: URL
    let home: URL
    let store: LiveConversationStore

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("og-adversarial-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = LiveConversationStore(openGrokHome: home)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func xaiAuth(zdr: Bool = false) -> GrokAuth {
        GrokAuth(
            key: "xai-test-key",
            authMode: .oidc,
            userID: "user-adv-1",
            teamBlockedReasons: zdr ? ["BLOCKED_REASON_NO_LOGS"] : [],
            codingDataRetentionOptOut: false,
            oidcIssuer: "https://auth.x.ai"
        )
    }

    static func nonXaiAuth() -> GrokAuth {
        GrokAuth(
            key: "custom-token-key",
            authMode: .apiKey,
            userID: "user-nonxai",
            teamBlockedReasons: [],
            codingDataRetentionOptOut: false,
            oidcIssuer: nil
        )
    }

    static func inlineAuthString(_ auth: GrokAuth) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = enc.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return String(decoding: try encoder.encode(auth), as: UTF8.self)
    }

    static func makeRemoteSettings(sharingEnabled: Bool) throws -> RemoteSettings {
        try JSONDecoder().decode(
            RemoteSettings.self,
            from: Data(#"{"sharing_enabled": \#(sharingEnabled)}"#.utf8)
        )
    }
}

// MARK: - Test Suite

@Suite("Export Boundary Adversarial Stress Tests", .serialized)
struct ExportBoundaryAdversarialStressTests {

    // MARK: - 1. Rapid Model Switching Monotonicity

    @Test("Rapid model switching across providers enforces strict irreversibility and disk persistence")
    func rapidModelSwitchingMonotonicity() async throws {
        let harness = try AdversarialHarness()
        defer { harness.cleanup() }

        let sessionID = "sess_rapid_switch"
        var record = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: harness.home
        )
        record.items = [.user("Initial prompt before switching")]
        try await harness.store.save(record)

        let history = LiveConversationHistory(record: record, store: harness.store)
        let boundary = await history.sharedExportBoundary

        // Step 1: Initial xAI state -> open
        _ = try await history.reconcileRoute(modelID: "grok-beta", provider: .xai)
        #expect(boundary.allowsXaiExport == true)
        #expect(boundary.everUsedNonXAI == false)

        var diskRecord = try await harness.store.load(sessionID: sessionID)
        #expect(diskRecord.everUsedNonXAI == false)

        // Step 2: Switch to Codex -> boundary closes permanently
        _ = try await history.reconcileRoute(modelID: "codex-5", provider: .codex)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        diskRecord = try await harness.store.load(sessionID: sessionID)
        #expect(diskRecord.everUsedNonXAI == true)

        // Step 3: Switch back to xAI -> MUST REMAIN CLOSED
        _ = try await history.reconcileRoute(modelID: "grok-2", provider: .xai)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        diskRecord = try await harness.store.load(sessionID: sessionID)
        #expect(diskRecord.everUsedNonXAI == true)

        // Step 4: Switch to DeepSeek -> remains closed
        _ = try await history.reconcileRoute(modelID: "deepseek-chat", provider: .deepseek)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        // Step 5: Switch back to xAI -> MUST REMAIN CLOSED
        _ = try await history.reconcileRoute(modelID: "grok-3", provider: .xai)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        // Step 6: Switch to Wafer -> remains closed
        _ = try await history.reconcileRoute(modelID: "wafer-1", provider: .wafer)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        // Step 7: Switch back to xAI -> MUST REMAIN CLOSED
        _ = try await history.reconcileRoute(modelID: "grok-beta", provider: .xai)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        // Step 8: Switch to Kimi -> remains closed
        _ = try await history.reconcileRoute(modelID: "kimi-k1.5", provider: .kimi)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        // Step 9: Switch back to xAI -> MUST REMAIN CLOSED
        _ = try await history.reconcileRoute(modelID: "grok-beta", provider: .xai)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        // Step 10: Switch to Z AI -> remains closed
        _ = try await history.reconcileRoute(modelID: "glm-4", provider: .zai)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        // Step 11: Switch back to xAI -> MUST REMAIN CLOSED
        _ = try await history.reconcileRoute(modelID: "grok-beta", provider: .xai)
        #expect(boundary.allowsXaiExport == false)
        #expect(boundary.everUsedNonXAI == true)

        // Final verification on disk
        let finalDiskRecord = try await harness.store.load(sessionID: sessionID)
        #expect(finalDiskRecord.everUsedNonXAI == true)
    }

    // MARK: - 2. Reference Identity Preservation during `LiveConversationHistory.replace`

    @Test("Reference identity of ExportBoundary is preserved across 10 sequential replacements")
    func referenceIdentityPreservedAcrossReplacements() async throws {
        let harness = try AdversarialHarness()
        defer { harness.cleanup() }

        var initialRecord = LiveConversationRecord.new(
            sessionID: "sess_identity_root",
            workingDirectory: harness.home
        )
        initialRecord.everUsedNonXAI = false
        try await harness.store.save(initialRecord)

        let history = LiveConversationHistory(record: initialRecord, store: harness.store)
        let rootBoundary = await history.sharedExportBoundary

        // Hand out references to 3 independent mock consumers
        let consumerPersistenceBoundary = rootBoundary
        let consumerACPBoundary = rootBoundary
        let consumerTelemetryBoundary = rootBoundary

        #expect(rootBoundary.allowsXaiExport == true)
        #expect(consumerPersistenceBoundary.allowsXaiExport == true)
        #expect(consumerACPBoundary.allowsXaiExport == true)
        #expect(consumerTelemetryBoundary.allowsXaiExport == true)

        // Perform 10 sequential replacements with varying sessions
        for i in 1...10 {
            var nextRecord = LiveConversationRecord.new(
                sessionID: "sess_identity_\(i)",
                workingDirectory: harness.home
            )
            // Even iterations close the boundary; odd iterations leave it open
            nextRecord.everUsedNonXAI = (i % 2 == 0)
            try await harness.store.save(nextRecord)
            try await history.replace(with: nextRecord)

            let currentBoundary = await history.sharedExportBoundary
            // Memory identity MUST NOT CHANGE
            #expect(currentBoundary === rootBoundary)
            #expect(currentBoundary === consumerPersistenceBoundary)
            #expect(currentBoundary === consumerACPBoundary)
            #expect(currentBoundary === consumerTelemetryBoundary)

            if i >= 2 {
                // Once closed at iteration 2, all consumers MUST observe closed state permanently
                #expect(!currentBoundary.allowsXaiExport)
                #expect(currentBoundary.everUsedNonXAI)
                #expect(!consumerPersistenceBoundary.allowsXaiExport)
                #expect(!consumerACPBoundary.allowsXaiExport)
                #expect(!consumerTelemetryBoundary.allowsXaiExport)
            }
        }
    }

    // MARK: - 3. Session Replacement (/new) and Resume (/resume) Registry Updates

    @Test("Session replacement and resume maintain proper boundary isolation and registration")
    func sessionReplacementAndResumeRegistry() async throws {
        let harness = try AdversarialHarness()
        defer { harness.cleanup() }

        var registry: [String: ExportBoundary] = [:]

        // 1. Create Session A (clean xAI session)
        let sessionAID = "session_A"
        var recordA = LiveConversationRecord.new(sessionID: sessionAID, workingDirectory: harness.home)
        recordA.everUsedNonXAI = false
        recordA.items = [.user("Session A message")]
        try await harness.store.save(recordA)

        let boundaryA = ExportBoundary(everUsedNonXAI: false)
        registry[sessionAID] = boundaryA
        #expect(boundaryA.allowsXaiExport == true)

        // 2. Create Session B (switches to Codex)
        let sessionBID = "session_B"
        var recordB = LiveConversationRecord.new(sessionID: sessionBID, workingDirectory: harness.home)
        recordB.everUsedNonXAI = false
        recordB.items = [.user("Session B message")]
        try await harness.store.save(recordB)

        let boundaryB = ExportBoundary(everUsedNonXAI: false)
        registry[sessionBID] = boundaryB

        // Close Session B's boundary
        boundaryB.observe(.codex)
        recordB.everUsedNonXAI = true
        try await harness.store.save(recordB)

        #expect(boundaryB.allowsXaiExport == false)
        #expect(boundaryB.everUsedNonXAI == true)

        // Verify Session A is unaffected
        #expect(registry[sessionAID]?.allowsXaiExport == true)
        #expect(registry[sessionAID]?.everUsedNonXAI == false)

        // 3. Resume Session A: rehydrates from disk & registry
        let loadedRecordA = try await harness.store.load(sessionID: sessionAID)
        #expect(loadedRecordA.everUsedNonXAI == false)
        #expect(registry[sessionAID]?.allowsXaiExport == true)

        // 4. Resume Session B: rehydrates from disk & registry
        let loadedRecordB = try await harness.store.load(sessionID: sessionBID)
        #expect(loadedRecordB.everUsedNonXAI == true)
        let resumedBoundaryB = registry[sessionBID] ?? ExportBoundary(everUsedNonXAI: loadedRecordB.everUsedNonXAI ?? false)
        #expect(resumedBoundaryB.allowsXaiExport == false)
        #expect(resumedBoundaryB.everUsedNonXAI == true)

        // 5. Verify share authorization: Session A passes, Session B fails
        #expect(throws: Never.self) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: loadedRecordA.everUsedNonXAI ?? false,
                liveBoundary: registry[sessionAID],
                messageCount: loadedRecordA.items.count
            )
        }

        #expect(throws: ShareRefusal.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: loadedRecordB.everUsedNonXAI ?? false,
                liveBoundary: resumedBoundaryB,
                messageCount: loadedRecordB.items.count
            )
        }
    }

    // MARK: - 4. Subagent Non-xAI Provider Execution Propagation

    @Test("Subagent non-xAI execution propagates to parent ExportBoundary and disk metadata")
    func subagentNonXAIPropagation() async throws {
        let harness = try AdversarialHarness()
        defer { harness.cleanup() }

        let parentSessionID = "sess_parent_subagent"
        var parentRecord = LiveConversationRecord.new(
            sessionID: parentSessionID,
            workingDirectory: harness.home
        )
        parentRecord.everUsedNonXAI = false
        parentRecord.items = [.user("Parent orchestrator turn")]
        try await harness.store.save(parentRecord)

        let parentBoundary = ExportBoundary(everUsedNonXAI: false)
        #expect(parentBoundary.allowsXaiExport == true)

        let syncCallback: @Sendable (Bool) async throws -> Void = { everUsed in
            if everUsed {
                var current = try await harness.store.load(sessionID: parentSessionID)
                current.everUsedNonXAI = true
                try await harness.store.save(current)
            }
        }

        // Subagent runs with Codex model
        let childModel = "codex-mini"
        let childProvider: ModelProvider = .codex
        #expect(!childProvider.profile.allowsXaiServices)

        // Subagent execution hook
        parentBoundary.observe(childProvider)
        try await syncCallback(true)

        // 1. Parent live boundary is closed
        #expect(!parentBoundary.allowsXaiExport)
        #expect(parentBoundary.everUsedNonXAI)

        // 2. Parent disk metadata is updated
        let updatedParentRecord = try await harness.store.load(sessionID: parentSessionID)
        #expect(updatedParentRecord.everUsedNonXAI == true)

        // 3. Parent share is refused
        #expect(throws: ShareRefusal.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: updatedParentRecord.everUsedNonXAI ?? false,
                liveBoundary: parentBoundary,
                messageCount: updatedParentRecord.items.count
            )
        }
    }

    // MARK: - 5. Refusal Behavior Across CLI and ACP Endpoints

    @Test("Complete refusal matrix across CLI open-grok share and ACP x.ai/share_session")
    func completeRefusalMatrixAcrossCLIAndACP() async throws {
        let harness = try AdversarialHarness()
        defer { harness.cleanup() }

        let backendURL = "https://grok.com/build/share/adv-pass"
        let mockBackend = AdversarialShareBackendClient(returnURL: backendURL)
        let mockUpload = AdversarialShareSignedUploadClient()

        // Case A: Unauthenticated -> authRequired
        do {
            let env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
            let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: true)
            let deps = LiveShareRouteDependencies(
                loadRemoteSettings: { _ in settings },
                makeSignedUploadClient: { _, _ in mockUpload },
                makeBackendClient: { _, _ in mockBackend }
            )
            let handler = LiveShareACPHandler(
                environment: env,
                routeDependencies: deps,
                signedUploadClient: mockUpload,
                backendClient: mockBackend
            )

            let output = try await handler.handle(
                method: "x.ai/share_session",
                params: .object(["session_id": .string("sess-nonexistent")])
            )
            Issue.record("Expected unauthenticated refusal, got \(output)")
        } catch let error as AcpError {
            #expect(error.code == .authRequired)
            #expect(error.data == .string(ShareRefusal.authenticationRequired.message))
        }

        // Case B: Non-xAI auth -> xaiAuthRequired
        do {
            var env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
            env["OPENGROK_AUTH"] = try AdversarialHarness.inlineAuthString(AdversarialHarness.nonXaiAuth())
            let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: true)
            let deps = LiveShareRouteDependencies(
                loadRemoteSettings: { _ in settings },
                makeSignedUploadClient: { _, _ in mockUpload },
                makeBackendClient: { _, _ in mockBackend }
            )
            let handler = LiveShareACPHandler(
                environment: env,
                routeDependencies: deps,
                signedUploadClient: mockUpload,
                backendClient: mockBackend
            )

            _ = try await handler.handle(
                method: "x.ai/share_session",
                params: .object(["session_id": .string("sess-nonexistent")])
            )
            Issue.record("Expected xaiAuthRequired refusal")
        } catch let error as AcpError {
            #expect(error.code == .authRequired)
            #expect(error.data == .string(ShareRefusal.xaiAuthRequired.message))
        }

        // Case C: Sharing disabled in remote settings -> sharingNotAvailableForAccount
        do {
            var env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
            env["OPENGROK_AUTH"] = try AdversarialHarness.inlineAuthString(AdversarialHarness.xaiAuth())
            let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: false)
            let deps = LiveShareRouteDependencies(
                loadRemoteSettings: { _ in settings },
                makeSignedUploadClient: { _, _ in mockUpload },
                makeBackendClient: { _, _ in mockBackend }
            )
            let handler = LiveShareACPHandler(
                environment: env,
                routeDependencies: deps,
                signedUploadClient: mockUpload,
                backendClient: mockBackend
            )

            _ = try await handler.handle(
                method: "x.ai/share_session",
                params: .object(["session_id": .string("sess-nonexistent")])
            )
            Issue.record("Expected sharingNotAvailableForAccount refusal")
        } catch let error as AcpError {
            #expect(error.code == .invalidParams)
            #expect(error.data == .string(ShareRefusal.sharingNotAvailableForAccount.message))
        }

        // Case D: ZDR team account -> zdrTeamPolicy
        do {
            var env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
            env["OPENGROK_AUTH"] = try AdversarialHarness.inlineAuthString(AdversarialHarness.xaiAuth(zdr: true))
            let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: true)
            let deps = LiveShareRouteDependencies(
                loadRemoteSettings: { _ in settings },
                makeSignedUploadClient: { _, _ in mockUpload },
                makeBackendClient: { _, _ in mockBackend }
            )
            let handler = LiveShareACPHandler(
                environment: env,
                routeDependencies: deps,
                signedUploadClient: mockUpload,
                backendClient: mockBackend
            )

            _ = try await handler.handle(
                method: "x.ai/share_session",
                params: .object(["session_id": .string("sess-nonexistent")])
            )
            Issue.record("Expected zdrTeamPolicy refusal")
        } catch let error as AcpError {
            #expect(error.code == .invalidParams)
            #expect(error.data == .string(ShareRefusal.zdrTeamPolicy.message))
        }

        // Case E: Session not found -> sessionNotFound
        do {
            var env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
            env["OPENGROK_AUTH"] = try AdversarialHarness.inlineAuthString(AdversarialHarness.xaiAuth())
            let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: true)
            let deps = LiveShareRouteDependencies(
                loadRemoteSettings: { _ in settings },
                makeSignedUploadClient: { _, _ in mockUpload },
                makeBackendClient: { _, _ in mockBackend }
            )
            let handler = LiveShareACPHandler(
                environment: env,
                routeDependencies: deps,
                signedUploadClient: mockUpload,
                backendClient: mockBackend
            )

            _ = try await handler.handle(
                method: "x.ai/share_session",
                params: .object(["session_id": .string("sess-does-not-exist")])
            )
            Issue.record("Expected sessionNotFound refusal")
        } catch let error as AcpError {
            #expect(error.code == .resourceNotFound)
            #expect(error.data == .string(ShareRefusal.sessionNotFound.message))
        }

        // Case F: Session closed on disk -> nonXaiProviderBoundary
        let closedSessionID = "sess-closed-on-disk"
        var closedRecord = LiveConversationRecord.new(sessionID: closedSessionID, workingDirectory: harness.home)
        closedRecord.items = [.user("Closed message")]
        closedRecord.everUsedNonXAI = true
        try await harness.store.save(closedRecord)

        do {
            var env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
            env["OPENGROK_AUTH"] = try AdversarialHarness.inlineAuthString(AdversarialHarness.xaiAuth())
            let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: true)
            let deps = LiveShareRouteDependencies(
                loadRemoteSettings: { _ in settings },
                makeSignedUploadClient: { _, _ in mockUpload },
                makeBackendClient: { _, _ in mockBackend }
            )
            let handler = LiveShareACPHandler(
                environment: env,
                routeDependencies: deps,
                signedUploadClient: mockUpload,
                backendClient: mockBackend
            )

            _ = try await handler.handle(
                method: "x.ai/share_session",
                params: .object(["session_id": .string(closedSessionID)])
            )
            Issue.record("Expected nonXaiProviderBoundary refusal")
        } catch let error as AcpError {
            #expect(error.code == .invalidParams)
            #expect(error.data == .string(ShareRefusal.nonXaiProviderBoundary.message))
        }

        // Case G: Empty transcript -> noMessages
        let emptySessionID = "sess-empty-transcript"
        var emptyRecord = LiveConversationRecord.new(sessionID: emptySessionID, workingDirectory: harness.home)
        emptyRecord.items = []
        emptyRecord.everUsedNonXAI = false
        try await harness.store.save(emptyRecord)

        do {
            var env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
            env["OPENGROK_AUTH"] = try AdversarialHarness.inlineAuthString(AdversarialHarness.xaiAuth())
            let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: true)
            let deps = LiveShareRouteDependencies(
                loadRemoteSettings: { _ in settings },
                makeSignedUploadClient: { _, _ in mockUpload },
                makeBackendClient: { _, _ in mockBackend }
            )
            let handler = LiveShareACPHandler(
                environment: env,
                routeDependencies: deps,
                signedUploadClient: mockUpload,
                backendClient: mockBackend
            )

            _ = try await handler.handle(
                method: "x.ai/share_session",
                params: .object(["session_id": .string(emptySessionID)])
            )
            Issue.record("Expected noMessages refusal")
        } catch let error as AcpError {
            #expect(error.code == .invalidParams)
            #expect(error.data == .string(ShareRefusal.noMessages.message))
        }

        // Case H: Mid-upload race condition -> boundaryCrossedDuringShare
        let raceSessionID = "sess-mid-upload-race"
        var raceRecord = LiveConversationRecord.new(sessionID: raceSessionID, workingDirectory: harness.home)
        raceRecord.items = [.user("Valid transcript message")]
        raceRecord.everUsedNonXAI = false
        try await harness.store.save(raceRecord)

        let raceLiveBoundary = ExportBoundary(everUsedNonXAI: false)
        let mutatingUpload = AdversarialShareSignedUploadClient { boundary in
            boundary?.observe(.codex)
        }

        do {
            var env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
            env["OPENGROK_AUTH"] = try AdversarialHarness.inlineAuthString(AdversarialHarness.xaiAuth())
            let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: true)
            let deps = LiveShareRouteDependencies(
                loadRemoteSettings: { _ in settings },
                makeSignedUploadClient: { _, _ in mutatingUpload },
                makeBackendClient: { _, _ in mockBackend }
            )
            let handler = LiveShareACPHandler(
                environment: env,
                liveBoundaries: { id in id == raceSessionID ? raceLiveBoundary : nil },
                routeDependencies: deps,
                signedUploadClient: mutatingUpload,
                backendClient: mockBackend
            )

            _ = try await handler.handle(
                method: "x.ai/share_session",
                params: .object(["session_id": .string(raceSessionID)])
            )
            Issue.record("Expected boundaryCrossedDuringShare refusal")
        } catch let error as AcpError {
            #expect(error.code == .invalidParams)
            #expect(error.data == .string(ShareRefusal.boundaryCrossedDuringShare.message))
        }

        // Case I: Successful valid share -> raw ShareSessionResponse
        let validSessionID = "sess-valid-share"
        var validRecord = LiveConversationRecord.new(sessionID: validSessionID, workingDirectory: harness.home)
        validRecord.items = [.user("Clean xAI conversation")]
        validRecord.everUsedNonXAI = false
        try await harness.store.save(validRecord)

        let validBoundary = ExportBoundary(everUsedNonXAI: false)
        var env = ["OPENGROK_HOME": harness.home.path, "HOME": harness.home.path]
        env["OPENGROK_AUTH"] = try AdversarialHarness.inlineAuthString(AdversarialHarness.xaiAuth())
        let settings = try AdversarialHarness.makeRemoteSettings(sharingEnabled: true)
        let deps = LiveShareRouteDependencies(
            loadRemoteSettings: { _ in settings },
            makeSignedUploadClient: { _, _ in mockUpload },
            makeBackendClient: { _, _ in mockBackend }
        )
        let handler = LiveShareACPHandler(
            environment: env,
            liveBoundaries: { id in id == validSessionID ? validBoundary : nil },
            routeDependencies: deps,
            signedUploadClient: mockUpload,
            backendClient: mockBackend
        )

        let validResult = try await handler.handle(
            method: "x.ai/share_session",
            params: .object(["session_id": .string(validSessionID)])
        )
        #expect(validResult == .object(["share_url": .string(backendURL)]))
        #expect(validResult["result"] == nil) // Raw response, no ExtMethodResult
    }

    // MARK: - 6. Session Fork Boundary Inheritance

    @Test("Session fork preserves export boundary state and handles edge cases safely")
    func sessionForkBoundaryInheritance() async throws {
        let harness = try AdversarialHarness()
        defer { harness.cleanup() }

        // 1. Source session with everUsedNonXAI == false
        let sourceOpenID = "source_open"
        var sourceOpenRecord = LiveConversationRecord.new(
            sessionID: sourceOpenID,
            workingDirectory: harness.home
        )
        sourceOpenRecord.everUsedNonXAI = false
        sourceOpenRecord.items = [.user("Open session prompt")]
        try await harness.store.save(sourceOpenRecord)

        let forkedOpenID = "fork_open_child"
        let forkedOpen = try await harness.store.fork(
            sourceSessionID: sourceOpenID,
            destinationSessionID: forkedOpenID,
            workingDirectory: harness.home
        )
        #expect(forkedOpen.everUsedNonXAI == false)
        #expect(forkedOpen.parentSessionID == sourceOpenID)

        let reloadedForkedOpen = try await harness.store.load(sessionID: forkedOpenID)
        #expect(reloadedForkedOpen.everUsedNonXAI == false)

        // 2. Source session with everUsedNonXAI == true
        let sourceClosedID = "source_closed"
        var sourceClosedRecord = LiveConversationRecord.new(
            sessionID: sourceClosedID,
            workingDirectory: harness.home
        )
        sourceClosedRecord.everUsedNonXAI = true
        sourceClosedRecord.items = [.user("Closed session prompt")]
        try await harness.store.save(sourceClosedRecord)

        let forkedClosedID = "fork_closed_child"
        let forkedClosed = try await harness.store.fork(
            sourceSessionID: sourceClosedID,
            destinationSessionID: forkedClosedID,
            workingDirectory: harness.home
        )
        #expect(forkedClosed.everUsedNonXAI == true)
        #expect(forkedClosed.parentSessionID == sourceClosedID)

        let reloadedForkedClosed = try await harness.store.load(sessionID: forkedClosedID)
        #expect(reloadedForkedClosed.everUsedNonXAI == true)

        // Attempt to share the forked closed session -> MUST be refused
        #expect(throws: ShareRefusal.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: reloadedForkedClosed.everUsedNonXAI ?? false,
                liveBoundary: ExportBoundary(everUsedNonXAI: reloadedForkedClosed.everUsedNonXAI ?? false),
                messageCount: reloadedForkedClosed.items.count
            )
        }

        // 3. Legacy source session without ever_used_codex marker -> refused
        let legacySourceID = "source_legacy"
        var legacyRecord = LiveConversationRecord(
            sessionID: legacySourceID,
            workingDirectory: harness.home.path,
            parentSessionID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            items: [.user("Legacy prompt")],
            everUsedNonXAI: nil
        )
        try await harness.store.save(legacyRecord)

        await #expect(throws: CLIApplicationError.self) {
            try await harness.store.fork(
                sourceSessionID: legacySourceID,
                destinationSessionID: "fork_legacy_dest",
                workingDirectory: harness.home
            )
        }

        // 4. Same source and destination ID -> throws error
        await #expect(throws: CLIApplicationError.self) {
            try await harness.store.fork(
                sourceSessionID: sourceOpenID,
                destinationSessionID: sourceOpenID,
                workingDirectory: harness.home
            )
        }

        // 5. Existing destination ID -> throws error
        await #expect(throws: CLIApplicationError.self) {
            try await harness.store.fork(
                sourceSessionID: sourceOpenID,
                destinationSessionID: forkedOpenID,
                workingDirectory: harness.home
            )
        }
    }
}
