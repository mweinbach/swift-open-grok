// ClaudeSessionScanner.swift
//
// Read-only scanner for Claude Code sessions stored as JSONL in
// `~/.claude/projects/<hash>/`.
//
// Rust reference (`~/Projects/grok-build` commit 650c1db7):
//   * `foreign_sessions/claude.rs:30-60` — scan entry point and config dir
//     resolution.
//   * `foreign_sessions/claude.rs` read_candidate / qualify_candidate / title
//     extraction from JSONL head and tail.
//
// This scanner never writes to the Claude store. It reads just enough of each
// file (head and tail) to extract a title and metadata, matching the bounded
// I/O strategy in the Rust reference.

import Foundation

public enum ClaudeSessionScanner {

    // MARK: - Constants (match Rust claude.rs)

    static let readChunk = 64 * 1024
    static let maxHead = 4 * 1024 * 1024
    static let maxContentReads = 128

    // MARK: - Public entry point

    /// Scan the Claude Code config directory for sessions whose `cwd` matches
    /// `requestedCwd`. Returns normalized summaries sorted newest-first.
    ///
    /// `configDir` is injectable for testing; production callers pass `nil` to
    /// use `CLAUDE_CONFIG_DIR` or `~/.claude`.
    public static func scan(
        requestedCwd: String,
        now: Date = Date(),
        configDir: URL? = nil,
        environment: [String: String] = [:]
    ) -> [ForeignSessionSummary] {
        guard let configDir = resolveConfigDir(configDir, environment: environment) else {
            return []
        }
        let projectDirs = scopedProjectDirs(configDir: configDir, cwd: requestedCwd)
        let candidates = collectCandidates(
            projectDirs: projectDirs,
            now: now,
            maxAge: ForeignSessionLimits.maxSessionAge,
            limit: maxContentReads
        )
        var accepted = Set<String>()
        var sessions: [ForeignSessionSummary] = []
        for candidate in candidates {
            guard !accepted.contains(candidate.sessionID) else { continue }
            guard let session = readCandidate(candidate, requestedCwd: requestedCwd) else {
                continue
            }
            accepted.insert(session.nativeID)
            sessions.append(session)
            if sessions.count >= ForeignSessionLimits.maxSessionsPerTool { break }
        }
        finishForeignToolScan(&sessions)
        return sessions
    }

    // MARK: - Config dir resolution

    static func resolveConfigDir(
        _ override: URL?,
        environment: [String: String]
    ) -> URL? {
        if let override { return override }
        if let envPath = environment["CLAUDE_CONFIG_DIR"] ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }
        guard let home = environment["HOME"] ?? ProcessInfo.processInfo.environment["HOME"] else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - Project directory scoping

