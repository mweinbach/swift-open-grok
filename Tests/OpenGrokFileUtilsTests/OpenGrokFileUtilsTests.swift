// OpenGrokFileUtilsTests.swift
//
// Hostile-path, atomic-write, lock, checksum, and permission tests for
// OpenGrokFileUtils. Derived from Rust secure_file / fs_atomic invariants.

import Foundation
import Testing
@testable import OpenGrokFileUtils

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("OpenGrokFileUtils")
struct OpenGrokFileUtilsTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ogrok-fileutils-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Atomic write

    @Test("atomic write creates file with contents")
    func atomicWriteCreates() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state.json")
        try AtomicFile.write(path, contents: #"{"ok":true}"#)
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text == #"{"ok":true}"#)
    }

    @Test("atomic write replaces existing without partial read")
    func atomicReplace() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("v.txt")
        try AtomicFile.write(path, contents: "old")
        try AtomicFile.write(path, contents: "new-value")
        #expect(try String(contentsOf: path, encoding: .utf8) == "new-value")
    }

    @Test("atomic write creates parent directories")
    func atomicParents() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a").appendingPathComponent("b").appendingPathComponent("c.txt")
        try AtomicFile.write(path, contents: "nested")
        #expect(try String(contentsOf: path, encoding: .utf8) == "nested")
    }

    @Test("atomic write with noFollow creates and replaces regular file")
    func noFollowRegularFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("secure.json")
        let options = AtomicWriteOptions(mode: 0o600, noFollowFinal: true)
        try AtomicFile.write(path, contents: "first", options: options)
        try AtomicFile.write(path, contents: "second", options: options)
        #expect(try String(contentsOf: path, encoding: .utf8) == "second")
    }

    @Test("atomic write cleans up temp on failure path collision")
    func atomicTempNaming() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("x.bin")
        try AtomicFile.write(path, data: Data([1, 2, 3]))
        try AtomicFile.write(path, data: Data([4, 5, 6]))
        let leftovers = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("Windows atomic directory prefixes distinguish extended drive and UNC roots")
    func windowsAtomicDirectoryPrefixes() throws {
        let drive = [
            #"\\?\C:\"#,
            #"\\?\C:\Users"#,
            #"\\?\C:\Users\me"#,
            #"\\?\C:\Users\me\session"#,
        ]
        #expect(try windowsDirectoryPrefixes("C:/Users//me/session") == drive)
        #expect(try windowsDirectoryPrefixes(#"\\?\C:\Users\me\session"#) == drive)
        #expect(try windowsDirectoryPrefixes(#"C:\"#) == [#"\\?\C:\"#])

        let unc = [
            #"\\?\UNC\server\share\"#,
            #"\\?\UNC\server\share\session"#,
            #"\\?\UNC\server\share\session\child"#,
        ]
        #expect(try windowsDirectoryPrefixes(#"\\server\share\session\child"#) == unc)
        #expect(try windowsDirectoryPrefixes(#"\\?\unc\server\share\session\child"#) == unc)
        #expect(try windowsDirectoryPrefixes(#"\\server\share"#) == [unc[0]])
    }

    @Test("Windows atomic directory prefixes validate the entire path before returning parents")
    func windowsAtomicDirectoryPrefixesRejectHostileNames() {
        for path in [
            #"C:relative\file"#,
            #"C:\good\NUL.json"#,
            #"C:\good\state.json:hidden"#,
            #"C:\good\ambiguous.\state.json"#,
            #"\\?\UNC\server\share\..\state.json"#,
            #"\\?\GLOBALROOT\Device\HarddiskVolume1\state.json"#,
        ] {
            #expect(throws: FileUtilsError.self) { try windowsDirectoryPrefixes(path) }
        }
    }

    #if os(Windows)
    @Test("Windows atomic writes, replacement, rename and fsync work beyond MAX_PATH")
    func windowsLongAtomicRoundTrip() throws {
        let root = try tempDir()
        defer { cleanupWindowsFixture(root) }
        let longParent = windowsLongDirectory(under: root)
        try #require(longParent.path.utf16.count > 300)

        let modes: [AtomicWriteOptions] = [
            AtomicWriteOptions(),
            AtomicWriteOptions(mode: 0o600),
            AtomicWriteOptions(mode: 0o644, noFollowFinal: true),
            .ownerOnly,
        ]
        for (index, options) in modes.enumerated() {
            let parent = longParent.appendingPathComponent("case-\(index)", isDirectory: true)
            let path = parent.appendingPathComponent("state.json")
            let ownerOnly = options.noFollowFinal && options.mode == 0o600
            try AtomicFile.write(path, contents: "first", options: options)
            #expect(try PathSecurity.readNoFollow(
                path,
                maximumBytes: 32_768,
                requireOwnerOnly: ownerOnly
            ) == Data("first".utf8))

            let native = try WindowsSecurePath.extendedLengthPath(path.path)
            let alreadyExtended = URL(fileURLWithPath: native)
            try #require(try WindowsSecurePath.extendedLengthPath(alreadyExtended.path) == native)
            let replacement = Data(repeating: UInt8(index + 1), count: 16_387)
            try AtomicFile.write(alreadyExtended, data: replacement, options: options)
            try AtomicFile.fsyncFile(at: alreadyExtended)
            #expect(try PathSecurity.readNoFollow(
                path,
                maximumBytes: 32_768,
                requireOwnerOnly: ownerOnly
            ) == replacement)
            if ownerOnly { #expect(try SecureFile.isOwnerOnly(at: path)) }

            let destination = parent.appendingPathComponent("new-parent").appendingPathComponent("moved.json")
            try AtomicFile.rename(path, to: destination)
            #expect(try WindowsSecurePath.metadata(at: path) == nil)
            #expect(try PathSecurity.readNoFollow(
                destination,
                maximumBytes: 32_768,
                requireOwnerOnly: ownerOnly
            ) == replacement)

            try AtomicFile.write(path, contents: "replacement rename", options: options)
            try AtomicFile.rename(path, to: destination)
            #expect(try WindowsSecurePath.metadata(at: path) == nil)
            #expect(try PathSecurity.readNoFollow(
                destination,
                maximumBytes: 64,
                requireOwnerOnly: ownerOnly
            ) == Data("replacement rename".utf8))
            let entries = try WindowsSecurePath.contentsOfDirectory(
                at: parent,
                maximumEntries: 8,
                skipsHiddenFiles: false
            )
            #expect(entries.map(\.lastPathComponent) == ["new-parent"])
        }
    }

    @Test("Windows failed long-path replacement removes only its temp and preserves the directory")
    func windowsLongAtomicFailedReplaceCleansTemp() throws {
        let root = try tempDir()
        defer { cleanupWindowsFixture(root) }
        let parent = windowsLongDirectory(under: root)
        try #require(parent.path.utf16.count > 300)
        let blocked = parent.appendingPathComponent("existing-directory", isDirectory: true)
        let survivor = blocked.appendingPathComponent("keep.txt")
        try AtomicFile.write(survivor, contents: "keep")

        #expect(throws: FileUtilsError.self) {
            try AtomicFile.write(blocked, contents: "must not replace a directory")
        }
        #expect(try PathSecurity.readNoFollow(survivor) == Data("keep".utf8))
        let entries = try WindowsSecurePath.contentsOfDirectory(
            at: parent,
            maximumEntries: 8,
            skipsHiddenFiles: false
        )
        #expect(entries.map(\.lastPathComponent) == ["existing-directory"])
    }

    @Test("Windows hostile write and rename endpoints do not create parents or alter the source")
    func windowsHostileAtomicPathsHaveNoSideEffects() throws {
        let root = try tempDir()
        defer { cleanupWindowsFixture(root) }
        let source = root.appendingPathComponent("source.json")
        try AtomicFile.write(source, contents: "keep source")
        let names = [
            "CON.json", "AUX", "state.json:hidden", "state.json.",
            "state.json ", "state?.json", "ambiguous./state.json",
        ]

        for (index, name) in names.enumerated() {
            for noFollow in [false, true] {
                let parent = root.appendingPathComponent("write-\(index)-\(noFollow)")
                let path = parent.appendingPathComponent("nested").appendingPathComponent(name)
                expectWindowsHostilePath {
                    try AtomicFile.write(
                        path,
                        contents: "must not create anything",
                        options: AtomicWriteOptions(mode: 0o600, noFollowFinal: noFollow)
                    )
                }
                #expect(try WindowsSecurePath.metadata(at: parent) == nil)
            }

            let parent = root.appendingPathComponent("rename-\(index)")
            let invalidDestination = parent.appendingPathComponent("nested").appendingPathComponent(name)
            expectWindowsHostilePath { try AtomicFile.rename(source, to: invalidDestination) }
            #expect(try WindowsSecurePath.metadata(at: parent) == nil)

            let invalidSource = root.appendingPathComponent(name)
            let destination = parent.appendingPathComponent("nested").appendingPathComponent("valid.json")
            expectWindowsHostilePath { try AtomicFile.rename(invalidSource, to: destination) }
            #expect(try WindowsSecurePath.metadata(at: parent) == nil)
            #expect(try PathSecurity.readNoFollow(source) == Data("keep source".utf8))
        }
        let entries = try WindowsSecurePath.contentsOfDirectory(
            at: root,
            maximumEntries: 8,
            skipsHiddenFiles: false
        )
        #expect(entries.map(\.lastPathComponent) == ["source.json"])
    }

    @Test("Windows ordinary writes retain reparse and inherited-mode behavior while no-follow refuses links")
    func windowsAtomicReparseAndModeSemantics() throws {
        let root = try tempDir()
        defer { cleanupWindowsFixture(root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let inherited = real.appendingPathComponent("inherited.json")
        try Data("inherited ACL".utf8).write(to: inherited)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try #require(try WindowsSecurePath.metadata(at: link)?.isReparsePoint == true)

        let ordinary = link.appendingPathComponent("ordinary.json")
        try AtomicFile.write(ordinary, contents: "follow parent", options: AtomicWriteOptions(mode: 0o600))
        let actual = real.appendingPathComponent("ordinary.json")
        #expect(try PathSecurity.readNoFollow(actual) == Data("follow parent".utf8))
        #expect(try SecureFile.isOwnerOnly(at: actual) == SecureFile.isOwnerOnly(at: inherited))

        let rejectedParent = link.appendingPathComponent("must-not-create", isDirectory: true)
        do {
            try AtomicFile.write(rejectedParent.appendingPathComponent("private.json"), contents: "no", options: .ownerOnly)
            Issue.record("no-follow write accepted a reparse parent")
        } catch FileUtilsError.symlinkEncountered {
        } catch {
            Issue.record(error)
        }
        #expect(try WindowsSecurePath.metadata(at: real.appendingPathComponent("must-not-create")) == nil)

        let victim = root.appendingPathComponent("victim.json")
        try AtomicFile.write(victim, contents: "keep victim")
        let alias = root.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: victim)
        try #require(try WindowsSecurePath.metadata(at: alias)?.isReparsePoint == true)
        do {
            try AtomicFile.write(alias, contents: "no", options: .ownerOnly)
            Issue.record("no-follow write accepted a final reparse point")
        } catch FileUtilsError.symlinkEncountered {
        } catch {
            Issue.record(error)
        }
        try AtomicFile.write(alias, contents: "replace alias")
        #expect(try WindowsSecurePath.metadata(at: alias)?.isReparsePoint == false)
        #expect(try PathSecurity.readNoFollow(alias) == Data("replace alias".utf8))
        #expect(try PathSecurity.readNoFollow(victim) == Data("keep victim".utf8))
    }

    private func windowsLongDirectory(under root: URL) -> URL {
        var directory = root
        for index in 0..<5 {
            directory.appendPathComponent(String(repeating: "long-", count: 12) + "\(index)", isDirectory: true)
        }
        return directory
    }

    private func expectWindowsHostilePath(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("hostile Windows path reached atomic filesystem operations")
        } catch FileUtilsError.hostilePath {
        } catch {
            Issue.record(error)
        }
    }

    private func cleanupWindowsFixture(_ root: URL) {
        do { try removeWindowsFixture(root) }
        catch { Issue.record(error) }
    }

    private func removeWindowsFixture(_ path: URL) throws {
        guard let metadata = try WindowsSecurePath.metadata(at: path) else { return }
        if metadata.isDirectory && !metadata.isReparsePoint {
            for entry in try WindowsSecurePath.contentsOfDirectory(
                at: path,
                maximumEntries: 64,
                skipsHiddenFiles: false
            ) {
                try removeWindowsFixture(entry)
            }
        }
        let native = try WindowsSecurePath.extendedLengthPath(path.path)
        let removed = native.withCString(encodedAs: UTF16.self) { pointer in
            metadata.isDirectory ? RemoveDirectoryW(pointer) : DeleteFileW(pointer)
        }
        guard removed else {
            throw WindowsSecurePath.windowsError(
                path: path.path,
                operation: "clean up atomic-write fixture",
                code: GetLastError()
            )
        }
    }
    #endif

    @Test("atomic write with noFollow rejects parent symlink")
    func noFollowParentSymlink() throws {
        #if os(Windows)
        return
        #else
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let target = link.appendingPathComponent("secret.txt")
        #expect(throws: FileUtilsError.self) {
            try AtomicFile.write(
                target,
                contents: "nope",
                options: AtomicWriteOptions(mode: 0o600, noFollowFinal: true)
            )
        }
        #endif
    }

    @Test("atomic write with noFollow rejects final symlink replacement race target")
    func noFollowFinalSymlink() throws {
        #if os(Windows)
        return
        #else
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("victim")
        try AtomicFile.write(victim, contents: "keep-me")
        let link = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        // Writing through no-follow to the symlink path must not clobber victim
        // via following; renameat replaces the symlink itself or fails closed.
        try AtomicFile.write(
            link,
            contents: "new-body",
            options: AtomicWriteOptions(mode: 0o600, noFollowFinal: true)
        )
        // Victim body must remain intact if link was replaced as a new file,
        // or if write failed. After successful renameat onto the symlink name,
        // the name is a regular file and victim is untouched.
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep-me")
        #endif
    }

    @Test("directory sync policy required is the durable default")
    func directorySyncDefault() throws {
        let opts = AtomicWriteOptions()
        #expect(opts.directorySync == .required)
        let best = AtomicWriteOptions(directorySync: .bestEffort)
        #expect(best.directorySync == .bestEffort)
    }

    @Test("hostile path with .. is rejected before write")
    func hostileTraversalWrite() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("..").appendingPathComponent("escape.txt")
        // URL may normalize; construct a raw path string with ..
        let raw = URL(fileURLWithPath: dir.path + "/../escape-\(UUID().uuidString).txt")
        #expect(throws: FileUtilsError.self) {
            try AtomicFile.write(raw, contents: "x")
        }
        _ = path
    }

    // MARK: - Owner-only secure file

    @Test("secure file is owner-only")
    func secureOwnerOnly() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("auth.json")
        try SecureFile.write(at: path, contents: "token")
        #expect(try SecureFile.isOwnerOnly(at: path))
    }

    @Test("ensureOwnerOnly tightens world-readable file")
    func tightenPermissions() throws {
        #if os(Windows)
        return
        #else
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("loose.txt")
        try "secret".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        try SecureFile.ensureOwnerOnlyPermissions(at: path)
        #expect(try SecureFile.isOwnerOnly(at: path))
        #endif
    }

    @Test("ensureOwnerOnly ignores missing file")
    func ensureMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SecureFile.ensureOwnerOnlyPermissions(at: dir.appendingPathComponent("nope"))
    }

    @Test("ensureOwnerOnly refuses symlink final component")
    func ensureNoFollowSymlink() throws {
        #if os(Windows)
        return
        #else
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try "secret".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: FileUtilsError.self) {
            try SecureFile.ensureOwnerOnlyPermissions(at: link)
        }
        // Target must remain world-readable — chmod must not have followed the link.
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o644)
        #endif
    }

    // MARK: - Checksums

    @Test("sha256 matches NIST empty vector")
    func sha256Empty() {
        let hex = FileChecksum.sha256Hex(Data())
        #expect(hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("sha256 from file and verify")
    func sha256File() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("blob")
        try AtomicFile.write(path, data: Data("abc".utf8))
        let hex = try FileChecksum.sha256HexFromFile(at: path)
        #expect(hex == FileChecksum.sha256Hex("abc"))
        try FileChecksum.verifyFile(at: path, expectedHex: hex)
        #expect(throws: FileUtilsError.self) {
            try FileChecksum.verifyFile(at: path, expectedHex: "00")
        }
    }

    @Test("sha256 maxBytes truncates stream")
    func sha256MaxBytes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("big")
        try AtomicFile.write(path, data: Data("abcdef".utf8))
        let full = try FileChecksum.sha256HexFromFile(at: path)
        let partial = try FileChecksum.sha256HexFromFile(at: path, maxBytes: 3)
        #expect(partial == FileChecksum.sha256Hex("abc"))
        #expect(full != partial)
    }

    // MARK: - Advisory locks

    @Test("exclusive lock blocks non-blocking peer")
    func advisoryLockBusy() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("res.lock")
        let held = try AdvisoryFileLock.acquire(at: path)
        defer { held.release() }
        let peer = try AdvisoryFileLock.tryAcquire(at: path)
        #expect(peer == nil)
        held.release()
        let after = try AdvisoryFileLock.tryAcquire(at: path)
        #expect(after != nil)
        after?.release()
    }

    // MARK: - Path security

    @Test("reject NUL empty and traversal paths")
    func hostileLexical() throws {
        #expect(throws: FileUtilsError.self) {
            try PathSecurity.rejectHostileLexical("")
        }
        #expect(throws: FileUtilsError.self) {
            try PathSecurity.rejectHostileLexical("a\0b")
        }
        #expect(throws: FileUtilsError.self) {
            try PathSecurity.rejectHostileLexical("foo/../bar")
        }
        #expect(throws: FileUtilsError.self) {
            try PathSecurity.rejectHostileLexical("../etc/passwd")
        }
        try PathSecurity.rejectHostileLexical("/tmp/safe/file.txt")
    }

    @Test("canonicalize resolves existing path")
    func canonicalize() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("f")
        try AtomicFile.write(path, contents: "x")
        let canon = try PathSecurity.canonicalize(path)
        #expect(FileManager.default.fileExists(atPath: canon.path))
    }

    @Test("no-follow read rejects symlink final component")
    func noFollowSymlink() throws {
        #if os(Windows)
        return
        #else
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target")
        try AtomicFile.write(target, contents: "secret-body")
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try PathSecurity.isSymlink(link))
        #expect(throws: FileUtilsError.self) {
            _ = try PathSecurity.readNoFollow(link)
        }
        let data = try PathSecurity.readNoFollow(target)
        #expect(String(data: data, encoding: .utf8) == "secret-body")
        #endif
    }

    @Test("no-follow read rejects trailing parent symlink")
    func noFollowParentRead() throws {
        #if os(Windows)
        return
        #else
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = real.appendingPathComponent("f.txt")
        try AtomicFile.write(file, contents: "body")
        // Parent path's trailing component is a symlink → open(O_NOFOLLOW) fails.
        let link = dir.appendingPathComponent("linkdir")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let viaLink = link.appendingPathComponent("f.txt")
        #expect(throws: FileUtilsError.self) {
            _ = try PathSecurity.readNoFollow(viaLink)
        }
        #endif
    }

    @Test("hard link count reports multi-link files")
    func hardLinkCount() throws {
        #if os(Windows)
        return
        #else
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        let b = dir.appendingPathComponent("b")
        try AtomicFile.write(a, contents: "x")
        try FileManager.default.linkItem(at: a, to: b)
        #expect(try PathSecurity.hardLinkCount(a) >= 2)
        #endif
    }

    // MARK: - Workspace classifier

    @Test("temp directories are not project dirs")
    func workspaceClassifier() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WorkspaceClassifier.isProjectDir(dir) == false || dir.path.contains(".git"))
    }

    @Test("git ancestor marks project dir")
    func gitProject() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let nested = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(WorkspaceClassifier.isProjectDir(nested))
    }

    // MARK: - Concurrent writers

    @Test("concurrent atomic writers leave a complete final file")
    func concurrentWriters() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("shared.txt")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try AtomicFile.write(path, contents: "writer-\(i)-payload")
                }
            }
            try await group.waitForAll()
        }
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.hasPrefix("writer-"))
        #expect(text.hasSuffix("-payload"))
    }

    @Test("permission failure on unreadable parent surfaces typed error")
    func permissionFailure() throws {
        #if os(Windows)
        return
        #else
        // Best-effort: only meaningful when not running as root.
        let dir = try tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let nested = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)
        let path = nested.appendingPathComponent("x.txt")
        let uid = getuid()
        if uid == 0 {
            // Root bypasses mode bits; skip assertion.
            return
        }
        #expect(throws: FileUtilsError.self) {
            try AtomicFile.write(
                path,
                contents: "x",
                options: AtomicWriteOptions(noFollowFinal: true)
            )
        }
        #endif
    }
}
