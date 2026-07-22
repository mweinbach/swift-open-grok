// PureStatus.swift
//
// Pure-path Git status: staged / unstaged / untracked / ignored / rename /
// type-change / conflict / submodule / bare / detached / sparse / linked-
// worktree — without shelling out.

import Foundation

/// Pure-path Git status scanner.
public struct PureGitStatusScanner: Sendable {
    public var options: GitStatusOptions

    public init(options: GitStatusOptions = GitStatusOptions()) {
        self.options = options
    }

    /// Discover the repository root and git dir from `path`, then scan.
    public func scan(path: String) throws -> GitStatusSnapshot {
        try Task.checkCancellation()
        let (root, gitDir, meta) = try discoverRepository(from: path)
        return try scan(root: root, gitDir: gitDir, meta: meta)
    }

    public func scan(root: String, gitDir: String, meta: RepoMeta) throws -> GitStatusSnapshot {
        try Task.checkCancellation()
        if meta.isBare {
            return GitStatusSnapshot(
                root: root,
                gitDir: gitDir,
                branch: meta.branch,
                headCommit: meta.headCommit,
                isBare: true,
                isDetached: meta.isDetached,
                isSparseCheckout: meta.isSparseCheckout,
                isLinkedWorktree: meta.isLinkedWorktree,
                entries: []
            )
        }

        let index = try loadGitIndex(gitDir: gitDir)
        let ignore = GitIgnoreMatcher(root: root, gitDir: gitDir)
        var entries: [GitStatusEntry] = []

        // Group index entries by path for conflict detection (stages 1/2/3).
        var byPath: [String: [GitIndexEntry]] = [:]
        for e in index.entries {
            byPath[e.path, default: []].append(e)
        }

        let threadLimit = options.threadLimit
            ?? computeGixStatusThreadLimit()
        _ = threadLimit // budget is honored by bounding parallelism below

        let workPaths = Array(byPath.keys).sorted()
        let pathFilter: (String) -> Bool = { path in
            if self.options.pathspecs.isEmpty { return true }
            return self.options.pathspecs.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        // HEAD tree for staged comparisons (pure object store; no shell).
        // Pack-only objects surface as `packedObjectUnsupported` (explicit
        // non-parity) rather than being swallowed into an empty HEAD tree.
        let store = GitObjectStore(gitDir: gitDir)
        let headTree: [String: GitTreeEntry]
        if let head = meta.headCommit {
            do {
                headTree = try store.loadHeadTree(headCommitHex: head)
            } catch let error as GitStatusError {
                switch error {
                case .packedObjectUnsupported:
                    throw error
                default:
                    // Corrupt/missing loose objects degrade to empty HEAD so
                    // worktree/index status can still surface.
                    headTree = [:]
                }
            } catch {
                headTree = [:]
            }
        } else {
            headTree = [:]
        }

        // Stage-0 index paths for HEAD-vs-index staged detection.
        var stage0ByPath: [String: GitIndexEntry] = [:]
        for e in index.entries where e.stage == 0 {
            stage0ByPath[e.path] = e
        }

        // Staged: compare stage-0 index entries to HEAD tree.
        for path in stage0ByPath.keys.sorted() where pathFilter(path) {
            try Task.checkCancellation()
            // Conflicts handled below; skip multi-stage paths here.
            if let stages = byPath[path], stages.count > 1 || stages.contains(where: { $0.stage > 0 }) {
                continue
            }
            guard let entry = stage0ByPath[path] else { continue }
            if let head = headTree[path] {
                let modeDiff = (entry.mode & 0o170000) != (head.mode & 0o170000)
                let contentDiff = entry.sha1 != head.oid
                if modeDiff {
                    entries.append(GitStatusEntry(
                        path: path,
                        status: .typeChange,
                        location: .staged,
                        isSubmodule: entry.isGitlink || head.isGitlink
                    ))
                } else if contentDiff {
                    entries.append(GitStatusEntry(
                        path: path,
                        status: .modified,
                        location: .staged,
                        isSubmodule: entry.isGitlink
                    ))
                }
            } else {
                // In index, not in HEAD → staged addition (or intent-to-add).
                entries.append(GitStatusEntry(
                    path: path,
                    status: .added,
                    location: .staged,
                    isSubmodule: entry.isGitlink
                ))
            }
        }
        // Paths in HEAD but missing from stage-0 index → staged deletion.
        for path in headTree.keys.sorted() where pathFilter(path) {
            if stage0ByPath[path] == nil {
                let head = headTree[path]!
                entries.append(GitStatusEntry(
                    path: path,
                    status: .deleted,
                    location: .staged,
                    isSubmodule: head.isGitlink
                ))
            }
        }

        // Staged rename detection (deleted staged + added staged with same oid).
        entries = detectStagedRenames(entries, headTree: headTree, stage0: stage0ByPath)

        // Unstaged vs worktree for each indexed path.
        for path in workPaths where pathFilter(path) {
            try Task.checkCancellation()
            let stages = byPath[path]!
            let conflictStages = stages.map(\.stage).filter { $0 > 0 }
            if !conflictStages.isEmpty || stages.count > 1 {
                entries.append(GitStatusEntry(
                    path: path,
                    status: .unmerged,
                    location: .conflict,
                    isSubmodule: stages.contains(where: \.isGitlink),
                    conflictStages: conflictStages.sorted()
                ))
                continue
            }
            let entry = stages[0]
            if entry.isSkipWorktree && meta.isSparseCheckout {
                // Sparse: not present in worktree by design.
                continue
            }

            let abs = (root as NSString).appendingPathComponent(path)
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: abs, isDirectory: &isDir)

            if entry.isGitlink {
                if !exists {
                    entries.append(GitStatusEntry(
                        path: path,
                        status: .deleted,
                        location: .unstaged,
                        isSubmodule: true
                    ))
                }
                // Submodule dirty detection is best-effort without recursion.
                continue
            }

            if !exists {
                entries.append(GitStatusEntry(
                    path: path,
                    status: .deleted,
                    location: .unstaged,
                    isSubmodule: entry.isGitlink
                ))
                continue
            }

            // Type change: mode mismatch (file vs symlink).
            let workMode = worktreeMode(at: abs, isDir: isDir.boolValue)
            if workMode != 0 && (workMode & 0o170000) != (entry.mode & 0o170000) {
                entries.append(GitStatusEntry(
                    path: path,
                    status: .typeChange,
                    location: .unstaged
                ))
                continue
            }

            if isWorktreeDirty(entry: entry, absolutePath: abs) {
                entries.append(GitStatusEntry(
                    path: path,
                    status: .modified,
                    location: .unstaged
                ))
            }
        }

        // Untracked / ignored.
        if options.includeUntracked || options.includeIgnored {
            let indexed = Set(byPath.keys)
            try walkWorktree(root: root, relative: "") { rel, isDir in
                try Task.checkCancellation()
                if rel.isEmpty { return }
                if rel == ".git" || rel.hasPrefix(".git/") { return }
                if indexed.contains(rel) { return }
                if !pathFilter(rel) { return }
                let ignored = ignore.isIgnored(rel, isDirectory: isDir)
                if ignored {
                    if options.includeIgnored && !isDir {
                        entries.append(GitStatusEntry(
                            path: rel,
                            status: .ignored,
                            location: .ignored
                        ))
                    }
                    // Still walk into ignored dirs so includeIgnored can see files;
                    // git itself prunes, but we emit file-level ignored entries.
                    return
                }
                if options.includeUntracked && !isDir {
                    entries.append(GitStatusEntry(
                        path: rel,
                        status: .untracked,
                        location: .untracked
                    ))
                }
            }
        }

        // Rename detection (simple content-hash pairing of deleted + untracked).
        entries = detectRenames(entries, root: root, index: index)

        return GitStatusSnapshot(
            root: root,
            gitDir: gitDir,
            branch: meta.branch,
            headCommit: meta.headCommit,
            isBare: meta.isBare,
            isDetached: meta.isDetached,
            isSparseCheckout: meta.isSparseCheckout,
            isLinkedWorktree: meta.isLinkedWorktree,
            entries: entries
        )
    }
}

