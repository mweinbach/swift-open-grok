import Foundation

private let dreamLockFileName = ".dream-lock"

/// PID-based lock file with mtime tracking for dream consolidation.
public struct DreamLock: Sendable, Equatable {
    public let path: URL

    public init(workspaceDirectory: URL) {
        path = workspaceDirectory.appendingPathComponent(dreamLockFileName)
    }

    /// Read the last consolidation timestamp (lock file mtime).
    public func lastConsolidatedAt() throws -> Date? {
        let values = try path.resourceValues(forKeys: [.contentModificationDateKey])
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return values.contentModificationDate
    }

    /// Try to acquire the lock for consolidation.
    ///
    /// Returns `.acquired(prior:)` on success. Returns `.held` when a live,
    /// non-stale process owns the lock.
    public enum AcquireResult: Equatable, Sendable {
        case acquired(prior: Date?)
        case held
    }

    public func tryAcquire(staleSeconds: UInt64) throws -> AcquireResult {
        let prior: Date?
        if FileManager.default.fileExists(atPath: path.path) {
            let values = try path.resourceValues(forKeys: [
                .contentModificationDateKey,
            ])
            let mtime = values.contentModificationDate ?? Date.distantPast
            if let content = try? String(contentsOf: path, encoding: .utf8),
               let pid = UInt32(content.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0
            {
                let age = Date().timeIntervalSince(mtime)
                if age < Double(staleSeconds), isProcessAlive(pid) {
                    return .held
                }
            }
            prior = mtime
        } else {
            prior = nil
        }

        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let ourPID = ProcessInfo.processInfo.processIdentifier
        try String(ourPID).write(to: path, atomically: true, encoding: .utf8)

        let content = try String(contentsOf: path, encoding: .utf8)
        if content.trimmingCharacters(in: .whitespacesAndNewlines) == String(ourPID) {
            return .acquired(prior: prior)
        }
        return .held
    }

    /// Restore lock state after a failed dream.
    public func rollback(prior: Date?) throws {
        guard let prior else {
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
            return
        }
        try Data().write(to: path)
        try FileManager.default.setAttributes(
            [.modificationDate: prior],
            ofItemAtPath: path.path
        )
    }

    /// Stamp the lock file with the current time to record a consolidation.
    public func recordConsolidation() throws {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).write(to: path, atomically: true, encoding: .utf8)
    }
}

/// Count session files modified after `since`, excluding the current session.
public func sessionsSince(
    sessionsDirectory: URL,
    since: Date,
    excludingSessionSID8: String?
) throws -> [String] {
    guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else {
        return []
    }
    let entries = try FileManager.default.contentsOfDirectory(
        at: sessionsDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    )

    var result: [String] = []
    for entry in entries {
        guard entry.pathExtension == "md" else { continue }
        let stem = entry.deletingPathExtension().lastPathComponent
        if let exclude = excludingSessionSID8, stem.hasSuffix(exclude) {
            continue
        }
        let values = try entry.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modified = values.contentModificationDate, modified > since else {
            continue
        }
        result.append(stem)
    }
    result.sort()
    return result
}

#if canImport(Darwin)
import Darwin

private func isProcessAlive(_ pid: UInt32) -> Bool {
    if kill(pid_t(pid), 0) == 0 { return true }
    return errno == EPERM
}
#else
private func isProcessAlive(_ pid: UInt32) -> Bool {
    _ = pid
    return false
}
#endif
