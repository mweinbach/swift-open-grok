// OpenGrokGitStatusTests.swift
//
// Thread-budget table tests (xai-gix-status) and pure-path status fixtures
// covering staged/unstaged/untracked/ignored/rename/type-change/conflict/
// submodule/bare/detached/sparse/linked-worktree.

import Foundation
import Testing
@testable import OpenGrokGitStatus

@Suite("OpenGrokGitStatus")
struct OpenGrokGitStatusTests {

    @Test("compute_from_table matches Rust")
    func computeFromTable() {
        let cases: [(Int, Int?, Int, Int)] = [
            (16, nil, 1, 8),
            (4, nil, 1, 4),
            (1, nil, 1, 1),
            (0, nil, 1, 1),
            (16, 100, 1, 8),
            (16, 20, 10, 2),
            (16, 19, 10, 1),
            (16, 18, 10, 1),
            (16, 10, 10, 1),
            (16, 8, 0, 1),
            (16, 9, 0, 1),
            (16, 10, 0, 2),
            (32, 25, 5, 8),
            (3, 25, 5, 3),
        ]
        for (cores, soft, used, want) in cases {
            let got = computeGixStatusThreadLimit(cores: cores, softNproc: soft, threadsUsed: used)
            #expect(got == want, "cores=\(cores) soft=\(String(describing: soft)) used=\(used)")
            #expect(got >= 1)
        }
    }

    @Test("parse_env_thread_override table")
    func parseEnvTable() {
        let cases: [(String, Int?)] = [
            ("", nil),
            ("0", nil),
            ("00", nil),
            ("1", 1),
            ("8", 8),
            ("16", 16),
            ("abc", nil),
            ("-1", nil),
            ("1.5", nil),
            (" 1", nil),
            ("1 ", nil),
        ]
        for (raw, want) in cases {
            #expect(parseEnvThreadOverride(raw) == want, "raw=\(raw)")
        }
    }

    @Test("production compute always ge one")
    func productionGeOne() {
        #expect(computeGixStatusThreadLimit() >= 1)
        #expect(budgetedStatusThreadLimit() >= 1)
    }

