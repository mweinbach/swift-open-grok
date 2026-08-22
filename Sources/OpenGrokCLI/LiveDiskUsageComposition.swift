import Foundation
import OpenGrokFastWorktree

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct LiveDiskDirectoryUsage: Encodable, Sendable {
    let name: String
    let bytes: UInt64?

    private enum CodingKeys: String, CodingKey {
        case name
        case bytes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if let bytes {
            try container.encode(bytes, forKey: .bytes)
        } else {
            try container.encodeNil(forKey: .bytes)
        }
    }
}

private struct LiveDiskWorktreeUsage: Encodable, Sendable {
    let bytes: UInt64?
    let kind: String
    let tracked: Bool
    let id: String?
    let status: String?
    let createdAt: Int64?
    let lastAccessedAt: Int64?
    let lastModifiedAt: Int64?
    let label: String?
    let repositoryName: String?
    let gitRef: String?
    let path: String

    private enum CodingKeys: String, CodingKey {
        case bytes
        case kind
        case tracked
        case id
        case status
        case createdAt = "created_at"
        case lastAccessedAt = "last_accessed_at"
        case lastModifiedAt = "last_modified_at"
        case label
        case repositoryName = "repo_name"
        case gitRef = "git_ref"
        case path
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeNullable(bytes, forKey: .bytes, in: &container)
        try container.encode(kind, forKey: .kind)
        try container.encode(tracked, forKey: .tracked)
        try encodeNullable(id, forKey: .id, in: &container)
        try encodeNullable(status, forKey: .status, in: &container)
        try encodeNullable(createdAt, forKey: .createdAt, in: &container)
        try encodeNullable(lastAccessedAt, forKey: .lastAccessedAt, in: &container)
        try encodeNullable(lastModifiedAt, forKey: .lastModifiedAt, in: &container)
        try encodeNullable(label, forKey: .label, in: &container)
        try encodeNullable(repositoryName, forKey: .repositoryName, in: &container)
        try encodeNullable(gitRef, forKey: .gitRef, in: &container)
        try container.encode(path, forKey: .path)
    }

    private func encodeNullable<Value: Encodable>(
        _ value: Value?,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

private struct LiveDiskUsageReport: Encodable, Sendable {
    let schemaVersion: UInt32 = 1
    let grokHome: String
    var totalBytes: UInt64 = 0
    var volumeCapacityBytes: UInt64?
    var volumeAvailableBytes: UInt64?
    var topLevelDirectories: [LiveDiskDirectoryUsage] = []
    var rootFilesBytes: UInt64 = 0
    var skippedEntries: UInt64 = 0
    var unreadableDirectories: UInt64 = 0
    var unstatableEntries: UInt64 = 0
    var otherFilesystemDirectories: UInt64 = 0
    var unfollowedDirectorySymlinks: UInt64 = 0
    var worktreesOutsideManagedRoots: UInt64 = 0
    var registry: String = "absent"
    var registryPath: String = ""
    var worktrees: [LiveDiskWorktreeUsage] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case grokHome = "grok_home"
        case totalBytes = "total_bytes"
        case volumeCapacityBytes = "volume_capacity_bytes"
        case volumeAvailableBytes = "volume_available_bytes"
        case topLevelDirectories = "top_level_dirs"
        case rootFilesBytes = "root_files_bytes"
        case skippedEntries = "skipped_entries"
        case unreadableDirectories = "unreadable_dirs"
        case unstatableEntries = "unstatable_entries"
        case otherFilesystemDirectories = "other_filesystem_dirs"
        case unfollowedDirectorySymlinks = "unfollowed_dir_symlinks"
        case worktreesOutsideManagedRoots = "worktrees_outside_managed_roots"
        case registry
        case registryPath = "registry_path"
        case worktrees
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(grokHome, forKey: .grokHome)
        try container.encode(totalBytes, forKey: .totalBytes)
        if let volumeCapacityBytes {
            try container.encode(volumeCapacityBytes, forKey: .volumeCapacityBytes)
        } else {
            try container.encodeNil(forKey: .volumeCapacityBytes)
        }
        if let volumeAvailableBytes {
            try container.encode(volumeAvailableBytes, forKey: .volumeAvailableBytes)
        } else {
            try container.encodeNil(forKey: .volumeAvailableBytes)
        }
        try container.encode(topLevelDirectories, forKey: .topLevelDirectories)
        try container.encode(rootFilesBytes, forKey: .rootFilesBytes)
        try container.encode(skippedEntries, forKey: .skippedEntries)
        try container.encode(unreadableDirectories, forKey: .unreadableDirectories)
        try container.encode(unstatableEntries, forKey: .unstatableEntries)
        try container.encode(otherFilesystemDirectories, forKey: .otherFilesystemDirectories)
        try container.encode(unfollowedDirectorySymlinks, forKey: .unfollowedDirectorySymlinks)
        try container.encode(worktreesOutsideManagedRoots, forKey: .worktreesOutsideManagedRoots)
        try container.encode(registry, forKey: .registry)
        try container.encode(registryPath, forKey: .registryPath)
        try container.encode(worktrees, forKey: .worktrees)
    }
}

private struct LiveDiskFileInformation: Sendable {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let allocatedBytes: UInt64
    let device: UInt64?
    let modifiedAt: Int64?

