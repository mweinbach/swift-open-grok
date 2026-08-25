import Foundation
import OpenGrokConfig
import OpenGrokFastWorktree
import OpenGrokFileUtils

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct LiveRestoreCodeSource: Sendable, Equatable {
    let sessionID: String
    let persistedWorkingDirectory: URL
    let headCommit: String
}

struct LiveRestoreCodeGitRunner: Sendable {
    let run: @Sendable ([String], URL) throws -> GitCommandResult

    static let live = Self { arguments, directory in
        try runGit(arguments, cwd: directory)
    }
}

enum LiveRestoreCodeLaunch {
    private static let operationStateNames = [
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD",
        "BISECT_LOG", "rebase-merge", "rebase-apply",
    ]

    static func capture(
        options: CLIExecutionOptions,
        workingDirectory: URL,
        openGrokHome: URL
    ) async throws -> LiveRestoreCodeSource? {
        guard options.restoreCode else { return nil }
        guard let resume = options.resume else {
            throw CLIApplicationError.failed("--restore-code requires --resume")
        }

        let store = LiveConversationStore(openGrokHome: openGrokHome)
        let requested = resume.trimmingCharacters(in: .whitespacesAndNewlines)
        let record: LiveConversationRecord
        if requested.isEmpty {
            guard let latest = try await store.latest(workingDirectory: workingDirectory) else {
                throw CLIApplicationError.failed("no session is available to restore")
            }
            record = latest
        } else if LiveSessionTitleResolver.looksLikeSessionID(requested) {
            record = try await store.load(sessionID: requested)
        } else {
            let safeSessionID: Bool
            do {
                try LiveConversationStore.validateSessionID(requested)
                safeSessionID = true
            } catch {
                safeSessionID = false
            }
            if safeSessionID,
               let existing = try await store.loadIfPresent(sessionID: requested)
            {
                record = existing
            } else {
                let sessions = try LiveSessionCatalog(openGrokHome: openGrokHome).list()
                let sessionID = try LiveSessionTitleResolver.resolve(
                    value: requested,
                    in: sessions,
                    workingDirectory: workingDirectory
                )
                record = try await store.load(sessionID: sessionID)
            }
        }

        guard let commit = record.headCommit, isCompleteObjectID(commit) else {
            throw CLIApplicationError.failed(
                "cannot restore session \(record.sessionID): its saved HEAD is not a complete Git object ID"
            )
        }

        let persisted = URL(fileURLWithPath: record.workingDirectory, isDirectory: true)
        guard LiveToolExecutor.workspaceRootsMatch(persisted, workingDirectory) else {
            throw CLIApplicationError.failed(
                "cannot restore session \(record.sessionID) outside its persisted workspace "
                    + "\(persisted.path)"
            )
        }

        if options.worktree != nil {
            try preparePrivateManagedPool(openGrokHome: openGrokHome)
        }

        return LiveRestoreCodeSource(
            sessionID: record.sessionID,
            persistedWorkingDirectory: persisted,
            headCommit: commit.lowercased()
        )
    }

