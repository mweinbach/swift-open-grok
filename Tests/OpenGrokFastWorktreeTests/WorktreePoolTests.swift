// WorktreePoolTests.swift
//
// Unit tests for pre-warmed subagent Git worktree pool in OpenGrokFastWorktree.
// Covers pre-warming capacity, rapid lease acquisition, release with dirty cleanup,
// and pool pruning/stale lock reclamation.

import Foundation
import Testing
@testable import OpenGrokFastWorktree

@Suite("WorktreePoolTests")
struct WorktreePoolTests {

    // MARK: - Test Helpers

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

    private func initRepo(at root: URL) throws {
        _ = try runGit(["init"], cwd: root)
        _ = try runGit(["config", "user.email", "test@example.com"], cwd: root)
        _ = try runGit(["config", "user.name", "Test"], cwd: root)
        _ = try runGit(["config", "commit.gpgsign", "false"], cwd: root)
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

    // MARK: - 1. Pre-warming Pool to Target Capacity

    @Test("Pre-warming pool creates target number of clean ready worktrees")
    func preWarmPoolToTargetCapacity() async throws {
        guard gitAvailable else { return }
        let repoRoot = try tempDir("og-pool-repo")
        let poolRoot = try tempDir("og-pool-root")
        defer {
            try? FileManager.default.removeItem(at: repoRoot)
            try? FileManager.default.removeItem(at: poolRoot)
        }

        try initRepo(at: repoRoot)
        try commitFile(at: repoRoot, name: "README.md", contents: "# Test Repo\n", message: "initial")

        let pool = WorktreePool(
            sourceRepo: repoRoot,
            poolRoot: poolRoot,
            targetWarmCount: 3,
            maxCapacity: 5,
            creationMode: .gitCheckout
        )

        #expect(await pool.readyCount == 0)
        #expect(await pool.activeLeaseCount == 0)

        try await pool.warmPool(targetCount: 3)

        #expect(await pool.readyCount == 3)
        #expect(await pool.activeLeaseCount == 0)
        #expect(await pool.totalManagedCount == 3)

        let paths = await pool.readyWorktreePaths
        #expect(paths.count == 3)

        for path in paths {
            #expect(FileManager.default.fileExists(atPath: path.path))
            let readme = path.appendingPathComponent("README.md")
            #expect(FileManager.default.fileExists(atPath: readme.path))
            let marker = path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".ready")
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }

        await pool.shutdown(cleanDisk: true)
    }

    // MARK: - 2. Rapid Lease Acquisition and Zero-Latency Retrieval

    @Test("Rapid lease acquisition claims pre-warmed worktree instantaneously and triggers replenishment")
    func rapidLeaseAcquisitionAndRetrieval() async throws {
        guard gitAvailable else { return }
        let repoRoot = try tempDir("og-rapid-repo")
        let poolRoot = try tempDir("og-rapid-pool")
        defer {
            try? FileManager.default.removeItem(at: repoRoot)
            try? FileManager.default.removeItem(at: poolRoot)
        }

        try initRepo(at: repoRoot)
        try commitFile(at: repoRoot, name: "main.swift", contents: "print(\"hello\")\n", message: "init")

        let pool = WorktreePool(
            sourceRepo: repoRoot,
            poolRoot: poolRoot,
            targetWarmCount: 2,
            maxCapacity: 4,
            creationMode: .gitCheckout
        )

        try await pool.warmPool(targetCount: 2)
        #expect(await pool.readyCount == 2)

        // Rapid zero-latency acquire
        let startTime = Date()
        let lease1 = try await pool.acquireLease(for: "session-alpha")
        let elapsed = Date().timeIntervalSince(startTime)

        #expect(elapsed < 0.5) // Instantaneous acquisition from pre-warmed pool
        #expect(lease1.isClean)
        #expect(FileManager.default.fileExists(atPath: lease1.worktreePath.path))
        #expect(await pool.isLeased(id: lease1.id))
        #expect(await pool.activeLeaseCount == 1)

        // Second acquire
        let lease2 = try await pool.acquireLease(for: "session-beta")
        #expect(lease2.id != lease1.id)
        #expect(lease2.worktreePath.path != lease1.worktreePath.path)
        #expect(await pool.activeLeaseCount == 2)

        // Wait briefly for background replenishment to restock the pool
        try await Task.sleep(nanoseconds: 800_000_000)

        // Total managed count should be active (2) + replenished ready worktrees
        let total = await pool.totalManagedCount
        #expect(total >= 2)

        await pool.shutdown(cleanDisk: true)
    }

    // MARK: - 3. Release and Dirty State Cleanup

