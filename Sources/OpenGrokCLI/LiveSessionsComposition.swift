// LiveSessionsComposition.swift
//
// Live session management: the `open-grok sessions` CLI route.
//
// This reads the same on-disk store the interactive/headless runs write:
// `$OPENGROK_HOME/sessions/<session-id>.json`, one `LiveConversationRecord`
// per file (see `LiveConversationStore` in `LiveComposition.swift`). The
// record type is shared rather than re-declared so the wire format cannot
// drift between the writer and this reader.
//
// Rust reference (`/Users/mweinbach/Projects/grok-build`):
//
//   * `crates/codegen/xai-grok-pager/src/sessions_cmd.rs:16-33` — the
//     subcommand surface. Rust ships `list`, `search` and `delete`; there is
//     no `--json` flag and no `show`. This port keeps `list`/`delete` with the
//     Rust wording, adds `show <id>` (a local-store detail view Rust has no
//     equivalent for), and adds `--json` throughout because every other
//     Swift-port route is headless-friendly.
//   * `sessions_cmd.rs:202-257` (`print_sessions_grouped`) — the column
//     layout copied loosely below.
//   * `sessions_cmd.rs:190,192` — the exact `delete` result strings.
//
// Deliberately NOT ported: Rust's remote session registry (`search` merges a
// local FTS index with a remote registry, `sessions_cmd.rs:71-166`) and the
// worktree-label grouping that depends on it. This route is local-store only.
//
// Like `LiveAuthComposition` and `LiveMCPComposition`, this file is
// self-contained: the launcher hook that routes `sessions` here belongs in
// `LiveComposition.swift`, which the integration slice owns.

import Foundation
import OpenGrokSamplingTypes

// MARK: - Catalog

/// One session as this route reports it.
///
/// `title` and `model` are derived, not stored: `LiveConversationRecord` keeps
/// the transcript, so the title is the session's first real user turn and the
/// model is the one that produced the most recent assistant turn.
public struct LiveSessionListing: Sendable, Equatable {
    public var sessionID: String
    public var workingDirectory: String
    public var parentSessionID: String?
    public var title: String?
    public var model: String?
    public var createdAt: Date
    public var lastActivityAt: Date
    public var messageCount: Int
    public var userMessageCount: Int
    public var assistantMessageCount: Int
    /// Non-nil for foreign sessions (Claude Code, Codex). Local OpenGrok
    /// sessions leave this nil. The badge is surfaced in both text and JSON
    /// output so the caller always knows the provenance.
    public var foreignSource: ForeignSessionSource?

    public init(
        sessionID: String,
        workingDirectory: String,
        parentSessionID: String? = nil,
        title: String? = nil,
        model: String? = nil,
        createdAt: Date,
        lastActivityAt: Date,
        messageCount: Int,
        userMessageCount: Int,
        assistantMessageCount: Int,
        foreignSource: ForeignSessionSource? = nil
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.parentSessionID = parentSessionID
        self.title = title
        self.model = model
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.assistantMessageCount = assistantMessageCount
        self.foreignSource = foreignSource
    }
}

/// Read/delete access to the live session directory.
///
/// `LiveConversationStore` owns writing and its storage is file-private, so
/// enumeration and deletion live here. Both types address the same layout and
/// share `LiveConversationRecord` plus `LiveConversationStore.validateSessionID`,
/// which is what keeps them from diverging.
struct LiveSessionCatalog {
    let sessionsDirectory: URL
    private let fileManager: FileManager

    init(openGrokHome: URL, fileManager: FileManager = .default) {
        self.sessionsDirectory = openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        self.fileManager = fileManager
    }