    static func restore(
        options: CLIExecutionOptions,
        source: LiveRestoreCodeSource?,
        workingDirectory: URL,
        preparation: LiveWorktreePreparation?,
        openGrokHome: URL,
        git: LiveRestoreCodeGitRunner = .live
    ) throws {
        guard options.restoreCode else { return }
        guard options.resume != nil, let source else {
            throw CLIApplicationError.failed("--restore-code requires a captured explicit resume session")
        }
        guard isCompleteObjectID(source.headCommit) else {
            throw CLIApplicationError.failed("refusing to restore an incomplete or invalid Git object ID")
        }
        guard (options.worktree != nil) == (preparation != nil) else {
            throw CLIApplicationError.failed("refusing to restore an unverified worktree checkout")
        }

        let protectedSourceHead: String?
        if let preparation {
            try validateManagedCheckout(
                preparation,
                source: source,
                workingDirectory: workingDirectory,
                openGrokHome: openGrokHome
            )
            protectedSourceHead = try command(
                ["rev-parse", "--verify", "HEAD"],
                at: source.persistedWorkingDirectory,
                using: git
            )
        } else {
            guard LiveToolExecutor.workspaceRootsMatch(
                workingDirectory,
                source.persistedWorkingDirectory
            ) else {
                throw CLIApplicationError.failed(
                    "refusing to restore session \(source.sessionID) outside its exact persisted workspace"
                )
            }
            protectedSourceHead = nil
        }

        let target = source.headCommit.lowercased()
        let current = try command(
            ["rev-parse", "--verify", "HEAD"],
            at: workingDirectory,
            using: git
        ).lowercased()
        guard isCompleteObjectID(current) else {
            throw CLIApplicationError.failed("refusing to restore a repository with an invalid current HEAD")
        }
        guard current != target else { return }

        do {
            _ = try command(
                ["cat-file", "-e", "\(target)^{commit}"],
                at: workingDirectory,
                using: git
            )
        } catch {
            throw CLIApplicationError.failed(
                "cannot restore session \(source.sessionID): commit \(target) is not available "
                    + "locally; automatic network fetching is disabled (\(error))"
            )
        }

        let gitDirectory = try command(
            ["rev-parse", "--absolute-git-dir"],
            at: workingDirectory,
            using: git
        )
        let gitDirectoryURL = try PathSecurity.canonicalize(
            URL(fileURLWithPath: gitDirectory, isDirectory: true)
        )
        for state in operationStateNames {
            let marker = gitDirectoryURL.appendingPathComponent(state)
            if FileManager.default.fileExists(atPath: marker.path) {
                throw CLIApplicationError.failed(
                    "refusing to restore code during in-progress Git operation \(state)"
                )
            }
        }

        let status = try command(["status", "--porcelain"], at: workingDirectory, using: git)
        let stash: String?
        if status.isEmpty {
            stash = nil
        } else {
            let previous = try optionalStash(at: workingDirectory, using: git)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let message = "grok: pre-restore-code \(source.sessionID) \(formatter.string(from: Date()))"
            do {
                _ = try command(
                    ["stash", "push", "--include-untracked", "-m", message],
                    at: workingDirectory,
                    using: git
                )
                let created = try command(
                    ["rev-parse", "--verify", "stash@{0}"],
                    at: workingDirectory,
                    using: git
                ).lowercased()
                guard isCompleteObjectID(created), created != previous else {
                    throw CLIApplicationError.failed("Git did not create a distinct recoverable stash")
                }
                stash = created
            } catch {
                throw CLIApplicationError.failed(
                    "refusing to restore session \(source.sessionID): dirty tracked or untracked "
                        + "files could not be preserved in a Git stash (\(error))"
                )
            }
        }

        do {
            _ = try command(["checkout", target], at: workingDirectory, using: git)
            let restored = try command(
                ["rev-parse", "--verify", "HEAD"],
                at: workingDirectory,
                using: git
            ).lowercased()
            guard restored == target else {
                throw CLIApplicationError.failed(
                    "Git checkout stopped at \(restored), not requested commit \(target)"
                )
            }
            if let protectedSourceHead {
                let finalSourceHead = try command(
                    ["rev-parse", "--verify", "HEAD"],
                    at: source.persistedWorkingDirectory,
                    using: git
                )
                guard finalSourceHead == protectedSourceHead else {
                    throw CLIApplicationError.failed(
                        "the source checkout changed during managed worktree restoration"
                    )
                }
            }
        } catch {
            let retained = stash.map { "; preserved files remain in stash \($0)" } ?? ""
            throw CLIApplicationError.failed(
                "could not restore session \(source.sessionID) to commit \(target): "
                    + "\(error)\(retained)"
            )
        }
    }

    static func preparePrivateManagedPool(openGrokHome: URL) throws {
        let home = openGrokHome.standardizedFileURL
        let pool = home.appendingPathComponent("worktrees", isDirectory: true)
        try validateExistingDirectoryBeforeCreation(home)
        #if os(Windows)
        try createDirAllOwnerOnly(home, stateRoot: home)
        #else
        try createDirAllOwnerOnly(home)
        #endif
        guard let approvedHome = ForeignSessionApprovedRoot(home) else {
            throw CLIApplicationError.failed("the restore-code state root is not a safe owner-owned directory")
        }
        try validateExistingDirectoryBeforeCreation(pool)
        #if os(Windows)
        try createDirAllOwnerOnly(pool, stateRoot: home)
        #else
        try createDirAllOwnerOnly(pool)
        #endif
        guard approvedHome.subroot(pool) != nil else {
            throw CLIApplicationError.failed("the restore-code worktree pool is not a safe owned subdirectory")
        }
        try validateOwnerPrivateDirectory(home)
        try validateOwnerPrivateDirectory(pool)
    }