    /// Claude Code stores sessions under `projects/<hash>/` where the hash is
    /// derived from the project path. We scan all project directories because
    /// the hash function is not public and may change.
    static func scopedProjectDirs(configDir: URL, cwd: String) -> [URL] {
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectsDir.path) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                && isDir.boolValue
        }
    }

    // MARK: - Candidate collection

    struct Candidate {
        let path: URL
        let sessionID: String
        let modified: Date
        let size: UInt64
    }

    static func collectCandidates(
        projectDirs: [URL],
        now: Date,
        maxAge: TimeInterval,
        limit: Int
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for projectDir in projectDirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                guard entry.pathExtension == "jsonl" else { continue }
                let stem = entry.deletingPathExtension().lastPathComponent
                guard isValidUUID(stem) else { continue }
                guard let attrs = try? entry.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                ) else { continue }
                guard attrs.isRegularFile == true else { continue }
                guard let modified = attrs.contentModificationDate else { continue }
                let size = UInt64(attrs.fileSize ?? 0)
                guard size > 0 else { continue }
                guard isForeignSessionWithin(modified, now: now, window: maxAge) else { continue }
                insertSorted(
                    &candidates,
                    Candidate(path: entry, sessionID: stem, modified: modified, size: size),
                    limit: limit
                )
            }
        }
        return candidates
    }

    // MARK: - Candidate reading

    static func readCandidate(
        _ candidate: Candidate,
        requestedCwd: String
    ) -> ForeignSessionSummary? {
        guard let (head, storedCwd) = readHeadForCwd(candidate) else { return nil }

        let firstLine = head.prefix(while: { !$0.isNewline })
        if firstLine.contains("\"isSidechain\":true")
            || firstLine.contains("\"isSidechain\": true") {
            return nil
        }

        guard let storedCwd, foreignSessionPathsEqual(storedCwd, requestedCwd) else { return nil }

        let tail = readTail(candidate)

        let title: String? = [
            lastJSONString(in: tail, key: "customTitle") ?? lastJSONString(in: head, key: "customTitle"),
            lastJSONString(in: tail, key: "aiTitle") ?? lastJSONString(in: head, key: "aiTitle"),
            lastJSONString(in: tail, key: "lastPrompt") ?? lastJSONString(in: head, key: "lastPrompt"),
            lastJSONString(in: tail, key: "summary") ?? lastJSONString(in: head, key: "summary"),
            firstPrompt(in: head),
        ]
        .compactMap { $0 }
        .compactMap { normalizeForeignTitle($0) }
        .first

        guard let title else { return nil }

        let branch = (lastJSONString(in: tail, key: "gitBranch")
            ?? lastJSONString(in: head, key: "gitBranch"))
            .flatMap { normalizeForeignTitle($0) }

        return ForeignSessionSummary(
            tool: .claude,
            source: .claudeCode,
            nativeID: candidate.sessionID,
            title: title,
            cwd: requestedCwd,
            updatedAt: candidate.modified,
            branch: branch
        )
    }

    // MARK: - Head / tail reading (bounded I/O)

    static func readHeadForCwd(
        _ candidate: Candidate
    ) -> (head: String, cwd: String?)? {
        let maxSize = min(candidate.size, UInt64(maxHead))
        var limit = min(readChunk, Int(maxSize))
        while true {
            guard let head = readPrefix(candidate.path, limit: limit) else { return nil }
            let cwd = firstJSONString(in: head, key: "cwd")
            if cwd != nil || limit >= Int(maxSize) {
                return (head, cwd)
            }
            limit = min(limit * 4, Int(maxSize))
        }
    }

    static func readPrefix(_ url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: limit)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func readTail(_ candidate: Candidate) -> String {
        let len = min(candidate.size, UInt64(readChunk))
        guard let handle = try? FileHandle(forReadingFrom: candidate.path) else { return "" }
        defer { try? handle.close() }
        let offset = candidate.size - len
        if offset > 0 {
            handle.seek(toFileOffset: offset)
        }
        let data = handle.readData(ofLength: Int(len))
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - JSONL field extraction

    static func firstJSONString(in text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            if let value = jsonStringField(String(line), key: key) {
                return value
            }
        }
        return nil
    }

    static func lastJSONString(in text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if let value = jsonStringField(String(line), key: key) {
                return value
            }
        }
        return nil
    }

    static func jsonStringField(_ line: String, key: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? String
        else { return nil }
        return value
    }

    // MARK: - First prompt extraction

    /// Extract the first real user prompt from the JSONL head, matching Rust's
    /// `first_prompt` logic including command-name and bash-input tag handling.
    static func firstPrompt(in head: String) -> String? {
        var commandFallback: String?
        for line in head.split(whereSeparator: \.isNewline) {
            let lineStr = String(line)
            if lineStr.contains("\"tool_result\"") { continue }
            guard let data = lineStr.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard (entry["type"] as? String) == "user" else { continue }
            if entry["isMeta"] as? Bool == true { continue }
            if entry["isCompactSummary"] as? Bool == true { continue }
            guard let message = entry["message"] as? [String: Any],
                  let content = message["content"]
            else { continue }
            let texts: [String]
            if let text = content as? String {
                texts = [text]
            } else if let blocks = content as? [[String: Any]] {
                texts = blocks
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }
            } else {
                continue
            }
            for text in texts {
                let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !normalized.isEmpty else { continue }
                if let command = between(normalized, start: "<command-name>", end: "</command-name>") {
                    if commandFallback == nil { commandFallback = command }
                    continue
                }
                if let bash = between(normalized, start: "<bash-input>", end: "</bash-input>") {
                    return normalizeForeignTitle("! \(bash.trimmingCharacters(in: .whitespaces))")
                }
                if isGeneratedPrompt(normalized) { continue }
                return normalizeForeignTitle(normalized)
            }
        }
        return commandFallback.flatMap { normalizeForeignTitle($0) }
    }

    static func between(_ value: String, start: String, end: String) -> String? {
        guard let startRange = value.range(of: start) else { return nil }
        let afterStart = value[startRange.upperBound...]
        guard let endRange = afterStart.range(of: end) else { return nil }
        return String(afterStart[..<endRange.lowerBound])
    }

    static func isGeneratedPrompt(_ value: String) -> Bool {
        if value.hasPrefix("[Request interrupted by user") { return true }
        let trimmed = value.drop(while: \.isWhitespace)
        guard let first = trimmed.first, first == "<" else { return false }
        let afterLT = trimmed.dropFirst()
        guard let next = afterLT.first else { return false }
        return next.isLowercase && next.isASCII
    }

    // MARK: - Helpers

    static func isValidUUID(_ string: String) -> Bool {
        UUID(uuidString: string) != nil
    }

    /// Insert into a sorted array, maintaining newest-first order and capping
    /// at `limit`. Matches Rust's `retain_top_k_by`.
    static func insertSorted(
        _ candidates: inout [Candidate],
        _ candidate: Candidate,
        limit: Int
    ) {
        guard limit > 0 else { return }
        if candidates.count == limit {
            guard let last = candidates.last,
                  candidateOrder(last, candidate) == .orderedDescending
            else { return }
            candidates.removeLast()
        }
        let index = candidates.firstIndex {
            candidateOrder($0, candidate) == .orderedDescending
        } ?? candidates.count
        candidates.insert(candidate, at: index)
    }

    /// Newest first, then by session ID for stability.
    static func candidateOrder(_ a: Candidate, _ b: Candidate) -> ComparisonResult {
        if b.modified > a.modified { return .orderedDescending }
        if b.modified < a.modified { return .orderedAscending }
        if a.sessionID < b.sessionID { return .orderedAscending }
        if a.sessionID > b.sessionID { return .orderedDescending }
        return .orderedSame
    }
}
