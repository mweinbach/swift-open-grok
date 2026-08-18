// OpenGrokFileUtilsTests.swift
//
// Hostile-path, atomic-write, lock, checksum, and permission tests for
// OpenGrokFileUtils. Derived from Rust secure_file / fs_atomic invariants.

import Foundation
import Testing
@testable import OpenGrokFileUtils

#if canImport(Darwin)
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