    private static func validateManagedCheckout(
        _ preparation: LiveWorktreePreparation,
        source: LiveRestoreCodeSource,
        workingDirectory: URL,
        openGrokHome: URL
    ) throws {
        let expectedHome = try PathSecurity.canonicalize(openGrokHome)
        let expectedPool = expectedHome.appendingPathComponent("worktrees", isDirectory: true)
        try validateOwnerPrivateDirectory(expectedHome)
        try validateOwnerPrivateDirectory(expectedPool)
        guard LiveToolExecutor.workspaceRootsMatch(preparation.registry.openGrokHome, expectedHome),
              LiveToolExecutor.workspaceRootsMatch(preparation.registry.poolRoot, expectedPool),
              LiveToolExecutor.workspaceRootsMatch(preparation.sourceDirectory, source.persistedWorkingDirectory),
              LiveToolExecutor.workspaceRootsMatch(preparation.effectiveDirectory, workingDirectory),
              let approvedHome = ForeignSessionApprovedRoot(expectedHome),
              let approvedPool = approvedHome.subroot(expectedPool),
              approvedHome.openRegularFile(preparation.registry.databaseURL) != nil,
              let record = try preparation.registry.records().first(where: { $0.id == preparation.recordID }),
              record.kind == .launch,
              approvedPool.subroot(record.url) != nil,
              approvedPool.subroot(workingDirectory) != nil
        else {
            throw CLIApplicationError.failed(
                "refusing to restore code outside an owner-private registered managed worktree"
            )
        }

        let sourceIdentity = try discoverGitRepo(at: source.persistedWorkingDirectory)
        let targetIdentity = try discoverGitRepo(at: workingDirectory)
        guard let sourceRoot = sourceIdentity.toplevel,
              let targetRoot = targetIdentity.toplevel,
              LiveToolExecutor.workspaceRootsMatch(sourceRoot, record.sourceURL),
              LiveToolExecutor.workspaceRootsMatch(targetRoot, record.url),
              LiveToolExecutor.workspaceRootsMatch(sourceIdentity.commonDir, targetIdentity.commonDir),
              !LiveToolExecutor.workspaceRootsMatch(sourceRoot, targetRoot)
        else {
            throw CLIApplicationError.failed(
                "refusing to restore a foreign or source-repository checkout as a managed worktree"
            )
        }
    }

    private static func command(
        _ arguments: [String],
        at directory: URL,
        using git: LiveRestoreCodeGitRunner
    ) throws -> String {
        let result: GitCommandResult
        do {
            result = try git.run(arguments, directory)
        } catch {
            throw CLIApplicationError.failed("git \(arguments.first ?? "command") could not start: \(error)")
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIApplicationError.failed(
                "git \(arguments.first ?? "command") failed (exit \(result.exitCode))"
                    + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func optionalStash(
        at directory: URL,
        using git: LiveRestoreCodeGitRunner
    ) throws -> String? {
        let result = try git.run(["rev-parse", "--verify", "--quiet", "refs/stash"], directory)
        if result.exitCode == 1 { return nil }
        guard result.exitCode == 0 else {
            throw CLIApplicationError.failed("could not inspect the existing Git stash")
        }
        let object = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isCompleteObjectID(object) else {
            throw CLIApplicationError.failed("the existing Git stash has an invalid object ID")
        }
        return object
    }

    private static func isCompleteObjectID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 40 || bytes.count == 64 else { return false }
        return bytes.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func validateExistingDirectoryBeforeCreation(_ directory: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
        var info = stat()
        let result = directory.path.withCString { lstat($0, &info) }
        guard result == 0 else {
            if errno == ENOENT { return }
            throw CLIApplicationError.failed("cannot safely inspect restore-code directory \(directory.path)")
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0
        else {
            throw CLIApplicationError.failed(
                "refusing a symlink, foreign-owned, or group-writable restore-code directory"
            )
        }
        #else
        _ = directory
        #endif
    }

    private static func validateOwnerPrivateDirectory(_ directory: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
        var info = stat()
        guard directory.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o077) == 0
        else {
            throw CLIApplicationError.failed(
                "restore-code worktree directories must be owner-private and cannot be symbolic links"
            )
        }
        #elseif os(Windows)
        guard ForeignSessionApprovedRoot(directory) != nil else {
            throw CLIApplicationError.failed(
                "restore-code worktree directories require a protected owner-private Windows ACL"
            )
        }
        #else
        throw CLIApplicationError.failed("restore-code cannot verify owner-private directories on this platform")
        #endif
    }
}
