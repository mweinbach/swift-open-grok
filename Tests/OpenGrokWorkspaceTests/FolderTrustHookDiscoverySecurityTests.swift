import Foundation
import OpenGrokWorkspace
import Testing

private func withHookTrustRepository(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("open-grok-folder-hook-trust-\(UUID().uuidString)")
        .appendingPathComponent("repository")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try body(root)
}

@Suite("folder trust executable hook and LSP markers")
struct FolderTrustHookDiscoverySecurityTests {
    @Test("an empty repository does not invent executable project configuration")
    func emptyRepositoryRemainsUnmarked() throws {
        try withHookTrustRepository { repository in
            #expect(repoConfigsPresent(at: repository) == false)
        }
    }

    @Test("a hooks-only project directory requires a folder trust decision")
    func projectHookDirectoryIsExecutableConfiguration() throws {
        try withHookTrustRepository { repository in
            try FileManager.default.createDirectory(
                at: repository.appendingPathComponent(".opengrok/hooks"),
                withIntermediateDirectories: true
            )

            #expect(repoConfigsPresent(at: repository))
            let verdict = decideFolderTrust(
                featureEnabled: true,
                inputs: FolderTrustDecideInputs(
                    storeTrusted: false,
                    repoConfigsPresent: repoConfigsPresent(at: repository),
                    isInteractive: false,
                    keyRecordable: true
                )
            )
            #expect(verdict == .untrusted)
        }
    }

    @Test("a plain file in place of the project hooks directory is still a marker")
    func projectHookFileIsExecutableConfiguration() throws {
        try withHookTrustRepository { repository in
            let config = repository.appendingPathComponent(".opengrok")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try "{}".write(
                to: config.appendingPathComponent("hooks"),
                atomically: true,
                encoding: .utf8
            )

            #expect(repoConfigsPresent(at: repository))
        }
    }

    @Test("a dangling hooks symlink cannot make a hostile repository look empty")
    func danglingHookSymlinkFailsClosed() throws {
        #if !os(Windows)
        try withHookTrustRepository { repository in
            let config = repository.appendingPathComponent(".opengrok")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: config.appendingPathComponent("hooks").path,
                withDestinationPath: "missing-repository-controlled-hooks"
            )

            #expect(repoConfigsPresent(at: repository))
        }
        #endif
    }

    @Test("a hooks symlink to another directory remains executable project configuration")
    func externalHookDirectorySymlinkRequiresTrust() throws {
        #if !os(Windows)
        try withHookTrustRepository { repository in
            let config = repository.appendingPathComponent(".opengrok")
            let external = repository.deletingLastPathComponent().appendingPathComponent("outside-hooks")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: config.appendingPathComponent("hooks"),
                withDestinationURL: external
            )

            #expect(repoConfigsPresent(at: repository))
        }
        #endif
    }

    @Test("hooks at the canonical repository root are detected from nested aliases")
    func hookDiscoveryCanonicalizesRootAndWalksParents() throws {
        #if !os(Windows)
        try withHookTrustRepository { repository in
            let nested = repository.appendingPathComponent("packages/feature")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: repository.appendingPathComponent(".opengrok/hooks"),
                withIntermediateDirectories: true
            )
            let alias = repository.deletingLastPathComponent().appendingPathComponent("feature-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)

            #expect(repoConfigsPresent(at: nested))
            #expect(repoConfigsPresent(at: alias))
        }
        #endif
    }

    @Test("a project LSP server declaration requires trust")
    func projectLSPConfigurationIsExecutableConfiguration() throws {
        try withHookTrustRepository { repository in
            let config = repository.appendingPathComponent(".opengrok")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try "{}".write(
                to: config.appendingPathComponent("lsp.json"),
                atomically: true,
                encoding: .utf8
            )

            #expect(repoConfigsPresent(at: repository))
        }
    }

    @Test("a dangling project LSP symlink cannot bypass trust discovery")
    func danglingLSPSymlinkFailsClosed() throws {
        #if !os(Windows)
        try withHookTrustRepository { repository in
            let config = repository.appendingPathComponent(".opengrok")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: config.appendingPathComponent("lsp.json").path,
                withDestinationPath: "missing-repository-controlled-server"
            )

            #expect(repoConfigsPresent(at: repository))
        }
        #endif
    }

    @Test("compatibility project hook files require the same trust gate")
    func cursorHookConfigurationIsExecutableConfiguration() throws {
        try withHookTrustRepository { repository in
            let config = repository.appendingPathComponent(".cursor")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try "{}".write(
                to: config.appendingPathComponent("hooks.json"),
                atomically: true,
                encoding: .utf8
            )

            #expect(repoConfigsPresent(at: repository))
        }
    }

    @Test("an owner-recorded decision explicitly trusts a hooks-only repository")
    func recordedTrustStillAllowsHookProjects() throws {
        try withHookTrustRepository { repository in
            try FileManager.default.createDirectory(
                at: repository.appendingPathComponent(".opengrok/hooks"),
                withIntermediateDirectories: true
            )
            let ownerHome = repository.deletingLastPathComponent().appendingPathComponent("home")
            let trustPath = ownerHome.appendingPathComponent("trusted_folders.toml")
            var store = PersistentFolderTrustStore(path: trustPath, home: ownerHome.path)
            try store.record(repository, trusted: true)

            let verdict = decideFolderTrust(
                featureEnabled: true,
                inputs: FolderTrustDecideInputs(
                    storeTrusted: PersistentFolderTrustStore(
                        path: trustPath,
                        home: ownerHome.path
                    ).isTrusted(repository),
                    repoConfigsPresent: repoConfigsPresent(at: repository),
                    isInteractive: false,
                    keyRecordable: true
                )
            )
            #expect(verdict == .trusted)
        }
    }
}
