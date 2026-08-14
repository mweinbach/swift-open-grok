// RelocationJournalTests.swift
//
// Unit tests for Durable Session Relocation Journal and Transactional Authority.
// Testing the 7-stage relocation lifecycle, authority boundary, atomic rollback, and torn-write recovery.

import Foundation
import Testing
@testable import OpenGrokSessionPersistence
import OpenGrokShared

@Suite("RelocationJournalTests")
struct RelocationJournalTests {

    private func createTempGrokHome() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-reloc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func createTestSession(
        grokHome: URL,
        cwd: String,
        sessionID: String,
        generation: UInt64 = 1
    ) throws -> URL {
        let sessionDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: cwd, sessionID: sessionID)
        try RelocationFS.createDirectoryDurable(sessionDir)

        let summaryURL = sessionDir.appendingPathComponent(RelocationFS.summaryFileName)
        let summaryJson: [String: Any] = [
            "session_id": sessionID,
            "cwd": cwd,
            "cwd_generation": generation,
            "session_summary": "Test session summary",
            "created_at": "2026-08-14T00:00:00Z",
            "updated_at": "2026-08-14T00:00:00Z",
            "num_messages": 5,
            "info": [
                "id": sessionID,
                "cwd": cwd,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: summaryJson, options: [.prettyPrinted, .sortedKeys])
        try RelocationFS.writeAtomicDurable(path: summaryURL, data: data)

        // Add a mock message file
        let historyURL = sessionDir.appendingPathComponent("chat_history.jsonl")
        try "{\"role\":\"user\",\"content\":\"hello\"}\n".write(to: historyURL, atomically: true, encoding: .utf8)

        // Add a sub-directory
        let subDir = sessionDir.appendingPathComponent("artifacts")
        try RelocationFS.createDirectoryDurable(subDir)
        try "code".write(to: subDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        return sessionDir
    }

    // MARK: - Phase Properties & Codable Tests

    @Test("RelocationPhase authority boundary and terminal definitions")
    func phaseAuthorityRules() throws {
        // Source authoritative phases
        #expect(RelocationPhase.initiated.hasSourceAuthority)
        #expect(!RelocationPhase.initiated.hasTargetAuthority)
        #expect(!RelocationPhase.initiated.isTerminal)

        #expect(RelocationPhase.sourceVerified.hasSourceAuthority)
        #expect(!RelocationPhase.sourceVerified.hasTargetAuthority)
        #expect(!RelocationPhase.sourceVerified.isTerminal)

        #expect(RelocationPhase.targetPublished.hasSourceAuthority)
        #expect(!RelocationPhase.targetPublished.hasTargetAuthority)
        #expect(!RelocationPhase.targetPublished.isTerminal)

        #expect(RelocationPhase.rolledBack.hasSourceAuthority)
        #expect(!RelocationPhase.rolledBack.hasTargetAuthority)
        #expect(RelocationPhase.rolledBack.isTerminal)

        // Target authoritative phases
        #expect(RelocationPhase.ready.hasTargetAuthority)
        #expect(!RelocationPhase.ready.hasSourceAuthority)
        #expect(!RelocationPhase.ready.isTerminal)

        #expect(RelocationPhase.sourcePruned.hasTargetAuthority)
        #expect(!RelocationPhase.sourcePruned.hasSourceAuthority)
        #expect(!RelocationPhase.sourcePruned.isTerminal)

        #expect(RelocationPhase.committed.hasTargetAuthority)
        #expect(!RelocationPhase.committed.hasSourceAuthority)
        #expect(RelocationPhase.committed.isTerminal)
    }

    @Test("RelocationPhase Codable supports snake_case and camelCase")
    func phaseCodableDecoding() throws {
        let jsonSnake = "[\"initiated\",\"source_verified\",\"target_published\",\"ready\",\"source_pruned\",\"committed\",\"rolled_back\"]"
        let decodedSnake = try JSONDecoder().decode([RelocationPhase].self, from: Data(jsonSnake.utf8))
        #expect(decodedSnake == RelocationPhase.allCases)

        let jsonCamel = "[\"initiated\",\"sourceVerified\",\"targetPublished\",\"ready\",\"sourcePruned\",\"committed\",\"rolledBack\"]"
        let decodedCamel = try JSONDecoder().decode([RelocationPhase].self, from: Data(jsonCamel.utf8))
        #expect(decodedCamel == RelocationPhase.allCases)
    }

    // MARK: - Full 7-Stage Lifecycle Test

    @Test("Full successful 7-stage relocation lifecycle")
    func fullRelocationLifecycle() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-lifecycle-001"
        let sourceCWD = "/Users/developer/project-alpha"
        let targetCWD = "/Users/developer/project-beta"

        let sourceDir = try createTestSession(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID, generation: 1)
        let journal = RelocationJournal(grokHome: grokHome)

        // Stage 1: beginRelocation -> .initiated
        let stage1 = try await journal.beginRelocation(
            sessionID: sessionID,
            sourceCWD: sourceCWD,
            targetCWD: targetCWD,
            cwdGeneration: 2
        )
        #expect(stage1.phase == .initiated)
        #expect(stage1.sessionID == sessionID)
        #expect(stage1.sourceCWD == sourceCWD)
        #expect(stage1.targetCWD == targetCWD)
        #expect(await journal.hasRelocationJournal(sessionID: sessionID))

        let auth1 = try await journal.authority(for: sessionID)
        #expect(auth1.cwd == sourceCWD)
        #expect(auth1.phase == .initiated)

        // Stage 2: verifySource -> .sourceVerified
        let stage2 = try await journal.verifySource(sessionID: sessionID)
        #expect(stage2.phase == .sourceVerified)
        let auth2 = try await journal.authority(for: sessionID)
        #expect(auth2.cwd == sourceCWD)

        // Stage 3: publishTarget -> .targetPublished
        let reminder = PendingCwdSwitchReminder(
            cwdGeneration: 2,
            previousCWD: sourceCWD,
            destinationCWD: targetCWD,
            content: "Directory relocated from alpha to beta",
            destinationProjectInstructions: "Follow beta guidelines"
        )
        let stage3 = try await journal.publishTarget(sessionID: sessionID, pendingReminder: reminder)
        #expect(stage3.phase == .targetPublished)

        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: targetCWD, sessionID: sessionID)
        #expect(FileManager.default.fileExists(atPath: targetDir.path))
        #expect(FileManager.default.fileExists(atPath: sourceDir.path))

