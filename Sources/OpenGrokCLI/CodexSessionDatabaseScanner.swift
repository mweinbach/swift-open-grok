import Foundation
import OpenGrokFileUtils

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(SQLite3)
import SQLite3
#endif

/// Descriptor-relative capability for one current-user-owned Codex store.
///
/// Codex creates ordinary 0644 files and 0755 directories. Requiring 0600 would
/// silently hide real stores, so reject other-user ownership and group/other
/// write access without rejecting their legitimate read permissions.
final class CodexApprovedRoot {
    let url: URL
    private let originalPath: String

    #if canImport(Darwin) || canImport(Glibc)
    private let descriptor: Int32

    init?(_ path: URL) {
        guard let canonical = try? PathSecurity.canonicalize(path) else { return nil }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let opened = canonical.path.withCString { open($0, flags) }
        guard opened >= 0 else { return nil }
        guard Self.isSafeDirectory(opened) else {
            close(opened)
            return nil
        }
        url = canonical
        originalPath = path.standardizedFileURL.path
        descriptor = opened
    }

    deinit {
        close(descriptor)
    }
    #else
    init?(_ path: URL) {
        _ = path
        return nil
    }
    #endif

    func containsSafeDirectory(_ path: URL) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        guard let components = relativeComponents(for: path),
              let opened = openDirectory(components)
        else { return false }
        close(opened)
        return true
        #else
        return false
        #endif
    }

    func relativeComponents(for path: URL) -> [String]? {
        let candidate = path.standardizedFileURL.path
        for root in [url.path, originalPath] {
            if candidate == root { return [] }
            guard candidate.hasPrefix(root + "/") else { continue }
            let suffix = candidate.dropFirst(root.count + 1)
            let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard components.allSatisfy({
                $0 != "." && $0 != ".." && !$0.contains("\0")
            }) else { return nil }
            return components
        }
        return nil
    }

    func openRegularFile(_ path: URL) -> CodexApprovedFile? {
        #if canImport(Darwin) || canImport(Glibc)
        guard let components = relativeComponents(for: path),
              let name = components.last,
              let parent = openDirectory(Array(components.dropLast()))
        else { return nil }
        defer { close(parent) }

        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let opened = name.withCString { openat(parent, $0, flags) }
        guard opened >= 0 else { return nil }

        var information = stat()
        guard fstat(opened, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o022) == 0,
              information.st_size >= 0
        else {
            close(opened)
            return nil
        }

        #if canImport(Darwin)
        let modified = information.st_mtimespec
        #else
        let modified = information.st_mtim
        #endif

        let canonical = components.reduce(url) { partial, component in
            partial.appendingPathComponent(component)
        }
        return CodexApprovedFile(
            descriptor: opened,
            path: canonical,
            modified: Date(
                timeIntervalSince1970: TimeInterval(modified.tv_sec)
                    + TimeInterval(modified.tv_nsec) / 1_000_000_000
            ),
            size: UInt64(information.st_size),
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
        #else
        return nil
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private func openDirectory(_ components: [String]) -> Int32? {
        var current = dup(descriptor)
        guard current >= 0 else { return nil }

        for component in components {
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            let next = component.withCString { openat(current, $0, flags) }
            close(current)
            guard next >= 0 else { return nil }
            guard Self.isSafeDirectory(next) else {
                close(next)
                return nil
            }
            current = next
        }
        return current
    }

    private static func isSafeDirectory(_ descriptor: Int32) -> Bool {
        var information = stat()
        return fstat(descriptor, &information) == 0
            && information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && information.st_uid == geteuid()
            && information.st_mode & mode_t(0o022) == 0
    }
    #endif
}

final class CodexApprovedFile {
    let descriptor: Int32
    let path: URL
    let modified: Date
    let size: UInt64
    let device: UInt64
    let inode: UInt64

    init(
        descriptor: Int32,
        path: URL,
        modified: Date,
        size: UInt64,
        device: UInt64,
        inode: UInt64
    ) {
        self.descriptor = descriptor
        self.path = path
        self.modified = modified
        self.size = size
        self.device = device
        self.inode = inode
    }

    deinit {
        #if canImport(Darwin) || canImport(Glibc)
        close(descriptor)
        #endif
    }

    func hasSameIdentity(as other: CodexApprovedFile) -> Bool {
        device == other.device && inode == other.inode
    }
}

enum CodexSessionDatabaseScanner {
    private static let maxGeneration = 128
    private static let maxCandidates = 200
    private static let maxIDBytes = 64
    private static let maxPathBytes = 16 * 1024
    private static let maxTextBytes = 64 * 1024
    private static let maxBranchBytes = 4 * 1024
    private static let minimumEpochMilliseconds: Int64 = 1_577_836_800_000

    static func scan(
        root: CodexApprovedRoot,
        requestedCwd: String,
        now: Date
    ) -> [ForeignSessionSummary]? {
        #if canImport(SQLite3)
        guard requestedCwd.utf8.count <= maxPathBytes,
              let bounds = millisecondsBounds(now: now)
        else { return nil }

        for generation in stride(from: maxGeneration, through: 0, by: -1) {
            let path = root.url.appendingPathComponent("state_\(generation).sqlite")
            guard let sessions = scanDatabase(
                root: root,
                path: path,
                requestedCwd: requestedCwd,
                now: now,
                bounds: bounds
            ), !sessions.isEmpty else { continue }
            return sessions
        }
        return nil
        #else
        return nil
        #endif
    }

    #if canImport(SQLite3)
    private static func scanDatabase(
        root: CodexApprovedRoot,
        path: URL,
        requestedCwd: String,
        now: Date,
        bounds: (Int64, Int64)
    ) -> [ForeignSessionSummary]? {
        guard let approved = root.openRegularFile(path) else { return nil }

        var handle: OpaquePointer?
        let noFollow: Int32 = 0x01000000
        let status = approved.path.path.withCString {
            sqlite3_open_v2(
                $0,
                &handle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | noFollow,
                nil
            )
        }
        guard status == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(database) }

        guard let name = sqlite3_db_filename(database, "main"),
              let observed = root.openRegularFile(
                  URL(fileURLWithPath: String(cString: name))
              ),
              approved.hasSameIdentity(as: observed),
              sqlite3_busy_timeout(database, 50) == SQLITE_OK,
              sqlite3_exec(
                  database,
                  "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; BEGIN DEFERRED",
                  nil,
                  nil,
                  nil
              ) == SQLITE_OK
        else { return nil }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

        guard let columns = tableColumns(database),
              let sql = scanSQL(columns: columns)
        else { return nil }

        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK,
              let statement = prepared
        else { return nil }
        defer { sqlite3_finalize(statement) }

        let binding = requestedCwd.withCString {
            sqlite3_bind_text(
                statement,
                1,
                $0,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard binding == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, bounds.0) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, bounds.1) == SQLITE_OK
        else { return nil }

        var sessions: [ForeignSessionSummary] = []
        while sessions.count < ForeignSessionLimits.maxSessionsPerTool {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            if let session = qualifyCandidate(
                statement,
                root: root,
                requestedCwd: requestedCwd,
                now: now
            ) {
                sessions.append(session)
            }
        }
        return sessions
    }

    private static func tableColumns(_ database: OpaquePointer) -> Set<String>? {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(threads)", -1, &prepared, nil)
                == SQLITE_OK,
              let statement = prepared
        else { return nil }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let name = text(statement, index: 1) else {
                return nil
            }
            columns.insert(name)
        }
        return columns.isEmpty ? nil : columns
    }

    private static func scanSQL(columns: Set<String>) -> String? {
        let required: Set<String> = ["id", "rollout_path", "source", "cwd", "archived"]
        guard required.isSubset(of: columns) else { return nil }

        let updated: String
        if columns.contains("updated_at_ms") {
            updated = "updated_at_ms"
        } else if columns.contains("updated_at") {
            updated = "updated_at"
        } else {
            return nil
        }

        let title = columns.contains("title") ? "title" : "''"
        let first = columns.contains("first_user_message") ? "first_user_message" : "''"
        let branch = columns.contains("git_branch") ? "git_branch" : "NULL"
        let safeTitle = boundedText(title, limit: maxTextBytes, fallback: "''")
        let safeFirst = boundedText(first, limit: maxTextBytes, fallback: "''")
        let safeBranch = boundedText(branch, limit: maxBranchBytes, fallback: "NULL")
        let normalizedTimestamp = """
            CASE WHEN \(updated) < \(minimumEpochMilliseconds)
                 THEN \(updated) * 1000 ELSE \(updated) END
            """

        return """
            SELECT id, rollout_path, \(updated), source, cwd,
                   \(safeTitle), \(safeFirst), \(safeBranch)
            FROM threads
            WHERE typeof(id) = 'text'
              AND typeof(rollout_path) = 'text'
              AND typeof(\(updated)) = 'integer'
              AND typeof(archived) = 'integer'
              AND archived = 0
              AND cwd = ?1
              AND source IN ('cli', 'vscode', '{"custom":"atlas"}', '{"custom":"chatgpt"}')
              AND octet_length(id) <= \(maxIDBytes)
              AND octet_length(rollout_path) <= \(maxPathBytes)
              AND \(normalizedTimestamp) BETWEEN ?2 AND ?3
            ORDER BY \(normalizedTimestamp) DESC, id ASC
            LIMIT \(maxCandidates)
            """
    }

    private static func boundedText(_ column: String, limit: Int, fallback: String) -> String {
        """
        CASE WHEN typeof(\(column)) = 'text'
                  AND octet_length(\(column)) <= \(limit)
             THEN \(column) ELSE \(fallback) END
        """
    }

    private static func qualifyCandidate(
        _ statement: OpaquePointer,
        root: CodexApprovedRoot,
        requestedCwd: String,
        now: Date
    ) -> ForeignSessionSummary? {
        guard let id = text(statement, index: 0),
              UUID(uuidString: id) != nil,
              let rollout = text(statement, index: 1),
              sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
              let sourceText = text(statement, index: 3),
              let source = persistedSource(sourceText),
              let cwd = text(statement, index: 4),
              cwd == requestedCwd,
              let updated = normalizeUpdatedAt(sqlite3_column_int64(statement, 2)),
              isForeignSessionWithin(
                  updated,
                  now: now,
                  window: ForeignSessionLimits.maxSessionAge
              ),
              approvedRollout(rollout, expectedID: id, root: root) != nil
        else { return nil }

        let title = text(statement, index: 5).flatMap(normalizeForeignTitle)
            ?? text(statement, index: 6).flatMap(normalizeForeignTitle)
        guard let title else { return nil }
        return ForeignSessionSummary(
            tool: .codex,
            source: source,
            nativeID: id,
            title: title,
            cwd: cwd,
            updatedAt: updated,
            branch: text(statement, index: 7).flatMap(normalizeForeignTitle)
        )
    }

    private static func approvedRollout(
        _ value: String,
        expectedID: String,
        root: CodexApprovedRoot
    ) -> CodexApprovedFile? {
        guard !value.isEmpty,
              !value.contains("\0"),
              !value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
        else { return nil }

        let path: URL
        if value.hasPrefix("/") {
            path = URL(fileURLWithPath: value)
        } else {
            path = value.split(separator: "/").reduce(root.url) { partial, component in
                partial.appendingPathComponent(String(component))
            }
        }
        let compressed = URL(fileURLWithPath: path.path + ".zst")
        for candidate in [path, compressed] {
            guard let components = root.relativeComponents(for: candidate),
                  let prefix = components.first,
                  prefix == "sessions" || prefix == "archived_sessions",
                  rolloutID(from: candidate) == expectedID,
                  let opened = root.openRegularFile(candidate)
            else { continue }
            return opened
        }
        return nil
    }

    private static func rolloutID(from path: URL) -> String? {
        CodexSessionScanner.rolloutID(fromPath: path)
    }

    private static func persistedSource(_ source: String) -> ForeignSessionSource? {
        if let direct = CodexSessionScanner.codexSourceFromString(source) {
            return direct
        }
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return CodexSessionScanner.codexSourceFromObject(object)
    }

    private static func normalizeUpdatedAt(_ value: Int64) -> Date? {
        let milliseconds: Int64
        if value < minimumEpochMilliseconds {
            let multiplied = value.multipliedReportingOverflow(by: 1_000)
            guard !multiplied.overflow else { return nil }
            milliseconds = multiplied.partialValue
        } else {
            milliseconds = value
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func millisecondsBounds(now: Date) -> (Int64, Int64)? {
        let current = now.timeIntervalSince1970 * 1_000
        guard current.isFinite,
              current >= Double(Int64.min),
              current < Double(Int64.max)
        else { return nil }
        let nowMilliseconds = Int64(current)
        let age = Int64(ForeignSessionLimits.maxSessionAge * 1_000)
        let skew = Int64(ForeignSessionLimits.maxFutureSkew * 1_000)
        let oldest = nowMilliseconds.subtractingReportingOverflow(age)
        let newest = nowMilliseconds.addingReportingOverflow(skew)
        guard !oldest.overflow, !newest.overflow else { return nil }
        return (oldest.partialValue, newest.partialValue)
    }

    private static func text(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: value)
    }
    #endif
}
