// RelocationJournal.swift
//
// Durable Session Relocation Journal and Transactional Authority.
// Port of `crates/codegen/xai-grok-shell/src/session/storage/relocation/` (journal.rs, mod.rs, view.rs).

import Foundation
import OpenGrokShared
import OpenGrokPaths
import OpenGrokFileUtils

/// Actor coordinating durable, transactional relocations of session directories.
///
/// Implements the 7-stage lifecycle with atomic journal persistence and clear authority boundary:
/// 1. `beginRelocation`: `.initiated` (source authoritative)
/// 2. `verifySource`: `.sourceVerified` (source authoritative)
/// 3. `publishTarget`: `.targetPublished` (source authoritative)
/// 4. `markReady`: `.ready` (target becomes authoritative)
/// 5. `pruneSource`: `.sourcePruned` (target authoritative)
/// 6. `commit`: `.committed` (target authoritative)
/// 7. `rollback`: `.rolledBack` (source authoritative; only permitted prior to `.ready`)
public actor RelocationJournal {
    public let grokHome: URL
    private var heldLocks: [String: AdvisoryLock] = [:]

    public init(grokHome: URL = RelocationFS.defaultGrokHome()) {
        self.grokHome = grokHome
    }

    // MARK: - Lease Management

    /// Acquire exclusive lock lease for a session relocation.
    public func acquireLease(sessionID: String) throws {
        if heldLocks[sessionID] != nil {
            return
        }
        try RelocationFS.validateComponent(field: "session id", value: sessionID)
        let lockURL = RelocationFS.lockPath(grokHome: grokHome, sessionID: sessionID)
        do {
            let lock = try AdvisoryFileLock.acquire(
                at: lockURL,
                options: AdvisoryLockOptions(nonBlocking: true, create: true, mode: 0o600)
            )
            heldLocks[sessionID] = lock
        } catch let err as FileUtilsError {
            if case .lockFailed = err {
                throw RelocationError.leaseBusy(sessionID: sessionID)
            }
            throw RelocationError.io(operation: "acquireLease", path: lockURL.path, message: err.localizedDescription)
        }
    }

    /// Release exclusive lock lease for a session.
    public func releaseLease(sessionID: String) {
        if let lock = heldLocks.removeValue(forKey: sessionID) {
            lock.release()
        }
    }

    // MARK: - Journal Persistence

    public func hasRelocationJournal(sessionID: String) -> Bool {
        let path = RelocationFS.journalPath(grokHome: grokHome, sessionID: sessionID)
        return FileManager.default.fileExists(atPath: path.path)
    }

    public func readJournal(sessionID: String) throws -> RelocationJournalState {
        try RelocationFS.validateComponent(field: "session id", value: sessionID)
        let path = RelocationFS.journalPath(grokHome: grokHome, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw RelocationError.journalMissing(sessionID: sessionID)
        }

        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw RelocationError.io(operation: "readJournal", path: path.path, message: error.localizedDescription)
        }

        do {
            let state = try JSONDecoder().decode(RelocationJournalState.self, from: data)
            guard state.sessionID == sessionID else {
                throw RelocationError.transactionMismatch(sessionID: sessionID)
            }
            return state
        } catch {
            throw RelocationError.json(path: path.path, message: error.localizedDescription)
        }
    }

    private func writeJournal(_ state: RelocationJournalState) throws {
        try RelocationFS.validateComponent(field: "session id", value: state.sessionID)
        try RelocationFS.validateCWD(field: "source cwd", value: state.sourceCWD)
        try RelocationFS.validateCWD(field: "target cwd", value: state.targetCWD)

        let path = RelocationFS.journalPath(grokHome: grokHome, sessionID: state.sessionID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw RelocationError.json(path: path.path, message: error.localizedDescription)
        }

        try RelocationFS.writeAtomicDurable(path: path, data: data, permissions: 0o600)
    }

    private func removeJournalFile(sessionID: String) throws {
        let path = RelocationFS.journalPath(grokHome: grokHome, sessionID: sessionID)
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                try FileManager.default.removeItem(at: path)
            } catch {
                throw RelocationError.io(operation: "removeJournalFile", path: path.path, message: error.localizedDescription)
            }
            try? RelocationFS.syncDirectory(path.deletingLastPathComponent())
        }
        let lockPath = RelocationFS.lockPath(grokHome: grokHome, sessionID: sessionID)
        if FileManager.default.fileExists(atPath: lockPath.path) {
            _ = try? FileManager.default.removeItem(at: lockPath)
        }
    }

    // MARK: - 7-Stage Relocation Lifecycle

    /// Stage 1: Begin a relocation transaction (`.initiated`).
    @discardableResult
    public func beginRelocation(
        sessionID: String,
        sourceCWD: String,
        targetCWD: String,
        cwdGeneration: UInt64 = 1,
        nonce: String = UUID().uuidString
    ) throws -> RelocationJournalState {
        try RelocationFS.validateComponent(field: "session id", value: sessionID)
        try RelocationFS.validateCWD(field: "source cwd", value: sourceCWD)
        try RelocationFS.validateCWD(field: "target cwd", value: targetCWD)

        if sourceCWD == targetCWD {
            throw RelocationError.inconsistent("source and target CWD paths are identical")
        }

        let sourceDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: sourceCWD, sessionID: sessionID)
        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: targetCWD, sessionID: sessionID)
        if sourceDir.standardizedFileURL.path == targetDir.standardizedFileURL.path {
            throw RelocationError.inconsistent("source and target storage paths resolve to the same location")
        }

        try acquireLease(sessionID: sessionID)

        if hasRelocationJournal(sessionID: sessionID) {
            throw RelocationError.journalExists(sessionID: sessionID)
        }

        let state = RelocationJournalState(
            sessionID: sessionID,
            nonce: nonce,
            sourceCWD: sourceCWD,
            targetCWD: targetCWD,
            cwdGeneration: cwdGeneration,
            phase: .initiated
        )

        try writeJournal(state)
        return state
    }

    /// Stage 2: Verify that the source session directory and its summary are valid (`.sourceVerified`).
    @discardableResult
    public func verifySource(sessionID: String) throws -> RelocationJournalState {
        var state = try readJournal(sessionID: sessionID)
        guard state.phase == .initiated || state.phase == .sourceVerified else {
            throw RelocationError.invalidPhase(operation: "verifySource", actual: state.phase)
        }

        let sourceDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: state.sourceCWD, sessionID: sessionID)
        try RelocationFS.requireDirectory(sourceDir)

        let summaryURL = sourceDir.appendingPathComponent(RelocationFS.summaryFileName)
        if FileManager.default.fileExists(atPath: summaryURL.path) {
            try RelocationFS.requireRegularFile(summaryURL)
        }

        state.phase = .sourceVerified
        state.updatedAtMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        try writeJournal(state)
        return state
    }

    /// Stage 3: Stage and atomically publish target session directory (`.targetPublished`).
    @discardableResult
    public func publishTarget(
        sessionID: String,
        pendingReminder: PendingCwdSwitchReminder? = nil
    ) throws -> RelocationJournalState {
        var state = try readJournal(sessionID: sessionID)
        guard state.phase == .sourceVerified || state.phase == .initiated else {
            throw RelocationError.invalidPhase(operation: "publishTarget", actual: state.phase)
        }

        if let pendingReminder {
            state.pendingReminder = pendingReminder
        }

        let sourceDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: state.sourceCWD, sessionID: sessionID)
        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: state.targetCWD, sessionID: sessionID)
        let stagingDir = RelocationFS.stagingDirAt(grokHome: grokHome, targetCWD: state.targetCWD, sessionID: sessionID, nonce: state.nonce)

        // Collision checks
        if FileManager.default.fileExists(atPath: targetDir.path) {
            throw RelocationError.collision(path: targetDir.path)
        }
        if FileManager.default.fileExists(atPath: stagingDir.path) {
            _ = try? FileManager.default.removeItem(at: stagingDir)
        }

        // Copy source directory to staging
        do {
            try RelocationFS.copyDirectory(source: sourceDir, target: stagingDir)
        } catch {
            _ = try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }

        // Rewrite summary in staging directory
        let summaryPath = stagingDir.appendingPathComponent(RelocationFS.summaryFileName)
        if FileManager.default.fileExists(atPath: summaryPath.path) {
            do {
                let summaryData = try Data(contentsOf: summaryPath)
                if var json = try JSONSerialization.jsonObject(with: summaryData, options: []) as? [String: Any] {
                    json["cwd"] = state.targetCWD
                    if var info = json["info"] as? [String: Any] {
                        info["cwd"] = state.targetCWD
                        json["info"] = info
                    }
                    json["cwd_generation"] = state.cwdGeneration
                    json["previous_cwd"] = state.sourceCWD

                    if let reminder = state.pendingReminder {
                        let reminderData = try JSONEncoder().encode(reminder)
                        if let reminderJson = try JSONSerialization.jsonObject(with: reminderData, options: []) as? [String: Any] {
                            json["pending_cwd_switch_reminder"] = reminderJson
                        }
                    }

                    let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                    try RelocationFS.writeAtomicDurable(path: summaryPath, data: updatedData)
                }
            } catch {
                _ = try? FileManager.default.removeItem(at: stagingDir)
                throw RelocationError.json(path: summaryPath.path, message: "failed to rewrite summary: \(error.localizedDescription)")
            }
        }

        // Atomically publish staging directory to target
        do {
            try RelocationFS.publishNoReplace(source: stagingDir, target: targetDir)
        } catch {
            _ = try? FileManager.default.removeItem(at: stagingDir)
            throw error
        }

        state.phase = .targetPublished
        state.updatedAtMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        try writeJournal(state)
        return state
    }

    /// Stage 4: Mark target directory as ready (`.ready`).
    ///
    /// This is the non-negotiable **authority boundary**: target path becomes authoritative once ready.
    @discardableResult
    public func markReady(sessionID: String) throws -> RelocationJournalState {
        var state = try readJournal(sessionID: sessionID)
        guard state.phase == .targetPublished || state.phase == .ready else {
            throw RelocationError.invalidPhase(operation: "markReady", actual: state.phase)
        }

        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: state.targetCWD, sessionID: sessionID)
        try RelocationFS.requireDirectory(targetDir)

        state.phase = .ready
        state.updatedAtMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        try writeJournal(state)
        return state
    }

    /// Stage 5: Prune source session directory (`.sourcePruned`).
    @discardableResult
    public func pruneSource(sessionID: String) throws -> RelocationJournalState {
        var state = try readJournal(sessionID: sessionID)
        guard state.phase == .ready || state.phase == .sourcePruned else {
            throw RelocationError.invalidPhase(operation: "pruneSource", actual: state.phase)
        }

        let sourceDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: state.sourceCWD, sessionID: sessionID)
        try RelocationFS.removeDirectoryDurable(sourceDir)

        let stagingDir = RelocationFS.stagingDirAt(grokHome: grokHome, targetCWD: state.targetCWD, sessionID: sessionID, nonce: state.nonce)
        try? RelocationFS.removeDirectoryDurable(stagingDir)

        state.phase = .sourcePruned
        state.updatedAtMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        try writeJournal(state)
        return state
    }

    /// Stage 6: Commit transaction and clean up journal (`.committed`).
    @discardableResult
    public func commit(sessionID: String) throws -> RelocationJournalState {
        var state = try readJournal(sessionID: sessionID)
        guard state.phase == .ready || state.phase == .sourcePruned || state.phase == .committed else {
            throw RelocationError.invalidPhase(operation: "commit", actual: state.phase)
        }

        // Ensure source is pruned
        if state.phase == .ready {
            let sourceDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: state.sourceCWD, sessionID: sessionID)
            try RelocationFS.removeDirectoryDurable(sourceDir)
        }

        state.phase = .committed
        state.updatedAtMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        try removeJournalFile(sessionID: sessionID)
        releaseLease(sessionID: sessionID)
        return state
    }

    /// Stage 7: Roll back transaction to source (`.rolledBack`).
    ///
    /// Rollback is only permitted BEFORE `.ready`. Once `.ready`, target is authoritative and rollback is rejected.
    @discardableResult
    public func rollback(sessionID: String, reason: String = "manual rollback") throws -> RelocationJournalState {
        var state = try readJournal(sessionID: sessionID)
        if state.phase.hasTargetAuthority {
            throw RelocationError.invalidPhase(operation: "rollback", actual: state.phase)
        }

        let stagingDir = RelocationFS.stagingDirAt(grokHome: grokHome, targetCWD: state.targetCWD, sessionID: sessionID, nonce: state.nonce)
        try? RelocationFS.removeDirectoryDurable(stagingDir)

        let targetDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: state.targetCWD, sessionID: sessionID)
        try? RelocationFS.removeDirectoryDurable(targetDir)

        // Ensure source is still intact
        let sourceDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: state.sourceCWD, sessionID: sessionID)
        try? RelocationFS.requireDirectory(sourceDir)

        state.phase = .rolledBack
        state.updatedAtMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        try removeJournalFile(sessionID: sessionID)
        releaseLease(sessionID: sessionID)
        return state
    }

    // MARK: - Authority Queries

    /// Determine the authoritative working directory and storage directory for a session.
    public func authority(for sessionID: String) throws -> RelocationAuthority {
        if hasRelocationJournal(sessionID: sessionID) {
            let state = try readJournal(sessionID: sessionID)
            let cwd = state.phase.hasTargetAuthority ? state.targetCWD : state.sourceCWD
            let sessionDir = RelocationFS.sessionDirAt(grokHome: grokHome, cwd: cwd, sessionID: sessionID)
            return RelocationAuthority(sessionID: sessionID, cwd: cwd, phase: state.phase, sessionDir: sessionDir)
        }
        throw RelocationError.journalMissing(sessionID: sessionID)
    }

    /// Query the authoritative CWD for a session.
    public func authoritativeCWD(for sessionID: String) throws -> String {
        try authority(for: sessionID).cwd
    }

    /// Query the authoritative session directory for a session.
    public func authoritativeSessionDir(for sessionID: String) throws -> URL {
        try authority(for: sessionID).sessionDir
    }

    // MARK: - Recovery & Torn Write Handling

    /// Recover an interrupted or torn relocation transaction.
    @discardableResult
    public func recover(sessionID: String) throws -> (action: RecoveryAction, state: RelocationJournalState) {
        try RelocationFS.validateComponent(field: "session id", value: sessionID)
        let journalURL = RelocationFS.journalPath(grokHome: grokHome, sessionID: sessionID)

        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw RelocationError.journalMissing(sessionID: sessionID)
        }

        try acquireLease(sessionID: sessionID)

        // Check for torn / corrupted JSON
        let data: Data
        do {
            data = try Data(contentsOf: journalURL)
        } catch {
            throw RelocationError.io(operation: "recover.read", path: journalURL.path, message: error.localizedDescription)
        }

        let decodedState: RelocationJournalState? = try? JSONDecoder().decode(RelocationJournalState.self, from: data)

        if let state = decodedState {
            let action: RecoveryAction
            switch state.phase {
            case .initiated, .sourceVerified, .targetPublished:
                action = .rollBackToSource
                let rolledBackState = try rollback(sessionID: sessionID, reason: "recovered rollback to source from phase \(state.phase.rawValue)")
                return (action, rolledBackState)
            case .ready, .sourcePruned:
                action = .commitTarget
                let committedState = try commit(sessionID: sessionID)
                return (action, committedState)
            case .committed:
                action = .verifyCommitted
                try removeJournalFile(sessionID: sessionID)
                releaseLease(sessionID: sessionID)
                return (action, state)
            case .rolledBack:
                action = .verifyRolledBack
                try removeJournalFile(sessionID: sessionID)
                releaseLease(sessionID: sessionID)
                return (action, state)
            }
        } else {
            // Torn write: journal JSON corrupted. Perform filesystem inspection.
            let sessions = RelocationFS.sessionsDir(grokHome: grokHome)
            var foundSource: (cwd: String, dir: URL)?
            var foundTarget: (cwd: String, dir: URL)?

            if let cwdDirs = try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isDirectoryKey]) {
                for cwdDir in cwdDirs {
                    let candidateSession = cwdDir.appendingPathComponent(sessionID)
                    if FileManager.default.fileExists(atPath: candidateSession.path) {
                        let summaryURL = candidateSession.appendingPathComponent(RelocationFS.summaryFileName)
                        if let summaryData = try? Data(contentsOf: summaryURL),
                           let json = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
                           let cwd = (json["cwd"] as? String)
                               ?? ((json["info"] as? [String: Any])?["cwd"] as? String) {
                            if json["previous_cwd"] != nil {
                                foundTarget = (cwd, candidateSession)
                            } else {
                                foundSource = (cwd, candidateSession)
                            }
                        }
                    }
                }
            }

            // Fallback recovery heuristic:
            // If target is fully formed with previous_cwd and source is pruned/missing -> commit target.
            // Otherwise, roll back to source.
            if let target = foundTarget, foundSource == nil {
                let state = RelocationJournalState(
                    sessionID: sessionID,
                    sourceCWD: (foundTarget?.cwd ?? "/unknown"),
                    targetCWD: target.cwd,
                    phase: .committed
                )
                try removeJournalFile(sessionID: sessionID)
                releaseLease(sessionID: sessionID)
                return (.commitTarget, state)
            } else if let source = foundSource {
                if let target = foundTarget {
                    try? RelocationFS.removeDirectoryDurable(target.dir)
                }
                let state = RelocationJournalState(
                    sessionID: sessionID,
                    sourceCWD: source.cwd,
                    targetCWD: (foundTarget?.cwd ?? "/unknown"),
                    phase: .rolledBack
                )
                try removeJournalFile(sessionID: sessionID)
                releaseLease(sessionID: sessionID)
                return (.rollBackToSource, state)
            } else {
                try removeJournalFile(sessionID: sessionID)
                releaseLease(sessionID: sessionID)
                throw RelocationError.tornWrite(path: journalURL.path, message: "unrecoverable corrupted journal with no matching session directories")
            }
        }
    }

    /// Recover all active relocation journals found under `$OPENGROK_HOME/relocations/`.
    @discardableResult
    public func recoverAll() throws -> [String: (action: RecoveryAction, state: RelocationJournalState)] {
        let relocDir = RelocationFS.relocationsDir(grokHome: grokHome)
        guard FileManager.default.fileExists(atPath: relocDir.path) else { return [:] }

        let entries = try FileManager.default.contentsOfDirectory(at: relocDir, includingPropertiesForKeys: nil)
        var results: [String: (action: RecoveryAction, state: RelocationJournalState)] = [:]

        for entry in entries where entry.pathExtension == "json" {
            let sessionID = entry.deletingPathExtension().lastPathComponent
            do {
                let recovered = try recover(sessionID: sessionID)
                results[sessionID] = recovered
            } catch {
                // Continue recovering remaining journals if one fails
                continue
            }
        }
        return results
    }
}