    @Test("env override OPENGROK_GIX_STATUS_THREADS")
    func envOverride() {
        #expect(
            computeGixStatusThreadLimit(environment: ["OPENGROK_GIX_STATUS_THREADS": "3"]) == 3
        )
        #expect(
            computeGixStatusThreadLimit(environment: ["GROK_GIX_STATUS_THREADS": "2"]) == 2
        )
    }

    @Test("git blob sha1 known vector")
    func blobSha1() {
        let data = Data("hello".utf8)
        let oid = gitBlobSHA1(data)
        #expect(oid.count == 20)
        let hex = oid.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
    }

    @Test("not a repository errors")
    func notARepo() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-not-repo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            _ = try gitStatus(path: temp.path)
            Issue.record("expected notARepository")
        } catch GitStatusError.notARepository {
            // ok
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("pure status: untracked and clean seed")
    func pureStatusUntracked() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        try "extra".write(
            to: root.appendingPathComponent("extra.txt"),
            atomically: true,
            encoding: .utf8
        )
        let snap = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: true, includeIgnored: false)
        )
        #expect(snap.root == root.path)
        #expect(snap.untracked.contains { $0.path == "extra.txt" })
        #expect(!snap.isBare)
    }

    @Test("pure status: ignored via .gitignore")
    func pureStatusIgnored() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try "build/\n".write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("build"),
            withIntermediateDirectories: true
        )
        try "x".write(
            to: root.appendingPathComponent("build/out.bin"),
            atomically: true,
            encoding: .utf8
        )
        let snap = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: true, includeIgnored: true)
        )
        #expect(snap.ignored.contains { $0.path == "build/out.bin" })
    }

    @Test("pure status: bare repository")
    func bareRepo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ref: refs/heads/main\n".write(
            to: root.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("objects"),
            withIntermediateDirectories: true
        )
        try "[core]\n\tbare = true\n".write(
            to: root.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        let snap = try gitStatus(path: root.path)
        #expect(snap.isBare)
        #expect(snap.entries.isEmpty)
    }

    @Test("pure status: linked worktree gitdir pointer")
    func linkedWorktree() throws {
        let main = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-main-\(UUID().uuidString)")
        let wt = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: main)
            try? FileManager.default.removeItem(at: wt)
        }
        let gitDir = main.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: gitDir.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: \(gitDir.path)\n".write(
            to: wt.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let snap = try gitStatus(path: wt.path)
        #expect(snap.isLinkedWorktree)
    }

    @Test("index parser empty and corrupt")
    func indexParserEdges() {
        do {
            _ = try parseGitIndex(data: Data())
            Issue.record("expected corruptIndex for empty data")
        } catch GitStatusError.corruptIndex {
            // expected
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("index parser rejects bad signature")
    func indexBadSig() {
        do {
            _ = try parseGitIndex(data: Data("XXXX".utf8) + Data(repeating: 0, count: 20))
            Issue.record("expected corrupt")
        } catch GitStatusError.corruptIndex {
            // ok
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - Object store + staged status fixtures

    @Test("object store round-trip blob/tree/commit and staged add")
    func stagedAddViaObjects() throws {
        let root = try makeRepoWithHead(files: ["hello.txt": "hello\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        // Stage a new file by writing content + updating index.
        let newContent = Data("world\n".utf8)
        let newOID = gitBlobSHA1(newContent)
        _ = try writeLooseObject(gitDir: gitDir, type: "blob", payload: newContent)
        try "world\n".write(
            to: root.appendingPathComponent("world.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Rebuild index: old hello + new world.
        let store = GitObjectStore(gitDir: gitDir)
        let meta = try readRepoMeta(gitDir: gitDir, worktreeRoot: root.path)
        let headTree = try store.loadHeadTree(headCommitHex: meta.headCommit)
        #expect(headTree["hello.txt"] != nil)

        var indexEntries: [GitIndexEntry] = []
        for (path, entry) in headTree {
            let abs = root.appendingPathComponent(path)
            let size = (try? Data(contentsOf: abs).count) ?? 0
            indexEntries.append(GitIndexEntry(
                path: path,
                mode: entry.mode,
                stage: 0,
                sha1: entry.oid,
                size: UInt32(size),
                mtimeSeconds: 0,
                mtimeNanoseconds: 0,
                ctimeSeconds: 0,
                ctimeNanoseconds: 0,
                dev: 0, ino: 0, uid: 0, gid: 0,
                flags: 0
            ))
        }
        indexEntries.append(GitIndexEntry(
            path: "world.txt",
            mode: 0o100644,
            stage: 0,
            sha1: newOID,
            size: UInt32(newContent.count),
            mtimeSeconds: 0, mtimeNanoseconds: 0,
            ctimeSeconds: 0, ctimeNanoseconds: 0,
            dev: 0, ino: 0, uid: 0, gid: 0,
            flags: 0
        ))
        let indexData = encodeGitIndex(entries: indexEntries)
        try indexData.write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("index"))

        let snap = try gitStatus(path: root.path)
        #expect(snap.staged.contains { $0.path == "world.txt" && $0.status == .added })
        #expect(snap.headCommit != nil)
    }

    @Test("staged modify when index oid differs from HEAD")
    func stagedModify() throws {
        let root = try makeRepoWithHead(files: ["f.txt": "base\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path
        let store = GitObjectStore(gitDir: gitDir)
        let meta = try readRepoMeta(gitDir: gitDir, worktreeRoot: root.path)
        let headTree = try store.loadHeadTree(headCommitHex: meta.headCommit)

        let newContent = Data("staged\n".utf8)
        let newOID = try writeLooseObject(gitDir: gitDir, type: "blob", payload: newContent)
        try "staged\n".write(to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let head = headTree["f.txt"]!
        let entry = GitIndexEntry(
            path: "f.txt",
            mode: head.mode,
            stage: 0,
            sha1: newOID,
            size: UInt32(newContent.count),
            mtimeSeconds: 0, mtimeNanoseconds: 0,
            ctimeSeconds: 0, ctimeNanoseconds: 0,
            dev: 0, ino: 0, uid: 0, gid: 0,
            flags: 0
        )
        try encodeGitIndex(entries: [entry])
            .write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("index"))

        let snap = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: false)
        )
        #expect(snap.staged.contains { $0.path == "f.txt" && $0.status == .modified })
    }

    @Test("staged delete when path in HEAD missing from index")
    func stagedDelete() throws {
        let root = try makeRepoWithHead(files: ["gone.txt": "x\n", "keep.txt": "y\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path
        let store = GitObjectStore(gitDir: gitDir)
        let meta = try readRepoMeta(gitDir: gitDir, worktreeRoot: root.path)
        let headTree = try store.loadHeadTree(headCommitHex: meta.headCommit)

        // Index only keep.txt
        let keep = headTree["keep.txt"]!
        let entry = GitIndexEntry(
            path: "keep.txt", mode: keep.mode, stage: 0, sha1: keep.oid,
            size: 2, mtimeSeconds: 0, mtimeNanoseconds: 0,
            ctimeSeconds: 0, ctimeNanoseconds: 0,
            dev: 0, ino: 0, uid: 0, gid: 0, flags: 0
        )
        try encodeGitIndex(entries: [entry])
            .write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("index"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))

        let snap = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: false)
        )
        #expect(snap.staged.contains { $0.path == "gone.txt" && $0.status == .deleted })
    }

    @Test("unstaged modify when worktree differs from index")
    func unstagedModify() throws {
        let root = try makeRepoWithHead(files: ["u.txt": "base\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        // Index matches HEAD; dirty worktree.
        try "dirty\n".write(
            to: root.appendingPathComponent("u.txt"),
            atomically: true,
            encoding: .utf8
        )
        let snap = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: false)
        )
        #expect(snap.unstaged.contains { $0.path == "u.txt" && $0.status == .modified })
    }

    @Test("conflict stages surface as unmerged")
    func conflictStages() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path
        let oid = gitBlobSHA1(Data("x\n".utf8))
        _ = try writeLooseObject(gitDir: gitDir, type: "blob", payload: Data("x\n".utf8))
        let stages = [1, 2, 3].map { stage in
            GitIndexEntry(
                path: "c.txt", mode: 0o100644, stage: stage, sha1: oid,
                size: 2, mtimeSeconds: 0, mtimeNanoseconds: 0,
                ctimeSeconds: 0, ctimeNanoseconds: 0,
                dev: 0, ino: 0, uid: 0, gid: 0, flags: 0
            )
        }
        try encodeGitIndex(entries: stages)
            .write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("index"))
        let snap = try gitStatus(path: root.path)
        #expect(snap.conflicts.contains { $0.path == "c.txt" && $0.status == .unmerged })
        #expect(snap.conflicts.first?.conflictStages == [1, 2, 3])
    }

    @Test("detached HEAD meta")
    func detachedHead() throws {
        let root = try makeRepoWithHead(files: ["d.txt": "d\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git")
        let meta = try readRepoMeta(gitDir: gitDir.path, worktreeRoot: root.path)
        guard let commit = meta.headCommit else {
            Issue.record("missing head")
            return
        }
        // Detach: write raw OID to HEAD
        try "\(commit)\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let snap = try gitStatus(path: root.path)
        #expect(snap.isDetached)
        #expect(snap.headCommit == commit)
        #expect(snap.branch == nil)
    }

    @Test("sparse checkout flag")
    func sparseCheckout() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(
            at: gitDir.appendingPathComponent("info"),
            withIntermediateDirectories: true
        )
        try "/*\n".write(
            to: gitDir.appendingPathComponent("info/sparse-checkout"),
            atomically: true,
            encoding: .utf8
        )
        try "[core]\n\tsparseCheckout = true\n".write(
            to: gitDir.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )
        let snap = try gitStatus(path: root.path)
        #expect(snap.isSparseCheckout)
    }

    @Test("submodule gitlink in index")
    func submoduleGitlink() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path
        let oid = Data(repeating: 0xAB, count: 20)
        let entry = GitIndexEntry(
            path: "vendor/lib",
            mode: 0o160000,
            stage: 0,
            sha1: oid,
            size: 0,
            mtimeSeconds: 0, mtimeNanoseconds: 0,
            ctimeSeconds: 0, ctimeNanoseconds: 0,
            dev: 0, ino: 0, uid: 0, gid: 0, flags: 0
        )
        try encodeGitIndex(entries: [entry])
            .write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("index"))
        // Missing worktree submodule → unstaged delete + staged add (no HEAD)
        let snap = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: false)
        )
        #expect(snap.entries.contains { $0.isSubmodule && $0.path == "vendor/lib" })
    }

    @Test("index v2 encode/parse round trip")
    func indexRoundTrip() throws {
        let oid = gitBlobSHA1(Data("hi".utf8))
        let entry = GitIndexEntry(
            path: "a/b.txt", mode: 0o100644, stage: 0, sha1: oid,
            size: 2, mtimeSeconds: 1, mtimeNanoseconds: 2,
            ctimeSeconds: 3, ctimeNanoseconds: 4,
            dev: 5, ino: 6, uid: 7, gid: 8, flags: 0
        )
        let data = encodeGitIndex(entries: [entry])
        let parsed = try parseGitIndex(data: data)
        #expect(parsed.version == 2)
        #expect(parsed.entries.count == 1)
        #expect(parsed.entries[0].path == "a/b.txt")
        #expect(parsed.entries[0].sha1 == oid)
        #expect(parsed.entries[0].mode == 0o100644)
    }

    @Test("staged rename detection pairs delete+add same oid")
    func stagedRename() throws {
        let root = try makeRepoWithHead(files: ["old.txt": "same\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path
        let store = GitObjectStore(gitDir: gitDir)
        let meta = try readRepoMeta(gitDir: gitDir, worktreeRoot: root.path)
        let headTree = try store.loadHeadTree(headCommitHex: meta.headCommit)
        let oid = headTree["old.txt"]!.oid

        // Index has only new.txt with same oid (rename)
        try "same\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("old.txt"))
        let entry = GitIndexEntry(
            path: "new.txt", mode: 0o100644, stage: 0, sha1: oid,
            size: 5, mtimeSeconds: 0, mtimeNanoseconds: 0,
            ctimeSeconds: 0, ctimeNanoseconds: 0,
            dev: 0, ino: 0, uid: 0, gid: 0, flags: 0
        )
        try encodeGitIndex(entries: [entry])
            .write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("index"))

        let snap = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: false)
        )
        #expect(snap.staged.contains {
            $0.status == .renamed && $0.path == "new.txt" && $0.otherPath == "old.txt"
        })
    }
}

