import Foundation
import Testing
@testable import OpenGrokSessionPersistence

private struct SessionWorkingDirectoriesFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let first: URL
    let second: URL
    let store: SessionWorkingDirectoriesStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-working-directory-store-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        home = root.appendingPathComponent("state")
        workspace = root.appendingPathComponent("workspace")
        first = root.appendingPathComponent("approved-first", isDirectory: true)
        second = root.appendingPathComponent("approved-second", isDirectory: true)
        for directory in [home, workspace, first, second] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        store = try SessionWorkingDirectoriesStore(
            grokHome: home,
            sessionID: "working-directory-session",
            workingDirectory: workspace
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func replaceDocument(_ data: Data) throws {
        try RelocationFS.writeAtomicDurable(
            path: store.fileURL,
            data: data,
            permissions: 0o600,
            stateRoot: home
        )
    }
}

@Suite("owner-private Rust working_dirs.json session persistence")
struct SessionWorkingDirectoriesParityTests {
    @Test("a session without a working-directory sidecar restores an empty set")
    func absentSidecarDoesNotCreateOrGrantAuthority() throws {
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }

        #expect(try fixture.store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
    }

    @Test("canonical roots round-trip as a private Rust-compatible JSON path array")
    func canonicalDirectoriesRoundTripAsPrivateJSONArray() throws {
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }

        try fixture.store.save([fixture.first, fixture.second])

        #expect(try fixture.store.load() == [fixture.first, fixture.second])
        #expect(try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: fixture.store.fileURL)
        ) == [fixture.first.path, fixture.second.path])
        #if !os(Windows)
        let filePermissions = try FileManager.default.attributesOfItem(
            atPath: fixture.store.fileURL.path
        )[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: fixture.store.sessionDirectory.path
        )[.posixPermissions] as? NSNumber
        #expect(filePermissions?.uint16Value == 0o600)
        #expect(directoryPermissions?.uint16Value == 0o700)
        #endif
    }

    @Test("replacing the complete directory set durably revokes removed roots")
    func replacementAndEmptySetRevokePersistedAuthority() throws {
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }

        try fixture.store.save([fixture.first, fixture.second])
        try fixture.store.save([fixture.second])
        #expect(try fixture.store.load() == [fixture.second])

        try fixture.store.save([])
        #expect(try fixture.store.load().isEmpty)
        #expect(try JSONDecoder().decode(
            [String].self,
            from: Data(contentsOf: fixture.store.fileURL)
        ).isEmpty)
    }

    @Test("corrupt or duplicate path documents never restore a filesystem grant")
    func malformedAndDuplicateDocumentsFailClosed() throws {
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }
        try fixture.store.save([fixture.first])

        try fixture.replaceDocument(Data("{\"directories\":[]}".utf8))
        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.load()
        }

        let duplicate = try JSONEncoder().encode([fixture.first.path, fixture.first.path])
        try fixture.replaceDocument(duplicate)
        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.load()
        }
    }

    @Test("missing directories, relative paths, workspace roots, and filesystem roots are rejected")
    func unsafeDirectoryDocumentsFailClosed() throws {
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }

        for invalid in [
            fixture.root.appendingPathComponent("missing").path,
            "../outside",
            fixture.workspace.path,
            URL(fileURLWithPath: "/").path,
        ] {
            try fixture.store.save([])
            try fixture.replaceDocument(try JSONEncoder().encode([invalid]))
            #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
                try fixture.store.load()
            }
        }
        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.save([fixture.workspace])
        }
    }

    @Test("a symlinked working-directory document is never followed or replaced")
    func sidecarSymlinkFailsClosed() throws {
        #if !os(Windows)
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }
        try fixture.store.save([])
        let outside = fixture.root.appendingPathComponent("attacker-document")
        try JSONEncoder().encode([fixture.first.path]).write(to: outside)
        try FileManager.default.removeItem(at: fixture.store.fileURL)
        try FileManager.default.createSymbolicLink(at: fixture.store.fileURL, withDestinationURL: outside)

        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.load()
        }
        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.save([fixture.first])
        }
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: outside)) == [fixture.first.path])
        #endif
    }

    @Test("a symlinked session-directory ancestor cannot redirect private state")
    func symlinkedSessionAncestorFailsClosed() throws {
        #if !os(Windows)
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }
        let bucket = fixture.store.sessionDirectory.deletingLastPathComponent()
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bucket.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: bucket, withDestinationURL: outside)

        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.load()
        }
        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.save([fixture.first])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #endif
    }

    @Test("a symlink spelling in persisted root entries is rejected")
    func persistedDirectoryAliasesAreNotImplicitGrants() throws {
        #if !os(Windows)
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }
        let alias = fixture.root.appendingPathComponent("approved-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.first)
        try fixture.store.save([])
        try fixture.replaceDocument(try JSONEncoder().encode([alias.path]))

        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.load()
        }
        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.save([alias])
        }
        #endif
    }

    @Test("hard-linked sidecars cannot disclose or overwrite another owner-private file")
    func hardLinkedSidecarFailsClosed() throws {
        #if !os(Windows)
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }
        try fixture.store.save([])
        let outside = fixture.root.appendingPathComponent("owner-secret")
        try JSONEncoder().encode([fixture.first.path]).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
        try FileManager.default.removeItem(at: fixture.store.fileURL)
        try FileManager.default.linkItem(at: outside, to: fixture.store.fileURL)

        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.load()
        }
        #expect(throws: SessionWorkingDirectoriesPersistenceError.self) {
            try fixture.store.save([fixture.first])
        }
        #endif
    }

    @Test("session traversal attempts cannot choose another session's sidecar")
    func hostileSessionIdentifierFailsClosed() throws {
        let fixture = try SessionWorkingDirectoriesFixture()
        defer { fixture.dispose() }

        #expect(throws: (any Error).self) {
            try SessionWorkingDirectoriesStore(
                grokHome: fixture.home,
                sessionID: "../other-session",
                workingDirectory: fixture.workspace
            )
        }
    }
}
