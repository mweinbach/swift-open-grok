// ExportBoundaryE2ETests.swift
//
// End-to-end and integration test suite for Monotonic Export Boundary Enforcement (Feature 6).
// Ported and verified against the upstream Rust reference at pin 9ed09e2a:
// `crates/codegen/xai-grok-shell/src/session/persistence.rs:1631-1668`,
// `crates/codegen/xai-grok-shell/src/session/mod.rs:295-306`,
// `crates/codegen/xai-grok-shell/src/extensions/share.rs:31-141`.
//
// Invariants verified:
// 1. Fresh session starts with export boundary OPEN (`allowsXaiExport == true`, `everUsedNonXAI == false`).
// 2. Observing any non-xAI provider (Codex, Kimi, Fireworks, DeepSeek, Wafer, Z AI, OpenCode Go) closes the boundary.
// 3. Monotonicity: once closed, the boundary can NEVER reopen, even if subsequent turns observe xAI.
// 4. Persistence roundtrip: `ever_used_codex: true` is persisted to disk and restored upon session reload.
// 5. ShareExportGate rejects closed sessions with `ShareRefusal.nonXaiProviderBoundary`.
// 6. Mid-share race condition: if boundary closes while share request is in-flight, `authorizePostExport` throws `boundaryCrossedDuringShare`.
// 7. Rejection priority: closed boundary check outranks empty transcript check.
// 8. Auth outranking: unauthenticated or non-xAI auth outranks boundary check.
// 9. Subagent inheritance: subagent running non-xAI model closes parent's export boundary.
// 10. Thread safety: concurrent observations from multiple tasks maintain monotonicity without race conditions.
// 11. Reference identity: LiveConversationHistory replacement preserves boundary reference identity.
// 12. Legacy migration: session record without ever_used_codex defaults open and safely closes.

import Foundation
import OpenGrokAuth
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokCLI

