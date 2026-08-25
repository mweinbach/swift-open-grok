import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokSessionPersistence

#if canImport(SQLite3)
import SQLite3
#endif

struct LiveSessionSearchIndexSource {
    let sessionID: String
    let workingDirectory: String
    let updatedAt: Date
    let load: () throws -> LiveSessionDocument?

    init(
        sessionID: String,
        workingDirectory: String,
        updatedAt: Date,
        load: @escaping () throws -> LiveSessionDocument?
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.updatedAt = updatedAt
        self.load = load
    }

    init(document: LiveSessionDocument) {
        self.init(
            sessionID: document.sessionID,
            workingDirectory: document.workingDirectory,
            updatedAt: document.updatedAt,
            load: { document }
        )
    }
}

struct LiveSessionSearchPage {
    var hits: [LiveSessionSearchHit]
    var total: Int
    var nextOffset: Int?
    var bootstrapping: Bool
    var documentsByID: [String: LiveSessionDocument]

    static var empty: LiveSessionSearchPage {
        LiveSessionSearchPage(
            hits: [],
            total: 0,
            nextOffset: nil,
            bootstrapping: false,
            documentsByID: [:]
        )
    }
}

enum LiveSessionSearchIndexError: Error, CustomStringConvertible {
    case disabled
    case sqliteUnavailable
    case insecure(String)
    case sqlite(String)

    var description: String {
        switch self {
        case .disabled: "session search is disabled"
        case .sqliteUnavailable: "SQLite FTS5 session search is not available on this platform"
        case .insecure(let reason): "insecure session search index: \(reason)"
        case .sqlite(let reason): "session search SQLite error: \(reason)"
        }
    }
}

enum LiveSessionSearchIndex {
    static func search(
        openGrokHome: URL,
        environment: [String: String],
        query: String,
        workingDirectory: URL? = nil,
        limit: Int,
        offset: Int = 0,
        includeContent: Bool = true,
        gate: SessionSearchGate = .shared,
        sources: (() throws -> [LiveSessionSearchIndexSource])? = nil
    ) throws -> LiveSessionSearchPage {
        guard gate.isIndexEnabled(environment: environment) else { return .empty }
        guard limit >= 0, offset >= 0 else { return .empty }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .empty }

