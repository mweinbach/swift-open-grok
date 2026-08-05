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
        assistantMessageCount: Int
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
            title: title,
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
    public static let actions: Set<CLISessionAction> = [.list, .show, .delete]

    public static func handles(_ command: CLICommand) -> Bool {
        guard case .sessions(let options) = command else { return false }
        return actions.contains(options.action)
    }

    /// Launcher entry point. Runs to completion and hands back a finished
    /// session, matching `LiveAuthComposition` and `LiveMCPComposition`.
    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext
    ) async throws -> CLIApplicationSession {
        guard case .sessions(let options) = command else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try run(options: options, environment: context.environment, streams: context.streams)
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    public static func run(
        options: CLISessionOptions,
        environment: [String: String],
        streams: CLIStreams
    ) throws {
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let catalog = LiveSessionCatalog(openGrokHome: home)
        switch options.action {
        case .list:
            try runList(catalog: catalog, json: options.json, streams: streams)
        case .show:
            try runShow(options: options, catalog: catalog, streams: streams)
        case .delete:
            try runDelete(options: options, catalog: catalog, streams: streams)
        case .new, .resume, .restore, .export:
            throw CLIApplicationError.unsupported(route: "sessions \(options.action.rawValue)")
        }
    }

    // MARK: list

    private static func runList(
        catalog: LiveSessionCatalog,
        json: Bool,
        streams: CLIStreams
    ) throws {
        let sessions = try catalog.list()
        if json {
            streams.out(try encodeJSON(sessions.map(payload(for:))) + "\n")
            return
        }
        guard !sessions.isEmpty else {
            // Rust: `println!("No sessions found.")` (sessions_cmd.rs:204).
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
            lines.append(
                row(
                    id: session.sessionID,
                    created: day(session.createdAt),
                    updated: day(session.lastActivityAt),
                    model: session.model ?? "-",
                    title: session.title ?? "(no title)"
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
        return payload
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