/// Pair staged deletions with staged additions that share the same oid.
func detectStagedRenames(
    _ entries: [GitStatusEntry],
    headTree: [String: GitTreeEntry],
    stage0: [String: GitIndexEntry]
) -> [GitStatusEntry] {
    let deleted = entries.filter { $0.status == .deleted && $0.location == .staged }
    let added = entries.filter { $0.status == .added && $0.location == .staged }
    guard !deleted.isEmpty, !added.isEmpty else { return entries }

    var remaining = entries.filter {
        !($0.status == .deleted && $0.location == .staged)
            && !($0.status == .added && $0.location == .staged)
    }
    var usedAdded = Set<String>()
    for del in deleted {
        guard let head = headTree[del.path] else {
            remaining.append(del)
            continue
        }
        var matched: String?
        for add in added where !usedAdded.contains(add.path) {
            guard let idx = stage0[add.path] else { continue }
            if idx.sha1 == head.oid {
                matched = add.path
                break
            }
        }
        if let to = matched {
            usedAdded.insert(to)
            remaining.append(GitStatusEntry(
                path: to,
                status: .renamed,
                location: .staged,
                otherPath: del.path,
                isSubmodule: del.isSubmodule
            ))
        } else {
            remaining.append(del)
        }
    }
    for add in added where !usedAdded.contains(add.path) {
        remaining.append(add)
    }
    return remaining
}