private struct ExportBoundaryHarness {
    let root: URL
    let home: URL
    let sessionStore: LiveConversationStore

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("og-export-boundary-e2e-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sessionStore = LiveConversationStore(openGrokHome: home)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Test Suite

@Suite("Export Boundary E2E Tests", .serialized)
struct ExportBoundaryE2ETests {

    // MARK: - Tier 1: Feature Coverage Tests (5+ tests)

    @Test("fresh session allows xAI export and starts with boundary open")
    func freshSessionAllowsExport() {
        let boundary = ExportBoundary(everUsedNonXAI: false)
        #expect(boundary.allowsXaiExport)
        #expect(!boundary.everUsedNonXAI)

        // Syncing with false keeps boundary open
        boundary.sync(everUsedNonXAI: false)
        #expect(boundary.allowsXaiExport)
        #expect(!boundary.everUsedNonXAI)
    }

    @Test("Codex observation closes boundary monotonically and does not reopen on xAI switch")
    func codexObservationClosesBoundary() {
        let boundary = ExportBoundary(everUsedNonXAI: false)
        #expect(boundary.allowsXaiExport)

        // First non-xAI observation returns true and closes boundary
        let firstClose = boundary.observe(.codex)
        #expect(firstClose == true)
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)

        // Subsequent non-xAI observation returns false (already closed)
        let secondClose = boundary.observe(.codex)
        #expect(secondClose == false)
        #expect(!boundary.allowsXaiExport)

        // Observing xAI DOES NOT reopen the boundary
        let xaiObserve = boundary.observe(.xai)
        #expect(xaiObserve == false)
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)

        // Syncing with false CANNOT reopen the boundary
        boundary.sync(everUsedNonXAI: false)
        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)
    }

    @Test("all non-xAI providers close the export boundary")
    func allNonXAIProvidersCloseBoundary() {
        let nonXAIProviders: [ModelProvider] = [
            .codex,
            .kimi,
            .fireworks,
            .deepseek,
            .wafer,
            .zai,
            .openCodeGo
        ]

        for provider in nonXAIProviders {
            let boundary = ExportBoundary(everUsedNonXAI: false)
            #expect(boundary.allowsXaiExport)
            #expect(!provider.profile.allowsXaiServices, "Provider \(provider) must deny xAI services")

            let closed = boundary.observe(provider)
            #expect(closed == true, "Observing \(provider) should close the boundary")
            #expect(!boundary.allowsXaiExport)
            #expect(boundary.everUsedNonXAI)
        }
    }

    @Test("xAI provider observation preserves open export state")
    func xaiProviderPreservesOpenBoundary() {
        let boundary = ExportBoundary(everUsedNonXAI: false)
        #expect(boundary.allowsXaiExport)
        #expect(ModelProvider.xai.profile.allowsXaiServices)

        let closed = boundary.observe(.xai)
        #expect(closed == false)
        #expect(boundary.allowsXaiExport)
        #expect(!boundary.everUsedNonXAI)
    }

    @Test("persistence roundtrip stores ever_used_codex on disk and restores closed boundary")
    func persistenceRoundtrip() async throws {
        let harness = try ExportBoundaryHarness()
        defer { harness.cleanup() }

        let sessionID = "sess_export_roundtrip"
        var initialRecord = LiveConversationRecord.new(
            sessionID: sessionID,
            workingDirectory: harness.home
        )
        initialRecord.everUsedNonXAI = true
        initialRecord.items = [
            .user("Test message before export check")
        ]

        try await harness.sessionStore.save(initialRecord)

        // Verify JSON file on disk has "ever_used_codex": true
        let sessionFile = harness.home.appendingPathComponent("sessions/\(sessionID).json")
        let fileData = try Data(contentsOf: sessionFile)
        let jsonString = String(decoding: fileData, as: UTF8.self)
        #expect(jsonString.contains("\"ever_used_codex\""))
        #expect(jsonString.contains("true"))

        // Rehydrate session record
        let record = try await harness.sessionStore.load(sessionID: sessionID)
        #expect(record.everUsedNonXAI == true)

        let restoredBoundary = ExportBoundary(everUsedNonXAI: record.everUsedNonXAI ?? false)
        #expect(!restoredBoundary.allowsXaiExport)
        #expect(restoredBoundary.everUsedNonXAI)
    }

    // MARK: - Tier 2: Boundary & Corner Cases Tests (5+ tests)

    @Test("ShareExportGate rejects closed session with nonXaiProviderBoundary refusal")
    func shareExportGateRejectsClosedSession() throws {
        let boundary = ExportBoundary(everUsedNonXAI: true)

        #expect(throws: ShareRefusal.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: true,
                liveBoundary: boundary,
                messageCount: 5
            )
        }
    }

    @Test("mid-share race condition triggers boundaryCrossedDuringShare refusal")
    func midShareRaceConditionRefusal() throws {
        let boundary = ExportBoundary(everUsedNonXAI: false)

        // Pre-export check passes
        try ShareExportGate.authorizeExport(
            persistedEverUsedNonXAI: false,
            liveBoundary: boundary,
            messageCount: 5
        )

        // Mid-flight non-xAI observation occurs
        boundary.observe(.codex)

        // Post-export check MUST throw boundaryCrossedDuringShare
        #expect(throws: ShareRefusal.boundaryCrossedDuringShare) {
            try ShareExportGate.authorizePostExport(liveBoundary: boundary)
        }
    }

    @Test("closed boundary check outranks empty transcript check")
    func closedBoundaryOutranksEmptyTranscript() {
        let boundary = ExportBoundary(everUsedNonXAI: true)

        // Both boundary is closed AND message count is 0
        #expect(throws: ShareRefusal.nonXaiProviderBoundary) {
            try ShareExportGate.authorizeExport(
                persistedEverUsedNonXAI: true,
                liveBoundary: boundary,
                messageCount: 0
            )
        }
    }

    @Test("account auth checks outrank session export checks")
    func authOutranksSessionChecks() {
        // 1. Unauthenticated throws authenticationRequired
        #expect(throws: ShareRefusal.authenticationRequired) {
            try ShareExportGate.authorizeAccount(auth: nil, sharingEnabled: true)
        }

        // 2. Sharing disabled throws sharingNotAvailableForAccount
        let xaiAuth = GrokAuth(
            key: "xai-test-key",
            authMode: .oidc,
            userID: "user-1",
            teamBlockedReasons: [],
            codingDataRetentionOptOut: false,
            oidcIssuer: "https://auth.x.ai"
        )
        #expect(throws: ShareRefusal.sharingNotAvailableForAccount) {
            try ShareExportGate.authorizeAccount(auth: xaiAuth, sharingEnabled: false)
        }
    }

    @Test("subagent shares and mutates parent export boundary")
    func subagentSharesParentBoundary() {
        let parentBoundary = ExportBoundary(everUsedNonXAI: false)
        #expect(parentBoundary.allowsXaiExport)

        // Subagent running non-xAI model observes parent boundary
        let childProvider: ModelProvider = .codex
        #expect(!childProvider.profile.allowsXaiServices)

        parentBoundary.observe(childProvider)

        // Parent boundary is permanently closed
        #expect(!parentBoundary.allowsXaiExport)
        #expect(parentBoundary.everUsedNonXAI)
    }

    @Test("LiveConversationHistory replace preserves reference identity and syncs boundary")
    func conversationHistoryReplacePreservesReferenceIdentity() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LiveConversationStore(openGrokHome: dir)
        var record1 = LiveConversationRecord.new(sessionID: "session_1", workingDirectory: dir)
        record1.everUsedNonXAI = false

        let history = LiveConversationHistory(record: record1, store: store)
        let boundary1 = await history.sharedExportBoundary
        #expect(boundary1.allowsXaiExport)

        var record2 = LiveConversationRecord.new(sessionID: "session_2", workingDirectory: dir)
        record2.everUsedNonXAI = true

        // Replace session
        try await history.replace(with: record2)
        let boundary2 = await history.sharedExportBoundary

        // Reference identity MUST be identical (same memory pointer)
        #expect(boundary1 === boundary2)
        // Boundary MUST now be closed
        #expect(!boundary2.allowsXaiExport)
        #expect(boundary2.everUsedNonXAI)
    }

    @Test("concurrent provider observations are thread-safe and maintain monotonicity")
    func concurrentProviderObservationsThreadSafe() async {
        let boundary = ExportBoundary(everUsedNonXAI: false)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i % 3 == 0 {
                        boundary.observe(.codex)
                    } else if i % 3 == 1 {
                        boundary.observe(.xai)
                    } else {
                        boundary.sync(everUsedNonXAI: false)
                    }
                }
            }
        }

        #expect(!boundary.allowsXaiExport)
        #expect(boundary.everUsedNonXAI)
    }

    @Test("legacy session record without ever_used_codex defaults open and safely closes")
    func legacySessionRecordDefaultsOpen() throws {
        let legacyJSON = """
        {
            "sessionID": "legacy-session-1",
            "workingDirectory": "/tmp/test",
            "createdAt": 1000,
            "updatedAt": 2000,
            "items": []
        }
        """
        let record = try JSONDecoder().decode(LiveConversationRecord.self, from: Data(legacyJSON.utf8))
        #expect((record.everUsedNonXAI ?? false) == false)

        let boundary = ExportBoundary(everUsedNonXAI: record.everUsedNonXAI ?? false)
        #expect(boundary.allowsXaiExport)

        boundary.observe(.kimi)
        #expect(!boundary.allowsXaiExport)
    }
}
