// FuzzyFileMatcher.swift
//
// Background directory tree indexer and fuzzy file search daemon for OpenGrokWorkspace.
//
// Ports directory traversal, gitignore filtering, hidden file handling, and background
// search query resolution matching `xai-fuzzy-file-search`.

import Foundation

/// Results returned by `FuzzyFileMatcherDaemon.query(...)`.
public struct FuzzyMatcherDaemonResults: Sendable, Equatable, Codable, Hashable {
    /// Top-K highest scoring matches.
    public var topk: [FuzzyMatchResult]
    /// Total number of matches across the indexed tree.
    public var totalMatches: Int
    /// Generation number of the matcher index.
    public var generation: Int

    public init(
        topk: [FuzzyMatchResult] = [],
        totalMatches: Int = 0,
        generation: Int = 0
    ) {
        self.topk = topk
        self.totalMatches = totalMatches
        self.generation = generation
    }
}

/// An entry indexed in the workspace directory tree.
public struct IndexedEntry: Sendable, Equatable, Hashable, Codable {
    /// Relative path from the workspace root.
    public var relativePath: String
    /// Whether this entry is a directory.
    public var isDir: Bool
    /// Basename / filename of the entry.
    public var name: String

    public init(relativePath: String, isDir: Bool, name: String? = nil) {
        self.relativePath = relativePath
        self.isDir = isDir
        if let name {
            self.name = name
        } else {
            self.name = (relativePath as NSString).lastPathComponent
        }
    }
}

/// Rule for ignoring files/directories based on `.gitignore` format.
public struct GitIgnoreRule: Sendable, Equatable {
    public let rawPattern: String
    public let scopePrefix: String
    public let negated: Bool
    public let dirOnly: Bool
    public let regex: NSRegularExpression?

    public init(rawPattern: String, scopePrefix: String = "", negated: Bool = false, dirOnly: Bool = false) {
        self.rawPattern = rawPattern
        self.scopePrefix = scopePrefix
        self.negated = negated
        self.dirOnly = dirOnly
        self.regex = GitIgnoreRule.compileRegex(pattern: rawPattern, scopePrefix: scopePrefix, dirOnly: dirOnly)
    }

    public static func parse(content: String, scope: String = "") -> [GitIgnoreRule] {
        var rules: [GitIgnoreRule] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for lineSub in lines {
            var line = String(lineSub).trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line.removeFirst()
            }
            var dirOnly = false
            if line.hasSuffix("/") {
                dirOnly = true
                line.removeLast()
            }
            if line.isEmpty { continue }
            rules.append(GitIgnoreRule(rawPattern: line, scopePrefix: scope, negated: negated, dirOnly: dirOnly))
        }
        return rules
    }

    private static func compileRegex(pattern: String, scopePrefix: String, dirOnly: Bool) -> NSRegularExpression? {
        var p = pattern
        let leadingSlash = p.hasPrefix("/")
        if leadingSlash { p.removeFirst() }

        let containsSlash = p.contains("/")
        let scopeRegex = scopePrefix.isEmpty ? "" : NSRegularExpression.escapedPattern(for: scopePrefix)

        var regexStr = ""
        var i = p.startIndex
        while i < p.endIndex {
            let c = p[i]
            if c == "*" {
                let next = p.index(after: i)
                if next < p.endIndex && p[next] == "*" {
                    let afterNext = p.index(after: next)
                    if afterNext < p.endIndex && p[afterNext] == "/" {
                        regexStr.append("(?:.*/)?")
                        i = p.index(after: afterNext)
                        continue
                    } else {
                        regexStr.append(".*")
                        i = afterNext
                        continue
                    }
                } else {
                    regexStr.append("[^/]*")
                    i = next
                    continue
                }
            } else if c == "?" {
                regexStr.append("[^/]")
            } else if c == "." || c == "(" || c == ")" || c == "[" || c == "]" || c == "{" || c == "}" || c == "+" || c == "^" || c == "$" || c == "|" || c == "\\" {
                regexStr.append("\\\(c)")
            } else {
                regexStr.append(c)
            }
            i = p.index(after: i)
        }

        let fullPattern: String
        if !containsSlash && !leadingSlash {
            fullPattern = "^\(scopeRegex)(?:.*/)?\(regexStr)(?:/.*)?$"
        } else {
            fullPattern = "^\(scopeRegex)\(regexStr)(?:/.*)?$"
        }

        return try? NSRegularExpression(pattern: fullPattern, options: [])
    }

    public func matches(path: String, isDir: Bool) -> Bool {
        if dirOnly && !isDir {
            return false
        }
        guard let regex else { return false }
        let range = NSRange(location: 0, length: (path as NSString).length)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    public static func isIgnored(path: String, isDir: Bool, rules: [GitIgnoreRule]) -> Bool {
        var ignored = false
        for rule in rules {
            if rule.matches(path: path, isDir: isDir) {
                ignored = !rule.negated
            }
        }
        return ignored
    }
}

