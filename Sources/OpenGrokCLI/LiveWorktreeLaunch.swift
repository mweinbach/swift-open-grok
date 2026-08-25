import Foundation
import OpenGrokFastWorktree

struct LiveWorktreePreparation: Sendable {
    let sourceDirectory: URL
    let effectiveDirectory: URL
    let recordID: String
    let registry: WorktreeRegistry
}

enum LiveWorktreeLaunch {
    static func prepare(
        options: CLIExecutionOptions,
        sourceDirectory: URL,
        openGrokHome: URL,
        isCancelled: @Sendable () -> Bool
    ) throws -> LiveWorktreePreparation? {
        guard let requestedLabel = options.worktree else { return nil }
        if options.forkSession {
            throw CLIApplicationError.failed(
                "--fork-session cannot be combined with --worktree"
            )
        }
        if options.restoreCode {
            try LiveRestoreCodeLaunch.preparePrivateManagedPool(openGrokHome: openGrokHome)
        }

        let identity = try discoverGitRepo(at: sourceDirectory)
        guard let sourceRoot = identity.toplevel else {
            throw CLIApplicationError.failed("--worktree requires a non-bare git repository")
        }
        let registry = WorktreeRegistry(openGrokHome: openGrokHome)
        let repositoryName = sanitizedComponent(sourceRoot.lastPathComponent)
        let worktreeID = UUID().uuidString
        let destination = registry.poolRoot
            .appendingPathComponent("\(repositoryName)-\(worktreeID)", isDirectory: true)
        let ref = options.worktreeRef ?? "HEAD"
        let resumeSource = options.sessionToResume?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Resume forks preserve the source checkout by default. An explicit
        // ref remains a clean checkout, matching upstream's copy-mode override.
        let preservesSourceCheckout = resumeSource?.isEmpty == false
            && options.worktreeRef == nil
        let report: WorktreeReport
        do {
            report = try WorktreeBuilder(
                source: sourceDirectory,
                dest: destination,
                gitRef: ref,
                workingTree: preservesSourceCheckout ? .preserveWorkingTree : .cleanTracked,
                ignoredFiles: .skip,
                creationMode: preservesSourceCheckout ? .linked : .gitCheckout,
                allowedPoolRoot: registry.poolRoot
            ).create(isCancelled: isCancelled)
        } catch let error as FastWorktreeError {
            throw CLIApplicationError.failed("could not create worktree: \(error)")
        } catch {
            throw CLIApplicationError.failed("could not create worktree: \(error)")
        }

        let relative = relativePath(from: sourceRoot, to: sourceDirectory)
        let effectiveDirectory = relative.isEmpty
            ? destination
            : destination.appendingPathComponent(relative, isDirectory: true)
        let record = WorktreeRecord(
            id: worktreeID,
            path: destination,
            sourceRepository: sourceRoot,
            repositoryName: sourceRoot.lastPathComponent,
            kind: .launch,
            creationMode: report.creationMode,
            ref: ref,
            head: report.commit,
            label: requestedLabel.isEmpty ? nil : requestedLabel
        )
        do {
            try registry.register(record)
        } catch {
            _ = try? removeWorktreeAt(dest: destination, primaryCheckout: sourceRoot, force: true)
            throw CLIApplicationError.failed("could not register worktree: \(error)")
        }
        return LiveWorktreePreparation(
            sourceDirectory: sourceDirectory,
            effectiveDirectory: effectiveDirectory,
            recordID: record.id,
            registry: registry
        )
    }

    static func attachSession(
        _ preparation: LiveWorktreePreparation?,
        sessionID: String
    ) throws {
        guard let preparation else { return }
        do {
            try preparation.registry.updateSession(id: preparation.recordID, sessionID: sessionID)
        } catch {
            throw CLIApplicationError.failed("could not persist worktree session: \(error)")
        }
    }

    /// A session may be resumed from another checkout of its repository, but
    /// never from an unrelated repository that happens to know its session ID.
    static func validateResumeSource(
        invocationDirectory: URL,
        sourceDirectory: URL
    ) throws {
        let invocation: GitRepoIdentity
        let source: GitRepoIdentity
        do {
            invocation = try discoverGitRepo(at: invocationDirectory)
            source = try discoverGitRepo(at: sourceDirectory)
        } catch {
            throw CLIApplicationError.failed(
                "cannot resume a session in a worktree: the invoking workspace and "
                    + "source session must belong to the same git repository (\(error))"
            )
        }

        guard invocation.toplevel != nil,
              source.toplevel != nil,
              LiveToolExecutor.workspaceRootsMatch(invocation.commonDir, source.commonDir)
        else {
            throw CLIApplicationError.failed(
                "cannot resume a session from workspace \(sourceDirectory.path) in "
                    + "the unrelated git repository \(invocationDirectory.path)"
            )
        }
    }

    /// A failed transcript fork must not strand a usable checkout or a
    /// registry row claiming that checkout belongs to a real session.
    static func discard(_ preparation: LiveWorktreePreparation) throws {
        guard let record = try preparation.registry.records().first(where: {
            $0.id == preparation.recordID
        }) else {
            throw CLIApplicationError.failed(
                "could not clean up worktree: registry record \(preparation.recordID) is missing"
            )
        }

        do {
            let report = try removeWorktreeAt(
                dest: record.url,
                primaryCheckout: record.sourceURL,
                force: true
            )
            guard report.removed, report.issues.isEmpty else {
                throw CLIApplicationError.failed(
                    "could not remove failed worktree \(record.path): "
                        + report.issues.joined(separator: "; ")
                )
            }
            try preparation.registry.remove(id: preparation.recordID)
        } catch {
            throw CLIApplicationError.failed("could not clean up failed worktree: \(error)")
        }
    }

    private static func relativePath(from root: URL, to child: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.starts(with: rootComponents) else { return "" }
        return childComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func sanitizedComponent(_ value: String) -> String {
        let result = value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? String(character)
                : "-"
        }.joined()
        return result.isEmpty ? "repo" : result
    }
}