        // Verify summary was rewritten in target
        let targetSummaryData = try Data(contentsOf: targetDir.appendingPathComponent(RelocationFS.summaryFileName))
        let targetSummaryJson = try JSONSerialization.jsonObject(with: targetSummaryData) as? [String: Any]
        #expect(targetSummaryJson?["cwd"] as? String == targetCWD)
        #expect(targetSummaryJson?["previous_cwd"] as? String == sourceCWD)
        #expect(targetSummaryJson?["pending_cwd_switch_reminder"] != nil)

        // Authority is STILL source in targetPublished!
        let auth3 = try await journal.authority(for: sessionID)
        #expect(auth3.cwd == sourceCWD)
        #expect(auth3.phase == .targetPublished)

        // Stage 4: markReady -> .ready (AUTHORITY FLIPS TO TARGET)
        let stage4 = try await journal.markReady(sessionID: sessionID)
        #expect(stage4.phase == .ready)

        let auth4 = try await journal.authority(for: sessionID)
        #expect(auth4.cwd == targetCWD)
        #expect(auth4.phase == .ready)
        #expect(auth4.sessionDir.path == targetDir.path)

        // Stage 5: pruneSource -> .sourcePruned
        let stage5 = try await journal.pruneSource(sessionID: sessionID)
        #expect(stage5.phase == .sourcePruned)
        #expect(!FileManager.default.fileExists(atPath: sourceDir.path))
        #expect(FileManager.default.fileExists(atPath: targetDir.path))

        let auth5 = try await journal.authority(for: sessionID)
        #expect(auth5.cwd == targetCWD)