    static func read(_ url: URL) throws -> Self {
        #if canImport(Darwin) || canImport(Glibc)
        var information = stat()
        guard url.path.withCString({ lstat($0, &information) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fileType = information.st_mode & mode_t(S_IFMT)
        let blocks = information.st_blocks > 0 ? UInt64(information.st_blocks) : 0
        let multiplication = blocks.multipliedReportingOverflow(by: 512)
        #if canImport(Darwin)
        let modifiedAt = Int64(information.st_mtimespec.tv_sec)
        #else
        let modifiedAt = Int64(information.st_mtim.tv_sec)
        #endif
        return Self(
            isDirectory: fileType == mode_t(S_IFDIR),
            isSymbolicLink: fileType == mode_t(S_IFLNK),
            allocatedBytes: multiplication.overflow ? UInt64.max : multiplication.partialValue,
            device: UInt64(information.st_dev),
            modifiedAt: modifiedAt
        )
        #else
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileType = attributes[.type] as? FileAttributeType
        let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date).map {
            Int64($0.timeIntervalSince1970)
        }
        return Self(
            isDirectory: fileType == .typeDirectory,
            isSymbolicLink: fileType == .typeSymbolicLink,
            allocatedBytes: bytes,
            device: nil,
            modifiedAt: modified
        )
        #endif
    }
}

private struct LiveDiskDirectoryMeasure: Sendable {
    var bytes: UInt64
    var lastModifiedAt: Int64?
}

private struct LiveDiskUsageCollector {
    private let fileManager = FileManager.default
    private let home: URL
    private let homeDevice: UInt64?
    private var report: LiveDiskUsageReport

    init(home: URL) throws {
        self.home = home
        homeDevice = try LiveDiskFileInformation.read(home).device
        report = LiveDiskUsageReport(grokHome: home.path)
    }

    mutating func collect() throws -> LiveDiskUsageReport {
        let children = try directoryContents(at: home)
        for child in children {
            guard let information = readInformation(child) else { continue }
            if information.isSymbolicLink {
                report.rootFilesBytes = adding(report.rootFilesBytes, information.allocatedBytes)
                var pointsToDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: child.path, isDirectory: &pointsToDirectory),
                   pointsToDirectory.boolValue {
                    report.unfollowedDirectorySymlinks += 1
                }
                continue
            }
            guard information.isDirectory else {
                report.rootFilesBytes = adding(report.rootFilesBytes, information.allocatedBytes)
                continue
            }
            let measure = measureDirectory(child, information: information)
            report.topLevelDirectories.append(LiveDiskDirectoryUsage(
                name: child.lastPathComponent,
                bytes: measure?.bytes
            ))
        }
        report.topLevelDirectories.sort { lhs, rhs in
            if lhs.bytes == rhs.bytes { return lhs.name < rhs.name }
            return (lhs.bytes ?? 0) > (rhs.bytes ?? 0)
        }
        report.totalBytes = report.topLevelDirectories.compactMap(\.bytes)
            .reduce(report.rootFilesBytes, adding)

        if let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]) {
            report.volumeCapacityBytes = values.volumeTotalCapacity.flatMap {
                $0 >= 0 ? UInt64($0) : nil
            }
            report.volumeAvailableBytes = values.volumeAvailableCapacity.flatMap {
                $0 >= 0 ? UInt64($0) : nil
            }
        }

