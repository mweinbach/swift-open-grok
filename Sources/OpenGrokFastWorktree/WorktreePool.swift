// WorktreePool.swift
//
// Pre-warmed subagent Git worktree pool for zero-latency worktree acquisition,
// background replenishment, dirty state wiping on return, and stale lease reclamation.
// Ported from `crates/codegen/xai-grok-shell/src/session/worktree_pool.rs`.

import Foundation
import OpenGrokFileUtils
import OpenGrokPaths

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Marker suffixes mirroring Rust reference `worktree_pool.rs`.
private let readyMarkerSuffix = ".ready"
private let claimedMarkerSuffix = ".claimed"
private let lockMarkerSuffix = ".lock"

/// Metadata written into sibling marker files for stale lock detection.
public struct WorktreeMarkerMetadata: Codable, Sendable {
    public let leaseID: String
    public let sessionID: String
    public let processID: Int32
    public let acquiredAtEpoch: TimeInterval

    public init(leaseID: String, sessionID: String, processID: Int32, acquiredAt: Date = Date()) {
        self.leaseID = leaseID
        self.sessionID = sessionID
        self.processID = processID
        self.acquiredAtEpoch = acquiredAt.timeIntervalSince1970
    }

    public var acquiredAt: Date {
        Date(timeIntervalSince1970: acquiredAtEpoch)
    }
}