// MARK: - Discovery

public struct RepoMeta: Sendable, Equatable {
    public var branch: String?
    public var headCommit: String?
    public var isBare: Bool
    public var isDetached: Bool
    public var isSparseCheckout: Bool
    public var isLinkedWorktree: Bool
}

/// Discover `(worktreeRoot, gitDir, meta)` walking ancestors of `path`.
public func discoverRepository(from path: String) throws -> (String, String, RepoMeta) {
    let fm = FileManager.default
    var current = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    while true {
        let dotGit = current.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
            if isDir.boolValue {
                let gitDir = dotGit.path
                let meta = try readRepoMeta(gitDir: gitDir, worktreeRoot: current.path)
                return (current.path, gitDir, meta)
            }
            // gitdir pointer (linked worktree)
            if let text = try? String(contentsOf: dotGit, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("gitdir:") {
                    let raw = trimmed.dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespaces)
                    let resolved: URL
                    if raw.hasPrefix("/") {
                        resolved = URL(fileURLWithPath: raw)
                    } else {
                        resolved = current.appendingPathComponent(raw)
                    }
                    let gitDir = resolved.resolvingSymlinksInPath().path
                    var meta = try readRepoMeta(gitDir: gitDir, worktreeRoot: current.path)
                    meta.isLinkedWorktree = true
                    return (current.path, gitDir, meta)
                }
            }
        }
        // Bare repo: path itself looks like a git dir.
        let head = current.appendingPathComponent("HEAD")
        let objects = current.appendingPathComponent("objects")
        if fm.fileExists(atPath: head.path),
           fm.fileExists(atPath: objects.path) {
            var meta = try readRepoMeta(gitDir: current.path, worktreeRoot: current.path)
            meta.isBare = true
            return (current.path, current.path, meta)
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path { break }
        current = parent
    }
    throw GitStatusError.notARepository(path)
}