/// Directory tree walker respecting `.gitignore` and hidden file options.
public struct FuzzyFileTreeWalker: Sendable {
    public static func walk(
        root: URL,
        hidden: Bool = false,
        respectGitignore: Bool = true
    ) -> [IndexedEntry] {
        var entries: [IndexedEntry] = []
        let fileManager = FileManager.default
        let rootPath = root.standardizedFileURL.path

        var rootGitIgnoreRules: [GitIgnoreRule] = []
        if respectGitignore {
            let rootGitIgnoreURL = root.appendingPathComponent(".gitignore")
            if let content = try? String(contentsOf: rootGitIgnoreURL, encoding: .utf8) {
                rootGitIgnoreRules = GitIgnoreRule.parse(content: content, scope: "")
            }
        }

        func recurse(currentDirURL: URL, currentRules: [GitIgnoreRule]) {
            guard let dirContents = try? fileManager.contentsOfDirectory(
                at: currentDirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ) else {
                return
            }

            var localRules = currentRules
            if respectGitignore && currentDirURL != root {
                let localGitIgnoreURL = currentDirURL.appendingPathComponent(".gitignore")
                if let content = try? String(contentsOf: localGitIgnoreURL, encoding: .utf8) {
                    let relativeDirPath: String
                    let currPath = currentDirURL.standardizedFileURL.path
                    if currPath.hasPrefix(rootPath) {
                        var rel = String(currPath.dropFirst(rootPath.count))
                        while rel.hasPrefix("/") { rel.removeFirst() }
                        relativeDirPath = rel.isEmpty ? "" : rel + "/"
                    } else {
                        relativeDirPath = ""
                    }
                    let newRules = GitIgnoreRule.parse(content: content, scope: relativeDirPath)
                    localRules.append(contentsOf: newRules)
                }
            }

            let sortedContents = dirContents.sorted { $0.lastPathComponent < $1.lastPathComponent }

            for fileURL in sortedContents {
                let name = fileURL.lastPathComponent
                if name == ".git" {
                    continue
                }
                if !hidden && name.hasPrefix(".") {
                    continue
                }

                let fullPath = fileURL.standardizedFileURL.path
                guard fullPath.hasPrefix(rootPath) else { continue }
                var relPath = String(fullPath.dropFirst(rootPath.count))
                while relPath.hasPrefix("/") { relPath.removeFirst() }
                if relPath.isEmpty { continue }

                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

                if respectGitignore && GitIgnoreRule.isIgnored(path: relPath, isDir: isDir, rules: localRules) {
                    continue
                }

                entries.append(IndexedEntry(relativePath: relPath, isDir: isDir, name: name))

                if isDir {
                    recurse(currentDirURL: fileURL, currentRules: localRules)
                }
            }
        }

        recurse(currentDirURL: root, currentRules: rootGitIgnoreRules)
        return entries
    }
}

