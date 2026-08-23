import Foundation

extension LiveInteractiveControllerRenderer {
    /// Create a dormant peer without borrowing this process's workspace-bound
    /// handlers. Its eventual `--resume` bootstraps a separate security stack.
    func performWorktreeFork(
        using conversationStore: LiveConversationStore,
        directive: String? = nil
    ) async throws -> LiveConversationRecord {
        guard let toolExecutor else {
            throw CLIApplicationError.failed(
                "cannot fork into a worktree: this session has no workspace authority"
            )
        }

        let sourceSessionID = sessionID
        let activeDirectory = URL(
            fileURLWithPath: workingDirectory,
            isDirectory: true
        ).standardizedFileURL
        try await toolExecutor.validateWorkspaceAuthority(
            sessionID: sourceSessionID,
            workingDirectory: activeDirectory,
            requiresRegisteredSession: true
        )

        let source = try await conversationStore.load(sessionID: sourceSessionID)
        guard sessionID == sourceSessionID,
              LiveToolExecutor.workspaceRootsMatch(
                activeDirectory,
                URL(fileURLWithPath: workingDirectory, isDirectory: true)
              )
        else {
            throw CLIApplicationError.failed("the active session changed before its worktree fork")
        }
        let sourceDirectory = URL(
            fileURLWithPath: source.workingDirectory,
            isDirectory: true
        ).standardizedFileURL
        guard LiveToolExecutor.workspaceRootsMatch(activeDirectory, sourceDirectory) else {
            throw CLIApplicationError.failed(
                "cannot fork session \(sourceSessionID): its stored workspace "
                    + "\(sourceDirectory.path) differs from this authorized workspace "
                    + "\(activeDirectory.path)"
            )
        }

        do {
            try LiveWorktreeLaunch.validateResumeSource(
                invocationDirectory: activeDirectory,
                sourceDirectory: sourceDirectory
            )
        } catch let error as CLIApplicationError {
            if error.description.contains("not a git repository") {
                throw CLIApplicationError.failed(LivePagerForkCommand.worktreeRequiresGit)
            }
            throw error
        }

        let options = CLIExecutionOptions(
            common: CLICommonOptions(cwd: sourceDirectory.path),
            resume: source.sessionID,
            worktree: ""
        )
        guard let preparation = try LiveWorktreeLaunch.prepare(
            options: options,
            sourceDirectory: sourceDirectory,
            openGrokHome: openGrokHome,
            isCancelled: { Task.isCancelled }
        ) else {
            throw CLIApplicationError.failed("worktree preparation was not requested")
        }

        let childSessionID = UUID().uuidString
        var childPersisted = false
        do {
            try Task.checkCancellation()
            let currentSource = try await conversationStore.load(sessionID: source.sessionID)
            let currentSourceDirectory = URL(
                fileURLWithPath: currentSource.workingDirectory,
                isDirectory: true
            )
            guard LiveToolExecutor.workspaceRootsMatch(sourceDirectory, currentSourceDirectory) else {
                throw CLIApplicationError.failed(
                    "cannot fork session \(source.sessionID): its workspace changed during worktree creation"
                )
            }

            var child = try await conversationStore.fork(
                sourceSessionID: source.sessionID,
                destinationSessionID: childSessionID,
                workingDirectory: preparation.effectiveDirectory,
                pendingFirstPrompt: directive
            )
            childPersisted = true
            try Task.checkCancellation()
            guard sessionID == sourceSessionID,
                  LiveToolExecutor.workspaceRootsMatch(
                    activeDirectory,
                    URL(fileURLWithPath: workingDirectory, isDirectory: true)
                  )
            else {
                throw CLIApplicationError.failed("the active session changed during its worktree fork")
            }
            child.sessionKind = "worktree"
            try await conversationStore.save(child)
            try Task.checkCancellation()
            try LiveWorktreeLaunch.attachSession(preparation, sessionID: child.sessionID)
            return child
        } catch {
            var cleanupFailures: [String] = []

            do {
                let deleted = try LiveSessionCatalog(openGrokHome: openGrokHome)
                    .delete(sessionID: childSessionID)
                if childPersisted && !deleted {
                    cleanupFailures.append("forked session \(childSessionID) could not be removed")
                }
            } catch {
                cleanupFailures.append("session cleanup failed: \(error)")
            }

            do {
                try LiveWorktreeLaunch.discard(preparation)
            } catch {
                cleanupFailures.append("worktree cleanup failed: \(error)")
            }

            if !cleanupFailures.isEmpty {
                throw CLIApplicationError.failed(
                    "failed to fork session \(source.sessionID) into a worktree: \(error); "
                        + cleanupFailures.joined(separator: "; ")
                )
            }
            throw error
        }
    }
}
