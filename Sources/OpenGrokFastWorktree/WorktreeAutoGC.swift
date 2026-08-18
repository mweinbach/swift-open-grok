import Foundation

public struct WorktreeAutoGCPolicy: Sendable, Equatable {
    public static let defaultMaxAge: TimeInterval = 7 * 86_400
    public static let defaultMinimumInterval: TimeInterval = 6 * 3_600

    public var enabled: Bool
    public var maxAge: TimeInterval
    public var minimumInterval: TimeInterval
    public var dryRun: Bool
    public var rebuildRegistry: Bool

    public init(
        enabled: Bool = true,
        maxAge: TimeInterval = Self.defaultMaxAge,
        minimumInterval: TimeInterval = Self.defaultMinimumInterval,
        dryRun: Bool = false,
        rebuildRegistry: Bool = false
    ) {
        self.enabled = enabled
        self.maxAge = min(max(maxAge, 3_600), 90 * 86_400)
        self.minimumInterval = min(max(minimumInterval, 60), 7 * 86_400)
        self.dryRun = dryRun
        self.rebuildRegistry = rebuildRegistry
    }
}

public enum WorktreeAutoGCOutcome: String, Sendable, Equatable, Codable {
    case disabled
    case throttled
    case ran
}

public struct WorktreeAutoGCReport: Sendable, Equatable {
    public let outcome: WorktreeAutoGCOutcome
    public let candidates: [String]
    public let removed: [String]
    public let skippedProtected: [String]
    public let skippedDirty: [String]
    public let failures: [String]
    public let stamped: Bool

    public init(
        outcome: WorktreeAutoGCOutcome,
        candidates: [String] = [],
        removed: [String] = [],
        skippedProtected: [String] = [],
        skippedDirty: [String] = [],
        failures: [String] = [],
        stamped: Bool = false
    ) {
        self.outcome = outcome
        self.candidates = candidates
        self.removed = removed
        self.skippedProtected = skippedProtected
        self.skippedDirty = skippedDirty
        self.failures = failures
        self.stamped = stamped
    }
}

public enum WorktreeAutoGC {
    private static let lastRunKey = "last_auto_gc_at"

    public static func runIfDue(
        registry: WorktreeRegistry,
        policy: WorktreeAutoGCPolicy = WorktreeAutoGCPolicy(),
        protectedPaths: [URL] = [],
        now: Date = Date()
    ) throws -> WorktreeAutoGCReport {
        guard policy.enabled else {
            return WorktreeAutoGCReport(outcome: .disabled)
        }

        let metadata = loadMetadata(registry: registry)
        if let lastRun = metadata[lastRunKey],
           lastRun <= now,
           now.timeIntervalSince(lastRun) < policy.minimumInterval {
            return WorktreeAutoGCReport(outcome: .throttled)
        }

        if policy.rebuildRegistry, !policy.dryRun {
            _ = try? registry.rebuild()
        }

        let records = try registry.records()
        let cutoff = now.addingTimeInterval(-policy.maxAge)
        let activeDirectories = processWorkingDirectories().union(
            protectedPaths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        )
        let ageExpiryEnabled = supportsProcessWorkingDirectoryScan || policy.dryRun
        let candidates = records.filter { record in
            if !record.isLive { return true }
            guard ageExpiryEnabled, record.kind != .manual else { return false }
            return record.lastSeenAt < cutoff
        }

        var removed: [String] = []
        var skippedProtected: [String] = []
        var skippedDirty: [String] = []
        var failures: [String] = []

        for record in candidates {
            if record.isLive, activeDirectories.contains(where: { isWithin($0, root: record.path) }) {
                skippedProtected.append(record.id)
                continue
            }
            if record.isLive,
               let dirty = try? getModifiedFiles(repoPath: record.url),
               !dirty.allDirtyPaths.isEmpty {
                skippedDirty.append(record.id)
                continue
            }
            guard !policy.dryRun else { continue }
            do {
                if record.isLive {
                    if FileManager.default.fileExists(atPath: record.sourceURL.path) {
                        _ = try removeWorktree(source: record.sourceURL, dest: record.url, force: false)
                    } else {
                        _ = try removeWorktreeAt(dest: record.url, force: false)
                    }
                }
                try registry.remove(id: record.id)
                removed.append(record.id)
            } catch {
                failures.append("\(record.id): \(error)")
            }
        }

        var stamped = false
        if failures.isEmpty {
            var updated = metadata
            updated[lastRunKey] = now
            do {
                try saveMetadata(updated, registry: registry)
                stamped = true
            } catch {
                failures.append("stamp: \(error)")
            }
        }

        return WorktreeAutoGCReport(
            outcome: .ran,
            candidates: candidates.map(\.id),
            removed: removed,
            skippedProtected: skippedProtected,
            skippedDirty: skippedDirty,
            failures: failures,
            stamped: stamped
        )
    }

    private static var supportsProcessWorkingDirectoryScan: Bool {
        #if os(Linux) || os(macOS)
        true
        #else
        false
        #endif
    }

    private static func processWorkingDirectories() -> Set<String> {
        var paths: Set<String> = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        ]
        #if os(Linux)
        let proc = URL(fileURLWithPath: "/proc", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: proc,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries where Int(entry.lastPathComponent) != nil {
            let cwd = entry.appendingPathComponent("cwd")
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: cwd.path) {
                paths.insert(
                    URL(fileURLWithPath: destination)
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                        .path
                )
            }
        }
        #elseif os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            for line in output.split(separator: "\n") where line.first == "n" {
                let path = String(line.dropFirst())
                guard path.hasPrefix("/") else { continue }
                paths.insert(
                    URL(fileURLWithPath: path)
                        .standardizedFileURL
                        .resolvingSymlinksInPath()
                        .path
                )
            }
        }
        #endif
        return paths
    }

    private static func isWithin(_ candidate: String, root: String) -> Bool {
        let candidatePath = worktreePathKey(candidate)
        let rootPath = worktreePathKey(root)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
    }

    private static func metadataURL(registry: WorktreeRegistry) -> URL {
        registry.openGrokHome.appendingPathComponent("worktrees.meta.json")
    }

    private static func loadMetadata(registry: WorktreeRegistry) -> [String: Date] {
        guard let data = try? Data(contentsOf: metadataURL(registry: registry)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    private static func saveMetadata(
        _ metadata: [String: Date],
        registry: WorktreeRegistry
    ) throws {
        try FileManager.default.createDirectory(
            at: registry.openGrokHome,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(
            to: metadataURL(registry: registry),
            options: .atomic
        )
    }
}
