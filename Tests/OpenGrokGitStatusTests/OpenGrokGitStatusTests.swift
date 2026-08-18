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

    @Test("minimal glob supports literals star and question")
    func minimalGlob() {
        #expect(globMatch("config.rc", "config.rc"))
        #expect(!globMatch("config.rc", "config.toml"))
        #expect(globMatch("*.swift", "main.swift"))
        #expect(globMatch("src/*.swift", "src/nested/main.swift"))
        #expect(globMatch("file?.txt", "file1.txt"))
        #expect(globMatch("?.txt", "é.txt"))
        #expect(!globMatch("file?.txt", "file10.txt"))
        #expect(globMatch("a**b", "axxb"))
    }

    @Test("portable SHA-1 empty and multi-chunk match single buffer")
    func portableSHA1Parity() {
        let empty = PortableSHA1.hash(Data())
        #expect(empty.map { String(format: "%02x", $0) }.joined() == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        let a = Data("abc".utf8)
        #expect(
            PortableSHA1.hash(a).map { String(format: "%02x", $0) }.joined()
                == "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
        #expect(PortableSHA1.hash(Data("ab".utf8), Data("c".utf8)) == PortableSHA1.hash(a))
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
        #if os(Windows)
        #expect(snap.root.lowercased() == root.path.lowercased())
        #else
        #expect(snap.root == root.path)
        #endif
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

@Suite("Packed Git Objects")
struct PackedGitObjectTests {
    @Test("non-delta packed objects match loose objects through live status")
    func nonDeltaPackedParity() throws {
        let root = try makeRepoWithHead(files: ["hello.txt": "hello\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        let blob = PackedFixtureObject.object(type: "blob", payload: Data("hello\n".utf8))
        let treePayload = encodeGitTree([(0o100644, "hello.txt", blob.oid)])
        let tree = PackedFixtureObject.object(type: "tree", payload: treePayload)
        let commit = PackedFixtureObject.object(
            type: "commit",
            payload: encodeGitCommit(treeOID: tree.oid, message: "seed\n")
        )
        let objects = [blob, tree, commit]

        let looseStore = GitObjectStore(gitDir: gitDir)
        let looseObjects = try objects.map { try looseStore.readObject(oid: $0.oid) }
        let looseStatus = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: false)
        )

        let fixture = try writePackFixture(gitDir: gitDir, objects: objects)
        #expect(FileManager.default.fileExists(atPath: fixture.packURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.indexURL.path))
        try removeLooseObjects(gitDir: gitDir, oids: objects.map(\.oid))

        let packedStore = GitObjectStore(gitDir: gitDir)
        let packedObjects = try objects.map { try packedStore.readObject(oid: $0.oid) }
        for index in objects.indices {
            #expect(packedObjects[index].type == looseObjects[index].type)
            #expect(packedObjects[index].payload == looseObjects[index].payload)
        }
        let packedStatus = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: false)
        )
        #expect(packedStatus == looseStatus)

        try "dirty\n".write(
            to: root.appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8
        )
        let dirtyStatus = try gitStatus(
            path: root.path,
            options: GitStatusOptions(includeUntracked: false)
        )
        #expect(dirtyStatus.unstaged.contains { $0.path == "hello.txt" && $0.status == .modified })
    }

    @Test("pack index checksum corruption is typed")
    func corruptPackIndex() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path
        let object = PackedFixtureObject.object(type: "blob", payload: Data("hello\n".utf8))
        let fixture = try writePackFixture(gitDir: gitDir, objects: [object])
        var indexData = try Data(contentsOf: fixture.indexURL)
        indexData[indexData.count - 1] ^= 0xFF
        try indexData.write(to: fixture.indexURL)

        do {
            _ = try GitObjectStore(gitDir: gitDir).readObject(oid: object.oid)
            Issue.record("expected corruptPackIndex")
        } catch GitStatusError.corruptPackIndex(let path, let reason) {
            #expect(path == fixture.indexURL.path)
            #expect(reason.contains("checksum"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("packed object declared size is bounded before inflate")
    func packedObjectSizeBound() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path
        let object = PackedFixtureObject.object(
            type: "blob",
            payload: Data("tiny".utf8),
            declaredSize: 1_024
        )
        let fixture = try writePackFixture(gitDir: gitDir, objects: [object])
        #expect(FileManager.default.fileExists(atPath: fixture.packURL.path))

        do {
            _ = try GitObjectStore(gitDir: gitDir, maximumPackedObjectSize: 8)
                .readObject(oid: object.oid)
            Issue.record("expected packedObjectTooLarge")
        } catch GitStatusError.packedObjectTooLarge(let oid, let declaredSize, let limit) {
            #expect(oid == GitObjectStore.hexFromOID(object.oid))
            #expect(declaredSize == 1_024)
            #expect(limit == 8)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("packed object corrupt zlib stream is typed")
    func packedObjectCorruptInflate() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path
        let object = PackedFixtureObject.object(
            type: "blob",
            payload: Data("hello\n".utf8),
            compressed: Data([0x78, 0x9C, 0x00])
        )
        let fixture = try writePackFixture(gitDir: gitDir, objects: [object])

        do {
            _ = try GitObjectStore(gitDir: gitDir).readObject(oid: object.oid)
            Issue.record("expected corruptPack")
        } catch GitStatusError.corruptPack(let path, let reason) {
            #expect(path == fixture.packURL.path)
            #expect(reason.contains("zlib"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("OFS_DELTA and REF_DELTA resolve to expected content")
    func packedDeltaResolution() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        let base = PackedFixtureObject.object(type: "blob", payload: Data("base\n".utf8))
        let offsetResult = Data("offset\n".utf8)
        let referenceResult = Data("reference\n".utf8)
        let offsetDelta = PackedFixtureObject.delta(
            resultType: "blob",
            resultPayload: offsetResult,
            deltaPayload: encodeInsertDelta(baseSize: base.payload.count, result: offsetResult),
            storage: .offset(baseIndex: 0)
        )
        let referenceDelta = PackedFixtureObject.delta(
            resultType: "blob",
            resultPayload: referenceResult,
            deltaPayload: encodeInsertDelta(baseSize: base.payload.count, result: referenceResult),
            storage: .reference(baseOID: base.oid)
        )
        let fixture = try writePackFixture(
            gitDir: gitDir,
            objects: [base, offsetDelta, referenceDelta]
        )
        #expect(FileManager.default.fileExists(atPath: fixture.indexURL.path))

        let store = GitObjectStore(gitDir: gitDir)
        for (object, expectedPayload) in [
            (offsetDelta, offsetResult),
            (referenceDelta, referenceResult),
        ] {
            let result = try store.readObject(oid: object.oid)
            #expect(result.type == "blob")
            #expect(result.payload == expectedPayload)
        }
    }
}

@Suite("Packed Git Delta Resolution")
struct PackedGitDeltaTests {

    @Test("copy-from-base delta instruction produces correct result")
    func copyFromBaseDelta() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        let baseContent = Data("Hello, World!\n".utf8)
        let base = PackedFixtureObject.object(type: "blob", payload: baseContent)

        let resultContent = Data("Hello, Swift!\n".utf8)
        let deltaPayload = encodeCopyInsertDelta(
            baseSize: baseContent.count,
            copyOffset: 0, copySize: 7,
            insert: Data("Swift!\n".utf8)
        )
        let delta = PackedFixtureObject.delta(
            resultType: "blob",
            resultPayload: resultContent,
            deltaPayload: deltaPayload,
            storage: .offset(baseIndex: 0)
        )

        _ = try writePackFixture(gitDir: gitDir, objects: [base, delta])
        let result = try GitObjectStore(gitDir: gitDir).readObject(oid: delta.oid)
        #expect(result.type == "blob")
        #expect(result.payload == resultContent)
    }

    @Test("nested two-deep OFS_DELTA chain resolves correctly")
    func nestedDeltaChain() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        let aContent = Data("aaa".utf8)
        let bContent = Data("bbb\n".utf8)
        let cContent = Data("ccc\n\n".utf8)
        let a = PackedFixtureObject.object(type: "blob", payload: aContent)
        let b = PackedFixtureObject.delta(
            resultType: "blob", resultPayload: bContent,
            deltaPayload: encodeInsertDelta(baseSize: aContent.count, result: bContent),
            storage: .offset(baseIndex: 0)
        )
        let c = PackedFixtureObject.delta(
            resultType: "blob", resultPayload: cContent,
            deltaPayload: encodeInsertDelta(baseSize: bContent.count, result: cContent),
            storage: .offset(baseIndex: 1)
        )

        _ = try writePackFixture(gitDir: gitDir, objects: [a, b, c])
        let store = GitObjectStore(gitDir: gitDir)
        let bResult = try store.readObject(oid: b.oid)
        #expect(bResult.type == "blob")
        #expect(bResult.payload == bContent)

        let cResult = try store.readObject(oid: c.oid)
        #expect(cResult.type == "blob")
        #expect(cResult.payload == cContent)
    }

    @Test("delta chain exceeding depth limit refuses with typed error")
    func deltaChainTooDeep() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        let aContent = Data("aaa".utf8)
        let bContent = Data("bbb\n".utf8)
        let cContent = Data("ccc\n\n".utf8)
        let a = PackedFixtureObject.object(type: "blob", payload: aContent)
        let b = PackedFixtureObject.delta(
            resultType: "blob", resultPayload: bContent,
            deltaPayload: encodeInsertDelta(baseSize: aContent.count, result: bContent),
            storage: .offset(baseIndex: 0)
        )
        let c = PackedFixtureObject.delta(
            resultType: "blob", resultPayload: cContent,
            deltaPayload: encodeInsertDelta(baseSize: bContent.count, result: cContent),
            storage: .offset(baseIndex: 1)
        )

        _ = try writePackFixture(gitDir: gitDir, objects: [a, b, c])

        let shallow = GitObjectStore(gitDir: gitDir, maximumDeltaChainDepth: 1)
        let bResult = try shallow.readObject(oid: b.oid)
        #expect(bResult.type == "blob")
        #expect(bResult.payload == bContent)

        do {
            _ = try shallow.readObject(oid: c.oid)
            Issue.record("expected packedDeltaChainTooDeep")
        } catch GitStatusError.packedDeltaChainTooDeep(_, let depth, let limit) {
            #expect(depth == 2)
            #expect(limit == 1)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("delta result exceeding size limit is refused")
    func deltaResultTooLarge() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        let baseContent = Data("x".utf8)
        let base = PackedFixtureObject.object(type: "blob", payload: baseContent)
        let bigResult = Data(repeating: 0x41, count: 64)
        let delta = PackedFixtureObject.delta(
            resultType: "blob", resultPayload: bigResult,
            deltaPayload: encodeInsertDelta(baseSize: baseContent.count, result: bigResult),
            storage: .offset(baseIndex: 0)
        )

        _ = try writePackFixture(gitDir: gitDir, objects: [base, delta])
        let tiny = GitObjectStore(gitDir: gitDir, maximumPackedObjectSize: 8)
        do {
            _ = try tiny.readObject(oid: delta.oid)
            Issue.record("expected packedObjectTooLarge")
        } catch GitStatusError.packedObjectTooLarge(_, _, let limit) {
            #expect(limit == 8)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("corrupt OFS_DELTA base offset is refused")
    func corruptDeltaBaseOffset() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        let baseContent = Data("base".utf8)
        let resultContent = Data("result".utf8)
        let base = PackedFixtureObject.object(type: "blob", payload: baseContent)
        let badDelta = PackedFixtureObject.delta(
            resultType: "blob", resultPayload: resultContent,
            deltaPayload: encodeInsertDelta(baseSize: baseContent.count, result: resultContent),
            storage: .offset(baseIndex: 0)
        )

        let packDir = URL(fileURLWithPath: gitDir)
            .appendingPathComponent("objects/pack", isDirectory: true)
        try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)

        var pack = Data("PACK".utf8)
        pack.appendBigEndianUInt32(2)
        pack.appendBigEndianUInt32(2)

        let baseOffset = UInt64(pack.count)
        let baseEntry = encodePackObjectHeader(typeCode: 3, size: UInt64(baseContent.count))
        let baseCompressed = try deflateZlib(baseContent)
        pack.append(baseEntry)
        pack.append(baseCompressed)

        let deltaOffset = UInt64(pack.count)
        let deltaInstructions = encodeInsertDelta(baseSize: baseContent.count, result: resultContent)
        let deltaHeader = encodePackObjectHeader(typeCode: 6, size: UInt64(deltaInstructions.count))
        let bogusDistance = deltaOffset + 100
        let bogusRef = encodeOffsetDeltaDistance(bogusDistance)
        let deltaCompressed = try deflateZlib(deltaInstructions)
        pack.append(deltaHeader)
        pack.append(bogusRef)
        pack.append(deltaCompressed)

        let packChecksum = PortableSHA1.hash(pack)
        pack.append(packChecksum)

        let stem = "pack-\(GitObjectStore.hexFromOID(packChecksum))"
        let packURL = packDir.appendingPathComponent(stem).appendingPathExtension("pack")
        try pack.write(to: packURL)

        let sorted = [
            (base, baseOffset, gitCRC32(Data(pack[Int(baseOffset)..<Int(deltaOffset)]))),
            (badDelta, deltaOffset, gitCRC32(Data(pack[Int(deltaOffset)..<(pack.count - 20)])))
        ].sorted { $0.0.oid.lexicographicallyPrecedes($1.0.oid) }

        var index = Data([0xFF, 0x74, 0x4F, 0x63])
        index.appendBigEndianUInt32(2)
        var counts = [UInt32](repeating: 0, count: 256)
        for s in sorted { counts[Int(s.0.oid[0])] += 1 }
        var cumulative: UInt32 = 0
        for c in counts { cumulative += c; index.appendBigEndianUInt32(cumulative) }
        for s in sorted { index.append(s.0.oid) }
        for s in sorted { index.appendBigEndianUInt32(s.2) }
        for s in sorted { index.appendBigEndianUInt32(UInt32(s.1)) }
        index.append(packChecksum)
        index.append(PortableSHA1.hash(index))
        let indexURL = packDir.appendingPathComponent(stem).appendingPathExtension("idx")
        try index.write(to: indexURL)

        do {
            _ = try GitObjectStore(gitDir: gitDir).readObject(oid: badDelta.oid)
            Issue.record("expected packedDeltaCorrupt")
        } catch GitStatusError.packedDeltaCorrupt(_, let reason) {
            #expect(reason.contains("offset"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("non-delta packed objects still resolve after delta support")
    func nonDeltaRegression() throws {
        let root = try makeSeedRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDir = root.appendingPathComponent(".git").path

        let blob = PackedFixtureObject.object(type: "blob", payload: Data("hello\n".utf8))
        _ = try writePackFixture(gitDir: gitDir, objects: [blob])
        let result = try GitObjectStore(gitDir: gitDir).readObject(oid: blob.oid)
        #expect(result.type == "blob")
        #expect(result.payload == Data("hello\n".utf8))
    }
}

// MARK: - Helpers

private enum PackedFixtureStorage {
    case object(typeCode: UInt8)
    case offset(baseIndex: Int)
    case reference(baseOID: Data)
}

private struct PackedFixtureObject {
    var oid: Data
    var payload: Data
    var declaredSize: UInt64
    var compressed: Data?
    var storage: PackedFixtureStorage

    static func object(
        type: String,
        payload: Data,
        declaredSize: UInt64? = nil,
        compressed: Data? = nil
    ) -> PackedFixtureObject {
        PackedFixtureObject(
            oid: gitObjectOID(type: type, payload: payload),
            payload: payload,
            declaredSize: declaredSize ?? UInt64(payload.count),
            compressed: compressed,
            storage: .object(typeCode: packTypeCode(type))
        )
    }

    static func delta(
        resultType: String,
        resultPayload: Data,
        deltaPayload: Data,
        storage: PackedFixtureStorage
    ) -> PackedFixtureObject {
        PackedFixtureObject(
            oid: gitObjectOID(type: resultType, payload: resultPayload),
            payload: deltaPayload,
            declaredSize: UInt64(deltaPayload.count),
            compressed: nil,
            storage: storage
        )
    }
}

private struct PackFixtureURLs {
    var packURL: URL
    var indexURL: URL
}

private func writePackFixture(
    gitDir: String,
    objects: [PackedFixtureObject]
) throws -> PackFixtureURLs {
    var pack = Data("PACK".utf8)
    pack.appendBigEndianUInt32(2)
    pack.appendBigEndianUInt32(UInt32(objects.count))

    var records: [(object: PackedFixtureObject, offset: UInt64, crc32: UInt32)] = []
    records.reserveCapacity(objects.count)
    for (index, object) in objects.enumerated() {
        let offset = UInt64(pack.count)
        let typeCode: UInt8
        var baseReference = Data()
        switch object.storage {
        case .object(let code):
            typeCode = code
        case .offset(let baseIndex):
            typeCode = 6
            precondition(baseIndex >= 0 && baseIndex < index)
            let distance = offset - records[baseIndex].offset
            baseReference = encodeOffsetDeltaDistance(distance)
        case .reference(let baseOID):
            typeCode = 7
            baseReference = baseOID
        }

        var entry = encodePackObjectHeader(typeCode: typeCode, size: object.declaredSize)
        entry.append(baseReference)
        let compressed = try object.compressed ?? deflateZlib(object.payload)
        entry.append(compressed)
        pack.append(entry)
        records.append((object, offset, gitCRC32(entry)))
    }

    let packChecksum = PortableSHA1.hash(pack)
    pack.append(packChecksum)
    let stem = "pack-\(GitObjectStore.hexFromOID(packChecksum))"
    let packDirectory = URL(fileURLWithPath: gitDir)
        .appendingPathComponent("objects/pack", isDirectory: true)
    try FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)
    let packURL = packDirectory.appendingPathComponent(stem).appendingPathExtension("pack")
    try pack.write(to: packURL)

    let sorted = records.sorted { $0.object.oid.lexicographicallyPrecedes($1.object.oid) }
    var index = Data([0xFF, 0x74, 0x4F, 0x63])
    index.appendBigEndianUInt32(2)
    var counts = [UInt32](repeating: 0, count: 256)
    for record in sorted {
        counts[Int(record.object.oid[0])] += 1
    }
    var cumulative: UInt32 = 0
    for count in counts {
        cumulative += count
        index.appendBigEndianUInt32(cumulative)
    }
    for record in sorted {
        index.append(record.object.oid)
    }
    for record in sorted {
        index.appendBigEndianUInt32(record.crc32)
    }
    for record in sorted {
        precondition(record.offset < 0x8000_0000)
        index.appendBigEndianUInt32(UInt32(record.offset))
    }
    index.append(packChecksum)
    index.append(PortableSHA1.hash(index))
    let indexURL = packDirectory.appendingPathComponent(stem).appendingPathExtension("idx")
    try index.write(to: indexURL)
    return PackFixtureURLs(packURL: packURL, indexURL: indexURL)
}

