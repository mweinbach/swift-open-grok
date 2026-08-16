import Foundation
import OpenGrokFastWorktree
import OpenGrokGitStatus

enum LiveWorktreeComposition {
    private struct RenderedRecord: Codable, Sendable {
        let id: String
        let path: String
        let sourceRepository: String
        let repository: String
        let type: String
        let creationMode: String
        let ref: String
        let head: String
        let sessionID: String?
        let label: String?
        let createdAt: Date
        let live: Bool

        init(_ record: WorktreeRecord) {
            id = record.id
            path = record.path
            sourceRepository = record.sourceRepository
            repository = record.repositoryName
            type = record.kind.rawValue
            creationMode = record.creationMode.rawValue
            ref = record.ref
            head = record.head
            sessionID = record.sessionID
            label = record.label
            createdAt = record.createdAt
            live = record.isLive
        }
    }

    private struct ListOutput: Codable, Sendable {
        let worktrees: [RenderedRecord]
    }

    private struct GCOutput: Codable, Sendable {
        let candidates: [String]
        let removed: [String]
    }

    static func handles(_ command: CLICommand) -> Bool {
        guard case .utility(let options) = command else { return false }
        return options.name == "worktree"
    }

    static func session(
        for command: CLICommand,
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, options.name == "worktree" else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try run(options: options, environment: context.environment, streams: context.streams)
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams
    ) throws {
        guard let action = options.values.first else {
            throw CLIApplicationError.failed("worktree requires an action")
        }
        let registry = WorktreeRegistry(openGrokHome: OpenGrokHomeResolver.resolve(environment: environment))
        switch action {
        case "list", "ls":
            try list(options: options, registry: registry, streams: streams)
        case "show":
            try show(options: options, registry: registry, streams: streams)
        case "rm":
            try remove(options: options, registry: registry, streams: streams)
        case "gc", "prune":
            try garbageCollect(options: options, registry: registry, streams: streams)
        case "db":
            try database(options: options, registry: registry, streams: streams)
        default:
            throw CLIApplicationError.failed("unknown worktree action: (action)")
        }
    }

