// ClaudeSessionScanner.swift
//
// Read-only scanner for Claude Code sessions stored as JSONL in
// `~/.claude/projects/<sanitized-workspace-path>/`.
//
// Rust reference (`~/Projects/grok-build` commit 00e176c8):
//   * `xai-grok-foreign-sessions/src/claude/projects.rs:6-50` — bounded
//     current-checkout/repository/worktree project derivation.
//   * `xai-grok-foreign-sessions/src/capability/unix.rs:7-43` — no-follow,
//     descriptor-relative directory and transcript access.
//   * `xai-grok-foreign-sessions/src/claude.rs:274-373` — bounded candidate
//     qualification and head/tail transcript reads.
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
    static let maxProjectDirs = 16
    static let maxSanitizedPathBytes = 200
    static let maxJSONLineBytes = 256 * 1024
    static let maxJSONLines = 4_096
    private static let maxGitMetadataBytes = 16 * 1024
    private static let maxGitWorktreeEntries = 256

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
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ForeignSessionSummary] {
        guard let configDir = resolveConfigDir(configDir, environment: environment),
              let approvedRoot = ForeignSessionApprovedRoot(configDir)
        else {
            return []
        }
        let projectDirs = scopedProjectDirs(configDir: approvedRoot.url, cwd: requestedCwd)
        let candidates = collectCandidates(
            root: approvedRoot,
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
        if let envPath = environment["CLAUDE_CONFIG_DIR"], !envPath.isEmpty {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }
        guard let home = environment["HOME"], !home.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
    }

    // MARK: - Project directory scoping

    /// Never enumerate `projects`: only Git-related paths can authorize a
    /// project directory, and every subsequent component is opened no-follow.
    static func scopedProjectDirs(configDir: URL, cwd: String) -> [URL] {
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        var seenPaths = Set<String>()
        var seenDirectories = Set<String>()
        var directories: [URL] = []

        for workspace in scopedWorkspacePaths(cwd: cwd) {
            guard seenPaths.insert(workspace.path).inserted,
                  directories.count < maxProjectDirs,
                  let sanitized = sanitizedProjectPath(workspace.path),
                  seenDirectories.insert(sanitized).inserted
            else { continue }
            directories.append(
                projectsDir.appendingPathComponent(sanitized, isDirectory: true)
            )
        }
        return directories
    }

    static func sanitizedProjectPath(_ path: String) -> String? {
        var sanitized = String()
        sanitized.reserveCapacity(maxSanitizedPathBytes)
        for scalar in path.unicodeScalars {
            let value = scalar.value
            if (48...57).contains(value)
                || (65...90).contains(value)
                || (97...122).contains(value)
            {
                sanitized.unicodeScalars.append(scalar)
            } else {
                sanitized.append("-")
            }
            if sanitized.utf8.count > maxSanitizedPathBytes { return nil }
        }
        return sanitized.isEmpty ? nil : sanitized
    }

    private struct GitTopology {
        let checkout: URL
        let gitDirectory: ForeignSessionApprovedRoot
        let commonDirectory: ForeignSessionApprovedRoot
    }

    private static func scopedWorkspacePaths(cwd: String) -> [URL] {
        let requested = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        var paths: [URL] = []
        var seen = Set<String>()

        func include(_ path: URL) {
            guard paths.count < maxProjectDirs, seen.insert(path.path).inserted else { return }
            paths.append(path)
        }

        include(requested)
        include(canonical)

        guard let topology = discoverGitTopology(startingAt: canonical) else {
            return paths
        }
        include(topology.checkout)

        if topology.gitDirectory.url.path != topology.commonDirectory.url.path {
            let mainCheckout = topology.commonDirectory.url.deletingLastPathComponent()
                .standardizedFileURL
            if gitDirectory(for: mainCheckout)?.url.path == topology.commonDirectory.url.path {
                include(mainCheckout)
            }
        }

        let worktrees = topology.commonDirectory.url
            .appendingPathComponent("worktrees", isDirectory: true)
        guard let approvedWorktrees = topology.commonDirectory.subroot(worktrees) else {
            return Array(paths.prefix(maxProjectDirs))
        }

        var registrations: [String] = []
        approvedWorktrees.visitEntries(maximum: maxGitWorktreeEntries) {
            registrations.append($0)
        }

        for registration in registrations.sorted().prefix(maxProjectDirs) {
            guard paths.count < maxProjectDirs else { break }
            let directory = approvedWorktrees.url.appendingPathComponent(
                registration,
                isDirectory: true
            )
            guard let registeredRoot = approvedWorktrees.subroot(directory),
                  let gitdir = readGitMetadata(named: "gitdir", under: registeredRoot),
                  let gitFile = resolveGitPath(gitdir, relativeTo: registeredRoot.url)
            else { continue }

            let checkout = gitFile.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
            guard gitDirectory(for: checkout)?.url.path == registeredRoot.url.path else {
                continue
            }
            include(checkout)
        }
        return paths
    }

    private static func discoverGitTopology(startingAt directory: URL) -> GitTopology? {
        var checkout = directory
        while true {
            if let gitDirectory = gitDirectory(for: checkout) {
                let commonDirectory: ForeignSessionApprovedRoot
                if let commonPath = readGitMetadata(named: "commondir", under: gitDirectory),
                   let resolved = resolveGitPath(commonPath, relativeTo: gitDirectory.url),
                   let approved = ForeignSessionApprovedRoot(resolved)
                {
                    commonDirectory = approved
                } else {
                    commonDirectory = gitDirectory
                }
                return GitTopology(
                    checkout: checkout.resolvingSymlinksInPath().standardizedFileURL,
                    gitDirectory: gitDirectory,
                    commonDirectory: commonDirectory
                )
            }

            let parent = checkout.deletingLastPathComponent()
            guard parent.path != checkout.path else { return nil }
            checkout = parent
        }
    }

    private static func gitDirectory(for checkout: URL) -> ForeignSessionApprovedRoot? {
        guard let approvedCheckout = ForeignSessionApprovedRoot(checkout) else { return nil }
        let metadata = approvedCheckout.url.appendingPathComponent(".git")
        if let directory = approvedCheckout.subroot(metadata) { return directory }

        guard let file = approvedCheckout.openRegularFile(metadata),
              let contents = boundedGitMetadata(file),
              contents.hasPrefix("gitdir:"),
              let resolved = resolveGitPath(
                String(contents.dropFirst("gitdir:".count)),
                relativeTo: approvedCheckout.url
              )
        else { return nil }
        return ForeignSessionApprovedRoot(resolved)
    }

    private static func readGitMetadata(
        named name: String,
        under root: ForeignSessionApprovedRoot
    ) -> String? {
        let candidate = root.url.appendingPathComponent(name)
        guard let file = root.openRegularFile(candidate) else { return nil }
        return boundedGitMetadata(file)
    }

    private static func boundedGitMetadata(_ file: ForeignSessionApprovedFile) -> String? {
        guard file.size > 0,
              file.size <= UInt64(maxGitMetadataBytes),
              let contents = file.read(maximum: Int(file.size)),
              let text = String(data: contents, encoding: .utf8)
        else { return nil }
        let firstLine = text.split(whereSeparator: \.isNewline).first
        return firstLine.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func resolveGitPath(_ value: String, relativeTo base: URL) -> URL? {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, relativeTo: base)
            .absoluteURL.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: - Candidate collection

    struct Candidate {
        let file: ForeignSessionApprovedFile
        let sessionID: String

        var path: URL { file.path }
        var modified: Date { file.modified }
        var size: UInt64 { file.size }
    }

    static func collectCandidates(
        root: ForeignSessionApprovedRoot,
        projectDirs: [URL],
        now: Date,
        maxAge: TimeInterval,
        limit: Int
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for projectDir in projectDirs.prefix(maxProjectDirs) {
            guard let projectRoot = root.subroot(projectDir) else { continue }
            var projectCandidates: [Candidate] = []
            let complete = projectRoot.visitEntries { name in
                let entry = projectRoot.url.appendingPathComponent(name)
                guard entry.pathExtension == "jsonl" else { return }
                let stem = entry.deletingPathExtension().lastPathComponent
                guard isValidUUID(stem) else { return }
                guard let file = projectRoot.openRegularFile(entry),
                      file.size > 0,
                      isForeignSessionWithin(file.modified, now: now, window: maxAge)
                else { return }
                insertSorted(
                    &projectCandidates,
                    Candidate(file: file, sessionID: stem),
                    limit: limit
                )
            }
            guard complete else { continue }
            for candidate in projectCandidates {
                insertSorted(&candidates, candidate, limit: limit)
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

        guard let storedCwd, canonicalPathsEqual(storedCwd, requestedCwd) else { return nil }

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
        guard maxSize > 0 else { return nil }
        var limit = min(readChunk, Int(maxSize))
        while true {
            guard let head = readPrefix(candidate.file, limit: limit) else { return nil }
            let cwd = firstJSONString(in: head, key: "cwd")
            if cwd != nil || limit >= Int(maxSize) {
                return (head, cwd)
            }
            limit = min(limit * 4, Int(maxSize))
        }
    }

    static func readPrefix(_ file: ForeignSessionApprovedFile, limit: Int) -> String? {
        guard limit <= maxHead, let data = file.read(maximum: limit) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func readTail(_ candidate: Candidate) -> String {
        let len = min(candidate.size, UInt64(readChunk))
        let offset = candidate.size - len
        guard let data = candidate.file.read(offset: offset, maximum: Int(len)) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - JSONL field extraction

    static func firstJSONString(in text: String, key: String) -> String? {
        for line in boundedLines(in: text) {
            if let value = jsonStringField(String(line), key: key) {
                return value
            }
        }
        return nil
    }

    static func lastJSONString(in text: String, key: String) -> String? {
        for line in boundedLines(in: text, fromEnd: true) {
            if let value = jsonStringField(String(line), key: key) {
                return value
            }
        }
        return nil
    }

    static func jsonStringField(_ line: String, key: String) -> String? {
        guard line.utf8.count <= maxJSONLineBytes,
              let data = line.data(using: .utf8),
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
        for line in boundedLines(in: head) {
            let lineStr = String(line)
            if lineStr.contains("\"tool_result\"") { continue }
            guard lineStr.utf8.count <= maxJSONLineBytes,
                  let data = lineStr.data(using: .utf8),
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

    private static func boundedLines(in text: String, fromEnd: Bool = false) -> [Substring] {
        var lines: [Substring] = []
        lines.reserveCapacity(min(maxJSONLines, 64))
        var remainder = text[...]

        while !remainder.isEmpty, lines.count < maxJSONLines {
            if fromEnd {
                if let separator = remainder.lastIndex(where: \.isNewline) {
                    let start = remainder.index(after: separator)
                    let line = remainder[start...]
                    if !line.isEmpty { lines.append(line) }
                    remainder = remainder[..<separator]
                } else {
                    lines.append(remainder)
                    break
                }
            } else if let separator = remainder.firstIndex(where: \.isNewline) {
                let line = remainder[..<separator]
                if !line.isEmpty { lines.append(line) }
                remainder = remainder[remainder.index(after: separator)...]
            } else {
                lines.append(remainder)
                break
            }
        }
        return lines
    }

    private static func canonicalPathsEqual(_ left: String, _ right: String) -> Bool {
        let canonicalLeft = URL(fileURLWithPath: left).standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalRight = URL(fileURLWithPath: right).standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL.path
        return foreignSessionPathsEqual(canonicalLeft, canonicalRight)
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
