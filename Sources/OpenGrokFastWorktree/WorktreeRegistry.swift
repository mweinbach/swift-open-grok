import Foundation

public enum WorktreeRecordKind: String, Codable, Sendable, Equatable, CaseIterable {
    case launch
    case manual
}

public struct WorktreeRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let sourceRepository: String
    public let repositoryName: String
    public let kind: WorktreeRecordKind
    public let creationMode: CreationMode
    public let ref: String
    public let head: String
    public let sessionID: String?
    public let label: String?
    public let createdAt: Date
    public var lastSeenAt: Date

    public init(
        id: String = UUID().uuidString,
        path: URL,
        sourceRepository: URL,
        repositoryName: String,
        kind: WorktreeRecordKind = .manual,
        creationMode: CreationMode = .gitCheckout,
        ref: String = "HEAD",
        head: String = "",
        sessionID: String? = nil,
        label: String? = nil,
        createdAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.path = path.standardizedFileURL.path
        self.sourceRepository = sourceRepository.standardizedFileURL.path
        self.repositoryName = repositoryName
        self.kind = kind
        self.creationMode = creationMode
        self.ref = ref
        self.head = head
        self.sessionID = sessionID
        self.label = label
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var sourceURL: URL { URL(fileURLWithPath: sourceRepository) }
    public var isLive: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

public struct WorktreeDatabaseStats: Codable, Sendable, Equatable {
    public let total: Int
    public let live: Int
    public let stale: Int

    public init(total: Int, live: Int, stale: Int) {
        self.total = total
        self.live = live
        self.stale = stale
    }
}

public struct WorktreeRegistry: Sendable {
    public let openGrokHome: URL
    public let databaseURL: URL
    public let poolRoot: URL

    public init(openGrokHome: URL) {
        self.openGrokHome = openGrokHome.standardizedFileURL
        self.databaseURL = self.openGrokHome.appendingPathComponent("worktrees.db")
        self.poolRoot = self.openGrokHome.appendingPathComponent("worktrees", isDirectory: true)
    }

    public func records() throws -> [WorktreeRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: databaseURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([WorktreeRecord].self, from: data)
        } catch {
            throw FastWorktreeError.gitFailed("failed to read worktree registry: \(error)")
        }
    }

    public func register(_ record: WorktreeRecord) throws {
        var current = try records()
        current.removeAll { $0.id == record.id || $0.path == record.path }
        current.append(record)
        try write(current)
    }

    public func updateSession(id: String, sessionID: String) throws {
        var current = try records()
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            throw FastWorktreeError.gitFailed("worktree record not found: \(id)")
        }
        let record = current[index]
        current[index] = WorktreeRecord(
            id: record.id,
            path: record.url,
            sourceRepository: record.sourceURL,
            repositoryName: record.repositoryName,
            kind: record.kind,
            creationMode: record.creationMode,
            ref: record.ref,
            head: record.head,
            sessionID: sessionID,
            label: record.label,
            createdAt: record.createdAt,
            lastSeenAt: Date()
        )
        try write(current)
    }

    public func remove(id: String) throws {
        var current = try records()
        current.removeAll { $0.id == id }
        try write(current)
    }

    public func remove(path: URL) throws {
        let normalized = path.standardizedFileURL.path
        var current = try records()
        current.removeAll { $0.path == normalized }
        try write(current)
    }

    public func stats() throws -> WorktreeDatabaseStats {
        let current = try records()
        let live = current.filter(\.isLive).count
        return WorktreeDatabaseStats(total: current.count, live: live, stale: current.count - live)
    }

    @discardableResult
    public func rebuild() throws -> WorktreeDatabaseStats {
        let current = try records()
        let live = current.filter(\.isLive)
        try write(live)
        return WorktreeDatabaseStats(
            total: live.count,
            live: live.count,
            stale: current.count - live.count
        )
    }

    private func write(_ records: [WorktreeRecord]) throws {
        do {
            try FileManager.default.createDirectory(
                at: openGrokHome,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(records.sorted { $0.createdAt < $1.createdAt })
            try data.write(to: databaseURL, options: .atomic)
        } catch {
            throw FastWorktreeError.gitFailed("failed to write worktree registry: \(error)")
        }
    }
}
