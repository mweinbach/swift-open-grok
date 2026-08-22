import Foundation
import OpenGrokPager
import OpenGrokWorkspace

/// Session-owned, bounded file-reference index for the synchronous pager seam.
///
/// Upstream retains one matcher daemon per workspace and restarts its walk only
/// when hidden mode changes. Rewalking the complete tree on every key press
/// both stalls the composer and makes ignore/symlink policy depend on timing.
final class LivePromptFileReferences: @unchecked Sendable {
    static let defaultMaximumIndexedEntries = 16_384
    static let defaultMaximumResults = 1_000
    static let maximumDepth = 64
    private static let maximumQueryBytes = 4_096
    private static let maximumIgnoreFileBytes = 1_048_576

    private let root: URL
    private let maximumIndexedEntries: Int
    private let maximumResults: Int
    private let lock = NSLock()
    private var shallowIndexes: [Bool: [IndexedEntry]] = [:]
    private var recursiveIndexes: [Bool: [IndexedEntry]] = [:]
    private var completedIndexBuilds = 0

    init(
        workingDirectory: URL,
        maximumIndexedEntries: Int = defaultMaximumIndexedEntries,
        maximumResults: Int = defaultMaximumResults
    ) {
        root = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumIndexedEntries = max(1, maximumIndexedEntries)
        self.maximumResults = max(1, min(maximumResults, Self.defaultMaximumResults))
    }

