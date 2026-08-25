import Foundation
import OpenGrokConfig
import Testing
@testable import OpenGrokMemory

@Suite("Memory storage Rust workspace identity and secure paths")
struct MemoryStorageParityTests {
    @Test("SSH, HTTPS, and scheme SSH origins share one normalized identity")
    func normalizedGitOrigins() {
        let remotes = [
            "git@github.com:acme/widgets.git",
            "https://github.com/acme/widgets.git",
            "ssh://git@github.com/acme/widgets",
        ]
        #expect(remotes.map(MemoryStorage.normalizeRemoteURL) == [
            "acme/widgets",
            "acme/widgets",
            "acme/widgets",
        ])
        #expect(
            MemoryStorage.normalizeRemoteURL("https://github.com/acme/tools/sub.git")
                == "acme/tools/sub"
        )
    }

    @Test("distinct clone, subdirectory, and worktree paths share the Rust BLAKE3 directory")
    func repositoryIdentitySharesMemoryAcrossCheckouts() {
        let root = URL(fileURLWithPath: "/state/memory", isDirectory: true)
        let paths = [
            URL(fileURLWithPath: "/checkout/widgets", isDirectory: true),
            URL(fileURLWithPath: "/checkout/widgets/Sources", isDirectory: true),
            URL(fileURLWithPath: "/worktrees/review-branch", isDirectory: true),
        ]
        let directories = paths.map {
            MemoryStorage(cwd: $0, rootOverride: root, workspaceIdentity: "acme/widgets")
                .workspaceDir
        }
        #expect(Set(directories).count == 1)
        #expect(
            directories.first?.lastPathComponent
                == "widgets-\(Blake3.hexPrefix("acme/widgets", length: 8))"
        )
    }

    @Test("git config discovery unifies real clone markers, nested paths, and linked worktrees")
    func discoversCloneAndWorktreeOrigins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-git-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first-clone", isDirectory: true)
        let second = root.appendingPathComponent("second-clone", isDirectory: true)
        let nested = first.appendingPathComponent("Sources/Feature", isDirectory: true)
        let linked = root.appendingPathComponent("linked-worktree", isDirectory: true)
        let worktreeMetadata = first.appendingPathComponent(".git/worktrees/linked", isDirectory: true)
        for directory in [
            first.appendingPathComponent(".git", isDirectory: true),
            second.appendingPathComponent(".git", isDirectory: true),
            nested,
            linked,
            worktreeMetadata,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "[remote \"origin\"]\n\turl = git@github.com:acme/widgets.git\n"
            .write(to: first.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "[remote \"origin\"]\n\turl = https://github.com/acme/widgets.git\n"
            .write(to: second.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "../..\n".write(
            to: worktreeMetadata.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(worktreeMetadata.path)\n".write(
            to: linked.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let memoryRoot = root.appendingPathComponent("state/memory", isDirectory: true)
        let storages = [first, second, nested, linked].map {
            MemoryStorage(cwd: $0, rootOverride: memoryRoot)
        }
        #expect(Set(storages.map(\.workspaceDir)).count == 1)
        #expect(storages.allSatisfy { $0.workspaceDir.lastPathComponent.hasPrefix("widgets-") })
    }

    @Test("non-Git workspaces hash their canonical path with Rust BLAKE3")
    func canonicalPathFallbackUsesBlake3() {
        let storage = MemoryStorage(
            cwd: URL(fileURLWithPath: "/Users/foo/project", isDirectory: true),
            rootOverride: URL(fileURLWithPath: "/state/memory", isDirectory: true)
        )
        #expect(storage.workspaceDir.lastPathComponent == "project-9c551524")
    }

    @Test("hostile and malformed origins never become workspace identities")
    func hostileOriginsAreRejected() {
        for remote in [
            "",
            "just-a-path",
            "git@github.com:widgets.git",
            "git@github.com:acme/../escape.git",
            "git@github.com:acme/./escape.git",
            "git@github.com:acme/widgets\n--exec=touch-pwned",
            "git@github.com:acme\\widgets.git",
        ] {
            #expect(MemoryStorage.normalizeRemoteURL(remote) == nil)
        }
    }

    @Test("memory directories and files are owner-private and reject final symlinks")
    func memoryPathsArePrivateAndRejectSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "memory-storage-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = MemoryStorage.newFlat(
            cwd: root,
            root: root.appendingPathComponent("memory", isDirectory: true)
        )
        try storage.ensureInitialized()

        #if !os(Windows)
        let directory = try FileManager.default.attributesOfItem(atPath: storage.globalDir.path)
        let file = try FileManager.default.attributesOfItem(atPath: storage.globalMemoryFile.path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let outside = root.appendingPathComponent("outside.md")
        try "outside secret".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: storage.globalMemoryFile)
        try FileManager.default.createSymbolicLink(
            at: storage.globalMemoryFile,
            withDestinationURL: outside
        )
        #expect(throws: (any Error).self) {
            try storage.ensureInitialized()
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside secret")
        #endif
    }
}