        #if canImport(SQLite3)
        let sessions = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
        try LiveSessionBusPresenceStore.ensureSecureDirectory(sessions)
        let indexPath = sessions.appendingPathComponent("session_search.sqlite")
        let database = try LiveSessionSearchSQLite(path: indexPath)
        let candidates = try sources?() ?? persistedSources(
            openGrokHome: openGrokHome,
            workingDirectory: workingDirectory
        )
        try synchronize(
            database: database,
            candidates: candidates,
            workingDirectory: workingDirectory,
            environment: environment,
            gate: gate,
            sourcesAreComplete: workingDirectory == nil
        )
        guard gate.isIndexEnabled(environment: environment) else { return .empty }
        return try database.search(
            query: needle,
            workingDirectory: workingDirectory,
            limit: limit,
            offset: offset,
            includeContent: includeContent
        )
        #else
        throw LiveSessionSearchIndexError.sqliteUnavailable
        #endif
    }

    #if canImport(SQLite3)
    private static func persistedSources(
        openGrokHome: URL,
        workingDirectory: URL?
    ) throws -> [LiveSessionSearchIndexSource] {
        let store = SessionDocumentStore(grokHome: openGrokHome)
        let root = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let requestedWorkspace = workingDirectory.map(canonicalWorkspace)
        var sources: [LiveSessionSearchIndexSource] = []
        var canonicalIDs = Set<String>()

        for summary in try store.list() {
            let sessionID = summary.sessionID.rawValue
            try LiveConversationStore.validateSessionID(sessionID)
            if let requestedWorkspace,
               canonicalWorkspace(URL(fileURLWithPath: summary.cwd)) != requestedWorkspace {
                continue
            }
            canonicalIDs.insert(sessionID)
            sources.append(LiveSessionSearchIndexSource(
                sessionID: sessionID,
                workingDirectory: summary.cwd,
                updatedAt: summary.updatedAt,
                load: {
                    let directory = try store.sessionDirectory(sessionID: sessionID, cwd: summary.cwd)
                    for name in [
                        SessionDocumentStore.summaryFileName,
                        SessionDocumentStore.chatHistoryFileName,
                        SessionDocumentStore.updatesFileName,
                    ] {
                        let file = directory.appendingPathComponent(name)
                        guard !FileManager.default.fileExists(atPath: file.path)
                                || isSafeRegularFile(file, root: root)
                        else { return nil }
                    }
                    guard let state = try store.load(sessionID: sessionID, cwd: summary.cwd) else {
                        return nil
                    }
                    return LiveSessionDocument.build(from: try LiveConversationStore.record(
                        from: state,
                        requestedSessionID: sessionID
                    ))
                }
            ))
        }

        // A flat legacy record contains its workspace inside the transcript;
        // scoped searches cannot inspect it without violating isolation.
        guard requestedWorkspace == nil else { return sources }
        for file in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) where file.pathExtension == "json" {
            let sessionID = file.deletingPathExtension().lastPathComponent
            guard !canonicalIDs.contains(sessionID),
                  isSafeRegularFile(file, root: root)
            else { continue }
            do {
                try LiveConversationStore.validateSessionID(sessionID)
            } catch {
                continue
            }
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate ?? Date.distantPast
            sources.append(LiveSessionSearchIndexSource(
                sessionID: sessionID,
                workingDirectory: "",
                updatedAt: modified,
                load: {
                    guard isSafeRegularFile(file, root: root) else { return nil }
                    let record = try JSONDecoder().decode(
                        LiveConversationRecord.self,
                        from: Data(contentsOf: file)
                    )
                    guard record.sessionID == sessionID,
                          record.sessionKind?.hasPrefix("subagent") != true
                    else { return nil }
                    return LiveSessionDocument.build(from: record)
                }
            ))
        }
        return sources
    }

    private static func synchronize(
        database: LiveSessionSearchSQLite,
        candidates: [LiveSessionSearchIndexSource],
        workingDirectory: URL?,
        environment: [String: String],
        gate: SessionSearchGate,
        sourcesAreComplete: Bool
    ) throws {
        let existing = try database.indexedMetadata()
        let requestedWorkspace = workingDirectory.map(canonicalWorkspace)
        var retainedIDs = Set<String>()
        try database.execute("BEGIN IMMEDIATE")
        do {
            for (offset, candidate) in candidates.enumerated() {
                try LiveConversationStore.validateSessionID(candidate.sessionID)
                if let requestedWorkspace,
                   canonicalWorkspace(URL(fileURLWithPath: candidate.workingDirectory))
                    != requestedWorkspace {
                    continue
                }
                retainedIDs.insert(candidate.sessionID)
                let timestamp = milliseconds(candidate.updatedAt)
                if let old = existing[candidate.sessionID],
                   unixSeconds(old.updatedAt) == unixSeconds(timestamp),
                   old.sourceTimestampBits == candidate.updatedAt.timeIntervalSince1970.bitPattern,
                   candidate.workingDirectory.isEmpty || old.workingDirectory == candidate.workingDirectory {
                    continue
                }
                if offset.isMultiple(of: 64), !gate.isIndexEnabled(environment: environment) {
                    throw LiveSessionSearchIndexError.disabled
                }
                guard let document = try candidate.load() else {
                    retainedIDs.remove(candidate.sessionID)
                    try database.delete(sessionID: candidate.sessionID)
                    continue
                }
                guard document.sessionID == candidate.sessionID,
                      candidate.workingDirectory.isEmpty
                        || canonicalWorkspace(URL(fileURLWithPath: document.workingDirectory))
                            == canonicalWorkspace(URL(fileURLWithPath: candidate.workingDirectory)),
                      requestedWorkspace == nil
                        || canonicalWorkspace(URL(fileURLWithPath: document.workingDirectory))
                            == requestedWorkspace
                else {
                    throw LiveSessionSearchIndexError.insecure(
                        "session document does not belong to its indexed owner or workspace"
                    )
                }
                try database.upsert(
                    document: document,
                    timestamp: timestamp,
                    sourceUpdatedAt: candidate.updatedAt
                )
            }
            for (sessionID, metadata) in existing where !retainedIDs.contains(sessionID) {
                if sourcesAreComplete
                    || requestedWorkspace == canonicalWorkspace(
                        URL(fileURLWithPath: metadata.workingDirectory)
                    ) {
                    try database.delete(sessionID: sessionID)
                }
            }
            guard gate.isIndexEnabled(environment: environment) else {
                throw LiveSessionSearchIndexError.disabled
            }
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    private static func canonicalWorkspace(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func unixSeconds(_ milliseconds: Int64) -> Int64 {
        let seconds = milliseconds / 1_000
        return milliseconds < 0 && milliseconds % 1_000 != 0 ? seconds - 1 : seconds
    }

    private static func isSafeRegularFile(_ file: URL, root: URL) -> Bool {
        guard let values = try? file.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 16 * 1_024 * 1_024
        else { return false }
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return resolved.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
    }
    #endif
}
