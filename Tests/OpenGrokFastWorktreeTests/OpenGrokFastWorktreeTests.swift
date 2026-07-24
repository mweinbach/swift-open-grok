// OpenGrokFastWorktreeTests.swift
//
// Focused acceptance tests for R16: create/list/remove across bare/non-bare,
// nested roots, dirty trees, detached HEAD, branch collisions, recoverable
// partial cleanup, pool-root/symlink safety, CoW copy, cancellation, and
// forced BTRFS/overlay fail-closed without a privileged delegate.

import Foundation
import Testing
@testable import OpenGrokFastWorktree

@Suite("OpenGrokFastWorktree")
struct OpenGrokFastWorktreeTests {

    // MARK: - Helpers

    private var gitAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/git")
    }

    private func tempDir(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func initRepo(at root: URL, bare: Bool = false) throws {
        if bare {
            _ = try runGit(["init", "--bare"], cwd: root)
        } else {
            _ = try runGit(["init"], cwd: root)
        }
        _ = try runGit(["config", "user.email", "test@example.com"], cwd: root)
        _ = try runGit(["config", "user.name", "Test"], cwd: root)
    }

    private func commitFile(at root: URL, name: String, contents: String, message: String) throws {
        try contents.write(
            to: root.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
        _ = try runGit(["add", name], cwd: root)
        _ = try runGit(["commit", "-m", message], cwd: root)
    }

    // MARK: - Safety

    @Test("primary checkout is protected from destination")
    func primaryProtected() throws {
        let primary = URL(fileURLWithPath: "/Users/me/project")
        let safety = WorktreeSafetyPolicy(primaryCheckout: primary)
        #expect(throws: FastWorktreeError.self) {
            try safety.validateDestination(primary)
        }
        #expect(throws: FastWorktreeError.self) {
            try safety.validateNotPrimary(primary)
        }
    }

    @Test("pool root containment rejects escapes")
    func poolRootEscape() {
        let safety = WorktreeSafetyPolicy(
            primaryCheckout: URL(fileURLWithPath: "/repo"),
            allowedPoolRoot: URL(fileURLWithPath: "/pool")
        )
        #expect(throws: FastWorktreeError.self) {
            try safety.validateDestination(URL(fileURLWithPath: "/etc/passwd"))
        }
        do {
            try safety.validateDestination(URL(fileURLWithPath: "/pool/wt-1"))
        } catch {
            Issue.record("pool destination should be allowed: \(error)")
        }
    }

    @Test("symlink escape out of pool is rejected")
    func symlinkEscapeRejected() throws {
        let root = try tempDir("og-symlink-escape")
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = root.appendingPathComponent("pool")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: pool, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = pool.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: outside.path
        )
        let dest = link.appendingPathComponent("wt")
        let safety = WorktreeSafetyPolicy(
            primaryCheckout: root.appendingPathComponent("repo"),
            allowedPoolRoot: pool
        )
        #expect(throws: FastWorktreeError.self) {
            try safety.validateDestination(dest)
        }
    }

    @Test("argument injection in git ref fails closed")
    func refInjection() {
        #expect(throws: FastWorktreeError.self) {
            try rejectHostileGitRef("--output=/tmp/pwned")
        }
        #expect(throws: FastWorktreeError.self) {
            try rejectHostileGitRef("HEAD\n--upload-pack")
        }
        #expect(throws: FastWorktreeError.self) {
            try rejectHostileGitRef("refs/../etc/passwd")
        }
        do {
            try rejectHostileGitRef("feature/ok-branch")
        } catch {
            Issue.record("valid ref rejected: \(error)")
        }
    }

    @Test("destination exists check including marker-only reuse")
    func destExists() throws {
        let dir = try tempDir("og-wt-exists")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: FastWorktreeError.self) {
            try ensureDestinationAvailable(dir)
        }
        let empty = try tempDir("og-wt-empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        try ensureDestinationAvailable(empty, allowEmptyReuse: true)

        let partial = try tempDir("og-wt-partial-reuse")
        defer { try? FileManager.default.removeItem(at: partial) }
        try writePartialMarker(
            PartialWorktreeMarker(
                sourcePath: "/repo",
                destPath: partial.path,
                creationMode: "linked",
                gitRef: "HEAD"
            ),
            at: partial
        )
        try ensureDestinationAvailable(partial, allowEmptyReuse: true)
    }

    // MARK: - Parsing

    @Test("worktree porcelain parser handles bare and detached")
    func porcelainParser() {
        let text = """
        worktree /repo
        HEAD abcdef
        branch refs/heads/main

        worktree /pool/wt1
        HEAD 123456
        detached
        prunable

        worktree /bare.git
        HEAD abcdef
        bare

        """
        let infos = parseWorktreePorcelain(text)
        #expect(infos.count == 3)
        #expect(infos[0].branch == "refs/heads/main")
        #expect(infos[1].prunable)
        #expect(infos[1].detached)
        #expect(infos[1].branch == nil)
        #expect(infos[2].bare)
    }

    @Test("porcelain status dirty parser")
    func dirtyParser() {
        let text = " M file.txt\0?? untracked.txt\0 D gone.txt\0"
        let report = parsePorcelainStatus(text)
        #expect(report.modifiedCount == 1)
        #expect(report.untrackedCount == 1)
        #expect(report.deletedCount == 1)
        #expect(report.modified.contains("file.txt"))
        #expect(report.allDirtyPaths.count == 3)
    }

    @Test("creation mode db strings")
    func creationModeStrings() {
        #expect(CreationMode.linked.asDBString == "linked")
        #expect(CreationMode.standalone.asDBString == "standalone")
        #expect(CreationMode.gitCheckout.asDBString == "git")
    }

    @Test("glob match path context")
    func globMatchPath() {
        #expect(globMatch(pattern: "src/*.rs", text: "src/main.rs"))
        #expect(!globMatch(pattern: "src/*.rs", text: "src/a/main.rs"))
        #expect(globMatch(pattern: "src/**/*.rs", text: "src/a/main.rs"))
    }

    @Test("gitdir skip list rejects locks and transient state")
    func gitDirSkipList() {
        #expect(shouldSkipGitEntry(name: "index.lock", depth: 0))
        #expect(shouldSkipGitEntry(name: "worktrees", depth: 0))
        #expect(shouldSkipGitEntry(name: "MERGE_HEAD", depth: 0))
        #expect(!shouldSkipGitEntry(name: "index", depth: 0))
        #expect(!shouldSkipGitEntry(name: "objects", depth: 0))
        #expect(shouldSkipGitEntry(name: "shallow.lock", depth: 2))
    }

    // MARK: - Forced privileged modes

    @Test("forced BTRFS without delegate is typed unsupported")
    func forcedBtrfsUnsupported() throws {
        let tmp = try tempDir("og-btrfs-force")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("wt")
        let builder = WorktreeBuilder(
            source: tmp,
            dest: dest,
            btrfsMode: .force
        )
        do {
            _ = try builder.create()
            Issue.record("expected unsupported")
        } catch let error as FastWorktreeError {
            guard case .unsupported = error else {
                Issue.record("expected .unsupported, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("forced overlay without delegate is typed unsupported")
    func forcedOverlayUnsupported() throws {
        let tmp = try tempDir("og-overlay-force")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("wt")
        let builder = WorktreeBuilder(
            source: tmp,
            dest: dest,
            overlayMode: .force
        )
        do {
            _ = try builder.create()
            Issue.record("expected unsupported")
        } catch let error as FastWorktreeError {
            guard case .unsupported = error else {
                Issue.record("expected .unsupported, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("builder validates non-git source")
    func builderNonGit() throws {
        let tmp = try tempDir("og-nongit")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("wt")
        let builder = WorktreeBuilder(source: tmp, dest: dest)
        #expect(throws: FastWorktreeError.self) {
            try builder.create()
        }
    }

    // MARK: - CoW / copy engine

    @Test("copyTree prefers CoW when available and preserves bytes")
    func copyTreeCowAndBytes() throws {
        let root = try tempDir("og-cow")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        let dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let payload = Data((0..<4096).map { UInt8($0 % 256) })
        try payload.write(to: src.appendingPathComponent("blob.bin"))
        try "hello".write(
            to: src.appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8
        )
        // Nested + symlink
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: src.appendingPathComponent("sub/link").path,
            withDestinationPath: "../hello.txt"
        )
        // Fake .git should be skipped for linked options
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try "index".write(
            to: src.appendingPathComponent(".git/index"),
            atomically: true,
            encoding: .utf8
        )

        let report = try copyTree(
            from: src,
            to: dst,
            options: CopyEngineOptions(skipGitDirectory: true, preferCow: true)
        )
        #expect(report.filesCopied >= 2)
        #expect(report.symlinksCopied >= 1)
        let copied = try Data(contentsOf: dst.appendingPathComponent("blob.bin"))
        #expect(copied == payload)
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent(".git/index").path))

        // Non-CoW fallback still byte-identical
        let dst2 = root.appendingPathComponent("dst2")
        let report2 = try copyTree(
            from: src,
            to: dst2,
            options: CopyEngineOptions(skipGitDirectory: true, preferCow: false)
        )
        #expect(report2.usedCow == false)
        #expect(try Data(contentsOf: dst2.appendingPathComponent("blob.bin")) == payload)
    }

    @Test("selective gitdir copy skips locks and worktrees")
    func selectiveGitDirCopy() throws {
        let root = try tempDir("og-gitdir")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src.git")
        let dst = root.appendingPathComponent("dst.git")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("objects/pack"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("refs/heads"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("worktrees/wt1"),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/main\n".write(
            to: src.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "index-data".write(
            to: src.appendingPathComponent("index"),
            atomically: true,
            encoding: .utf8
        )
        try "lock".write(
            to: src.appendingPathComponent("index.lock"),
            atomically: true,
            encoding: .utf8
        )
        try "MERGE".write(
            to: src.appendingPathComponent("MERGE_HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "pack".write(
            to: src.appendingPathComponent("objects/pack/pack-a.pack"),
            atomically: true,
            encoding: .utf8
        )

        let report = try copyGitDir(from: src, to: dst, preferCow: true)
        #expect(report.filesCopied >= 3)
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("HEAD").path))
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("index").path))
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("index.lock").path))
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("MERGE_HEAD").path))
        #expect(!FileManager.default.fileExists(atPath: dst.appendingPathComponent("worktrees").path))
    }

    // MARK: - Git integration

    @Test("end-to-end linked create/list/remove with progress and primary protection")
    func e2eLinkedWorktree() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-wt-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "hello.txt", contents: "hello", message: "init")

        let pool = try tempDir("og-wt-pool")
        defer { try? FileManager.default.removeItem(at: pool) }
        let dest = pool.appendingPathComponent("wt1")

        var progress: [WorktreeProgress] = []
        let report = try WorktreeBuilder(
            source: root,
            dest: dest,
            creationMode: .gitCheckout,
            allowedPoolRoot: pool
        ).create(onProgress: { progress.append($0) })

        #expect(FileManager.default.fileExists(atPath: report.worktreePath.path))
        #expect(!report.commit.isEmpty)
        #expect(progress.contains(.discovering))
        #expect(progress.contains(.complete))
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(partialMarkerFileName).path
        ))

        let listed = try listLinkedWorktrees(source: root)
        #expect(listed.count >= 2) // main + linked
        #expect(listed.contains(where: {
            $0.path.standardizedFileURL.path == dest.standardizedFileURL.path
        }))

        let remove = try removeWorktree(source: root, dest: dest)
        #expect(remove.removed)
        #expect(!FileManager.default.fileExists(atPath: dest.path))

        #expect(throws: FastWorktreeError.self) {
            try removeWorktree(source: root, dest: root)
        }
    }

    @Test("linked mode preserves dirty working tree")
    func dirtyTreePreserve() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-dirty-preserve")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "file.txt", contents: "original", message: "init")
        try "modified".write(
            to: root.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "scratch".write(
            to: root.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-dirty-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }

        let report = try WorktreeBuilder(
            source: root,
            dest: dest,
            workingTree: .preserveWorkingTree,
            creationMode: .linked
        ).create()
        #expect(try String(contentsOf: dest.appendingPathComponent("file.txt"), encoding: .utf8) == "modified")
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("untracked.txt").path))
        #expect(report.unignoredCopy.dirtyFiles != nil)
        #expect((report.unignoredCopy.dirtyFiles?.modifiedCount ?? 0) >= 1)

        _ = try removeWorktree(source: root, dest: dest)
    }

    @Test("linked cleanTracked skips dirty content")
    func dirtyTreeClean() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-dirty-clean")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "file.txt", contents: "original", message: "init")
        try "modified".write(
            to: root.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-clean-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }

        _ = try WorktreeBuilder(
            source: root,
            dest: dest,
            workingTree: .cleanTracked,
            creationMode: .linked
        ).create()
        let content = try String(contentsOf: dest.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(content == "original")
        _ = try removeWorktree(source: root, dest: dest)
    }

    @Test("nested subdirectory source resolves to repo root")
    func nestedRoot() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-nested")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/pkg"),
            withIntermediateDirectories: true
        )
        try commitFile(at: root, name: "src/pkg/a.txt", contents: "a", message: "init")

        let nested = root.appendingPathComponent("src/pkg")
        let identity = try discoverGitRepo(at: nested)
        #expect(identity.toplevel?.standardizedFileURL.path == root.standardizedFileURL.path)

        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-nested-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let report = try WorktreeBuilder(
            source: nested,
            dest: dest,
            creationMode: .gitCheckout
        ).create()
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("src/pkg/a.txt").path))
        #expect(!report.commit.isEmpty)
        _ = try removeWorktree(source: root, dest: dest)
    }

    @Test("detached HEAD source create/list")
    func detachedHead() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-detached")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "a.txt", contents: "1", message: "c1")
        try commitFile(at: root, name: "b.txt", contents: "2", message: "c2")
        let head = try runGit(["rev-parse", "HEAD~1"], cwd: root)
        let old = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try runGit(["checkout", "--detach", old], cwd: root)

        let identity = try discoverGitRepo(at: root)
        #expect(identity.isDetached)

        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-detached-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let report = try WorktreeBuilder(
            source: root,
            dest: dest,
            creationMode: .gitCheckout
        ).create()
        #expect(report.wasDetached)
        let listed = try listLinkedWorktrees(source: root)
        let wt = listed.first {
            $0.path.standardizedFileURL.path == dest.standardizedFileURL.path
        }
        #expect(wt?.detached == true)
        _ = try removeWorktree(source: root, dest: dest)
    }

    @Test("bare repository create/list/remove")
    func bareRepo() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-bare-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        let bare = root.appendingPathComponent("repo.git")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try initRepo(at: work)
        try commitFile(at: work, name: "f.txt", contents: "x", message: "init")
        // Clone to bare
        _ = try runGit(["clone", "--bare", work.path, bare.path], cwd: root)

        let identity = try discoverGitRepo(at: bare)
        #expect(identity.isBare)
        #expect(identity.toplevel == nil)

        let dest = root.appendingPathComponent("wt-bare")
        defer { try? FileManager.default.removeItem(at: dest) }
        let report = try WorktreeBuilder(
            source: bare,
            dest: dest,
            creationMode: .gitCheckout
        ).create()
        #expect(report.isBareSource)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("f.txt").path))

        let listed = try listLinkedWorktrees(source: bare)
        #expect(listed.contains(where: {
            $0.path.standardizedFileURL.path == dest.standardizedFileURL.path
        }))
        let remove = try removeWorktree(source: bare, dest: dest)
        #expect(remove.removed)
    }

    @Test("branch collision detection for already-checked-out branch")
    func branchCollision() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-branch-coll")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "a.txt", contents: "1", message: "init")
        _ = try runGit(["branch", "-M", "main"], cwd: root)

        // Create a non-detached worktree on main via raw git (our API always detaches).
        let other = root.deletingLastPathComponent()
            .appendingPathComponent("og-branch-other-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        let add = try runGit(
            ["worktree", "add", other.path, "main"],
            cwd: root
        )
        // If git refuses because main is checked out in root, that's also a collision signal.
        if add.exitCode == 0 {
            let collision = try detectBranchCollision(ref: "main", source: root)
            #expect(collision != nil)
            _ = try runGit(["worktree", "remove", "--force", other.path], cwd: root)
        } else {
            // main checked out at root — detectBranchCollision should find root's branch.
            let collision = try detectBranchCollision(ref: "main", source: root)
            #expect(collision != nil)
        }

        // Our builder always uses --detach so create still succeeds on that branch tip.
        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-branch-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let report = try WorktreeBuilder(
            source: root,
            dest: dest,
            gitRef: "main",
            creationMode: .gitCheckout
        ).create()
        #expect(!report.commit.isEmpty)
        _ = try removeWorktree(source: root, dest: dest)
    }

    @Test("cancellation after worktree add reclaims partial state")
    func cancellationReclaims() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "a.txt", contents: "1", message: "init")

        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-cancel-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }

        // Cancel only after the worktree has been registered so reclaim must run.
        final class Gate: @unchecked Sendable {
            var cancel = false
            var sawReclaim = false
            var sawAdd = false
        }
        let gate = Gate()
        do {
            _ = try WorktreeBuilder(
                source: root,
                dest: dest,
                creationMode: .linked
            ).create(
                isCancelled: { gate.cancel },
                onProgress: { p in
                    if case .addingWorktree = p {
                        gate.sawAdd = true
                        gate.cancel = true
                    }
                    if case .reclaiming = p { gate.sawReclaim = true }
                }
            )
            Issue.record("expected cancellation after worktree add")
        } catch let error as FastWorktreeError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(gate.sawAdd)
        #expect(gate.sawReclaim)
        // Half-created worktree must not remain registered/usable.
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path))
        let listed = try listLinkedWorktrees(source: root)
        #expect(!listed.contains(where: {
            $0.path.standardizedFileURL.path == dest.standardizedFileURL.path
        }))
    }

    @Test("interrupted partial marker is recoverable via cleanup")
    func recoverablePartialCleanup() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-partial-repo")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "a.txt", contents: "1", message: "init")

        let pool = try tempDir("og-partial-pool")
        defer { try? FileManager.default.removeItem(at: pool) }
        let dest = pool.appendingPathComponent("half-built")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try writePartialMarker(
            PartialWorktreeMarker(
                sourcePath: root.path,
                destPath: dest.path,
                creationMode: "linked",
                gitRef: "HEAD",
                phase: "linked_copy"
            ),
            at: dest
        )
        // Simulate leftover debris
        try "junk".write(
            to: dest.appendingPathComponent("junk.txt"),
            atomically: true,
            encoding: .utf8
        )
        #expect(isRecoverablePartialWorktree(dest))

        let report = try cleanupWorktreesIn(source: root, poolRoot: pool)
        #expect(report.recoveredPartials.contains(where: {
            $0.standardizedFileURL.path == dest.standardizedFileURL.path
        }) || report.removed.contains(where: {
            $0.standardizedFileURL.path == dest.standardizedFileURL.path
        }))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test("standalone create produces independent .git and marker")
    func standaloneCreate() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-standalone")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "a.txt", contents: "1", message: "init")

        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-standalone-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }

        let report = try WorktreeBuilder(
            source: root,
            dest: dest,
            creationMode: .standalone
        ).create()
        #expect(report.creationMode == .standalone)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(".git").path,
            isDirectory: &isDir
        ) && isDir.boolValue)
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(".git/grok-worktree-source").path
        ))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
    }

    @Test("pool root rejects create outside pool")
    func poolRootEnforcedOnCreate() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-pool-enforce")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "a.txt", contents: "1", message: "init")
        let pool = try tempDir("og-pool-only")
        defer { try? FileManager.default.removeItem(at: pool) }
        let outside = try tempDir("og-pool-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let dest = outside.appendingPathComponent("wt")

        #expect(throws: FastWorktreeError.self) {
            try WorktreeBuilder(
                source: root,
                dest: dest,
                creationMode: .gitCheckout,
                allowedPoolRoot: pool
            ).create()
        }
    }

    @Test("count tracked files")
    func countTracked() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-count")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "a.txt", contents: "a", message: "c")
        let n = try countTrackedFiles(repoPath: root)
        #expect(n == 1)
    }

    @Test("mapGitWorktreeError classifies branch collision and ENOSPC")
    func mapErrors() {
        let collision = mapGitWorktreeError(GitCommandResult(
            exitCode: 128,
            stdout: "",
            stderr: "fatal: 'main' is already checked out at '/repo'"
        ))
        #expect(collision == .branchCollision("fatal: 'main' is already checked out at '/repo'"))

        let disk = mapGitWorktreeError(GitCommandResult(
            exitCode: 128,
            stdout: "",
            stderr: "error: \(enospcOSMessage)"
        ))
        #expect(disk == .outOfDisk)
    }

    @Test("progress callback fires for linked copy path")
    func progressLinked() throws {
        guard gitAvailable else { return }
        let root = try tempDir("og-progress")
        defer { try? FileManager.default.removeItem(at: root) }
        try initRepo(at: root)
        try commitFile(at: root, name: "a.txt", contents: "1", message: "init")
        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-progress-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }

        var phases: [WorktreeProgress] = []
        _ = try WorktreeBuilder(
            source: root,
            dest: dest,
            creationMode: .linked
        ).create(onProgress: { phases.append($0) })
        #expect(phases.contains(.discovering))
        #expect(phases.contains(.addingWorktree))
        #expect(phases.contains(.complete))
        _ = try removeWorktree(source: root, dest: dest)
    }
}
