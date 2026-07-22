// OpenGrokFastWorktreeTests.swift
import Foundation
import Testing
@testable import OpenGrokFastWorktree

@Suite("OpenGrokFastWorktree")
struct OpenGrokFastWorktreeTests {
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

    @Test("destination exists check")
    func destExists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-wt-exists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: FastWorktreeError.self) {
            try ensureDestinationAvailable(dir)
        }
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-wt-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try ensureDestinationAvailable(empty, allowEmptyReuse: true)
    }

    @Test("worktree porcelain parser")
    func porcelainParser() {
        let text = """
        worktree /repo
        HEAD abcdef
        branch refs/heads/main

        worktree /pool/wt1
        HEAD 123456
        detached
        prunable

        """
        let infos = parseWorktreePorcelain(text)
        #expect(infos.count == 2)
        #expect(infos[0].branch == "refs/heads/main")
        #expect(infos[1].prunable)
        #expect(infos[1].branch == nil)
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

    @Test("builder validates non-git source")
    func builderNonGit() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-nongit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appendingPathComponent("wt")
        let builder = WorktreeBuilder(source: tmp, dest: dest)
        #expect(throws: FastWorktreeError.self) {
            try builder.create()
        }
    }

    @Test("end-to-end linked worktree create/remove when git available")
    func e2eLinkedWorktree() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git")
        else {
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-wt-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try runGit(["init"], cwd: root)
        _ = try runGit(["config", "user.email", "test@example.com"], cwd: root)
        _ = try runGit(["config", "user.name", "Test"], cwd: root)
        let file = root.appendingPathComponent("hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        _ = try runGit(["add", "hello.txt"], cwd: root)
        _ = try runGit(["commit", "-m", "init"], cwd: root)

        let dest = root.deletingLastPathComponent()
            .appendingPathComponent("og-wt-dest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }

        let report = try WorktreeBuilder(
            source: root,
            dest: dest,
            creationMode: .gitCheckout
        ).create()
        #expect(FileManager.default.fileExists(atPath: report.worktreePath.path))
        #expect(!report.commit.isEmpty)

        let remove = try removeWorktree(source: root, dest: dest)
        #expect(remove.removed)

        // Primary must never be removable via this API.
        #expect(throws: FastWorktreeError.self) {
            try removeWorktree(source: root, dest: root)
        }
    }

    @Test("count tracked files")
    func countTracked() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
            || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/git")
        else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-count-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try runGit(["init"], cwd: root)
        _ = try runGit(["config", "user.email", "t@e.com"], cwd: root)
        _ = try runGit(["config", "user.name", "T"], cwd: root)
        try "a".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "a.txt"], cwd: root)
        _ = try runGit(["commit", "-m", "c"], cwd: root)
        let n = try countTrackedFiles(repoPath: root)
        #expect(n == 1)
    }
}