    private static func list(
        options: CLIUtilityOptions,
        registry: WorktreeRegistry,
        streams: CLIStreams
    ) throws {
        let types = try requestedTypes(options)
        let repo = options.options["--repo"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = try registry.records().filter { record in
            (options.flags.contains("--all") || record.isLive)
                && (types.isEmpty || types.contains(record.kind))
                && (repo == nil || repo == record.repositoryName || repo == record.sourceRepository)
        }
        let rendered = records.map(RenderedRecord.init)
        if options.json {
            streams.out(try encode(ListOutput(worktrees: rendered)))
            return
        }
        for record in rendered {
            streams.out("\(record.id)\t\(record.path)\t\(record.repository)\t\(record.type)\n")
        }
    }

    private static func show(
        options: CLIUtilityOptions,
        registry: WorktreeRegistry,
        streams: CLIStreams
    ) throws {
        guard options.values.count == 2 else {
            throw CLIApplicationError.failed("worktree show requires one id or path")
        }
        let record = try findRecord(options.values[1], registry: registry)
        if options.json {
            streams.out(try encode(RenderedRecord(record)))
        } else {
            let rendered = RenderedRecord(record)
            streams.out("id: \(rendered.id)\n")
            streams.out("path: \(rendered.path)\n")
            streams.out("repository: \(rendered.sourceRepository)\n")
            streams.out("type: \(rendered.type)\n")
            streams.out("ref: \(rendered.ref)\n")
            streams.out("head: \(rendered.head)\n")
            streams.out("live: \(rendered.live)\n")
        }
    }

    private static func remove(
        options: CLIUtilityOptions,
        registry: WorktreeRegistry,
        streams: CLIStreams
    ) throws {
        guard options.values.count > 1 else {
            throw CLIApplicationError.failed("worktree rm requires at least one id or path")
        }
        let dryRun = options.flags.contains("--dry-run")
        var removed: [String] = []
        for target in options.values.dropFirst() {
            let record = try findRecord(target, registry: registry)
            if dryRun {
                streams.out("would remove \(record.id) \(record.path)\n")
                continue
            }
            if !options.force, record.isLive, try hasLocalChanges(record) {
                throw CLIApplicationError.failed(
                    "worktree \(record.id) has local changes; use --force to remove it"
                )
            }
            do {
                if FileManager.default.fileExists(atPath: record.sourceURL.path) {
                    _ = try removeWorktree(source: record.sourceURL, dest: record.url, force: options.force)
                } else {
                    _ = try removeWorktreeAt(dest: record.url, force: options.force)
                }
                try registry.remove(id: record.id)
                removed.append(record.id)
            } catch let error as FastWorktreeError {
                throw CLIApplicationError.failed("could not remove worktree \(record.id): \(error)")
            }
        }
        if options.json {
            streams.out(try encode(removed))
        } else if !removed.isEmpty {
            streams.out("removed \(removed.count) worktree(s)\n")
        }
    }

    private static func garbageCollect(
        options: CLIUtilityOptions,
        registry: WorktreeRegistry,
        streams: CLIStreams
    ) throws {
        let maxAge = try parseAge(options.options["--max-age"] ?? "7d")
        let cutoff = Date().addingTimeInterval(-maxAge)
        let candidates = try registry.records().filter { record in
            !record.isLive || record.lastSeenAt < cutoff
        }
        let dryRun = options.flags.contains("--dry-run")
        var removed: [String] = []
        if !dryRun {
            for record in candidates {
                if record.isLive, !options.force { continue }
                if record.isLive {
                    if FileManager.default.fileExists(atPath: record.sourceURL.path) {
                        _ = try removeWorktree(source: record.sourceURL, dest: record.url, force: true)
                    } else {
                        _ = try removeWorktreeAt(dest: record.url, force: true)
                    }
                }
                try registry.remove(id: record.id)
                removed.append(record.id)
            }
        }
        if options.json {
            streams.out(try encode(GCOutput(
                candidates: candidates.map(\.id),
                removed: removed
            )))
        } else {
            streams.out("gc candidates: \(candidates.count)\n")
            streams.out("gc removed: \(removed.count)\n")
        }
    }

    private static func database(
        options: CLIUtilityOptions,
        registry: WorktreeRegistry,
        streams: CLIStreams
    ) throws {
        guard options.values.count == 2 else {
            throw CLIApplicationError.failed("worktree db requires rebuild, stats, or path")
        }
        switch options.values[1] {
        case "path":
            streams.out("\(registry.databaseURL.path)\n")
        case "stats":
            let stats = try registry.stats()
            if options.json {
                streams.out(try encode(stats))
            } else {
                streams.out("total: \(stats.total)\nlive: \(stats.live)\nstale: \(stats.stale)\n")
            }
        case "rebuild":
            let stats = try registry.rebuild()
            if options.json {
                streams.out(try encode(stats))
            } else {
                streams.out("rebuilt worktree database: \(stats.total) record(s)\n")
            }
        default:
            throw CLIApplicationError.failed("unknown worktree db action: \(options.values[1])")
        }
    }

    private static func requestedTypes(_ options: CLIUtilityOptions) throws -> Set<WorktreeRecordKind> {
        guard let raw = options.options["--type"], !raw.isEmpty else { return [] }
        var result = Set<WorktreeRecordKind>()
        for value in raw.split(separator: ",").map(String.init) {
            guard let kind = WorktreeRecordKind(rawValue: value) else {
                throw CLIApplicationError.failed("unknown worktree type: \(value)")
            }
            result.insert(kind)
        }
        return result
    }

    private static func findRecord(_ target: String, registry: WorktreeRegistry) throws -> WorktreeRecord {
        let records = try registry.records()
        if let byID = records.first(where: { $0.id == target }) { return byID }
        let path = URL(fileURLWithPath: target).standardizedFileURL.path
        if let byPath = records.first(where: { $0.path == path }) { return byPath }
        throw CLIApplicationError.failed("worktree not found: \(target)")
    }

    static func hasLocalChanges(_ record: WorktreeRecord) throws -> Bool {
        do {
            return try !gitStatus(path: record.path).clean
        } catch {
            return try !getModifiedFiles(repoPath: record.url).allDirtyPaths.isEmpty
        }
    }

    private static func parseAge(_ value: String) throws -> TimeInterval {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { throw CLIApplicationError.failed("--max-age must not be empty") }
        let suffix = trimmed.last.flatMap { "smhdw".contains($0) ? $0 : nil }
        let number = suffix == nil ? trimmed : String(trimmed.dropLast())
        guard let amount = Double(number), amount >= 0 else {
            throw CLIApplicationError.failed("invalid --max-age: \(value)")
        }
        switch suffix {
        case "s": return amount
        case "m": return amount * 60
        case "h": return amount * 3_600
        case "d": return amount * 86_400
        case "w": return amount * 604_800
        default: return amount
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }
}