private func removeLooseObjects(gitDir: String, oids: [Data]) throws {
    for oid in oids {
        let hex = GitObjectStore.hexFromOID(oid)
        let url = URL(fileURLWithPath: gitDir)
            .appendingPathComponent("objects")
            .appendingPathComponent(String(hex.prefix(2)))
            .appendingPathComponent(String(hex.dropFirst(2)))
        try FileManager.default.removeItem(at: url)
    }
}

private func gitObjectOID(type: String, payload: Data) -> Data {
    var canonical = Data("\(type) \(payload.count)".utf8)
    canonical.append(0)
    canonical.append(payload)
    return PortableSHA1.hash(canonical)
}

private func packTypeCode(_ type: String) -> UInt8 {
    switch type {
    case "commit": return 1
    case "tree": return 2
    case "blob": return 3
    case "tag": return 4
    default: preconditionFailure("unsupported fixture object type")
    }
}

private func encodePackObjectHeader(typeCode: UInt8, size: UInt64) -> Data {
    var remaining = size >> 4
    var first = UInt8(size & 0x0F) | (typeCode << 4)
    if remaining != 0 {
        first |= 0x80
    }
    var data = Data([first])
    while remaining != 0 {
        var byte = UInt8(remaining & 0x7F)
        remaining >>= 7
        if remaining != 0 {
            byte |= 0x80
        }
        data.append(byte)
    }
    return data
}

