import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

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

enum WorktreeAutoGCScanFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case processEnumerationFailed(String)
    case processEnumerationTimedOut
    case currentProcessNotObserved
    case dirtyStateUnavailable(String)
    case creatorStateUnavailable(String)
    case unsafeWorktree(String)

    var description: String {
        switch self {
        case .processEnumerationFailed(let reason):
            "process working-directory scan failed: \(reason)"
        case .processEnumerationTimedOut:
            "process working-directory scan timed out"
        case .currentProcessNotObserved:
            "process working-directory scan did not observe this process and its current directory"
        case .dirtyStateUnavailable(let reason):
            "worktree dirty state could not be verified: \(reason)"
        case .creatorStateUnavailable(let reason):
            "worktree creator process could not be verified: \(reason)"
        case .unsafeWorktree(let reason):
            "refusing unsafe worktree removal: \(reason)"
        }
    }
}

struct WorktreeAutoGCProcessObservation: Sendable, Equatable {
    let processID: Int32
    let workingDirectory: String

    init(processID: Int32, workingDirectory: String) {
        self.processID = processID
        self.workingDirectory = workingDirectory
    }
}

enum WorktreeAutoGCProcessScan: Sendable, Equatable {
    case observed([WorktreeAutoGCProcessObservation])
    case unsupported
    case failed(WorktreeAutoGCScanFailure)
}

public enum WorktreeAutoGC {
    private static let lastRunKey = "last_auto_gc_at"
    private static let processScanTimeout: TimeInterval = 5

    public static func runIfDue(
        registry: WorktreeRegistry,
        policy: WorktreeAutoGCPolicy = WorktreeAutoGCPolicy(),
        protectedPaths: [URL] = [],
        now: Date = Date()
    ) throws -> WorktreeAutoGCReport {
        try runIfDue(
            registry: registry,
            policy: policy,
            protectedPaths: protectedPaths,
            now: now,
            processScan: processWorkingDirectories,
            dirtyScan: scanDirtyFiles
        )
    }

    static func runIfDue(
        registry: WorktreeRegistry,
        policy: WorktreeAutoGCPolicy,
        protectedPaths: [URL],
        now: Date,
        activeProcessDirectories: () -> Set<String>
    ) throws -> WorktreeAutoGCReport {
        try runIfDue(
            registry: registry,
            policy: policy,
            protectedPaths: protectedPaths,
            now: now,
            processScan: {
                .observed(activeProcessDirectories().map {
                    WorktreeAutoGCProcessObservation(
                        processID: ProcessInfo.processInfo.processIdentifier,
                        workingDirectory: $0
                    )
                })
            },
            dirtyScan: scanDirtyFiles
        )
    }

    static func runIfDue(
        registry: WorktreeRegistry,
        policy: WorktreeAutoGCPolicy,
        protectedPaths: [URL],
        now: Date,
        processScan: () -> WorktreeAutoGCProcessScan
    ) throws -> WorktreeAutoGCReport {
        try runIfDue(
            registry: registry,
            policy: policy,
            protectedPaths: protectedPaths,
            now: now,
            processScan: processScan,
            dirtyScan: scanDirtyFiles
        )
    }

    static func runIfDue(
        registry: WorktreeRegistry,
        policy: WorktreeAutoGCPolicy,
        protectedPaths: [URL],
        now: Date,
        processScan: () -> WorktreeAutoGCProcessScan,
        dirtyScan: (URL) -> Result<DirtyFilesReport, WorktreeAutoGCScanFailure>
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
            try registry.rebuild()
        }