        collectWorktrees()
        report.skippedEntries = adding(report.unreadableDirectories, report.unstatableEntries)
        return report
    }

    private mutating func collectWorktrees() {
        let registry = WorktreeRegistry(openGrokHome: home)
        report.registryPath = registry.databaseURL.path
        var records: [WorktreeRecord] = []
        if fileManager.fileExists(atPath: registry.databaseURL.path) {
            if let information = readInformation(registry.databaseURL),
               !information.isSymbolicLink,
               fileManager.isReadableFile(atPath: registry.databaseURL.path) {
                do {
                    records = try registry.records()
                    report.registry = "read"
                } catch {
                    report.registry = "corrupt"
                }
            } else {
                report.registry = "unopenable"
            }
        }

        let roots = ["worktrees", "worktree_pool"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
        var knownPaths = Set<String>()
        for record in records {
            let location = URL(fileURLWithPath: record.path).resolvingSymlinksInPath()
            guard fileManager.fileExists(atPath: location.path) else { continue }
            guard isContained(location, in: roots), knownPaths.insert(location.path).inserted else {
                if !isContained(location, in: roots) {
                    report.worktreesOutsideManagedRoots += 1
                }
                continue
            }
            guard let information = readInformation(location), !information.isSymbolicLink else {
                continue
            }
            let measure = measureDirectory(location, information: information)
            report.worktrees.append(LiveDiskWorktreeUsage(
                bytes: measure?.bytes,
                kind: record.kind == .launch ? "session" : "manual",
                tracked: true,
                id: record.id,
                status: "alive",
                createdAt: Int64(record.createdAt.timeIntervalSince1970),
                lastAccessedAt: Int64(record.lastSeenAt.timeIntervalSince1970),
                lastModifiedAt: measure?.lastModifiedAt,
                label: record.label,
                repositoryName: record.repositoryName,
                gitRef: record.ref,
                path: location.path
            ))
        }

        for root in roots {
            guard let information = try? LiveDiskFileInformation.read(root),
                  information.isDirectory, !information.isSymbolicLink else { continue }
            guard let outerEntries = try? directoryContents(at: root) else { continue }
            for outer in outerEntries {
                guard isDiscoverable(outer),
                      let outerInformation = try? LiveDiskFileInformation.read(outer),
                      outerInformation.isDirectory, !outerInformation.isSymbolicLink,
                      let innerEntries = try? directoryContents(at: outer)
                else { continue }
                for candidate in innerEntries {
                    guard isDiscoverable(candidate),
                          let entryInformation = try? LiveDiskFileInformation.read(candidate),
                          entryInformation.isDirectory, !entryInformation.isSymbolicLink
                    else { continue }
                    let canonical = candidate.resolvingSymlinksInPath()
                    guard isContained(canonical, in: roots) else {
                        report.worktreesOutsideManagedRoots += 1
                        continue
                    }
                    guard knownPaths.insert(canonical.path).inserted else { continue }
                    let measure = measureDirectory(canonical, information: entryInformation)
                    report.worktrees.append(LiveDiskWorktreeUsage(
                        bytes: measure?.bytes,
                        kind: root.lastPathComponent == "worktree_pool" ? "pool" : "session",
                        tracked: false,
                        id: nil,
                        status: nil,
                        createdAt: nil,
                        lastAccessedAt: nil,
                        lastModifiedAt: measure?.lastModifiedAt,
                        label: nil,
                        repositoryName: nil,
                        gitRef: nil,
                        path: canonical.path
                    ))
                }
            }
        }

        report.worktrees.sort { lhs, rhs in
            if lhs.bytes == rhs.bytes { return lhs.path < rhs.path }
            return (lhs.bytes ?? 0) > (rhs.bytes ?? 0)
        }
    }

    private mutating func measureDirectory(
        _ directory: URL,
        information: LiveDiskFileInformation
    ) -> LiveDiskDirectoryMeasure? {
        if let homeDevice, let device = information.device, homeDevice != device {
            report.otherFilesystemDirectories += 1
            return nil
        }
        let children: [URL]
        do {
            children = try directoryContents(at: directory)
        } catch {
            report.unreadableDirectories += 1
            return LiveDiskDirectoryMeasure(bytes: 0, lastModifiedAt: nil)
        }

        var result = LiveDiskDirectoryMeasure(bytes: 0, lastModifiedAt: nil)
        for child in children {
            guard let childInformation = readInformation(child) else { continue }
            if childInformation.isDirectory, !childInformation.isSymbolicLink {
                if let nested = measureDirectory(child, information: childInformation) {
                    result.bytes = adding(result.bytes, nested.bytes)
                    result.lastModifiedAt = maxOptional(result.lastModifiedAt, nested.lastModifiedAt)
                }
            } else {
                result.bytes = adding(result.bytes, childInformation.allocatedBytes)
                result.lastModifiedAt = maxOptional(
                    result.lastModifiedAt, childInformation.modifiedAt
                )
            }
        }
        return result
    }

    private mutating func readInformation(_ url: URL) -> LiveDiskFileInformation? {
        do {
            return try LiveDiskFileInformation.read(url)
        } catch {
            report.unstatableEntries += 1
            return nil
        }
    }

    private func directoryContents(at directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isContained(_ candidate: URL, in roots: [URL]) -> Bool {
        roots.contains { root in
            let prefix = root.standardizedFileURL.path + "/"
            return candidate.standardizedFileURL.path.hasPrefix(prefix)
        }
    }

    private func isDiscoverable(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return !name.hasPrefix(".")
            && !name.hasSuffix(".ready")
            && !name.hasSuffix(".claimed")
            && !name.hasSuffix(".claiming")
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let sum = lhs.addingReportingOverflow(rhs)
        return sum.overflow ? .max : sum.partialValue
    }

    private func maxOptional(_ lhs: Int64?, _ rhs: Int64?) -> Int64? {
        switch (lhs, rhs) {
        case (.some(let first), .some(let second)):
            return max(first, second)
        case (.some(let value), .none), (.none, .some(let value)):
            return value
        case (.none, .none):
            return nil
        }
    }
}

public enum LiveDiskUsageComposition {
    public static func run(
        json: Bool,
        environment: [String: String],
        streams: CLIStreams
    ) -> Int32 {
        let requestedHome = OpenGrokHomeResolver.resolve(environment: environment)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: requestedHome.path) else {
            if json {
                return write(LiveDiskUsageReport(grokHome: requestedHome.path), streams: streams)
            }
            streams.out("Nothing on disk yet at \(homeLabel(environment: environment)).\n")
            return CLIRunner.ExitCode.success.rawValue
        }

        do {
            var collector = try LiveDiskUsageCollector(home: requestedHome.resolvingSymlinksInPath())
            let report = try collector.collect()
            if json { return write(report, streams: streams) }
            streams.out(humanReport(report, environment: environment))
            return CLIRunner.ExitCode.success.rawValue
        } catch {
            streams.err("open-grok: cannot inspect disk usage at \(requestedHome.path): \(error).\n")
            return CLIRunner.ExitCode.failure.rawValue
        }
    }

    private static func write(_ report: LiveDiskUsageReport, streams: CLIStreams) -> Int32 {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            guard let output = String(data: data, encoding: .utf8) else {
                throw CLIApplicationError.failed("disk-usage report is not valid UTF-8")
            }
            streams.out(output + "\n")
            return CLIRunner.ExitCode.success.rawValue
        } catch {
            streams.err("open-grok: cannot encode disk-usage report: \(error).\n")
            return CLIRunner.ExitCode.failure.rawValue
        }
    }

    private static func humanReport(
        _ report: LiveDiskUsageReport,
        environment: [String: String]
    ) -> String {
        var lines = ["Disk usage for \(homeLabel(environment: environment))"]
        for directory in report.topLevelDirectories {
            lines.append("  \(size(directory.bytes))  \(directory.name)")
        }
        if report.rootFilesBytes > 0 {
            lines.append("  \(size(report.rootFilesBytes))  (top-level files)")
        }
        lines.append("  \(size(report.totalBytes))  total")
        if report.unfollowedDirectorySymlinks > 0 {
            lines.append("  \(report.unfollowedDirectorySymlinks) top-level directory symlink(s) not followed.")
        }
        lines.append("")
        lines.append("Worktrees")
        if report.worktreesOutsideManagedRoots > 0 {
            lines.append("  \(report.worktreesOutsideManagedRoots) worktree(s) outside managed roots not shown.")
        }
        if report.registry != "read", report.registry != "absent" {
            lines.append("  Worktree registry is \(report.registry); rows show as untracked.")
        }
        if report.worktrees.isEmpty {
            lines.append("  No worktrees found.")
        } else {
            lines.append("  SIZE  TYPE  PATH")
            for worktree in report.worktrees {
                let kind = worktree.tracked ? worktree.kind : "untracked (\(worktree.kind))"
                lines.append("  \(size(worktree.bytes))  \(kind)  \(worktree.path)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func size(_ bytes: UInt64?) -> String {
        guard let bytes else { return "-" }
        if bytes < 1_024 { return "\(bytes) B" }
        let units = ["KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var index = -1
        while value >= 1_024, index < units.count - 1 {
            value /= 1_024
            index += 1
        }
        return String(format: "%.1f %@", value, units[index])
    }

    private static func homeLabel(environment: [String: String]) -> String {
        if let override = environment["OPENGROK_HOME"], !override.isEmpty {
            return "$OPENGROK_HOME"
        }
        return "~/.opengrok"
    }
}