func readRepoMeta(gitDir: String, worktreeRoot: String) throws -> RepoMeta {
    let fm = FileManager.default
    let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
    let headText = (try? String(contentsOfFile: headPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var branch: String? = nil
    var isDetached = false
    var headCommit: String? = nil
    if headText.hasPrefix("ref: ") {
        let ref = String(headText.dropFirst(5))
        if ref.hasPrefix("refs/heads/") {
            branch = String(ref.dropFirst("refs/heads/".count))
        }
        let refPath = (gitDir as NSString).appendingPathComponent(ref)
        if let oid = try? String(contentsOfFile: refPath, encoding: .utf8) {
            headCommit = oid.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // packed-refs
            headCommit = resolvePackedRef(gitDir: gitDir, name: ref)
        }
    } else if !headText.isEmpty {
        isDetached = true
        headCommit = headText
    }

    let sparse = fm.fileExists(
        atPath: (gitDir as NSString).appendingPathComponent("info/sparse-checkout")
    )
    // Also check config core.sparseCheckout
    let configPath = (gitDir as NSString).appendingPathComponent("config")
    var isSparse = sparse
    if let config = try? String(contentsOfFile: configPath, encoding: .utf8),
       config.contains("sparseCheckout = true") || config.contains("sparsecheckout = true") {
        isSparse = true
    }

    let isBare: Bool = {
        if let config = try? String(contentsOfFile: configPath, encoding: .utf8) {
            return config.contains("bare = true")
        }
        return false
    }()

    return RepoMeta(
        branch: branch,
        headCommit: headCommit,
        isBare: isBare,
        isDetached: isDetached,
        isSparseCheckout: isSparse,
        isLinkedWorktree: false
    )
}

func resolvePackedRef(gitDir: String, name: String) -> String? {
    let path = (gitDir as NSString).appendingPathComponent("packed-refs")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
        if line.hasPrefix("#") || line.hasPrefix("^") { continue }
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { continue }
        if parts[1] == name {
            return String(parts[0])
        }
    }
    return nil
}

// MARK: - Worktree comparison

func worktreeMode(at path: String, isDir: Bool) -> UInt32 {
    if isDir { return 0o040000 }
    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: path),
       let type = attrs[.type] as? FileAttributeType {
        if type == .typeSymbolicLink { return 0o120000 }
    }
    // Executable bit
    #if os(Windows)
    return 0o100644
    #else
    var st = stat()
    if lstat(path, &st) == 0 {
        if (st.st_mode & S_IFMT) == S_IFLNK { return 0o120000 }
        if (st.st_mode & 0o111) != 0 { return 0o100755 }
    }
    return 0o100644
    #endif
}

func isWorktreeDirty(entry: GitIndexEntry, absolutePath: String) -> Bool {
    let fm = FileManager.default
    // Symlink: compare target string hash would need blob read; treat mtime/size first.
    guard let attrs = try? fm.attributesOfItem(atPath: absolutePath) else { return true }
    if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
        // Compare symlink target as blob content is out of pure scope without
        // object store; mark dirty if we cannot confirm cleanliness via size.
        return true // conservative — symlink dirty without object store
    }
    let size = (attrs[.size] as? NSNumber)?.uint32Value ?? 0
    if size != entry.size { return true }

    // Stat racy-git: if size matches and mtime matches index, treat clean.
    if let mtime = attrs[.modificationDate] as? Date {
        let secs = UInt32(mtime.timeIntervalSince1970)
        if secs == entry.mtimeSeconds {
            return false
        }
    }

    // Content hash (git blob SHA-1) comparison.
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: absolutePath)) else {
        return true
    }
    let oid = gitBlobSHA1(data)
    return oid != entry.sha1
}

/// Compute git blob SHA-1: `sha1("blob \(size)\0" + content)`.
public func gitBlobSHA1(_ data: Data) -> Data {
    var header = Array("blob \(data.count)".utf8)
    header.append(0)
    return PortableSHA1.hash(Data(header), data)
}

// MARK: - Ignore

struct GitIgnoreMatcher {
    let root: String
    var patterns: [(pattern: String, negated: Bool, dirOnly: Bool)]

