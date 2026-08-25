// CodexSessionScanner.swift
//
// Read-only scanner for Codex sessions stored in state databases or JSONL
// rollout files under `~/.codex/`.
//
// Rust reference (`~/Projects/grok-build` commit 00e176c8fb4035701c24199bf9225973c1b13c20):
//   * `xai-grok-foreign-sessions/src/codex/mod.rs:42-51` — database-first scan.
//   * `xai-grok-foreign-sessions/src/codex/files.rs:244-349` — rollout metadata.
//
// This scanner never writes to the Codex store. Read-only, bounded I/O.

import Foundation

public enum CodexSessionScanner {

    // MARK: - Constants

    static let maxMetadataReads = 128
    static let maxHeadRecords = 10
    static let maxHeadBytes = 64 * 1024
    static let maxDateDirectories = 32

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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ForeignSessionSummary] {
        guard let home = resolveCodexHome(codexHome, environment: environment),
              let root = CodexApprovedRoot(home)
        else {
            return []
        }
        if var sessions = CodexSessionDatabaseScanner.scan(
            root: root,
            requestedCwd: requestedCwd,
            now: now
        ) {
            finishForeignToolScan(&sessions)
            return sessions
        }

        let sessionsDir = root.url.appendingPathComponent("sessions", isDirectory: true)
        guard root.containsSafeDirectory(sessionsDir) else { return [] }
        let candidates = collectRolloutCandidates(
            sessionsDir: sessionsDir,
            now: now,
            maxAge: ForeignSessionLimits.maxSessionAge,
            limit: maxMetadataReads,
            root: root
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
        if let envPath = environment["CODEX_HOME"], !envPath.isEmpty {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }
        guard let home = environment["HOME"], !home.isEmpty else {
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
        let root: CodexApprovedRoot
    }

    /// Codex stores plain and single-frame zstd rollouts in date-partitioned
    /// directories: `sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl[.zst]`.
    ///
    /// We walk the date directories for the last 31 days (matching Rust's
    /// `DAYS_IN_WINDOW`) and collect the newest candidates.
    static func collectRolloutCandidates(
        sessionsDir: URL,
        now: Date,
        maxAge: TimeInterval,
        limit: Int,
        root: CodexApprovedRoot
    ) -> [RolloutCandidate] {
        var candidates: [RolloutCandidate] = []
        let dateDirs = recentDateDirectories(sessionsDir: sessionsDir, now: now, days: 31)
        for dateDir in dateDirs {
            guard root.containsSafeDirectory(dateDir) else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dateDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                guard let id = rolloutID(fromPath: entry) else { continue }
                guard let opened = root.openRegularFile(entry), opened.size > 0 else { continue }
                guard isForeignSessionWithin(opened.modified, now: now, window: maxAge) else {
                    continue
                }
                insertRolloutSorted(
                    &candidates,
                    RolloutCandidate(
                        path: opened.path,
                        id: id,
                        modified: opened.modified,
                        size: opened.size,
                        root: root
                    ),
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
        let localCalendar = Calendar(identifier: .gregorian)
        var utcCalendar = localCalendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? localCalendar.timeZone
        var dirs: [String: URL] = [:]

        for calendar in [localCalendar, utcCalendar] {
            for dayOffset in 0..<days {
                guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else {
                    continue
                }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = components.year,
                      let month = components.month,
                      let day = components.day
                else { continue }
                let key = String(format: "%04d/%02d/%02d", year, month, day)
                let dir = sessionsDir
                    .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                    .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
                if FileManager.default.fileExists(atPath: dir.path) {
                    dirs[key] = dir
                }
            }
        }
        return dirs.keys.sorted(by: >).prefix(maxDateDirectories).compactMap { dirs[$0] }
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
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        formatter.isLenient = false
        guard formatter.date(from: timestamp) != nil else { return nil }
        return id
    }

    static func rolloutID(fromPath path: URL) -> String? {
        let name = path.lastPathComponent
        let stem: String
        if name.hasSuffix(".jsonl.zst") {
            stem = String(name.dropLast(".jsonl.zst".count))
        } else if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(".jsonl".count))
        } else {
            return nil
        }
        return rolloutID(from: stem)
    }

    // MARK: - Candidate reading

    static func readRolloutCandidate(
        _ candidate: RolloutCandidate,
        requestedCwd: String
    ) -> ForeignSessionSummary? {
        let head = readHead(candidate)
        guard !head.isEmpty else { return nil }
        let meta = parseHeadMetadata(head)
        guard let metadataID = meta.id,
              let parsedMetadataID = UUID(uuidString: metadataID),
              parsedMetadataID == UUID(uuidString: candidate.id),
              let storedCwd = meta.cwd,
              foreignSessionPathsEqual(storedCwd, requestedCwd),
              let source = meta.source,
              let firstMessage = meta.firstUserMessage,
              let title = normalizeForeignTitle(firstMessage)
        else { return nil }
        return ForeignSessionSummary(
            tool: .codex,
            source: source,
            nativeID: candidate.id,
            title: title,
            cwd: storedCwd,
            updatedAt: candidate.modified,
            branch: meta.branch.flatMap { normalizeForeignTitle($0) }
        )
    }

    /// Read the first few JSONL records from a plain or single-frame zstd
    /// rollout. The compressed input and decoded output have independent caps.
    static func readHead(_ candidate: RolloutCandidate) -> String {
        guard let opened = candidate.root.openRegularFile(candidate.path),
              opened.size > 0
        else { return "" }
        let compressed = candidate.path.lastPathComponent.hasSuffix(".jsonl.zst")
        let ceiling = compressed ? CodexZstdSessionReader.maxCompressedBytes : maxHeadBytes
        let limit = Int(min(opened.size, UInt64(ceiling)))
        #if os(Windows)
        guard let input = opened.read(maximum: limit) else { return "" }
        #else
        let handle = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: false)
        let input = handle.readData(ofLength: limit)
        #endif
        let data: Data
        if compressed {
            do {
                data = try CodexZstdSessionReader.decodeHead(input)
            } catch {
                return ""
            }
        } else {
            data = input
        }
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
        var sawSessionMetadata = false
        var acceptsLegacyRecords = false
        for line in head.split(whereSeparator: \.isNewline) {
            guard recordCount < maxHeadRecords else { break }
            recordCount += 1
            let lineStr = String(line)
            guard let data = lineStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if obj["type"] as? String == "session_meta", !sawSessionMetadata {
                sawSessionMetadata = true
                acceptsLegacyRecords = false
                meta = HeadMetadata()
                guard let payload = obj["payload"] as? [String: Any] else { continue }
                meta.id = payload["id"] as? String
                meta.cwd = payload["cwd"] as? String
                meta.source = codexSourceFromValue(payload["source"])
                let git = payload["git"] as? [String: Any]
                meta.branch = git?["branch"] as? String ?? payload["git_branch"] as? String
            } else if !sawSessionMetadata,
                      !acceptsLegacyRecords,
                      let id = obj["session_id"] as? String,
                      let cwd = obj["cwd"] as? String
            {
                acceptsLegacyRecords = true
                meta.id = id
                meta.cwd = cwd
                meta.source = codexSourceFromValue(obj["source"])
                meta.branch = obj["git_branch"] as? String
            }

            guard meta.firstUserMessage == nil else { continue }
            if let payload = obj["payload"] as? [String: Any],
               let message = userMessage(from: payload)
            {
                meta.firstUserMessage = normalizeForeignTitle(message)
            } else if acceptsLegacyRecords,
                      obj["role"] as? String == "user",
                      let content = obj["content"] as? String
            {
                meta.firstUserMessage = normalizeForeignTitle(content)
            }
        }
        return meta
    }

    private static func userMessage(from payload: [String: Any]) -> String? {
        if payload["type"] as? String == "user_message" {
            return payload["message"] as? String
        }
        guard payload["type"] as? String == "message",
              payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]]
        else { return nil }

        guard let text = content.first(where: { item in
            guard let type = item["type"] as? String else { return false }
            return (type == "input_text" || type == "text") && item["text"] is String
        })?["text"] as? String else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<environment_context>"),
              !trimmed.hasPrefix("<user_instructions>")
        else { return nil }
        return text
    }

    static func codexSourceFromValue(_ value: Any?) -> ForeignSessionSource? {
        if let string = value as? String {
            return codexSourceFromString(string)
        }
        if let object = value as? [String: Any] {
            return codexSourceFromObject(object)
        }
        return nil
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
        if a.path.path < b.path.path { return .orderedAscending }
        if a.path.path > b.path.path { return .orderedDescending }
        return .orderedSame
    }
}