    var indexBuildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completedIndexBuilds
    }

    func invalidate() {
        lock.lock()
        shallowIndexes.removeAll()
        recursiveIndexes.removeAll()
        lock.unlock()
    }

    func suggestions(
        query: String,
        isDirectoryMode: Bool,
        hidden: Bool
    ) -> [OpenGrokPagerCommandSuggestion] {
        guard query.utf8.count <= Self.maximumQueryBytes,
              let reference = ReferenceQuery.parse(query),
              Self.isSafeRelativePath(reference.path, allowEmpty: true)
        else { return [] }

        // The upstream prompt never sets the daemon's directory-only filter:
        // a trailing slash scopes matching to that directory and must retain
        // its files (file_search/state.rs:139-149).
        _ = isDirectoryMode

        let entries = index(hidden: hidden, recursive: !reference.path.isEmpty)
        let selected: [IndexedEntry]
        if reference.path.isEmpty {
            selected = Array(entries.sorted { $0.relativePath < $1.relativePath }
                .prefix(maximumResults))
        } else {
            let smartCase = reference.path.unicodeScalars.contains {
                CharacterSet.uppercaseLetters.contains($0)
            }
            let matcher = FuzzyMatcher(caseSensitive: smartCase)
            let matches = matcher.rank(
                pattern: reference.path,
                candidates: entries.map { ($0.relativePath, $0.isDir) },
                limit: maximumResults
            )
            selected = matches.map {
                IndexedEntry(relativePath: $0.path, isDir: $0.isDir, name: $0.name)
            }
        }

        return selected.compactMap { entry in
            if entry.isDir, reference.lineSuffix != nil { return nil }
            let insertion = entry.relativePath + (reference.lineSuffix ?? "")
            return OpenGrokPagerCommandSuggestion(
                name: "@\(insertion)",
                summary: entry.isDir ? "dir" : "",
                isAvailable: true,
                insertText: insertion
            )
        }
    }

    /// Enforce the provenance normally supplied by the non-symlink workspace
    /// walker before a separately delivered line-viewer action reads a file.
    static func validatedFileURL(for path: String, workingDirectory: URL) -> URL? {
        guard isSafeRelativePath(path, allowEmpty: false) else { return nil }

        let root = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let normalized = normalizedRelativePath(path)
        let candidate = root.appendingPathComponent(normalized).standardizedFileURL
        guard isContained(candidate, in: root) else { return nil }

        var componentURL = root
        for component in normalized.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            guard let values = try? componentURL.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            ), values.isSymbolicLink != true else { return nil }
        }

        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(resolved, in: root),
              let values = try? resolved.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return nil }
        return resolved
    }

    private func index(hidden: Bool, recursive: Bool) -> [IndexedEntry] {
        lock.lock()
        defer { lock.unlock() }

        if recursive, let cached = recursiveIndexes[hidden] { return cached }
        if !recursive, let cached = shallowIndexes[hidden] { return cached }

        let entries = walk(hidden: hidden, recursive: recursive)
        if recursive {
            recursiveIndexes[hidden] = entries
        } else {
            shallowIndexes[hidden] = entries
        }
        completedIndexBuilds += 1
        return entries
    }

    private func walk(hidden: Bool, recursive: Bool) -> [IndexedEntry] {
        let propertyKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let values = try? root.resourceValues(forKeys: propertyKeys),
              values.isDirectory == true,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: Array(propertyKeys),
                  options: [],
                  errorHandler: { _, _ in true }
              )
        else { return [] }

        var entries: [IndexedEntry] = []
        var scanned = 0
        var ignoreCache: [String: [GitIgnoreRule]] = [:]
        if !hidden {
            ignoreCache[""] = rootIgnoreRules()
        }

        while let entryURL = enumerator.nextObject() as? URL {
            guard scanned < maximumIndexedEntries else { break }
            scanned += 1

            guard let relativePath = relativePath(for: entryURL),
                  !relativePath.isEmpty
            else {
                enumerator.skipDescendants()
                continue
            }

            let components = relativePath.split(separator: "/")
            guard components.count <= Self.maximumDepth else {
                enumerator.skipDescendants()
                continue
            }

            guard let resourceValues = try? entryURL.resourceValues(forKeys: propertyKeys),
                  resourceValues.isSymbolicLink != true
            else {
                continue
            }
            let isDirectory = resourceValues.isDirectory == true
            guard isDirectory || resourceValues.isRegularFile == true else { continue }

            let name = entryURL.lastPathComponent
            guard name != ".git", hidden || !name.hasPrefix(".") else {
                // Applying this to an ignore file skips its enclosing directory's remaining entries.
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            if !hidden {
                let parent = entryURL.deletingLastPathComponent()
                let rules = ignoreRules(for: parent, cache: &ignoreCache)
                if GitIgnoreRule.isIgnored(
                    path: relativePath,
                    isDir: isDirectory,
                    rules: rules
                ) {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }
            }

            entries.append(IndexedEntry(
                relativePath: relativePath,
                isDir: isDirectory,
                name: name
            ))
            if isDirectory, !recursive {
                enumerator.skipDescendants()
            }
        }
        return entries
    }

    private func rootIgnoreRules() -> [GitIgnoreRule] {
        var rules = loadIgnoreFile(
            at: root.appendingPathComponent(".git/info/exclude"),
            scope: ""
        )
        rules.append(contentsOf: directoryIgnoreRules(at: root, scope: ""))
        return rules
    }

    private func ignoreRules(
        for directory: URL,
        cache: inout [String: [GitIgnoreRule]]
    ) -> [GitIgnoreRule] {
        let key = relativePath(for: directory) ?? ""
        if let rules = cache[key] { return rules }

        let parent = directory.deletingLastPathComponent()
        var rules = ignoreRules(for: parent, cache: &cache)
        let scope = key.isEmpty ? "" : key + "/"
        rules.append(contentsOf: directoryIgnoreRules(at: directory, scope: scope))
        cache[key] = rules
        return rules
    }

    private func directoryIgnoreRules(at directory: URL, scope: String) -> [GitIgnoreRule] {
        [".gitignore", ".ignore"].flatMap { name in
            loadIgnoreFile(at: directory.appendingPathComponent(name), scope: scope)
        }
    }

    private func loadIgnoreFile(at url: URL, scope: String) -> [GitIgnoreRule] {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size <= Self.maximumIgnoreFileBytes,
            let content = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        // CRLF is one Swift Character: the workspace rule parser's literal LF
        // split would otherwise silently merge every Windows ignore rule.
        let normalized = content.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).joined(separator: "\n")
        return GitIgnoreRule.parse(content: normalized, scope: scope)
    }

    private func relativePath(for url: URL) -> String? {
        let candidate = url.standardizedFileURL
        guard Self.isContained(candidate, in: root) else { return nil }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return String(candidate.path.dropFirst(prefix.count))
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func normalizedRelativePath(_ path: String) -> String {
        var normalized = path
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        return normalized
    }

    private static func isSafeRelativePath(_ path: String, allowEmpty: Bool) -> Bool {
        guard !path.contains("\0"),
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains("\\")
        else { return false }

        let normalized = normalizedRelativePath(path)
        if normalized.isEmpty { return allowEmpty }
        if normalized.utf8.count >= 2 {
            let bytes = Array(normalized.utf8.prefix(2))
            let first = bytes[0]
            if ((65...90).contains(first) || (97...122).contains(first)), bytes[1] == 58 {
                return false
            }
        }
        return !normalized.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == ".." })
    }

    private struct ReferenceQuery {
        let path: String
        let lineSuffix: String?

        static func parse(_ query: String) -> ReferenceQuery? {
            guard let colon = query.lastIndex(of: ":") else {
                return ReferenceQuery(path: query, lineSuffix: nil)
            }
            let suffixStart = query.index(after: colon)
            let suffix = query[suffixStart...]
            guard !suffix.isEmpty else { return nil }

            let parts = suffix.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count),
                  parts.allSatisfy({ part in
                      !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
                  }),
                  let first = Int(parts[0]), first > 0,
                  parts.count == 1 || (Int(parts[1]).map { $0 >= first && $0 < Int.max } ?? false)
            else { return nil }
            let path = String(query[..<colon])
            guard !path.isEmpty else { return nil }
            return ReferenceQuery(path: path, lineSuffix: String(query[colon...]))
        }
    }
}