/// Actor managing background directory indexing and serving fuzzy queries.
public actor FuzzyFileMatcherDaemon {
    public let root: URL
    public let maxTopK: Int
    public private(set) var generation: Int
    private var indexedEntries: [IndexedEntry]
    private var isIndexed: Bool
    private var matcher: FuzzyMatcher

    public init(
        root: URL,
        maxTopK: Int = 100,
        caseSensitive: Bool = false
    ) {
        self.root = root
        self.maxTopK = maxTopK
        self.generation = 0
        self.indexedEntries = []
        self.isIndexed = false
        self.matcher = FuzzyMatcher(caseSensitive: caseSensitive)
    }

    /// Explicitly override indexed entries (e.g. for testing or memory-backed mock trees).
    public func setEntries(_ entries: [IndexedEntry]) {
        self.indexedEntries = entries
        self.isIndexed = true
        self.generation += 1
    }

    /// Re-index the directory tree.
    public func restartWalk(
        hidden: Bool = false,
        respectGitignore: Bool = true
    ) {
        self.indexedEntries = FuzzyFileTreeWalker.walk(
            root: root,
            hidden: hidden,
            respectGitignore: respectGitignore
        )
        self.isIndexed = true
        self.generation += 1
    }

    /// Asynchronously query the indexed directory tree.
    public func query(
        _ query: String,
        isDir: Bool = false,
        hidden: Bool = false
    ) async -> FuzzyMatcherDaemonResults {
        if !isIndexed {
            restartWalk(hidden: hidden, respectGitignore: true)
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let filteredEntries = indexedEntries.filter { entry in
            if !hidden {
                let components = entry.relativePath.split(separator: "/")
                if components.contains(where: { $0.hasPrefix(".") }) {
                    return false
                }
            }
            if isDir && !entry.isDir {
                return false
            }
            return true
        }

        if trimmed.isEmpty {
            let topEntries = filteredEntries.prefix(maxTopK).map { entry in
                FuzzyMatchResult(
                    path: entry.relativePath,
                    score: 0,
                    indices: [],
                    isDir: entry.isDir,
                    name: entry.name
                )
            }
            return FuzzyMatcherDaemonResults(
                topk: Array(topEntries),
                totalMatches: filteredEntries.count,
                generation: generation
            )
        }

        var matches: [FuzzyMatchResult] = []
        for entry in filteredEntries {
            if let result = matcher.match(pattern: trimmed, candidate: entry.relativePath, isDir: entry.isDir) {
                matches.append(result)
            }
        }

        matches.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.path.count != rhs.path.count {
                return lhs.path.count < rhs.path.count
            }
            return lhs.path < rhs.path
        }

        let topk = Array(matches.prefix(maxTopK))
        return FuzzyMatcherDaemonResults(
            topk: topk,
            totalMatches: matches.count,
            generation: generation
        )
    }
}

/// Synchronous file matcher holding a snapshot of indexed paths.
public struct FuzzyFileMatcher: Sendable {
    public let root: URL
    public var entries: [IndexedEntry]
    public var matcher: FuzzyMatcher

    public init(
        root: URL,
        entries: [IndexedEntry] = [],
        matcher: FuzzyMatcher = FuzzyMatcher()
    ) {
        self.root = root
        self.entries = entries
        self.matcher = matcher
    }

    public mutating func restartWalk(
        hidden: Bool = false,
        respectGitignore: Bool = true
    ) {
        self.entries = FuzzyFileTreeWalker.walk(
            root: root,
            hidden: hidden,
            respectGitignore: respectGitignore
        )
    }

    public func query(
        _ query: String,
        isDir: Bool = false,
        hidden: Bool = false,
        topK: Int = 100
    ) -> (results: [FuzzyMatchResult], totalMatches: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            if !hidden {
                let components = entry.relativePath.split(separator: "/")
                if components.contains(where: { $0.hasPrefix(".") }) { return false }
            }
            if isDir && !entry.isDir { return false }
            return true
        }

        if trimmed.isEmpty {
            let res = filtered.prefix(topK).map {
                FuzzyMatchResult(path: $0.relativePath, score: 0, indices: [], isDir: $0.isDir, name: $0.name)
            }
            return (Array(res), filtered.count)
        }

        var matches: [FuzzyMatchResult] = []
        for entry in filtered {
            if let m = matcher.match(pattern: trimmed, candidate: entry.relativePath, isDir: entry.isDir) {
                matches.append(m)
            }
        }
        matches.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
        return (Array(matches.prefix(topK)), matches.count)
    }
}
