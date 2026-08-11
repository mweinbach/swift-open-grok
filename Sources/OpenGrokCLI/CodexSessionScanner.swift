// CodexSessionScanner.swift
//
// Read-only scanner for Codex sessions stored as JSONL rollout files under
// `~/.codex/sessions/`.
//
// Rust reference (`~/Projects/grok-build` commit 650c1db7):
//   * `foreign_sessions/codex/mod.rs:18-50` — home resolution and scan entry
//     point.
//   * `foreign_sessions/codex/files.rs` — rollout-file based scanner.
//
// The Rust reference also supports a SQLite state database
// (`codex/db.rs`). This Swift port scans only the rollout JSONL files,
// matching the files.rs path. The database path is deliberately deferred:
// it requires SQLite bindings that this target does not carry, and the
// file-based scanner covers the common case. The omission is recorded in
// the handoff.
//
// This scanner never writes to the Codex store. Read-only, bounded I/O.

import Foundation

public enum CodexSessionScanner {

    // MARK: - Constants

    static let maxMetadataReads = 128
    static let maxHeadRecords = 10
    static let maxHeadBytes = 64 * 1024

    // MARK: - Public entry point

    /// Scan the Codex home directory for rollout sessions whose `cwd` matches
    /// `requestedCwd`. Returns normalized summaries sorted newest-first.
    ///
    /// `codexHome` is injectable for testing; production callers pass `nil` to
    /// use `CODEX_HOME` or `~/.codex`.
    public static func scan(
        requestedCwd: String,
        now: Date = Date(),
        codexHome: URL? = nil,
        environment: [String: String] = [:]
    ) -> [ForeignSessionSummary] {
        guard let home = resolveCodexHome(codexHome, environment: environment) else {
            return []
        }
        let sessionsDir = home.appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return [] }
        let candidates = collectRolloutCandidates(
            sessionsDir: sessionsDir,
            now: now,
            maxAge: ForeignSessionLimits.maxSessionAge,
            limit: maxMetadataReads
        )
        var accepted = Set<String>()
        var sessions: [ForeignSessionSummary] = []
        for candidate in candidates {
            guard !accepted.contains(candidate.id) else { continue }
            guard let session = readRolloutCandidate(candidate, requestedCwd: requestedCwd) else {
                continue
            }
            accepted.insert(session.nativeID)
            sessions.append(session)
            if sessions.count >= ForeignSessionLimits.maxSessionsPerTool { break }
        }
        finishForeignToolScan(&sessions)
        return sessions
    }

    // MARK: - Home resolution

    static func resolveCodexHome(
        _ override: URL?,
        environment: [String: String]
    ) -> URL? {
        if let override { return override }
        if let envPath = environment["CODEX_HOME"] ?? ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }
        guard let home = environment["HOME"] ?? ProcessInfo.processInfo.environment["HOME"] else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }

    // MARK: - Rollout candidate collection

    struct RolloutCandidate {
        let path: URL
        let id: String
        let modified: Date
        let size: UInt64
    }

    /// Codex stores rollouts in date-partitioned directories:
    /// `sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl`
    ///
    /// We walk the date directories for the last 31 days (matching Rust's
    /// `DAYS_IN_WINDOW`) and collect the newest candidates.
    static func collectRolloutCandidates(
        sessionsDir: URL,
        now: Date,
        maxAge: TimeInterval,
        limit: Int
    ) -> [RolloutCandidate] {
        var candidates: [RolloutCandidate] = []
        let dateDirs = recentDateDirectories(sessionsDir: sessionsDir, now: now, days: 31)
        for dateDir in dateDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dateDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                guard entry.pathExtension == "jsonl" else { continue }
                let name = entry.deletingPathExtension().lastPathComponent
                guard let id = rolloutID(from: name) else { continue }
                guard let attrs = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                ) else { continue }
                guard attrs.isRegularFile == true else { continue }
                guard let modified = attrs.contentModificationDate else { continue }
                let size = UInt64(attrs.fileSize ?? 0)
                guard size > 0 else { continue }
                guard isForeignSessionWithin(modified, now: now, window: maxAge) else { continue }
                insertRolloutSorted(
                    &candidates,
                    RolloutCandidate(path: entry, id: id, modified: modified, size: size),
                    limit: limit
                )
            }
        }
        return candidates
    }

    /// Generate the date directory paths for the last N days.
    /// Codex uses `sessions/YYYY/MM/DD/`.
    static func recentDateDirectories(
        sessionsDir: URL,
        now: Date,
        days: Int
    ) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        var dirs: [URL] = []
        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else {
                continue
            }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else { continue }
            let dir = sessionsDir
                .appendingPathComponent(String(year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.path) {
                dirs.append(dir)
            }
        }
        return dirs
    }

    // MARK: - Rollout ID extraction

    /// Extract the UUID from a rollout filename like
    /// `rollout-2027-01-15T12-00-00-<uuid>`.
    /// Matches Rust's `rollout_id`.
    static func rolloutID(from name: String) -> String? {
        guard name.hasPrefix("rollout-") else { return nil }
        let value = String(name.dropFirst("rollout-".count))
        guard value.count >= 36 else { return nil }
        let idStart = value.index(value.endIndex, offsetBy: -36)
        guard idStart > value.startIndex else { return nil }
        let beforeID = value[value.index(before: idStart)]
        guard beforeID == "-" else { return nil }
        let id = String(value[idStart...])
        guard UUID(uuidString: id) != nil else { return nil }
        let timestamp = String(value[..<value.index(before: idStart)])
        guard timestamp.count == 19 else { return nil }
        return id
    }

    // MARK: - Candidate reading

    static func readRolloutCandidate(
        _ candidate: RolloutCandidate,
        requestedCwd: String
    ) -> ForeignSessionSummary? {
        let head = readHead(candidate)
        guard !head.isEmpty else { return nil }
        let meta = parseHeadMetadata(head)
        guard let storedCwd = meta.cwd, storedCwd == requestedCwd else { return nil }
        let source = meta.source ?? .codexCli
        let titleText: String?
        if let firstMsg = meta.firstUserMessage {
            titleText = normalizeForeignTitle(firstMsg)
        } else {
            titleText = nil
        }
        guard let title = titleText else { return nil }
        return ForeignSessionSummary(
            tool: .codex,
            source: source,
            nativeID: candidate.id,
            title: title,
            cwd: requestedCwd,
            updatedAt: candidate.modified,
            branch: meta.branch.flatMap { normalizeForeignTitle($0) }
        )
    }

    /// Read the first few JSONL records from a rollout, bounded to
    /// `maxHeadBytes`.
    static func readHead(_ candidate: RolloutCandidate) -> String {
        let limit = min(Int(candidate.size), maxHeadBytes)
        guard let handle = try? FileHandle(forReadingFrom: candidate.path) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    struct HeadMetadata {
        var id: String?
        var cwd: String?
        var source: ForeignSessionSource?
        var branch: String?
        var firstUserMessage: String?
    }

    /// Parse the first few JSONL records for metadata fields. The Codex rollout
    /// format stores metadata in the first record and messages in subsequent
    /// records.
    static func parseHeadMetadata(_ head: String) -> HeadMetadata {
        var meta = HeadMetadata()
        var recordCount = 0
        for line in head.split(whereSeparator: \.isNewline) {
            guard recordCount < maxHeadRecords else { break }
            recordCount += 1
            let lineStr = String(line)
            guard let data = lineStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if meta.cwd == nil, let cwd = obj["cwd"] as? String {
                meta.cwd = cwd
            }
            if meta.id == nil, let id = obj["session_id"] as? String {
                meta.id = id
            }
            if meta.source == nil {
                if let sourceStr = obj["source"] as? String {
                    meta.source = codexSourceFromString(sourceStr)
                } else if let sourceObj = obj["source"] as? [String: Any] {
                    meta.source = codexSourceFromObject(sourceObj)
                }
            }
            if meta.branch == nil, let branch = obj["git_branch"] as? String {
                meta.branch = branch
            }
            if meta.firstUserMessage == nil {
                if let role = obj["role"] as? String, role == "user",
                   let content = obj["content"] as? String {
                    meta.firstUserMessage = content
                } else if let msg = obj["message"] as? String {
                    meta.firstUserMessage = msg
                }
            }
        }
        return meta
    }

    /// Map a Codex source string to a `ForeignSessionSource`, matching Rust's
    /// `source_from_str`.
    static func codexSourceFromString(_ source: String) -> ForeignSessionSource? {
        switch source {
        case "cli": return .codexCli
        case "vscode": return .codexVsCode
        default: return nil
        }
    }

    /// Map a Codex source object to a `ForeignSessionSource`, matching Rust's
    /// `source_from_value` for the `{ "custom": "atlas" }` shape.
    static func codexSourceFromObject(_ source: [String: Any]) -> ForeignSessionSource? {
        guard let custom = source["custom"] as? String else { return nil }
        switch custom {
        case "atlas": return .codexAtlas
        case "chatgpt": return .codexChatGpt
        default: return nil
        }
    }

    // MARK: - Sorted insert

    static func insertRolloutSorted(
        _ candidates: inout [RolloutCandidate],
        _ candidate: RolloutCandidate,
        limit: Int
    ) {
        guard limit > 0 else { return }
        if candidates.count == limit {
            guard let last = candidates.last,
                  rolloutOrder(last, candidate) == .orderedDescending
            else { return }
            candidates.removeLast()
        }
        let index = candidates.firstIndex {
            rolloutOrder($0, candidate) == .orderedDescending
        } ?? candidates.count
        candidates.insert(candidate, at: index)
    }

    static func rolloutOrder(
        _ a: RolloutCandidate,
        _ b: RolloutCandidate
    ) -> ComparisonResult {
        if b.modified > a.modified { return .orderedDescending }
        if b.modified < a.modified { return .orderedAscending }
        if a.id < b.id { return .orderedAscending }
        if a.id > b.id { return .orderedDescending }
        return .orderedSame
    }
}
