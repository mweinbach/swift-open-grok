// LiveSessionsComposition.swift
//
// Live session management: the `open-grok sessions` CLI route.
//
// This reads the canonical Rust-compatible cwd-bucket session documents the
// interactive/headless runs write, while retaining flat Swift session files
// as a compatibility migration surface. Canonical records always win when a
// session has both representations.
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
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence

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
    private let documentStore: SessionDocumentStore
    private let fileManager: FileManager

    init(openGrokHome: URL, fileManager: FileManager = .default) {
        self.sessionsDirectory = openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        self.documentStore = SessionDocumentStore(grokHome: openGrokHome)
        self.fileManager = fileManager
    }

    /// Every readable session, newest activity first, ties broken by ID so the
    /// order is total and test assertions are stable.
    ///
    /// A file that fails to decode is skipped rather than failing the whole
    /// listing: a half-written session from a crashed run must not make
    /// `sessions list` unusable.
    func list() throws -> [LiveSessionListing] {
        try records()
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
        var records: [LiveConversationRecord] = []
        var sessionIDs = Set<String>()
        do {
            for summary in try documentStore.list() {
                guard sessionIDs.insert(summary.sessionID.rawValue).inserted else {
                    continue
                }
                let visibilityOverride = summary.extra["hidden"]?.boolValue
                if visibilityOverride == true
                    || (
                        visibilityOverride == nil
                            && summary.sessionKind?.hasPrefix("subagent") == true
                    )
                {
                    continue
                }
                do {
                    guard let state = try documentStore.load(
                        sessionID: summary.sessionID.rawValue,
                        cwd: summary.cwd
                    ) else { continue }
                    let record = try LiveConversationStore.record(
                        from: state,
                        requestedSessionID: summary.sessionID.rawValue
                    )
                    records.append(record)
                } catch {
                    continue
                }
            }
        } catch {
            throw CLIApplicationError.failed("failed to list sessions: \(error)")
        }

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
        let legacy = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> LiveConversationRecord? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(
                        LiveConversationRecord.self,
                        from: data
                      ),
                      !sessionIDs.contains(record.sessionID)
                else { return nil }
                if let directory = try? documentStore.sessionDirectory(
                    sessionID: record.sessionID,
                    cwd: record.workingDirectory
                ), fileManager.fileExists(
                    atPath: directory.appendingPathComponent("summary.json").path
                ) {
                    return nil
                }
                guard sessionIDs.insert(record.sessionID).inserted else {
                    return nil
                }
                return record
            }
        records.append(contentsOf: legacy)
        return records
    }

    /// Flattened search documents for every session.
    func documents() throws -> [LiveSessionDocument] {
        try records().map(LiveSessionDocument.build(from:))
    }

    func load(sessionID: String) throws -> LiveSessionListing? {
        try LiveConversationStore.validateSessionID(sessionID)
        do {
            if let state = try documentStore.load(sessionID: sessionID) {
                let directory = try documentStore.sessionDirectory(
                    sessionID: sessionID,
                    cwd: state.summary.cwd
                )
                if fileManager.fileExists(
                    atPath: directory.appendingPathComponent("summary.json").path
                ) {
                    return Self.listing(for: try LiveConversationStore.record(
                        from: state,
                        requestedSessionID: sessionID
                    ))
                }
            }
            let url = fileURL(sessionID: sessionID)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
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
        let legacyDirectory = sessionsDirectory.appendingPathComponent(
            sessionID,
            isDirectory: true
        )
        let legacyState = legacyDirectory.appendingPathComponent("state.json")
        do {
            let state = try documentStore.load(sessionID: sessionID)
            var canonicalDirectories: Set<URL> = []
            if let state {
                let directory = try documentStore.sessionDirectory(
                    sessionID: sessionID,
                    cwd: state.summary.cwd
                )
                if fileManager.fileExists(
                    atPath: directory.appendingPathComponent("summary.json").path
                ) {
                    canonicalDirectories.insert(directory)
                }
            }
            for summary in try documentStore.list()
                where summary.sessionID.rawValue == sessionID
            {
                canonicalDirectories.insert(try documentStore.sessionDirectory(
                    sessionID: sessionID,
                    cwd: summary.cwd
                ))
            }

            guard !canonicalDirectories.isEmpty
                || fileManager.fileExists(atPath: url.path)
                || fileManager.fileExists(atPath: legacyState.path)
            else { return false }

            for canonicalDirectory in canonicalDirectories {
                try fileManager.removeItem(at: canonicalDirectory)
            }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            if fileManager.fileExists(atPath: legacyDirectory.path) {
                try fileManager.removeItem(at: legacyDirectory)
            }

            let rewindURL = LiveRewindStore.rewindFileURL(
                openGrokHome: sessionsDirectory.deletingLastPathComponent(),
                sessionID: sessionID
            )
            if fileManager.fileExists(atPath: rewindURL.path) {
                try fileManager.removeItem(at: rewindURL)
            }
        } catch {
            throw CLIApplicationError.failed("failed to delete session \(sessionID): \(error)")
        }
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
            model: model ?? record.currentModelID,
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
    /// `sessions list` merges Claude/Codex foreign sessions only when the
    /// matching `[compat.*.sessions]` cell is on *and* the resume skill exists
    /// (`gated_sources_async` / `foreign_sessions.rs` at pin `650c1db7`).
    /// Import/writeback and Cursor scanning remain absent by architecture (§4).
    ///
    /// Project compat and the foreign scanner both key off the same resolved
    /// launch cwd (`options.common.cwd` / `--cwd`), not the process cwd. The
    /// process cwd is only the fallback when `--cwd` is absent — the AGENTS.md
    /// process-cwd trap is that library helpers must not invent their own.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .sessions(let options) = command else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        let home = OpenGrokHomeResolver.resolve(environment: context.environment)
        let cwd = try resolveWorkingDirectory(options.common.cwd)
        let foreignSources = resolveProductionForeignSources(
            environment: context.environment,
            cwd: cwd,
            openGrokHome: home
        )
        try run(
            options: options,
            environment: context.environment,
            streams: context.streams,
            cwd: cwd,
            foreignScanner: LiveForeignSessionScanner(environment: context.environment),
            foreignSources: foreignSources
        )
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    /// Production gate for `sessions list`: resolve session-compat cells from
    /// the authoritative config composition, then require the matching
    /// `resume-*` skill under `$OPENGROK_HOME`.
    ///
    /// Remote `*_sessions_enabled` fields are intentionally not read here —
    /// they are not on `AllowlistedRemoteSettings`, and the LiveComposition
    /// remote path is outside this route's ownership.
    ///
    /// `cwd` is required: project `[compat.*.sessions]` cells live under the
    /// launch working directory, which is not necessarily the process cwd.
    public static func resolveProductionForeignSources(
        environment: [String: String],
        cwd: URL,
        openGrokHome: URL? = nil,
        skillExists: ((URL) -> Bool)? = nil
    ) -> EnabledForeignSources {
        let home = openGrokHome ?? OpenGrokHomeResolver.resolve(environment: environment)
        let compat = resolveForeignSessionCompatSessions(
            environment: environment,
            cwd: cwd
        )
        let exists = skillExists ?? { FileManager.default.fileExists(atPath: $0.path) }
        return gatedForeignSessionSources(
            compat: compat,
            openGrokHome: home,
            skillExists: exists
        )
    }

    /// Resolve picker-facing session cells through
    /// `loadAuthorityComposition(...).effective()`, then apply env overrides.
    ///
    /// Precedence matches `resolve_compat_sessions_from_raw` +
    /// `resolve_compat_cell` at pin `650c1db7` (`config.rs:880` /
    /// `resolve_compat_cell_with_env`):
    /// 1. `GROK_{CLAUDE,CODEX,CURSOR}_SESSIONS_ENABLED` env
    /// 2. `[compat.<vendor>] sessions` on the effective merged document
    ///    (system managed → user managed → user → project chain →
    ///    requirements; see `AuthorityComposition.effective`)
    /// 3. default `true` when the cell is absent after a successful load
    ///
    /// Entire authority-load failure fails closed (`false`) per vendor, as
    /// Rust does when `load_effective_config` returns `None`. A malformed
    /// sessions cell fails closed for that vendor only.
    ///
    /// `cwd` is required so project `.opengrok/config.toml` is read from the
    /// launch directory (`--cwd`), never silently from the process cwd.
    public static func resolveForeignSessionCompatSessions(
        environment: [String: String],
        cwd: URL
    ) -> ForeignSessionCompatSessions {
        let document: ForeignSessionCompatDocument
        do {
            document = .loaded(
                try loadAuthorityComposition(
                    cwd: cwd,
                    environment: environment
                ).effective()
            )
        } catch {
            document = .unavailable
        }
        return ForeignSessionCompatSessions(
            claude: resolveCompatSessionsCell(
                envName: "GROK_CLAUDE_SESSIONS_ENABLED",
                vendor: "claude",
                document: document,
                environment: environment
            ),
            codex: resolveCompatSessionsCell(
                envName: "GROK_CODEX_SESSIONS_ENABLED",
                vendor: "codex",
                document: document,
                environment: environment
            ),
            cursor: resolveCompatSessionsCell(
                envName: "GROK_CURSOR_SESSIONS_ENABLED",
                vendor: "cursor",
                document: document,
                environment: environment
            )
        )
    }

    private enum ForeignSessionCompatDocument {
        case loaded(TOMLValue)
        case unavailable
    }

    private enum ForeignSessionCompatCell {
        case value(Bool)
        case absent
        case malformed
    }

    private static func resolveCompatSessionsCell(
        envName: String,
        vendor: String,
        document: ForeignSessionCompatDocument,
        environment: [String: String]
    ) -> Bool {
        if let env = OpenGrokConfig.envBool(envName, environment: environment) {
            return env
        }
        switch document {
        case .unavailable:
            return false
        case .loaded(let effective):
            switch readCompatSessionsCell(effective, vendor: vendor) {
            case .value(let value):
                return value
            case .absent:
                return true
            case .malformed:
                return false
            }
        }
    }

    private static func readCompatSessionsCell(
        _ document: TOMLValue,
        vendor: String
    ) -> ForeignSessionCompatCell {
        guard let compat = document["compat"] else { return .absent }
        guard let compatTable = compat.table else { return .malformed }
        guard let vendorValue = compatTable[vendor] else { return .absent }
        guard let vendorTable = vendorValue.table else { return .malformed }
        guard let sessions = vendorTable["sessions"] else { return .absent }
        guard let bool = sessions.boolValue else { return .malformed }
        return .value(bool)
    }

    /// Compatibility overload for unowned call sites that omit `cwd`.
    ///
    /// Resolves `options.common.cwd` through the same
    /// `resolveWorkingDirectory` seam production `session()` uses — so a test
    /// that builds options with `--cwd` still gets the launch directory, and
    /// there is still only one place that falls back to the process cwd.
    public static func run(
        options: CLISessionOptions,
        environment: [String: String],
        streams: CLIStreams,
        foreignScanner: (any ForeignSessionScanning)? = nil,
        foreignSources: EnabledForeignSources = .none
    ) throws {
        try run(
            options: options,
            environment: environment,
            streams: streams,
            cwd: try resolveWorkingDirectory(options.common.cwd),
            foreignScanner: foreignScanner,
            foreignSources: foreignSources
        )
    }

    public static func run(
        options: CLISessionOptions,
        environment: [String: String],
        streams: CLIStreams,
        cwd: URL,
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
                cwd: cwd,
                foreignScanner: foreignScanner,
                foreignSources: foreignSources
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
        cwd: URL,
        foreignScanner: (any ForeignSessionScanning)? = nil,
        foreignSources: EnabledForeignSources = .none
    ) throws {
        var sessions = try catalog.list()
        // Zero scanner calls (and therefore zero vendor I/O) when every source
        // is gated off — missing/disabled resume skill or compat.sessions=false.
        if let scanner = foreignScanner, foreignSources.anyEnabled {
            let foreign = scanner.scan(cwd: cwd.path, enabled: foreignSources)
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
        let isEnabled = SessionSearchGate.shared.isIndexEnabled()
        let hits: [LiveSessionSearchHit]
        if isEnabled {
            hits = LiveSessionSearch.rank(
                documents: try catalog.documents(),
                query: query,
                limit: options.limit
            )
        } else {
            hits = []
        }
        if let by = SessionSearchGate.shared.sessionSearchTurnedOffBy() {
            streams.err("warning: local session search is off (\(by)); local sessions were not searched.\n")
        }
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

    /// Same seam as `LiveComposition.resolveWorkingDirectory`: honor `--cwd`
    /// when present, otherwise the process cwd, and reject a missing path.
    /// Kept private so call sites cannot invent a second process-cwd default.
    private static func resolveWorkingDirectory(_ path: String?) throws -> URL {
        try liveResolveWorkingDirectory(path)
    }
}