        let records = try registry.records()
        let cutoff = now.addingTimeInterval(-policy.maxAge)
        let ageExpiryEnabled = supportsProcessWorkingDirectoryScan || policy.dryRun
        let candidates = records.filter { record in
            if !record.isLive { return true }
            guard ageExpiryEnabled, record.kind != .manual else { return false }
            return record.lastSeenAt < cutoff
        }
        let protectedDirectories = Set(protectedPaths.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
        })
        var activeDirectories: Set<String>?
        var failures: [String] = []
        if candidates.contains(where: \.isLive) {
            switch validatedProcessDirectories(processScan()) {
            case .success(let directories):
                activeDirectories = directories.union(protectedDirectories)
            case .failure(let error):
                failures.append("process scan: \(error)")
            }
        }

        var removed: [String] = []
        var skippedProtected: [String] = []
        var skippedDirty: [String] = []

        for record in candidates {
            do {
                if record.isLive {
                    if protects(record: record, directories: protectedDirectories) {
                        skippedProtected.append(record.id)
                        continue
                    }
                    guard let currentDirectories = activeDirectories else { continue }
                    if protects(record: record, directories: currentDirectories) {
                        skippedProtected.append(record.id)
                        continue
                    }
                    if try hasLiveCreator(record: record, registry: registry) {
                        skippedProtected.append(record.id)
                        continue
                    }

                    try validateCandidate(record)

                    let dirty: DirtyFilesReport
                    switch dirtyScan(record.url) {
                    case .success(let report):
                        dirty = report
                    case .failure(let error):
                        throw error
                    }
                    if !dirty.allDirtyPaths.isEmpty {
                        skippedDirty.append(record.id)
                        continue
                    }

                    guard !policy.dryRun else { continue }

                    let freshRecords = try registry.records()
                    guard let fresh = freshRecords.first(where: { $0.id == record.id }),
                          fresh.path == record.path,
                          fresh.sourceRepository == record.sourceRepository,
                          fresh.isLive,
                          fresh.kind != .manual,
                          fresh.lastSeenAt < cutoff
                    else {
                        skippedProtected.append(record.id)
                        continue
                    }

                    let freshDirectories: Set<String>
                    switch validatedProcessDirectories(processScan()) {
                    case .success(let directories):
                        freshDirectories = directories.union(protectedDirectories)
                    case .failure(let error):
                        activeDirectories = nil
                        throw error
                    }
                    if protects(record: fresh, directories: freshDirectories) {
                        skippedProtected.append(record.id)
                        continue
                    }
                    if try hasLiveCreator(record: fresh, registry: registry) {
                        skippedProtected.append(record.id)
                        continue
                    }

                    try validateCandidate(fresh)
                    guard FileManager.default.fileExists(atPath: fresh.sourceURL.path) else {
                        throw WorktreeAutoGCScanFailure.unsafeWorktree(
                            "source repository is missing for \(fresh.path)"
                        )
                    }

                    let removal = try removeWorktree(
                        source: fresh.sourceURL,
                        dest: fresh.url,
                        force: false
                    )
                    guard removal.removed,
                          !FileManager.default.fileExists(atPath: fresh.path)
                    else {
                        throw WorktreeAutoGCScanFailure.unsafeWorktree(
                            "Git did not confirm removal of \(fresh.path)"
                        )
                    }
                } else if policy.dryRun {
                    continue
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

    private static func processWorkingDirectories() -> WorktreeAutoGCProcessScan {
        #if os(Linux)
        let proc = URL(fileURLWithPath: "/proc", isDirectory: true)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: proc,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .failed(.processEnumerationFailed("cannot enumerate /proc: \(error)"))
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let budget = UInt64(processScanTimeout * 1_000_000_000)
        var observations: [WorktreeAutoGCProcessObservation] = []
        for entry in entries {
            if DispatchTime.now().uptimeNanoseconds - started >= budget {
                return .failed(.processEnumerationTimedOut)
            }
            guard let processID = Int32(entry.lastPathComponent), processID > 0 else {
                continue
            }
            let cwd = entry.appendingPathComponent("cwd")
            do {
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: cwd.path)
                observations.append(
                    WorktreeAutoGCProcessObservation(
                        processID: processID,
                        workingDirectory: destination
                    )
                )
            } catch {
                continue
            }
        }
        return .observed(observations)
        #elseif os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-d", "cwd", "-Fpn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }
        do {
            try process.run()
        } catch {
            return .failed(.processEnumerationFailed("cannot launch lsof: \(error)"))
        }

        let reader = GitPipeReader(pipe.fileHandleForReading)
        reader.start()
        let deadline = DispatchTime.now() + processScanTimeout
        guard finished.wait(timeout: deadline) == .success else {
            process.terminate()
            return .failed(.processEnumerationTimedOut)
        }
        guard process.terminationStatus == 0 else {
            return .failed(.processEnumerationFailed("lsof exited \(process.terminationStatus)"))
        }
        guard let data = reader.result(until: deadline) else {
            return .failed(.processEnumerationTimedOut)
        }

        let output = String(decoding: data, as: UTF8.self)
        var observations: [WorktreeAutoGCProcessObservation] = []
        var processID: Int32?
        for line in output.split(whereSeparator: \.isNewline) {
            switch line.first {
            case "p":
                processID = Int32(line.dropFirst())
            case "n":
                let path = String(line.dropFirst())
                guard let processID, processID > 0, path.hasPrefix("/") else { continue }
                observations.append(
                    WorktreeAutoGCProcessObservation(
                        processID: processID,
                        workingDirectory: path
                    )
                )
            default:
                continue
            }
        }
        return .observed(observations)
        #else
        return .unsupported
        #endif
    }

    private static func validatedProcessDirectories(
        _ scan: WorktreeAutoGCProcessScan
    ) -> Result<Set<String>, WorktreeAutoGCScanFailure> {
        switch scan {
        case .failed(let error):
            return .failure(error)
        case .unsupported:
            return .failure(.processEnumerationFailed("platform has no process directory enumerator"))
        case .observed(let observations):
            let currentProcess = ProcessInfo.processInfo.processIdentifier
            let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard observations.contains(where: {
                $0.processID == currentProcess
                    && worktreePathKey(resolvedPath($0.workingDirectory))
                        == worktreePathKey(currentDirectory)
            }) else {
                return .failure(.currentProcessNotObserved)
            }
            return .success(Set(observations.map { resolvedPath($0.workingDirectory) }))
        }
    }

    private static func scanDirtyFiles(
        at url: URL
    ) -> Result<DirtyFilesReport, WorktreeAutoGCScanFailure> {
        do {
            return .success(try getModifiedFiles(repoPath: url))
        } catch {
            return .failure(.dirtyStateUnavailable(String(describing: error)))
        }
    }

    private static func protects(record: WorktreeRecord, directories: Set<String>) -> Bool {
        directories.contains { directory in
            isWithin(directory, root: record.path)
                || isWithin(directory, root: resolvedPath(record.path))
        }
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func validateCandidate(_ record: WorktreeRecord) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: record.path)
        } catch {
            throw WorktreeAutoGCScanFailure.unsafeWorktree(
                "cannot inspect \(record.path): \(error)"
            )
        }
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw WorktreeAutoGCScanFailure.unsafeWorktree(
                "\(record.path) is not a real directory"
            )
        }
        let sourcePath = resolvedPath(record.sourceRepository)
        if isWithin(sourcePath, root: record.path)
            || isWithin(sourcePath, root: resolvedPath(record.path))
        {
            throw WorktreeAutoGCScanFailure.unsafeWorktree(
                "candidate contains its source repository: \(record.path)"
            )
        }
    }

    private static func hasLiveCreator(
        record: WorktreeRecord,
        registry: WorktreeRegistry
    ) throws -> Bool {
        let records: [WorktreeCreatorRecord]
        do {
            let data = try Data(contentsOf: registry.databaseURL)
            records = try JSONDecoder().decode([WorktreeCreatorRecord].self, from: data)
        } catch {
            throw WorktreeAutoGCScanFailure.creatorStateUnavailable(String(describing: error))
        }

        var creatorIDs: [Int32] = []
        if let creatorID = records.first(where: { $0.id == record.id })?.creatorPID {
            creatorIDs.append(creatorID)
        }

        let claimed = record.url.deletingLastPathComponent()
            .appendingPathComponent(record.url.lastPathComponent + ".claimed")
        if FileManager.default.fileExists(atPath: claimed.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: claimed.path)
                guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                    throw WorktreeAutoGCScanFailure.creatorStateUnavailable(
                        "claimed marker is not a regular file: \(claimed.path)"
                    )
                }
                let data = try Data(contentsOf: claimed)
                let marker = try JSONDecoder().decode(WorktreeMarkerMetadata.self, from: data)
                creatorIDs.append(marker.processID)
            } catch let error as WorktreeAutoGCScanFailure {
                throw error
            } catch {
                throw WorktreeAutoGCScanFailure.creatorStateUnavailable(String(describing: error))
            }
        }

        for processID in creatorIDs {
            guard processID > 0 else {
                throw WorktreeAutoGCScanFailure.creatorStateUnavailable(
                    "invalid creator process ID \(processID)"
                )
            }
            #if os(Windows)
            return true
            #else
            if kill(processID, 0) == 0 || errno != ESRCH {
                return true
            }
            #endif
        }
        return false
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

private struct WorktreeCreatorRecord: Decodable {
    let id: String
    let creatorPID: Int32?

    private enum CodingKeys: String, CodingKey {
        case id
        case creatorPID
        case creatorSnakePID = "creator_pid"
        case processID
        case processSnakeID = "process_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        var observed: [Int32] = []
        for key in [
            CodingKeys.creatorPID,
            .creatorSnakePID,
            .processID,
            .processSnakeID,
        ] where container.contains(key) {
            if let processID = try container.decodeIfPresent(Int32.self, forKey: key) {
                observed.append(processID)
            }
        }
        guard Set(observed).count <= 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "conflicting creator process identifiers"
            ))
        }
        creatorPID = observed.first
    }
}