private func encodeOffsetDeltaDistance(_ distance: UInt64) -> Data {
    precondition(distance > 0)
    var value = distance
    var bytes = [UInt8(value & 0x7F)]
    while value > 0x7F {
        value = (value >> 7) - 1
        bytes.append(UInt8(value & 0x7F) | 0x80)
    }
    return Data(bytes.reversed())
}

private func encodeInsertDelta(baseSize: Int, result: Data) -> Data {
    precondition(baseSize < 0x80 && result.count > 0 && result.count < 0x80)
    var data = Data([UInt8(baseSize), UInt8(result.count), UInt8(result.count)])
    data.append(result)
    return data
}

private func encodeCopyInsertDelta(
    baseSize: Int,
    copyOffset: Int,
    copySize: Int,
    insert: Data
) -> Data {
    let resultSize = copySize + insert.count
    var delta = encodeDeltaVarint(baseSize)
    delta.append(contentsOf: encodeDeltaVarint(resultSize))
    if copySize > 0 {
        var cmd: UInt8 = 0x80
        var params = Data()
        if copyOffset != 0 {
            cmd |= 0x01
            params.append(UInt8(copyOffset & 0xFF))
        }
        cmd |= 0x10
        params.append(UInt8(copySize & 0xFF))
        delta.append(cmd)
        delta.append(params)
    }
    if !insert.isEmpty {
        precondition(insert.count < 0x80)
        delta.append(UInt8(insert.count))
        delta.append(insert)
    }
    return delta
}

private func encodeDeltaVarint(_ value: Int) -> Data {
    precondition(value >= 0)
    var remaining = value
    var bytes = Data()
    repeat {
        var byte = UInt8(remaining & 0x7F)
        remaining >>= 7
        if remaining != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while remaining != 0
    return bytes
}

private func gitCRC32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask = UInt32(bitPattern: -Int32(crc & 1))
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
        }
    }
    return ~crc
}

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

private extension Data {
    mutating func appendBigEndianUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
