import Foundation
import OpenGrokFastWorktree

/// Foundation resolves a nonexistent descendant of `/var` inconsistently with
/// its existing `/private/var` ancestor. Resolve only the deepest existing
/// entry, then reconstruct missing components in that same physical namespace.
enum LiveSubagentCanonicalPath {
    static func resolve(_ url: URL) -> URL {
        let files = FileManager.default
        var existing = url.standardizedFileURL
        var unresolved: [String] = []

        while !files.fileExists(atPath: existing.path),
              (try? files.destinationOfSymbolicLink(atPath: existing.path)) == nil {
            let parent = existing.deletingLastPathComponent()
            guard parent != existing else { break }
            unresolved.append(existing.lastPathComponent)
            existing = parent
        }

        var canonical = existing.resolvingSymlinksInPath()
        let components = unresolved.reversed()
        for (index, component) in components.enumerated() {
            canonical.appendPathComponent(
                component,
                isDirectory: index < unresolved.count - 1 || url.hasDirectoryPath
            )
        }
        return canonical
    }
}

/// A real detached Git worktree backing one explicitly isolated subagent.
///
/// Rust derives `$OPENGROK_HOME/worktrees/<repo-slug>/subagent-<id>` in
/// `xai-grok-workspace/src/worktree/mod.rs:731-745,784-818` and creates it
/// with `PreserveWorkingTree` in
/// `xai-grok-shell/src/agent/subagent/handle_request.rs:439-476`.
struct LiveSubagentWorktree: Sendable {
    let path: URL
    let sourceRepository: URL

    enum Failure: Error, Sendable, CustomStringConvertible {
        case invalidChildID(String)
        case bareRepository(String)
        case destinationInsideParent(String)
        case managedRootEscapesHome(String)
        case invalidWorktree(String)
        case removalFailed(String)

        var description: String {
            switch self {
            case .invalidChildID(let value):
                return "invalid subagent worktree identifier: \(value)"
            case .bareRepository(let path):
                return "worktree isolation requires a non-bare git repository: \(path)"
            case .destinationInsideParent(let path):
                return "isolated worktree would be created inside the parent workspace: \(path)"
            case .managedRootEscapesHome(let path):
                return "managed worktree root escapes OPENGROK_HOME: \(path)"
            case .invalidWorktree(let path):
                return "isolated worktree is not linked to its parent repository: \(path)"
            case .removalFailed(let detail):
                return "could not remove an unregistered subagent worktree: \(detail)"
            }
        }
    }

