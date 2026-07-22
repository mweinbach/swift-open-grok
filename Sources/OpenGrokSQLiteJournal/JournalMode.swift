// JournalMode.swift
//
// Port of `xai-sqlite-journal::JournalMode` — filesystem-aware SQLite
// journal-mode selection (WAL on local disks, TRUNCATE on network mounts).

import Foundation

/// Journal mode chosen for a SQLite database based on where it lives.
public enum JournalMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Write-ahead logging — historical default, local filesystems only.
    case wal = "WAL"
    /// Rollback journal truncated at commit — safe on network filesystems.
    case truncate = "TRUNCATE"

    /// `PRAGMA journal_mode` value.
    public var pragmaValue: String { rawValue }

    /// Pick the journal mode for a database at `dbPath`.
    ///
    /// Classifies the parent directory (the DB file itself may not exist
    /// yet). `OPENGROK_SQLITE_JOURNAL_MODE` or legacy
    /// `GROK_SQLITE_JOURNAL_MODE` (`wal`|`truncate`) overrides detection.
    public static func forDBPath(_ dbPath: URL) -> JournalMode {
        switch modeFromEnv() {
        case .mode(let mode):
            return mode
        case .invalid, .unset:
            break
        }
        let dir: URL
        let parent = dbPath.deletingLastPathComponent()
        if parent.path.isEmpty || parent.path == dbPath.path {
            dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        } else {
            dir = parent
        }
        return isNetworkFS(dir) ? .truncate : .wal
    }

    /// Path actually opened under this mode.
    ///
    /// `wal` (local): unchanged. `truncate` (network): a per-host sibling
    /// (`worktrees.db` → `worktrees.h-<host>.db`). Idempotent.
    public func effectiveDBPath(_ dbPath: URL) -> URL {
        guard self == .truncate else { return dbPath }
        guard let host = hostDiscriminator() else { return dbPath }
        let name = dbPath.lastPathComponent
        guard !name.isEmpty else { return dbPath }
        let tag = ".h-\(host)"
        if name.hasSuffix(tag) || name.contains("\(tag).") {
            return dbPath
        }
        let newName: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let stem = String(name[..<dot])
            let ext = String(name[name.index(after: dot)...])
            newName = "\(stem)\(tag).\(ext)"
        } else {
            newName = "\(name)\(tag)"
        }
        return dbPath.deletingLastPathComponent().appendingPathComponent(newName)
    }
}

// MARK: - Env override

enum EnvOverride: Equatable {
    case unset
    case invalid
    case mode(JournalMode)
}

/// Pure parser for journal-mode kill-switch values.
func modeFromEnvValue(_ value: String?) -> EnvOverride {
    guard let value else { return .unset }
    if value.isEmpty { return .unset }
    if value.lowercased() == "wal" { return .mode(.wal) }
    if value.lowercased() == "truncate" { return .mode(.truncate) }
    return .invalid
}

func modeFromEnv(
    openGrok: String? = ProcessInfo.processInfo.environment["OPENGROK_SQLITE_JOURNAL_MODE"],
    legacy: String? = ProcessInfo.processInfo.environment["GROK_SQLITE_JOURNAL_MODE"]
) -> EnvOverride {
    // Prefer OPENGROK_* branding; fall back to Rust-compatible GROK_*.
    let primary = modeFromEnvValue(openGrok)
    if case .unset = primary {
        return modeFromEnvValue(legacy)
    }
    return primary
}

// MARK: - Host discriminator

/// Short per-host discriminator (lowercased alphanumeric, other → `-`, max 24).
func hostDiscriminator(raw: String? = nil) -> String? {
    let source = raw ?? currentHostname()
    guard let source else { return nil }
    var s = String(source.trimmingCharacters(in: .whitespacesAndNewlines).map { ch -> Character in
        if ch.isASCII && (ch.isLetter || ch.isNumber) {
            return Character(ch.lowercased())
        }
        return "-"
    })
    if s.count > 24 {
        s = String(s.prefix(24))
    }
    while s.hasPrefix("-") { s.removeFirst() }
    while s.hasSuffix("-") { s.removeLast() }
    return s.isEmpty ? nil : s
}

private func currentHostname() -> String? {
    #if os(Windows)
    return ProcessInfo.processInfo.environment["COMPUTERNAME"]
    #else
    var buf = [CChar](repeating: 0, count: 256)
    if gethostname(&buf, buf.count) != 0 {
        return ProcessInfo.processInfo.hostName
    }
    let len = buf.firstIndex(of: 0) ?? buf.endIndex
    return String(decoding: buf[..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    #endif
}