/// Actor managing a bounded pool of pre-warmed clean Git worktrees.
public actor WorktreePool {
    /// The primary repository root whose commits/refs will be checked out.
    public let sourceRepo: URL
    /// The directory under which pooled worktrees and marker files are stored.
    public let poolRoot: URL
    /// The base ref/branch/commit to check out (default "HEAD").
    public let gitRef: String
    /// Creation mode for worktrees (linked or gitCheckout).
    public let creationMode: CreationMode
    /// Target number of pre-warmed clean worktrees to keep ready in the pool.
    public private(set) var targetWarmCount: Int
    /// Hard capacity cap on total managed worktrees (ready + active).
    public let maxCapacity: Int

    /// Internal representation of a clean, pre-warmed worktree ready for leasing.
    public struct PooledWorktree: Sendable, Identifiable, Equatable {
        public let id: String
        public let path: URL
        public let branchName: String
        public let createdAt: Date
        public var lastCleanedAt: Date

        public init(
            id: String,
            path: URL,
            branchName: String,
            createdAt: Date = Date(),
            lastCleanedAt: Date = Date()
        ) {
            self.id = id
            self.path = path.standardizedFileURL
            self.branchName = branchName
            self.createdAt = createdAt
            self.lastCleanedAt = lastCleanedAt
        }
    }

    /// Internal record for an actively leased worktree.
    private struct ActiveLeaseEntry: Sendable {
        let lease: WorktreeLease
        let sessionID: String
        let processID: Int32
    }

    /// Ready worktrees available for immediate acquisition.
    private var readyWorktrees: [PooledWorktree] = []
    /// Actively leased worktrees indexed by lease ID.
    private var activeLeases: [String: ActiveLeaseEntry] = [:]
    /// In-flight background replenishment task.
    private var replenishmentTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Initialize a new worktree pool.
    ///
    /// - Parameters:
    ///   - sourceRepo: URL to the Git repository root.
    ///   - poolRoot: URL to store pooled worktrees. Defaults to `$OPENGROK_HOME/worktrees/pool`.
    ///   - targetWarmCount: Target number of pre-warmed worktrees (default: 2).
    ///   - maxCapacity: Maximum number of total concurrent worktrees (default: 10).
    ///   - gitRef: Git ref to check out for pre-warmed worktrees (default: "HEAD").
    ///   - creationMode: Strategy for worktree creation (default: .gitCheckout).
    public init(
        sourceRepo: URL,
        poolRoot: URL? = nil,
        targetWarmCount: Int = 2,
        maxCapacity: Int = 10,
        gitRef: String = "HEAD",
        creationMode: CreationMode = .gitCheckout
    ) {
        self.sourceRepo = sourceRepo.standardizedFileURL
        self.targetWarmCount = max(0, min(targetWarmCount, maxCapacity))
        self.maxCapacity = max(1, maxCapacity)
        self.gitRef = gitRef
        self.creationMode = creationMode

        if let explicitRoot = poolRoot {
            self.poolRoot = explicitRoot.standardizedFileURL
        } else {
            let env = ProcessInfo.processInfo.environment
            let stateDir = OpenGrokStatePaths.stateDirectory(environment: env)
            self.poolRoot = stateDir
                .appendingPathComponent("worktrees", isDirectory: true)
                .appendingPathComponent("pool", isDirectory: true)
                .standardizedFileURL
        }

        try? FileManager.default.createDirectory(at: self.poolRoot, withIntermediateDirectories: true)
    }

    deinit {
        replenishmentTask?.cancel()
    }

    // MARK: - Public Inspection Properties

    /// Number of pre-warmed worktrees ready for instantaneous lease.
    public var readyCount: Int {
        readyWorktrees.count
    }

    /// Number of currently active worktree leases.
    public var activeLeaseCount: Int {
        activeLeases.count
    }

    /// Total managed worktrees (ready + active).
    public var totalManagedCount: Int {
        readyWorktrees.count + activeLeases.count
    }

    /// Absolute URLs of currently ready worktrees.
    public var readyWorktreePaths: [URL] {
        readyWorktrees.map(\.path)
    }

    /// Absolute URLs of currently leased worktrees.
    public var activeWorktreePaths: [URL] {
        activeLeases.values.map(\.lease.worktreePath)
    }

    /// Checks whether a lease ID is currently active.
    public func isLeased(id: String) -> Bool {
        activeLeases[id] != nil
    }

    /// Retrieves an active lease by ID if present.
    public func getLease(id: String) -> WorktreeLease? {
        activeLeases[id]?.lease
    }

    // MARK: - Warm Pool

    /// Pre-warm the pool to reach the target capacity.
    ///
    /// Cleans existing adoptable worktrees and creates new linked worktrees
    /// until `readyWorktrees.count` reaches `targetCount`.
    public func warmPool(targetCount: Int) async throws {
        self.targetWarmCount = max(0, min(targetCount, maxCapacity))
        try FileManager.default.createDirectory(at: poolRoot, withIntermediateDirectories: true)

        // First discover and adopt any existing valid worktrees under poolRoot
        await adoptExistingPoolWorktrees()

        // Create new worktrees until we hit the target count or maxCapacity
        while readyWorktrees.count < self.targetWarmCount && totalManagedCount < maxCapacity {
            try await createAndAddReadyWorktree()
        }
    }

    // MARK: - Acquire Lease

    /// Acquire a worktree lease for a session.
    ///
    /// If pre-warmed worktrees are available, claims one with zero latency (no creation delay).
    /// If the pool is empty, creates a worktree on demand up to `maxCapacity`.
    /// Kicks off background replenishment to keep the pool stocked.
    public func acquireLease(for sessionID: String) async throws -> WorktreeLease {
        try FileManager.default.createDirectory(at: poolRoot, withIntermediateDirectories: true)

        // 1. Try zero-latency retrieval from pre-warmed pool
        if let pooled = readyWorktrees.popLast() {
            // Remove ready marker, write claimed marker
            removeMarker(for: pooled.path, suffix: readyMarkerSuffix)
            writeClaimedMarker(for: pooled.path, leaseID: pooled.id, sessionID: sessionID)

            let lease = WorktreeLease(
                id: pooled.id,
                worktreePath: pooled.path,
                branchName: pooled.branchName,
                isClean: true,
                acquiredAt: Date()
            )
            activeLeases[lease.id] = ActiveLeaseEntry(
                lease: lease,
                sessionID: sessionID,
                processID: ProcessInfo.processInfo.processIdentifier
            )

            scheduleReplenishment()
            return lease
        }

        // 2. Pool empty — check capacity before on-demand creation
        guard totalManagedCount < maxCapacity else {
            throw FastWorktreeError.destinationExists(
                "Worktree pool capacity exceeded (active: \(activeLeases.count), max: \(maxCapacity))"
            )
        }

        // 3. Create on-demand worktree
        let leaseID = UUID().uuidString.lowercased()
        let wtPath = poolRoot.appendingPathComponent("wt-\(leaseID)", isDirectory: true)
        let branchName = "subagent/\(leaseID)"

        let builder = WorktreeBuilder(
            source: sourceRepo,
            dest: wtPath,
            gitRef: gitRef,
            workingTree: .cleanAll,
            creationMode: creationMode,
            allowedPoolRoot: poolRoot
        )
        _ = try builder.create()

        writeClaimedMarker(for: wtPath, leaseID: leaseID, sessionID: sessionID)
        let lease = WorktreeLease(
            id: leaseID,
            worktreePath: wtPath,
            branchName: branchName,
            isClean: true,
            acquiredAt: Date()
        )
        activeLeases[lease.id] = ActiveLeaseEntry(
            lease: lease,
            sessionID: sessionID,
            processID: ProcessInfo.processInfo.processIdentifier
        )

        scheduleReplenishment()
        return lease
    }

    // MARK: - Release Lease

    /// Release an acquired lease back to the pool.
    ///
    /// Wipes all dirty state (`git reset --hard HEAD` and `git clean -fdx`),
    /// removes `.claimed` marker, writes `.ready` marker, and returns the worktree
    /// to the warm pool for future reuse. If total managed count exceeds `maxCapacity`,
    /// the worktree is destroyed instead.
    public func releaseLease(_ lease: WorktreeLease) async {
        activeLeases.removeValue(forKey: lease.id)
        removeMarker(for: lease.worktreePath, suffix: claimedMarkerSuffix)

        guard FileManager.default.fileExists(atPath: lease.worktreePath.path) else {
            // Path no longer exists on disk
            removeMarker(for: lease.worktreePath, suffix: readyMarkerSuffix)
            scheduleReplenishment()
            return
        }

        // If over capacity, destroy the returned worktree
        if totalManagedCount >= maxCapacity {
            _ = try? worktreeRemove(source: sourceRepo, dest: lease.worktreePath, force: true)
            removeMarker(for: lease.worktreePath, suffix: readyMarkerSuffix)
            scheduleReplenishment()
            return
        }

        // Reset and wipe dirty state
        let isCleaned = wipeDirtyState(at: lease.worktreePath)
        if isCleaned {
            writeMarker(for: lease.worktreePath, suffix: readyMarkerSuffix, contents: "")
            let pooled = PooledWorktree(
                id: lease.id,
                path: lease.worktreePath,
                branchName: lease.branchName,
                createdAt: lease.acquiredAt,
                lastCleanedAt: Date()
            )
            // Avoid duplicate entries
            readyWorktrees.removeAll { $0.id == pooled.id || $0.path.path == pooled.path.path }
            readyWorktrees.append(pooled)
        } else {
            // Cleanup failed, safely destroy the corrupted worktree
            _ = try? worktreeRemove(source: sourceRepo, dest: lease.worktreePath, force: true)
            removeMarker(for: lease.worktreePath, suffix: readyMarkerSuffix)
        }

        scheduleReplenishment()
    }

    // MARK: - Prune & Stale Lock Reclamation

    /// Prune expired ready worktrees, reclaim stale active leases, and remove orphan directories.
    ///
    /// - Parameter maxAge: Maximum age in seconds before an inactive worktree or stale lease is considered expired.
    public func prune(maxAge: TimeInterval) async {
        let now = Date()

        // 1. Reclaim stale active leases
        var leasesToReclaim: [WorktreeLease] = []
        for (_, entry) in activeLeases {
            let age = now.timeIntervalSince(entry.lease.acquiredAt)
            let processDead = !isProcessAlive(pid: entry.processID)
            if age >= maxAge || processDead {
                leasesToReclaim.append(entry.lease)
            }
        }
        for lease in leasesToReclaim {
            await releaseLease(lease)
        }

        // 2. Prune excess ready worktrees beyond targetWarmCount that exceed maxAge
        if readyWorktrees.count > targetWarmCount {
            var retained: [PooledWorktree] = []
            for pooled in readyWorktrees {
                let age = now.timeIntervalSince(pooled.lastCleanedAt)
                if retained.count >= targetWarmCount && age >= maxAge {
                    // Prune excess aged worktree
                    _ = try? worktreeRemove(source: sourceRepo, dest: pooled.path, force: true)
                    removeMarker(for: pooled.path, suffix: readyMarkerSuffix)
                    removeMarker(for: pooled.path, suffix: claimedMarkerSuffix)
                } else {
                    retained.append(pooled)
                }
            }
            readyWorktrees = retained
        }

        // 3. Scan poolRoot for orphan directories not tracked in activeLeases or readyWorktrees
        scanAndCleanOrphanDirectories(maxAge: maxAge)
    }

    /// Explicitly shutdown the pool, cancelling replenishment and optionally destroying all worktrees.
    public func shutdown(cleanDisk: Bool = false) async {
        replenishmentTask?.cancel()
        replenishmentTask = nil

        if cleanDisk {
            for pooled in readyWorktrees {
                _ = try? worktreeRemove(source: sourceRepo, dest: pooled.path, force: true)
                removeMarker(for: pooled.path, suffix: readyMarkerSuffix)
                removeMarker(for: pooled.path, suffix: claimedMarkerSuffix)
            }
            readyWorktrees.removeAll()

            for entry in activeLeases.values {
                _ = try? worktreeRemove(source: sourceRepo, dest: entry.lease.worktreePath, force: true)
                removeMarker(for: entry.lease.worktreePath, suffix: claimedMarkerSuffix)
            }
            activeLeases.removeAll()
        }
    }

    // MARK: - Internal Helpers

    /// Schedule asynchronous background replenishment to reach `targetWarmCount`.
    private func scheduleReplenishment() {
        guard replenishmentTask == nil else { return }
        guard readyWorktrees.count < targetWarmCount && totalManagedCount < maxCapacity else { return }

        replenishmentTask = Task { [weak self] in
            guard let self else { return }
            await self.runReplenishmentLoop()
        }
    }

    private func runReplenishmentLoop() async {
        defer { self.replenishmentTask = nil }

        while !Task.isCancelled {
            let needMore = readyWorktrees.count < targetWarmCount && totalManagedCount < maxCapacity
            guard needMore else { break }

            do {
                try await createAndAddReadyWorktree()
            } catch {
                // Break replenishment on persistent errors to avoid tight spin loop
                break
            }
        }
    }

    /// Create a single clean linked worktree and add it to `readyWorktrees`.
    private func createAndAddReadyWorktree() async throws {
        let poolID = UUID().uuidString.lowercased()
        let wtPath = poolRoot.appendingPathComponent("wt-\(poolID)", isDirectory: true)
        let branchName = "subagent/\(poolID)"

        let builder = WorktreeBuilder(
            source: sourceRepo,
            dest: wtPath,
            gitRef: gitRef,
            workingTree: .cleanAll,
            creationMode: creationMode,
            allowedPoolRoot: poolRoot
        )
        _ = try builder.create()

        writeMarker(for: wtPath, suffix: readyMarkerSuffix, contents: "")
        let pooled = PooledWorktree(
            id: poolID,
            path: wtPath,
            branchName: branchName,
            createdAt: Date(),
            lastCleanedAt: Date()
        )
        readyWorktrees.append(pooled)
    }

    /// Wipe dirty state in a worktree directory using `git reset --hard HEAD` and `git clean -fdx`.
    @discardableResult
    private func wipeDirtyState(at worktreePath: URL) -> Bool {
        let resetResult = try? runGit(["reset", "--hard", "HEAD"], cwd: worktreePath)
        let cleanResult = try? runGit(["clean", "-fdx"], cwd: worktreePath)

        let resetSuccess = resetResult?.exitCode == 0
        let cleanSuccess = cleanResult?.exitCode == 0
        return resetSuccess && cleanSuccess
    }

    /// Adopt existing directories under `poolRoot` that contain valid git worktrees.
    private func adoptExistingPoolWorktrees() async {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: poolRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard entry.lastPathComponent.hasPrefix("wt-") else { continue }

            let poolID = String(entry.lastPathComponent.dropFirst("wt-".count))
            let claimedMarker = markerURL(for: entry, suffix: claimedMarkerSuffix)

            // If claimed, check stale metadata
            if FileManager.default.fileExists(atPath: claimedMarker.path) {
                if let metadata = readMarkerMetadata(at: claimedMarker) {
                    if isProcessAlive(pid: metadata.processID) {
                        // Still active in another process or session
                        continue
                    }
                }
                // Process is dead, reclaim it
                removeMarker(for: entry, suffix: claimedMarkerSuffix)
            }

            // Verify worktree integrity
            let gitFile = entry.appendingPathComponent(".git")
            guard FileManager.default.fileExists(atPath: gitFile.path) else {
                // Not a valid git worktree directory, skip or remove
                continue
            }

            // Clean and mark ready
            if wipeDirtyState(at: entry) {
                writeMarker(for: entry, suffix: readyMarkerSuffix, contents: "")
                let pooled = PooledWorktree(
                    id: poolID,
                    path: entry,
                    branchName: "subagent/\(poolID)",
                    createdAt: Date(),
                    lastCleanedAt: Date()
                )
                if !readyWorktrees.contains(where: { $0.id == pooled.id || $0.path.path == pooled.path.path }) {
                    readyWorktrees.append(pooled)
                }
            }
        }
    }

    /// Scan `poolRoot` for orphan directories not tracked in the pool and older than `maxAge`.
    private func scanAndCleanOrphanDirectories(maxAge: TimeInterval) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: poolRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        ) else { return }

        let now = Date()
        let knownPaths = Set(readyWorktrees.map(\.path.path) + activeLeases.values.map(\.lease.worktreePath.path))

        for entry in entries {
            let normalized = entry.standardizedFileURL.path
            if knownPaths.contains(normalized) { continue }

            let isMarker = entry.pathExtension == "ready"
                || entry.pathExtension == "claimed"
                || entry.pathExtension == "lock"
                || entry.lastPathComponent.hasSuffix(readyMarkerSuffix)
                || entry.lastPathComponent.hasSuffix(claimedMarkerSuffix)
                || entry.lastPathComponent.hasSuffix(lockMarkerSuffix)

            if isMarker {
                // Marker for unknown worktree
                let baseName = entry.deletingPathExtension().lastPathComponent
                let relatedWorktree = poolRoot.appendingPathComponent(baseName)
                if !knownPaths.contains(relatedWorktree.standardizedFileURL.path) {
                    try? FileManager.default.removeItem(at: entry)
                }
                continue
            }

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path)
                let modDate = (attrs?[.modificationDate] as? Date) ?? now
                if now.timeIntervalSince(modDate) >= maxAge {
                    _ = try? worktreeRemove(source: sourceRepo, dest: entry, force: true)
                    removeMarker(for: entry, suffix: readyMarkerSuffix)
                    removeMarker(for: entry, suffix: claimedMarkerSuffix)
                    removeMarker(for: entry, suffix: lockMarkerSuffix)
                }
            }
        }
    }

    // MARK: - Marker Utilities

    private func markerURL(for worktreePath: URL, suffix: String) -> URL {
        let parent = worktreePath.deletingLastPathComponent()
        let name = worktreePath.lastPathComponent + suffix
        return parent.appendingPathComponent(name)
    }

    private func writeMarker(for worktreePath: URL, suffix: String, contents: String) {
        let marker = markerURL(for: worktreePath, suffix: suffix)
        try? contents.write(to: marker, atomically: true, encoding: .utf8)
    }

    private func writeClaimedMarker(for worktreePath: URL, leaseID: String, sessionID: String) {
        let metadata = WorktreeMarkerMetadata(
            leaseID: leaseID,
            sessionID: sessionID,
            processID: ProcessInfo.processInfo.processIdentifier,
            acquiredAt: Date()
        )
        let marker = markerURL(for: worktreePath, suffix: claimedMarkerSuffix)
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: marker)
        }
    }

    private func removeMarker(for worktreePath: URL, suffix: String) {
        let marker = markerURL(for: worktreePath, suffix: suffix)
        try? FileManager.default.removeItem(at: marker)
    }

    private func readMarkerMetadata(at markerURL: URL) -> WorktreeMarkerMetadata? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(WorktreeMarkerMetadata.self, from: data)
    }
}

// MARK: - Process Liveness Check

private func isProcessAlive(pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    #if os(Windows)
    return true
    #else
    return kill(pid, 0) == 0 || errno == EPERM
    #endif
}