    /// Git discovery, copy, and process waits run off the host actor. Cancellation
    /// reaches the builder between its guarded phases so partial trees are reclaimed.
    static func prepare(
        sourceDirectory: URL,
        openGrokHome: URL,
        childID: String
    ) async throws -> LiveSubagentWorktree {
        let operation = Task.detached(priority: .utility) {
            try create(
                sourceDirectory: sourceDirectory,
                openGrokHome: openGrokHome,
                childID: childID
            )
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Registration failed after materialization; a child never owned this tree,
    /// so it must not survive as an apparently resumable subagent workspace.
    func discard() async throws {
        let source = sourceRepository
        let destination = path
        let operation = Task.detached(priority: .utility) {
            let report = try worktreeRemove(source: source, dest: destination, force: true)
            guard report.removed, report.issues.isEmpty else {
                throw Failure.removalFailed(report.issues.joined(separator: "; "))
            }
        }
        try await operation.value
    }

    static func resume(
        _ recorded: URL,
        sourceDirectory: URL,
        openGrokHome: URL
    ) async throws -> URL {
        let operation = Task.detached(priority: .utility) {
            try validateReuse(
                recorded,
                sourceDirectory: sourceDirectory,
                openGrokHome: openGrokHome
            )
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    /// Existing managed worktrees must remain within the managed root, stay
    /// distinct from the parent checkout, and resolve to the same Git common dir.
    static func validateReuse(
        _ recorded: URL,
        sourceDirectory: URL,
        openGrokHome: URL
    ) throws -> URL {
        let sourceIdentity = try discoverGitRepo(at: sourceDirectory)
        guard let sourceRoot = sourceIdentity.toplevel else {
            throw Failure.bareRepository(sourceDirectory.path)
        }
        let managedRoot = try managedRoot(openGrokHome: openGrokHome)
        let candidate = recorded.standardizedFileURL.resolvingSymlinksInPath()
        let safety = WorktreeSafetyPolicy(
            primaryCheckout: sourceRoot,
            allowedPoolRoot: managedRoot
        )
        try safety.validateDestination(candidate)

        let childIdentity = try discoverGitRepo(at: candidate)
        guard childIdentity.toplevel?.standardizedFileURL.resolvingSymlinksInPath() == candidate,
              childIdentity.commonDir.standardizedFileURL.resolvingSymlinksInPath()
                == sourceIdentity.commonDir.standardizedFileURL.resolvingSymlinksInPath()
        else {
            throw Failure.invalidWorktree(candidate.path)
        }
        return candidate
    }

    /// Exact Rust repo-slug semantics: last two meaningful components,
    /// ASCII-only lowercased label, collapsed hyphens, 64-character ceiling.
    static func repositorySlug(_ repositoryRoot: URL) -> String {
        let meaningful = repositoryRoot.standardizedFileURL.pathComponents.filter {
            !$0.isEmpty && $0 != "/" && $0 != "home" && $0 != "Users" && !$0.hasPrefix(".")
        }
        let raw = meaningful.suffix(2).joined(separator: "-").lowercased()
        var sanitized = ""
        var previousWasHyphen = false
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let isASCIIAlpha = (97...122).contains(value)
            let isASCIIDigit = (48...57).contains(value)
            if isASCIIAlpha || isASCIIDigit {
                sanitized.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if value == 45 || value == 32 || value == 95 {
                guard !previousWasHyphen else { continue }
                sanitized.append("-")
                previousWasHyphen = true
            }
        }
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty else { return "repo" }
        return String(trimmed.prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func create(
        sourceDirectory: URL,
        openGrokHome: URL,
        childID: String
    ) throws -> LiveSubagentWorktree {
        guard isSafeSubagentChildID(childID) else {
            throw Failure.invalidChildID(childID)
        }
        let identity = try discoverGitRepo(at: sourceDirectory)
        guard let sourceRoot = identity.toplevel else {
            throw Failure.bareRepository(sourceDirectory.path)
        }
        let root = try managedRoot(openGrokHome: openGrokHome)
        let source = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let sourceComponents = source.pathComponents
        let repositoryComponent: String
        if sourceComponents.starts(with: rootComponents),
           sourceComponents.count > rootComponents.count {
            repositoryComponent = sourceComponents[rootComponents.count]
        } else {
            repositoryComponent = repositorySlug(sourceRoot)
        }
        let destination = root
            .appendingPathComponent(repositoryComponent, isDirectory: true)
            .appendingPathComponent("subagent-\(childID)", isDirectory: true)
            .standardizedFileURL
        let canonicalParent = sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
        if destination == canonicalParent
            || destination.path.hasPrefix(canonicalParent.path + "/") {
            throw Failure.destinationInsideParent(destination.path)
        }

        let report = try WorktreeBuilder(
            source: source,
            dest: destination,
            gitRef: "HEAD",
            workingTree: .preserveWorkingTree,
            ignoredFiles: .skip,
            creationMode: .linked,
            allowedPoolRoot: root
        ).create(isCancelled: { Task.isCancelled })

        let worktree = LiveSubagentWorktree(
            path: report.worktreePath.standardizedFileURL,
            sourceRepository: sourceRoot.standardizedFileURL
        )
        do {
            let validated = try validateReuse(
                worktree.path,
                sourceDirectory: source,
                openGrokHome: openGrokHome
            )
            guard validated == worktree.path.resolvingSymlinksInPath() else {
                throw Failure.invalidWorktree(worktree.path.path)
            }
            return worktree
        } catch {
            do {
                let removed = try worktreeRemove(
                    source: sourceRoot,
                    dest: worktree.path,
                    force: true
                )
                guard removed.removed else {
                    throw Failure.removalFailed(removed.issues.joined(separator: "; "))
                }
            } catch let cleanupError {
                throw Failure.removalFailed("\(error); cleanup: \(cleanupError)")
            }
            throw error
        }
    }

    private static func managedRoot(openGrokHome: URL) throws -> URL {
        let home = LiveSubagentCanonicalPath.resolve(openGrokHome)
        let expected = home.appendingPathComponent("worktrees", isDirectory: true)
        let resolved = LiveSubagentCanonicalPath.resolve(expected)
        guard resolved == expected else {
            throw Failure.managedRootEscapesHome(expected.path)
        }
        return expected
    }
}