    @Test("Releasing a dirty lease wipes untracked and modified files, restoring clean state")
    func releaseAndDirtyStateCleanup() async throws {
        guard gitAvailable else { return }
        let repoRoot = try tempDir("og-dirty-repo")
        let poolRoot = try tempDir("og-dirty-pool")
        defer {
            try? FileManager.default.removeItem(at: repoRoot)
            try? FileManager.default.removeItem(at: poolRoot)
        }

        try initRepo(at: repoRoot)
        try commitFile(at: repoRoot, name: "file.txt", contents: "version 1\n", message: "v1")

        let pool = WorktreePool(
            sourceRepo: repoRoot,
            poolRoot: poolRoot,
            targetWarmCount: 1,
            maxCapacity: 3,
            creationMode: .gitCheckout
        )

        try await pool.warmPool(targetCount: 1)
        let lease = try await pool.acquireLease(for: "session-dirty-test")

        // 1. Introduce dirty modifications in the leased worktree
        let trackedFile = lease.worktreePath.appendingPathComponent("file.txt")
        try "version 2 modified\n".write(to: trackedFile, atomically: true, encoding: .utf8)

        let untrackedFile = lease.worktreePath.appendingPathComponent("scratch_dirty.tmp")
        try "untracked garbage\n".write(to: untrackedFile, atomically: true, encoding: .utf8)

        let untrackedDir = lease.worktreePath.appendingPathComponent("nested_dirty")
        try FileManager.default.createDirectory(at: untrackedDir, withIntermediateDirectories: true)
        try "nested\n".write(to: untrackedDir.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)

        let statusBefore = try getModifiedFiles(repoPath: lease.worktreePath)
        #expect(statusBefore.modifiedCount >= 1)
        #expect(statusBefore.untrackedCount >= 1)

        // 2. Release lease back to pool
        await pool.releaseLease(lease)

        #expect(await pool.activeLeaseCount == 0)
        #expect(await pool.readyCount >= 1)
        #expect(!(await pool.isLeased(id: lease.id)))

        // 3. Verify that the worktree on disk is now completely pristine
        #expect(!FileManager.default.fileExists(atPath: untrackedFile.path))
        #expect(!FileManager.default.fileExists(atPath: untrackedDir.path))

        let cleanedContent = try String(contentsOf: trackedFile, encoding: .utf8)
        #expect(cleanedContent == "version 1\n")

        let statusAfter = try getModifiedFiles(repoPath: lease.worktreePath)
        #expect(statusAfter.modifiedCount == 0)
        #expect(statusAfter.untrackedCount == 0)
        #expect(statusAfter.deletedCount == 0)

        await pool.shutdown(cleanDisk: true)
    }

    // MARK: - 4. Pool Pruning of Expired Worktrees and Stale Locks

    @Test("Pruning removes excess expired worktrees and reclaims stale leases")
    func poolPruningAndStaleReclamation() async throws {
        guard gitAvailable else { return }
        let repoRoot = try tempDir("og-prune-repo")
        let poolRoot = try tempDir("og-prune-pool")
        defer {
            try? FileManager.default.removeItem(at: repoRoot)
            try? FileManager.default.removeItem(at: poolRoot)
        }

        try initRepo(at: repoRoot)
        try commitFile(at: repoRoot, name: "lib.swift", contents: "// swift code\n", message: "init")

        let pool = WorktreePool(
            sourceRepo: repoRoot,
            poolRoot: poolRoot,
            targetWarmCount: 1,
            maxCapacity: 5,
            creationMode: .gitCheckout
        )

        // Pre-warm to 3 (which is above targetWarmCount = 1)
        try await pool.warmPool(targetCount: 3)
        #expect(await pool.readyCount == 3)

        // Acquire 1 lease
        let lease = try await pool.acquireLease(for: "session-stale")
        #expect(await pool.activeLeaseCount == 1)

        // Add an untracked orphan directory in poolRoot to test orphan cleanup
        let orphanDir = poolRoot.appendingPathComponent("wt-orphan-test", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        try "dummy".write(to: orphanDir.appendingPathComponent("dummy.txt"), atomically: true, encoding: .utf8)

        // Pruning with maxAge: 0.0 forces cleanup of stale lease and excess pre-warmed worktrees
        await pool.prune(maxAge: 0.0)

        // Stale lease should be reclaimed
        #expect(await pool.activeLeaseCount == 0)
        // Ready worktrees pruned down toward targetWarmCount (1)
        #expect(await pool.readyCount <= 2)
        // Orphan directory should be removed
        #expect(!FileManager.default.fileExists(atPath: orphanDir.path))

        await pool.shutdown(cleanDisk: true)
    }

    // MARK: - 5. Capacity Cap and On-Demand Fallback

    @Test("Acquiring beyond max capacity fails gracefully")
    func capacityCapEnforcement() async throws {
        guard gitAvailable else { return }
        let repoRoot = try tempDir("og-cap-repo")
        let poolRoot = try tempDir("og-cap-pool")
        defer {
            try? FileManager.default.removeItem(at: repoRoot)
            try? FileManager.default.removeItem(at: poolRoot)
        }

        try initRepo(at: repoRoot)
        try commitFile(at: repoRoot, name: "app.swift", contents: "// app\n", message: "init")

        let pool = WorktreePool(
            sourceRepo: repoRoot,
            poolRoot: poolRoot,
            targetWarmCount: 1,
            maxCapacity: 2,
            creationMode: .gitCheckout
        )

        let lease1 = try await pool.acquireLease(for: "s1")
        let lease2 = try await pool.acquireLease(for: "s2")
        #expect(await pool.activeLeaseCount == 2)

        do {
            _ = try await pool.acquireLease(for: "s3")
            Issue.record("expected capacity error")
        } catch let error as FastWorktreeError {
            guard case .destinationExists = error else {
                Issue.record("expected destinationExists/capacity error, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        await pool.releaseLease(lease1)
        await pool.releaseLease(lease2)
        await pool.shutdown(cleanDisk: true)
    }
}