    /// Every readable session, newest activity first, ties broken by ID so the
    /// order is total and test assertions are stable.
    ///
    /// A file that fails to decode is skipped rather than failing the whole
    /// listing: a half-written session from a crashed run must not make
    /// `sessions list` unusable.
    func list() throws -> [LiveSessionListing] {
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CLIApplicationError.failed("failed to list sessions: \(error)")
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LiveConversationRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(LiveConversationRecord.self, from: data)
            }
            .map(Self.listing(for:))
            .sorted { lhs, rhs in
                if lhs.lastActivityAt == rhs.lastActivityAt {
                    return lhs.sessionID < rhs.sessionID
                }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
    }

    /// Every decodable session record, for the routes that need the whole
    /// transcript rather than the derived listing — today that is content
    /// search and the `/resume` picker's preview column.
    ///
    /// Kept separate from `list()` because it is materially more expensive: it
    /// keeps every item of every session alive at once, where `list()` reduces
    /// each record to a handful of fields as it goes.
    func records() throws -> [LiveConversationRecord] {
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CLIApplicationError.failed("failed to list sessions: \(error)")
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LiveConversationRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(LiveConversationRecord.self, from: data)
            }
    }

    /// Flattened search documents for every session.
    func documents() throws -> [LiveSessionDocument] {
        try records().map(LiveSessionDocument.build(from:))
    }

    func load(sessionID: String) throws -> LiveSessionListing? {
        try LiveConversationStore.validateSessionID(sessionID)
        let url = fileURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let record = try JSONDecoder().decode(
                LiveConversationRecord.self,
                from: try Data(contentsOf: url)
            )
            return Self.listing(for: record)
        } catch {
            throw CLIApplicationError.failed("failed to load session \(sessionID): \(error)")
        }
    }

    /// Delete exactly one session file. Returns `false` when nothing was there.
    ///
    /// There is no bulk form on purpose: the id must be spelled out, matching
    /// Rust's `SessionsCommand::Delete { id }` (`sessions_cmd.rs:30-33`).
    func delete(sessionID: String) throws -> Bool {
        try LiveConversationStore.validateSessionID(sessionID)
        let url = fileURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw CLIApplicationError.failed("failed to delete session \(sessionID): \(error)")
        }
        // Rewind snapshots live beside the session as `<id>.rewind.jsonl` and
        // hold verbatim copies of the user's source files. Leaving them behind
        // after a delete would keep that content on disk with nothing left
        // pointing at it, which is the opposite of what deleting a session
        // means. Absent file is not an error: most sessions never record one.
        try? fileManager.removeItem(at: LiveRewindStore.rewindFileURL(
            openGrokHome: sessionsDirectory.deletingLastPathComponent(),
            sessionID: sessionID
        ))
        return true
    }

    private func fileURL(sessionID: String) -> URL {
        sessionsDirectory.appendingPathComponent(sessionID).appendingPathExtension("json")
    }

    static func listing(for record: LiveConversationRecord) -> LiveSessionListing {
        var title: String?
        var model: String?
        var userCount = 0
        var assistantCount = 0
        for item in record.items {
            switch item {
            case .user(let user):
                // Synthetic turns are injected context (project instructions
                // and friends), never something the operator typed, so they
                // must not become the session's title.
                guard user.syntheticReason == nil else { continue }
                userCount += 1
                if title == nil { title = Self.title(from: user.content) }
            case .assistant(let assistant):
                assistantCount += 1
                if let id = assistant.modelId, !id.isEmpty { model = id }
            default:
                continue
            }
        }
        return LiveSessionListing(
            sessionID: record.sessionID,
            workingDirectory: record.workingDirectory,
            parentSessionID: record.parentSessionID,
            // A `/rename`d title wins over the derived first-prompt one
            // (upstream stores the rename as the session's summary,
            // `rename.rs:42-53`); sessions never renamed keep deriving.
            title: record.title ?? title,
            model: model,
            createdAt: record.createdAt,
            lastActivityAt: record.updatedAt,
            messageCount: record.items.count,
            userMessageCount: userCount,
            assistantMessageCount: assistantCount
        )
    }

    /// First non-blank line of the first text part, whitespace-collapsed.
    static func title(from content: [ContentPart]) -> String? {
        for part in content {
            guard case .text(let text) = part else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

// MARK: - Composition

public enum LiveSessionsComposition {
    public static let routeName = "sessions"

    /// Subcommands this route serves. `new`/`resume`/`restore`/`export` are
    /// parsed by `CLICommand` but belong to the launch path, not here.
    public static let actions: Set<CLISessionAction> = [.list, .search, .show, .delete]

    public static func handles(_ command: CLICommand) -> Bool {
        guard case .sessions(let options) = command else { return false }
        return actions.contains(options.action)
    }

    /// Launcher entry point. Runs to completion and hands back a finished
    /// session, matching `LiveAuthComposition` and `LiveMCPComposition`.
    ///
    /// Wave 20 S10: `sessions list` merges Claude/Codex foreign sessions via
    /// `LiveForeignSessionScanner` with every source enabled. Import/writeback
    /// remain absent by architecture (§4).
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .sessions(let options) = command else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try run(
            options: options,
            environment: context.environment,
            streams: context.streams,
            foreignScanner: LiveForeignSessionScanner(environment: context.environment),
            foreignSources: .all
        )
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    public static func run(
        options: CLISessionOptions,
        environment: [String: String],
        streams: CLIStreams,
        foreignScanner: (any ForeignSessionScanning)? = nil,
        foreignSources: EnabledForeignSources = .none
    ) throws {
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let catalog = LiveSessionCatalog(openGrokHome: home)
        switch options.action {
        case .list:
            try runList(
                catalog: catalog,
                json: options.json,
                limit: options.limit,
                streams: streams,
                foreignScanner: foreignScanner,
                foreignSources: foreignSources,
                environment: environment
            )
        case .search:
            try runSearch(options: options, catalog: catalog, streams: streams)
        case .show:
            try runShow(options: options, catalog: catalog, streams: streams)
        case .delete:
            try runDelete(options: options, catalog: catalog, streams: streams)
        case .new, .resume, .restore, .export:
            throw CLIApplicationError.unsupported(route: "sessions \(options.action.rawValue)")
        }
    }

    // MARK: list

    /// `-n`/`--limit` applies to **both** output branches.
    ///
    /// It previously applied to neither: the flag parsed, defaulted to 20, and
    /// was then dropped on the floor, so `sessions list -n 5` printed every
    /// session. A limit flag that silently does nothing is worse than an
    /// unimplemented one — the user reads the short output they asked for and
    /// gets the whole list. `catalog.list()` is already sorted newest-first, so
    /// the prefix is the most recent N, which is what Rust's `--limit` means.
    private static func runList(
        catalog: LiveSessionCatalog,
        json: Bool,
        limit: Int,
        streams: CLIStreams,
        foreignScanner: (any ForeignSessionScanning)? = nil,
        foreignSources: EnabledForeignSources = .none,
        environment: [String: String] = [:]
    ) throws {
        var sessions = try catalog.list()
        if let scanner = foreignScanner,
           (foreignSources.claude || foreignSources.codex) {
            let cwd = FileManager.default.currentDirectoryPath
            let foreign = scanner.scan(cwd: cwd, enabled: foreignSources)
            sessions.append(contentsOf: foreign.map(listing(fromForeign:)))
        }
        sessions.sort { lhs, rhs in
            if lhs.lastActivityAt == rhs.lastActivityAt {
                return lhs.sessionID < rhs.sessionID
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        sessions = Array(sessions.prefix(max(0, limit)))
        if json {
            streams.out(try encodeJSON(sessions.map(payload(for:))) + "\n")
            return
        }
        guard !sessions.isEmpty else {
            streams.out("No sessions found.\n")
            return
        }
        var lines = [
            row(
                id: "SESSION ID",
                created: "CREATED",
                updated: "UPDATED",
                model: "MODEL",
                title: "TITLE"
            )
        ]
        for session in sessions {
            let badge = session.foreignSource.map { "[\($0.badge)] " } ?? ""
            lines.append(
                row(
                    id: session.sessionID,
                    created: day(session.createdAt),
                    updated: day(session.lastActivityAt),
                    model: session.model ?? (session.foreignSource != nil ? "-" : "-"),
                    title: badge + (session.title ?? "(no title)")
                )
            )
        }
        streams.out(lines.joined(separator: "\n") + "\n")
    }

    /// Rust's list row is `{:<36}  {:<10}  {:<10}  {:<10}  {}` over
    /// id/created/updated/status/summary (`sessions_cmd.rs:218-246`). The
    /// status column is a remote-registry concept this port has no source for,
    /// so it carries the model instead; the widths are otherwise the same.
    private static func row(
        id: String,
        created: String,
        updated: String,
        model: String,
        title: String
    ) -> String {
        [
            pad(id, 36),
            pad(created, 10),
            pad(updated, 10),
            pad(truncate(model, 20), 20),
            truncate(title, 50)
        ].joined(separator: "  ")
    }

    // MARK: search

    /// `open-grok sessions search <query> [-n LIMIT] [--json]`.
    ///
    /// Rust runs a local FTS query and a remote-registry query concurrently and
    /// merges them (`sessions_cmd.rs:71-166`). This port has no remote registry
    /// — the file header already records that as deliberately not ported — so
    /// the output carries local hits only and omits Rust's `(remote)` rows
    /// rather than printing an empty section that implies a lookup happened.
    private static func runSearch(
        options: CLISessionOptions,
        catalog: LiveSessionCatalog,
        streams: CLIStreams
    ) throws {
        guard let query = options.query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else {
            throw CLIApplicationError.failed(
                "sessions search requires a query: open-grok sessions search <query>"
            )
        }
        let hits = LiveSessionSearch.rank(
            documents: try catalog.documents(),
            query: query,
            limit: options.limit
        )
        if options.json {
            streams.out(try encodeJSON(hits.map(payload(for:))) + "\n")
            return
        }
        guard !hits.isEmpty else {
            streams.out("No sessions matched \(query).\n")
            return
        }
        var lines: [String] = []
        for hit in hits {
            // Rust's three-line-per-hit shape (`sessions_cmd.rs`): the id and
            // score with a human timestamp, then the title, then the snippet.
            lines.append(
                "\(hit.sessionID) (score: \(String(format: "%.2f", hit.score)))  "
                    + timestamp(hit.updatedAt)
            )
            lines.append("  \(hit.title ?? "(untitled)")")
            lines.append("  \(hit.snippet)")
        }
        lines.append("")
        lines.append("Total: \(hits.count)")
        streams.out(lines.joined(separator: "\n") + "\n")
    }

    private static func payload(for hit: LiveSessionSearchHit) -> [String: Any] {
        var payload: [String: Any] = [
            "id": hit.sessionID,
            "cwd": hit.workingDirectory,
            "last_activity_at": timestamp(hit.updatedAt),
            "score": hit.score,
            "snippet": hit.snippet
        ]
        if let title = hit.title { payload["title"] = title }
        return payload
    }

    // MARK: show

    private static func runShow(
        options: CLISessionOptions,
        catalog: LiveSessionCatalog,
        streams: CLIStreams
    ) throws {
        let id = try requireIdentifier(options, action: "show")
        guard let session = try catalog.load(sessionID: id) else {
            // No trailing period: `CLIRunner` appends one when it renders the
            // error, and Rust's period-terminated wording at
            // `sessions_cmd.rs:192` belongs to `delete`, which prints to
            // stdout rather than throwing.
            throw CLIApplicationError.failed("no session found with id \(id)")
        }
        if options.json {
            streams.out(try encodeJSON(payload(for: session)) + "\n")
            return
        }
        var lines = [
            "Session:    \(session.sessionID)",
            "Directory:  \(session.workingDirectory)",
            "Title:      \(session.title ?? "(no title)")",
            "Model:      \(session.model ?? "(unknown)")",
            "Created:    \(timestamp(session.createdAt))",
            "Updated:    \(timestamp(session.lastActivityAt))",
            "Messages:   \(session.messageCount) "
                + "(\(session.userMessageCount) user, \(session.assistantMessageCount) assistant)"
        ]
        if let parent = session.parentSessionID {
            lines.append("Forked from: \(parent)")
        }
        streams.out(lines.joined(separator: "\n") + "\n")
    }

    // MARK: delete

    private static func runDelete(
        options: CLISessionOptions,
        catalog: LiveSessionCatalog,
        streams: CLIStreams
    ) throws {
        let id = try requireIdentifier(options, action: "delete")
        let removed = try catalog.delete(sessionID: id)
        if options.json {
            streams.out(try encodeJSON(["id": id, "deleted": removed] as [String: Any]) + "\n")
            return
        }
        // Rust: sessions_cmd.rs:190 and :192 verbatim, trailing period on the
        // miss only.
        streams.out(removed ? "Deleted session \(id)\n" : "No session found with id \(id).\n")
    }

    // MARK: helpers

    private static func requireIdentifier(
        _ options: CLISessionOptions,
        action: String
    ) throws -> String {
        guard let id = options.identifier, !id.isEmpty else {
            throw CLIApplicationError.failed(
                "sessions \(action) requires a session id: open-grok sessions \(action) <id>"
            )
        }
        return id
    }

    private static func payload(for session: LiveSessionListing) -> [String: Any] {
        var payload: [String: Any] = [
            "id": session.sessionID,
            "cwd": session.workingDirectory,
            "created_at": timestamp(session.createdAt),
            "last_activity_at": timestamp(session.lastActivityAt),
            "num_messages": session.messageCount,
            "num_user_messages": session.userMessageCount,
            "num_assistant_messages": session.assistantMessageCount
        ]
        if let title = session.title { payload["title"] = title }
        if let model = session.model { payload["model"] = model }
        if let parent = session.parentSessionID { payload["parent_session_id"] = parent }
        if let foreign = session.foreignSource {
            payload["foreign_source"] = foreign.rawValue
            payload["foreign_tool"] = (foreign == .claudeCode) ? "claude" : "codex"
        }
        return payload
    }

    /// Convert a `ForeignSessionSummary` into the unified listing type.
    /// Foreign sessions carry no transcript, so message counts are zero and
    /// `createdAt` equals `updatedAt` — we have only the file modification
    /// time, which is the closest proxy.
    static func listing(
        fromForeign summary: ForeignSessionSummary
    ) -> LiveSessionListing {
        LiveSessionListing(
            sessionID: summary.nativeID,
            workingDirectory: summary.cwd,
            title: summary.title,
            createdAt: summary.updatedAt,
            lastActivityAt: summary.updatedAt,
            messageCount: 0,
            userMessageCount: 0,
            assistantMessageCount: 0,
            foreignSource: summary.source
        )
    }

    private static func encodeJSON(_ value: Any) throws -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw CLIApplicationError.failed("failed to encode session JSON: \(error)")
        }
    }

    /// `ISO8601DateFormatter` is not `Sendable`, so under strict concurrency
    /// it cannot be cached in a `static let`. A CLI route formats a handful of
    /// dates per invocation, so building one per call costs nothing.
    private static func format(_ date: Date, options: ISO8601DateFormatter.Options) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = options
        return formatter.string(from: date)
    }

    /// Rust prints the first 10 characters of the RFC3339 timestamp
    /// (`sessions_cmd.rs:236-241`), i.e. the UTC date.
    static func day(_ date: Date) -> String { format(date, options: [.withFullDate]) }

    static func timestamp(_ date: Date) -> String { format(date, options: [.withInternetDateTime]) }

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    private static func truncate(_ value: String, _ limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit))
    }
}
