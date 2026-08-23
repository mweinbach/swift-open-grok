import Foundation
import OpenGrokTestUtilities
import Testing
@testable import OpenGrokWorkspace

private let missingSessionGitObjectID = "0123456789abcdef0123456789abcdef01234567"

private func withSessionGitRepository(_ body: (URL) throws -> Void) throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("session-git-identity-\(UUID().uuidString)")
    let repository = temporary.appendingPathComponent("repository")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try HermeticGit.initGitRepo(at: repository)
    try body(repository.resolvingSymlinksInPath())
}

@discardableResult
private func makeSessionGitCommit(in repository: URL) throws -> String {
    try "session fixture\n".write(
        to: repository.appendingPathComponent("tracked.txt"),
        atomically: true,
        encoding: .utf8
    )
    try HermeticGit.gitCommitAll(at: repository, message: "session identity fixture")
    return try HermeticGit.runGit(in: repository, arguments: ["rev-parse", "HEAD"])
}

@Suite("workspace session Git identity upstream parity")
struct SessionGitIdentityParityTests {
    @Test("unborn HEAD has no branch or commit but preserves root and scrubbed remotes")
    func unbornHeadAndRemoteCredentials() throws {
        try withSessionGitRepository { repository in
            try HermeticGit.runGit(
                in: repository,
                arguments: ["remote", "add", "origin", "https://user:secret@github.com/org/repo.git"]
            )
            try HermeticGit.runGit(
                in: repository,
                arguments: ["remote", "add", "duplicate", "https://github.com/org/repo.git"]
            )
            try HermeticGit.runGit(
                in: repository,
                arguments: ["remote", "add", "backup", "git@gitlab.com:org/repo.git"]
            )

            let snapshot = WorkspaceSessionGitMetadata.resolve(at: repository)

            #expect(snapshot.gitRootDirectory == repository.path)
            #expect(snapshot.headCommit == nil)
            #expect(snapshot.headBranch == nil)
            #expect(snapshot.gitRemotes == [
                "git@gitlab.com:org/repo.git",
                "https://github.com/org/repo.git",
            ])
        }
    }

    @Test("live workspace snapshot resolves a valid branch OID without its commit object")
    func missingCommitObjectStillResolvesLiveSnapshot() throws {
        try withSessionGitRepository { repository in
            let originalCommit = try makeSessionGitCommit(in: repository)
            let branch = try HermeticGit.runGit(
                in: repository,
                arguments: ["symbolic-ref", "--short", "HEAD"]
            )
            let reference = repository.appendingPathComponent(".git/refs/heads/\(branch)")

            #expect(WorkspaceSessionGitMetadata.currentCommit(at: repository) == originalCommit)
            try "\(missingSessionGitObjectID)\n".write(
                to: reference,
                atomically: true,
                encoding: .utf8
            )
            #expect(throws: HermeticGitError.self) {
                try HermeticGit.runGit(
                    in: repository,
                    arguments: ["cat-file", "-t", missingSessionGitObjectID]
                )
            }

            let workspace = LocalWorkspaceOps(config: WorkspaceConfig(root: repository))
            #expect(workspace.sessionGitMetadata.gitRootDirectory == repository.path)
            #expect(workspace.sessionGitMetadata.headCommit == missingSessionGitObjectID)
            #expect(workspace.sessionGitMetadata.headBranch == branch)
            #expect(WorkspaceSessionGitMetadata.currentCommit(at: repository) == missingSessionGitObjectID)
        }
    }

    @Test("detached HEAD resolves a missing object without manufacturing a branch")
    func detachedMissingObject() throws {
        try withSessionGitRepository { repository in
            try makeSessionGitCommit(in: repository)
            try HermeticGit.runGit(in: repository, arguments: ["checkout", "--detach", "HEAD"])
            try "\(missingSessionGitObjectID)\r\n".write(
                to: repository.appendingPathComponent(".git/HEAD"),
                atomically: true,
                encoding: .utf8
            )

            let snapshot = WorkspaceSessionGitMetadata.resolve(at: repository)
            #expect(snapshot.headCommit == missingSessionGitObjectID)
            #expect(snapshot.headBranch == nil)
        }
    }

    @Test("packed-only references handle CRLF and missing commit objects")
    func packedReferenceWithoutObject() throws {
        try withSessionGitRepository { repository in
            let commit = try makeSessionGitCommit(in: repository)
            let branch = try HermeticGit.runGit(
                in: repository,
                arguments: ["symbolic-ref", "--short", "HEAD"]
            )
            try HermeticGit.runGit(in: repository, arguments: ["pack-refs", "--all", "--prune"])
            let looseReference = repository.appendingPathComponent(".git/refs/heads/\(branch)")
            #expect(!FileManager.default.fileExists(atPath: looseReference.path))

            let packedReference = repository.appendingPathComponent(".git/packed-refs")
            let original = try String(contentsOf: packedReference, encoding: .utf8)
            let rewritten = original.replacingOccurrences(of: commit, with: missingSessionGitObjectID)
                .split(whereSeparator: { $0.isNewline })
                .joined(separator: "\r\n") + "\r\n"
            try rewritten.write(to: packedReference, atomically: true, encoding: .utf8)
            try "ref: refs/heads/\(branch)\r\n".write(
                to: repository.appendingPathComponent(".git/HEAD"),
                atomically: true,
                encoding: .utf8
            )

            let snapshot = WorkspaceSessionGitMetadata.resolve(at: repository)
            #expect(snapshot.headCommit == missingSessionGitObjectID)
            #expect(snapshot.headBranch == branch)
        }
    }

    @Test("linked worktrees use private HEAD with shared refs, packed refs and remotes")
    func linkedWorktreeUsesSharedGitDirectory() throws {
        try withSessionGitRepository { repository in
            let commit = try makeSessionGitCommit(in: repository)
            try HermeticGit.runGit(
                in: repository,
                arguments: ["remote", "add", "origin", "https://token:private@example.com/org/repo.git"]
            )
            let worktree = repository.deletingLastPathComponent()
                .appendingPathComponent("linked-worktree")
            try HermeticGit.runGit(
                in: repository,
                arguments: ["worktree", "add", "-b", "session-feature", worktree.path]
            )
            try HermeticGit.runGit(in: repository, arguments: ["pack-refs", "--all", "--prune"])

            let resolvedWorktree = worktree.resolvingSymlinksInPath()
            let snapshot = WorkspaceSessionGitMetadata.resolve(at: resolvedWorktree)
            #expect(snapshot.gitRootDirectory == resolvedWorktree.path)
            #expect(snapshot.headCommit == commit)
            #expect(snapshot.headBranch == "session-feature")
            #expect(snapshot.gitRemotes == ["https://example.com/org/repo.git"])
        }
    }

    @Test("unreadable or malformed loose references never fall back to a valid packed object")
    func invalidLooseReferenceCannotFallBackToPackedReference() throws {
        try withSessionGitRepository { repository in
            let commit = try makeSessionGitCommit(in: repository)
            let branch = try HermeticGit.runGit(
                in: repository,
                arguments: ["symbolic-ref", "--short", "HEAD"]
            )
            try HermeticGit.runGit(in: repository, arguments: ["pack-refs", "--all", "--prune"])
            #expect(WorkspaceSessionGitMetadata.currentCommit(at: repository) == commit)

            let looseReference = repository.appendingPathComponent(".git/refs/heads/\(branch)")
            try FileManager.default.createDirectory(
                at: looseReference.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "not-a-valid-object-id\n".write(
                to: looseReference,
                atomically: true,
                encoding: .utf8
            )

            let snapshot = WorkspaceSessionGitMetadata.resolve(at: repository)
            #expect(snapshot.headCommit == nil)
            #expect(snapshot.headBranch == nil)
        }
    }

    @Test("malicious reference traversal and malformed object records fail closed")
    func malformedReferencesCannotEscapeGitDirectory() throws {
        try withSessionGitRepository { repository in
            try makeSessionGitCommit(in: repository)
            let outside = repository.deletingLastPathComponent().appendingPathComponent("outside")
            try "\(missingSessionGitObjectID)\n".write(
                to: outside,
                atomically: true,
                encoding: .utf8
            )
            let head = repository.appendingPathComponent(".git/HEAD")

            for invalid in [
                "ref: refs/heads/../../../../outside\n",
                "ref: refs/heads/C:/outside\n",
                "ref: refs/heads/main\n\(missingSessionGitObjectID)\n",
                "0123456789abcdef\n",
                "gggggggggggggggggggggggggggggggggggggggg\n",
            ] {
                try invalid.write(to: head, atomically: true, encoding: .utf8)
                let snapshot = WorkspaceSessionGitMetadata.resolve(at: repository)
                #expect(snapshot.headCommit == nil)
                #expect(snapshot.headBranch == nil)
            }
        }
    }

    @Test("a broken nested gitdir pointer cannot silently inherit its parent repository")
    func invalidNestedRepositoryStopsDiscovery() throws {
        try withSessionGitRepository { repository in
            try makeSessionGitCommit(in: repository)
            let nested = repository.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "gitdir: ../missing-git-directory\n".write(
                to: nested.appendingPathComponent(".git"),
                atomically: true,
                encoding: .utf8
            )

            let snapshot = WorkspaceSessionGitMetadata.resolve(at: nested)
            #expect(snapshot == WorkspaceSessionGitMetadata())
        }
    }

    @Test("bare repositories and directories outside repositories have no session identity")
    func bareRepositoriesAreNotSessionWorktrees() throws {
        try withSessionGitRepository { repository in
            let parent = repository.deletingLastPathComponent()
            let bare = parent.appendingPathComponent("bare.git")
            try HermeticGit.runGit(in: parent, arguments: ["init", "--bare", bare.path])

            #expect(WorkspaceSessionGitMetadata.resolve(at: bare) == WorkspaceSessionGitMetadata())
            #expect(WorkspaceSessionGitMetadata.resolve(at: parent) == WorkspaceSessionGitMetadata())
        }
    }

    @Test("snapshots encode the upstream canonical persistence field names")
    func canonicalSnakeCaseEncoding() throws {
        let snapshot = WorkspaceSessionGitMetadata(
            gitRootDirectory: "/workspace",
            gitRemotes: ["https://github.com/org/repo.git"],
            headCommit: missingSessionGitObjectID,
            headBranch: "main"
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let object = try #require(encoded as? [String: Any])

        #expect(object["git_root_dir"] as? String == "/workspace")
        #expect(object["git_remotes"] as? [String] == ["https://github.com/org/repo.git"])
        #expect(object["head_commit"] as? String == missingSessionGitObjectID)
        #expect(object["head_branch"] as? String == "main")
    }

    #if !os(Windows)
    @Test("symbolic-link references cannot read an object ID outside the Git directory")
    func symbolicLinkReferenceCannotEscape() throws {
        try withSessionGitRepository { repository in
            try makeSessionGitCommit(in: repository)
            let branch = try HermeticGit.runGit(
                in: repository,
                arguments: ["symbolic-ref", "--short", "HEAD"]
            )
            let outside = repository.deletingLastPathComponent().appendingPathComponent("outside-ref")
            try "\(missingSessionGitObjectID)\n".write(
                to: outside,
                atomically: true,
                encoding: .utf8
            )
            let looseReference = repository.appendingPathComponent(".git/refs/heads/\(branch)")
            try FileManager.default.removeItem(at: looseReference)
            try FileManager.default.createSymbolicLink(at: looseReference, withDestinationURL: outside)

            let snapshot = WorkspaceSessionGitMetadata.resolve(at: repository)
            #expect(snapshot.headCommit == nil)
            #expect(snapshot.headBranch == nil)
        }
    }
    #endif
}