        // Stage 6: commit -> .committed
        let stage6 = try await journal.commit(sessionID: sessionID)
        #expect(stage6.phase == .committed)
        let hasJournal1 = await journal.hasRelocationJournal(sessionID: sessionID)
        #expect(!hasJournal1)
        #expect(FileManager.default.fileExists(atPath: targetDir.path))
    }

    // MARK: - Authority Boundary Transition Tests

    @Test("Authority boundary transition exactly follows ready phase")
    func authorityBoundaryTransition() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-auth-002"
        let sourceCWD = "/Users/test/workspaceA"
        let targetCWD = "/Users/test/workspaceB"

        _ = try createTestSession(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID)
        let journal = RelocationJournal(grokHome: grokHome)

        try await journal.beginRelocation(sessionID: sessionID, sourceCWD: sourceCWD, targetCWD: targetCWD)
        #expect(try await journal.authoritativeCWD(for: sessionID) == sourceCWD)

        try await journal.verifySource(sessionID: sessionID)
        #expect(try await journal.authoritativeCWD(for: sessionID) == sourceCWD)

        try await journal.publishTarget(sessionID: sessionID)
        #expect(try await journal.authoritativeCWD(for: sessionID) == sourceCWD)

        // Boundary transition
        try await journal.markReady(sessionID: sessionID)
        #expect(try await journal.authoritativeCWD(for: sessionID) == targetCWD)

        try await journal.pruneSource(sessionID: sessionID)
        #expect(try await journal.authoritativeCWD(for: sessionID) == targetCWD)
    }

    // MARK: - Atomic Rollback Tests

    @Test("Atomic rollback before ready restores source authority and cleans target")
    func rollbackBeforeReady() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-rollback-003"
        let sourceCWD = "/Users/test/source"
        let targetCWD = "/Users/test/target"

        let sourceDir = try createTestSession(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID)
        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: targetCWD, sessionID: sessionID)
        let journal = RelocationJournal(grokHome: grokHome)

        try await journal.beginRelocation(sessionID: sessionID, sourceCWD: sourceCWD, targetCWD: targetCWD)
        try await journal.verifySource(sessionID: sessionID)
        try await journal.publishTarget(sessionID: sessionID)

        #expect(FileManager.default.fileExists(atPath: targetDir.path))
        #expect(FileManager.default.fileExists(atPath: sourceDir.path))

        // Trigger rollback
        let rolledBack = try await journal.rollback(sessionID: sessionID, reason: "network interruption simulation")
        #expect(rolledBack.phase == .rolledBack)
        #expect(!FileManager.default.fileExists(atPath: targetDir.path))
        #expect(FileManager.default.fileExists(atPath: sourceDir.path))
        let hasJournal1 = await journal.hasRelocationJournal(sessionID: sessionID)
        #expect(!hasJournal1)
    }

    @Test("Rollback is rejected once target is ready")
    func rollbackRejectedAfterReady() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-rollback-reject-004"
        let sourceCWD = "/Users/test/source"
        let targetCWD = "/Users/test/target"

        _ = try createTestSession(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID)
        let journal = RelocationJournal(grokHome: grokHome)

        try await journal.beginRelocation(sessionID: sessionID, sourceCWD: sourceCWD, targetCWD: targetCWD)
        try await journal.verifySource(sessionID: sessionID)
        try await journal.publishTarget(sessionID: sessionID)
        try await journal.markReady(sessionID: sessionID)

        // Rollback must fail with invalidPhase
        do {
            _ = try await journal.rollback(sessionID: sessionID)
            #expect(Bool(false), "Rollback should have failed after markReady")
        } catch let err as RelocationError {
            if case .invalidPhase(let op, let actual) = err {
                #expect(op == "rollback")
                #expect(actual == .ready)
            } else {
                #expect(Bool(false), "Unexpected error: \(err)")
            }
        }
    }

    @Test("Target directory collision is detected and rejected")
    func targetCollisionDetection() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-collision-005"
        let sourceCWD = "/Users/test/source"
        let targetCWD = "/Users/test/target"

        _ = try createTestSession(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID)
        // Pre-create target to trigger collision
        _ = try createTestSession(grokHome: grokHome, cwd: targetCWD, sessionID: sessionID)

        let journal = RelocationJournal(grokHome: grokHome)
        try await journal.beginRelocation(sessionID: sessionID, sourceCWD: sourceCWD, targetCWD: targetCWD)
        try await journal.verifySource(sessionID: sessionID)

        do {
            try await journal.publishTarget(sessionID: sessionID)
            #expect(Bool(false), "publishTarget should have failed on collision")
        } catch let err as RelocationError {
            if case .collision = err {
                // Expected collision error
            } else {
                #expect(Bool(false), "Expected collision error, got: \(err)")
            }
        }
    }

    // MARK: - Torn Write & Interruption Recovery Tests

    @Test("Recovery rolls back uncommitted target-published session")
    func recoverTargetPublished() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-recover-published-006"
        let sourceCWD = "/Users/test/source"
        let targetCWD = "/Users/test/target"

        let sourceDir = try createTestSession(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID)
        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: targetCWD, sessionID: sessionID)
        let journal = RelocationJournal(grokHome: grokHome)

        try await journal.beginRelocation(sessionID: sessionID, sourceCWD: sourceCWD, targetCWD: targetCWD)
        try await journal.verifySource(sessionID: sessionID)
        try await journal.publishTarget(sessionID: sessionID)

        #expect(FileManager.default.fileExists(atPath: targetDir.path))

        // Release lease on old journal to simulate process death
        await journal.releaseLease(sessionID: sessionID)

        // Create a new journal instance to simulate process restart / recovery
        let recoveryJournal = RelocationJournal(grokHome: grokHome)
        let (action, state) = try await recoveryJournal.recover(sessionID: sessionID)

        #expect(action == .rollBackToSource)
        #expect(state.phase == .rolledBack)
        #expect(!FileManager.default.fileExists(atPath: targetDir.path))
        #expect(FileManager.default.fileExists(atPath: sourceDir.path))
        let hasReloc1 = await recoveryJournal.hasRelocationJournal(sessionID: sessionID)
        #expect(!hasReloc1)
    }

    @Test("Recovery commits interrupted ready session")
    func recoverReadySession() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-recover-ready-007"
        let sourceCWD = "/Users/test/source"
        let targetCWD = "/Users/test/target"

        let sourceDir = try createTestSession(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID)
        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: targetCWD, sessionID: sessionID)
        let journal = RelocationJournal(grokHome: grokHome)

        try await journal.beginRelocation(sessionID: sessionID, sourceCWD: sourceCWD, targetCWD: targetCWD)
        try await journal.verifySource(sessionID: sessionID)
        try await journal.publishTarget(sessionID: sessionID)
        try await journal.markReady(sessionID: sessionID)

        // Release lease on old journal to simulate process death
        await journal.releaseLease(sessionID: sessionID)

        // Simulate crash right after markReady
        let recoveryJournal = RelocationJournal(grokHome: grokHome)
        let (action, state) = try await recoveryJournal.recover(sessionID: sessionID)

        #expect(action == .commitTarget)
        #expect(state.phase == .committed)
        #expect(FileManager.default.fileExists(atPath: targetDir.path))
        #expect(!FileManager.default.fileExists(atPath: sourceDir.path))
        let hasReloc1 = await recoveryJournal.hasRelocationJournal(sessionID: sessionID)
        #expect(!hasReloc1)
    }

    @Test("Torn write recovery with corrupted journal JSON")
    func tornWriteRecovery() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-torn-008"
        let sourceCWD = "/Users/test/source"
        let targetCWD = "/Users/test/target"

        let sourceDir = try createTestSession(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID)
        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: targetCWD, sessionID: sessionID)

        // Write a torn / corrupted journal file
        let journalPath = RelocationFS.journalPath(grokHome: grokHome, sessionID: sessionID)
        try RelocationFS.createDirectoryDurable(journalPath.deletingLastPathComponent())
        let corruptData = "{\"version\":1,\"session_id\":\"sess-torn-008\",\"source_cwd\":".data(using: .utf8)!
        try corruptData.write(to: journalPath)

        let recoveryJournal = RelocationJournal(grokHome: grokHome)
        let (action, state) = try await recoveryJournal.recover(sessionID: sessionID)

        #expect(action == .rollBackToSource)
        #expect(state.phase == .rolledBack)
        #expect(FileManager.default.fileExists(atPath: sourceDir.path))
        #expect(!FileManager.default.fileExists(atPath: targetDir.path))
        let hasReloc1 = await recoveryJournal.hasRelocationJournal(sessionID: sessionID)
        #expect(!hasReloc1)
    }

    @Test("recoverAll recovers all active relocation journals")
    func recoverAllMultipleJournals() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let journal = RelocationJournal(grokHome: grokHome)

        // Session 1: targetPublished -> should roll back to source
        let s1 = "session-multi-1"
        _ = try createTestSession(grokHome: grokHome, cwd: "/src1", sessionID: s1)
        try await journal.beginRelocation(sessionID: s1, sourceCWD: "/src1", targetCWD: "/dst1")
        try await journal.verifySource(sessionID: s1)
        try await journal.publishTarget(sessionID: s1)

        // Session 2: ready -> should commit to target
        let s2 = "session-multi-2"
        _ = try createTestSession(grokHome: grokHome, cwd: "/src2", sessionID: s2)
        try await journal.beginRelocation(sessionID: s2, sourceCWD: "/src2", targetCWD: "/dst2")
        try await journal.verifySource(sessionID: s2)
        try await journal.publishTarget(sessionID: s2)
        try await journal.markReady(sessionID: s2)

        let recovered = try await journal.recoverAll()
        #expect(recovered.count == 2)
        #expect(recovered[s1]?.action == .rollBackToSource)
        #expect(recovered[s2]?.action == .commitTarget)
    }

    // MARK: - Exclusive Lease Tests

    @Test("Exclusive lease prevents concurrent relocation on same session")
    func leaseMutualExclusion() async throws {
        let grokHome = try createTempGrokHome()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        let sessionID = "sess-lease-009"
        _ = try createTestSession(grokHome: grokHome, cwd: "/src", sessionID: sessionID)

        let journal1 = RelocationJournal(grokHome: grokHome)
        try await journal1.beginRelocation(sessionID: sessionID, sourceCWD: "/src", targetCWD: "/dst")

        let journal2 = RelocationJournal(grokHome: grokHome)
        do {
            try await journal2.acquireLease(sessionID: sessionID)
            #expect(Bool(false), "Second lease acquisition should fail with leaseBusy")
        } catch let err as RelocationError {
            if case .leaseBusy(let id) = err {
                #expect(id == sessionID)
            } else {
                #expect(Bool(false), "Unexpected error: \(err)")
            }
        }
    }
}