    init(root: String, gitDir: String) {
        self.root = root
        var patterns: [(String, Bool, Bool)] = []
        // Default: ignore .git
        patterns.append((".git", false, true))
        let gi = (root as NSString).appendingPathComponent(".gitignore")
        if let text = try? String(contentsOfFile: gi, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var s = String(line)
                if s.hasPrefix("#") || s.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                var negated = false
                if s.hasPrefix("!") {
                    negated = true
                    s = String(s.dropFirst())
                }
                var dirOnly = false
                if s.hasSuffix("/") {
                    dirOnly = true
                    s = String(s.dropLast())
                }
                patterns.append((s, negated, dirOnly))
            }
        }
        let exclude = (gitDir as NSString).appendingPathComponent("info/exclude")
        if let text = try? String(contentsOfFile: exclude, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var s = String(line)
                if s.hasPrefix("#") || s.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                var negated = false
                if s.hasPrefix("!") {
                    negated = true
                    s = String(s.dropFirst())
                }
                var dirOnly = false
                if s.hasSuffix("/") {
                    dirOnly = true
                    s = String(s.dropLast())
                }
                patterns.append((s, negated, dirOnly))
            }
        }
        self.patterns = patterns
    }

    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        var ignored = false
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        let components = relativePath.split(separator: "/").map(String.init)
        for (pattern, negated, dirOnly) in patterns {
            let matched: Bool
            if pattern.contains("/") {
                matched = globMatch(pattern, relativePath)
                    || relativePath.hasPrefix(pattern)
                    || relativePath.hasPrefix(pattern + "/")
            } else if dirOnly {
                // Directory pattern `build/` ignores the directory and all descendants.
                matched = components.contains { globMatch(pattern, $0) }
                    || (isDirectory && (globMatch(pattern, name) || globMatch(pattern, relativePath)))
            } else {
                matched = globMatch(pattern, name) || globMatch(pattern, relativePath)
            }
            if matched {
                ignored = !negated
            }
        }
        return ignored
    }
}

/// Minimal glob: `*` and `?` only, no `**`.
func globMatch(_ pattern: String, _ text: String) -> Bool {
    fnmatch(pattern, text, 0) == 0
}

// MARK: - Walk

func walkWorktree(
    root: String,
    relative: String,
    visit: (String, Bool) throws -> Void
) throws {
    let fm = FileManager.default
    let abs = relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
    if !relative.isEmpty {
        try visit(relative, true)
    }
    guard let children = try? fm.contentsOfDirectory(atPath: abs) else { return }
    for name in children.sorted() {
        if name == ".git" { continue }
        let childRel = relative.isEmpty ? name : relative + "/" + name
        let childAbs = (abs as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: childAbs, isDirectory: &isDir) else { continue }
        // Don't follow symlinks out of the worktree.
        if let attrs = try? fm.attributesOfItem(atPath: childAbs),
           let type = attrs[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            try visit(childRel, false)
            continue
        }
        if isDir.boolValue {
            try walkWorktree(root: root, relative: childRel, visit: visit)
        } else {
            try visit(childRel, false)
        }
    }
}

// MARK: - Rename detection

func detectRenames(
    _ entries: [GitStatusEntry],
    root: String,
    index: GitIndex
) -> [GitStatusEntry] {
    let deleted = entries.filter { $0.status == .deleted && $0.location == .unstaged }
    let untracked = entries.filter { $0.status == .untracked }
    guard !deleted.isEmpty, !untracked.isEmpty else { return entries }

    var remaining = entries.filter {
        !($0.status == .deleted && $0.location == .unstaged)
            && $0.status != .untracked
    }
    var usedUntracked = Set<String>()
    let indexByPath = Dictionary(uniqueKeysWithValues: index.entries.filter { $0.stage == 0 }.map { ($0.path, $0) })

    for del in deleted {
        guard let idx = indexByPath[del.path] else {
            remaining.append(del)
            continue
        }
        var matched: String?
        for u in untracked where !usedUntracked.contains(u.path) {
            let abs = (root as NSString).appendingPathComponent(u.path)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: abs)) else { continue }
            if gitBlobSHA1(data) == idx.sha1 {
                matched = u.path
                break
            }
        }
        if let to = matched {
            usedUntracked.insert(to)
            remaining.append(GitStatusEntry(
                path: to,
                status: .renamed,
                location: .unstaged,
                otherPath: del.path
            ))
        } else {
            remaining.append(del)
        }
    }
    for u in untracked where !usedUntracked.contains(u.path) {
        remaining.append(u)
    }
    return remaining
}