// MARK: - Helpers

/// Minimal fake repo: `.git` + empty index + one untracked-ready worktree file.
private func makeSeedRepo() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("og-seed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let git = root.appendingPathComponent(".git")
    try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: git.appendingPathComponent("objects"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: git.appendingPathComponent("refs/heads"),
        withIntermediateDirectories: true
    )
    try "ref: refs/heads/main\n".write(
        to: git.appendingPathComponent("HEAD"),
        atomically: true,
        encoding: .utf8
    )
    return root
}

/// Build a pure-path repo with real loose objects, HEAD commit, and matching index.
private func makeRepoWithHead(files: [String: String]) throws -> URL {
    let root = try makeSeedRepo()
    let gitDir = root.appendingPathComponent(".git").path

    var treeEntries: [(mode: UInt32, name: String, oid: Data)] = []
    var indexEntries: [GitIndexEntry] = []

    for (path, content) in files.sorted(by: { $0.key < $1.key }) {
        let data = Data(content.utf8)
        let oid = try writeLooseObject(gitDir: gitDir, type: "blob", payload: data)
        try content.write(
            to: root.appendingPathComponent(path),
            atomically: true,
            encoding: .utf8
        )
        // Flat tree only (no nested dirs in helper).
        let name = path
        treeEntries.append((0o100644, name, oid))
        indexEntries.append(GitIndexEntry(
            path: path,
            mode: 0o100644,
            stage: 0,
            sha1: oid,
            size: UInt32(data.count),
            mtimeSeconds: 0, mtimeNanoseconds: 0,
            ctimeSeconds: 0, ctimeNanoseconds: 0,
            dev: 0, ino: 0, uid: 0, gid: 0, flags: 0
        ))
    }

    let treePayload = encodeGitTree(treeEntries)
    let treeOID = try writeLooseObject(gitDir: gitDir, type: "tree", payload: treePayload)
    let commitPayload = encodeGitCommit(treeOID: treeOID, message: "seed\n")
    let commitOID = try writeLooseObject(gitDir: gitDir, type: "commit", payload: commitPayload)
    let hex = GitObjectStore.hexFromOID(commitOID)

    try "\(hex)\n".write(
        to: URL(fileURLWithPath: gitDir)
            .appendingPathComponent("refs/heads/main"),
        atomically: true,
        encoding: .utf8
    )
    try encodeGitIndex(entries: indexEntries)
        .write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("index"))

    return root
}
