import Foundation
import OpenGrokConfigTypes
import Testing
@testable import OpenGrokMemory

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-dream-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTemporaryDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func setModificationDate(_ url: URL, ageSeconds: TimeInterval) throws {
    let date = Date(timeIntervalSinceNow: -ageSeconds)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private func writeSession(
    sessionsDirectory: URL,
    name: String,
    content: String = "test",
    ageSeconds: TimeInterval = 100
) throws {
    try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    let path = sessionsDirectory.appendingPathComponent("\(name).md")
    try content.write(to: path, atomically: true, encoding: .utf8)
    try setModificationDate(path, ageSeconds: ageSeconds)
}

private func enabledDreamConfig(
    minHours: UInt64 = 24,
    minSessions: UInt64 = 5
) -> MemoryDreamConfig {
    MemoryDreamConfig(
        enabled: true,
        minHours: minHours,
        minSessions: minSessions,
        staleLockSecs: 3600,
        checkIntervalSecs: nil
    )
}

private func setConsolidationAge(lock: DreamLock, ageSeconds: TimeInterval) throws {
    try FileManager.default.createDirectory(
        at: lock.path.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: lock.path)
    try setModificationDate(lock.path, ageSeconds: ageSeconds)
}

@Suite("Dream gate checks")
struct DreamGateTests {
    @Test("disabled config returns disabled")
    func disabledConfig() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let lock = DreamLock(workspaceDirectory: root)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        var config = enabledDreamConfig()
        config.enabled = false
        #expect(
            checkDreamGates(
                config: config,
                lock: lock,
                sessionsDirectory: sessions,
                currentSessionSID8: nil
            ) == .disabled
        )
    }

    @Test("too soon when recently consolidated")
    func tooSoon() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let lock = DreamLock(workspaceDirectory: root)
        try lock.recordConsolidation()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let result = checkDreamGates(
            config: enabledDreamConfig(),
            lock: lock,
            sessionsDirectory: sessions,
            currentSessionSID8: nil
        )
        guard case .tooSoon(let hoursSince) = result else {
            Issue.record("expected tooSoon, got \(result)")
            return
        }
        #expect(hoursSince < 24)
    }

    @Test("too few sessions when under threshold")
    func tooFewSessions() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let lock = DreamLock(workspaceDirectory: root)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try setConsolidationAge(lock: lock, ageSeconds: 48 * 3600)
        for index in 0..<3 {
            try writeSession(
                sessionsDirectory: sessions,
                name: "2026-01-0\(index)-proj-aaa\(index)0000"
            )
        }
        #expect(
            checkDreamGates(
                config: enabledDreamConfig(),
                lock: lock,
                sessionsDirectory: sessions,
                currentSessionSID8: nil
            ) == .tooFewSessions(count: 3, required: 5)
        )
    }

    @Test("all gates pass returns open with sorted sessions")
    func gatesOpen() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let lock = DreamLock(workspaceDirectory: root)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try setConsolidationAge(lock: lock, ageSeconds: 48 * 3600)
        for index in 0..<6 {
            try writeSession(
                sessionsDirectory: sessions,
                name: String(format: "2026-01-%02d-proj-aaa%05d", index, index)
            )
        }
        let result = checkDreamGates(
            config: enabledDreamConfig(),
            lock: lock,
            sessionsDirectory: sessions,
            currentSessionSID8: nil
        )
        guard case .open(let stems) = result else {
            Issue.record("expected open, got \(result)")
            return
        }
        #expect(stems.count == 6)
        #expect(stems == stems.sorted())
    }

    @Test("current session excluded from gate count")
    func currentSessionExcluded() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let lock = DreamLock(workspaceDirectory: root)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try setConsolidationAge(lock: lock, ageSeconds: 48 * 3600)
        for index in 0..<4 {
            try writeSession(
                sessionsDirectory: sessions,
                name: "2026-01-0\(index)-proj-aaa\(index)0000"
            )
        }
        try writeSession(sessionsDirectory: sessions, name: "2026-01-05-proj-current1")
        #expect(
            checkDreamGates(
                config: enabledDreamConfig(),
                lock: lock,
                sessionsDirectory: sessions,
                currentSessionSID8: "current1"
            ) == .tooFewSessions(count: 4, required: 5)
        )
    }
}

@Suite("Dream response processing")
struct DreamResponseTests {
    @Test("empty and NO_REPLY responses are rejected")
    func emptyAndNoReply() {
        #expect(processDreamResponse("") == nil)
        #expect(processDreamResponse("   ") == nil)
        #expect(processDreamResponse("NO_REPLY") == nil)
        #expect(processDreamResponse("no reply") == nil)
    }

    @Test("markdown headers are required")
    func markdownRequired() {
        #expect(processDreamResponse("## Topic\n\nInsight.") == "## Topic\n\nInsight.")
        #expect(processDreamResponse("Just plain text.") == nil)
    }
}

@Suite("Dream execution")
struct DreamExecutionTests {
    @Test("valid response writes workspace MEMORY.md")
    func writesMemory() throws {
        let root = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(root) }
        let cwd = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let storage = MemoryStorage.newFlat(cwd: cwd, root: root.appendingPathComponent("memory"))
        try storage.ensureInitialized()
        let lock = DreamLock(workspaceDirectory: storage.workspaceDir)
        let response = "## Decisions\n\nWe chose Swift.\n\n## Architecture\n\nEvent-driven."
        let result = executeDream(
            lock: lock,
            storage: storage,
            response: response,
            sessionsEligible: 2,
            staleLockSeconds: 300,
            sessionsDirectory: storage.sessionsDir,
            processedStems: []
        )
        guard case .completed(let charsWritten) = result.status else {
            Issue.record("expected completed, got \(result.status)")
            return
        }
        #expect(charsWritten == response.count)
        let memory = try String(contentsOf: storage.workspaceMemoryFile, encoding: .utf8)
        #expect(memory.contains("We chose Swift."))
    }
}
