// LiveSessionAdminACPHandlers.swift
//
// The routed slice of upstream's session-admin ext family — Wave 15 item 6.
//
// Upstream's `x.ai/session/*` dispatch (acp_agent.rs:4115-4155) spans four
// modules; the arms with real port backings are the three
// `extensions/session_admin.rs` methods that operate on PERSISTED sessions:
//
//   * `x.ai/session/rename` (session_admin.rs:80-219) — non-blank title into
//     local storage, then a `SessionSummaryGenerated` broadcast. Backing:
//     `LiveConversationStore.renameStored` for stored sessions and the live
//     `LiveConversationHistory.rename` for the resident one (the turn loop
//     re-saves the whole record per commit, so the resident title MUST go
//     through the history actor or the next commit clobbers it).
//   * `x.ai/session/delete` (session_admin.rs:267-318) — idempotent local
//     delete: the session file plus its rewind sidecar
//     (`LiveSessionCatalog.delete`, the same removal `open-grok sessions
//     delete` performs).
//   * `x.ai/session/fork`   (session_admin.rs:799-810 → session/fork.rs) —
//     copy a saved session under a new id/cwd with parent tracking
//     (`LiveConversationStore.fork`, the same coupled transcript+rewind
//     transaction `--fork-session` uses).
//
// Everything else in the family stays refused with the router's terminal
// error: `info`/`close`/`updates`/`state`/`import`/`load_history`/`search`/
// `repair`/`usage` need live-session internals (SessionCommand plumbing,
// updates journals, FTS index) this port does not have;
// Singular `x.ai/session/list` still needs the persisted-history lane.
// Plural `x.ai/sessions/list` is now the live typed leader roster snapshot;
// peers listing persisted local history still use the CLI surface.
//
// Recorded divergences (beyond the refusals above):
//   1. No remote writeback: upstream syncs renames/deletes to the backend
//      registry when auth allows (session_admin.rs:144-195, 289-306); this
//      port is local-store only, same as `LiveSessionsComposition`.
//   2. `delete` of the RESIDENT session is refused with internal_error:
//      upstream tears the live actor down first
//      (`teardown_live_session_before_delete`, session_admin.rs:295-297);
//      this composition has no teardown seam, and deleting the file under a
//      live spine would silently resurrect it at the next turn commit —
//      fail-loud beats a delete that undoes itself.
//   3. `fork`'s optional `newModelId`/`targetPromptIndex`/`sessionKind`/
//      `sourceWorkspaceDir` arms are refused with internal_error naming the
//      field: the port's record store has no model-override/prompt-index/
//      kind machinery, and accepting-then-ignoring a payload is the silent
//      case AGENTS.md §3 exists to kill.
//   4. `kind: "chat"` arms answer upstream's no-conversations-lane refusal
//      byte-exact (session_admin.rs:228-231, 323-326) — honest here because
//      this port genuinely has no conversations lane.
//   5. The rename broadcast rides the gateway's uniform
//      `x.ai/session_notification` envelope, whose `_meta` carries
//      eventId/agentTimestampMs; upstream's rename notify sends `meta: None`
//      (session_admin.rs:204-219). Cost: a client asserting meta-absence on
//      this one notification sees the standard meta instead.
//   6. Fork ids are UUIDv4 (the store's convention) where upstream mints
//      UUIDv7 (fork.rs:60-62); `chatMessagesCopied` counts the copied
//      transcript items, and `updatesCopied: 0` / `planStateCopied: false`
//      are literal truth — this store has no updates journal or plan file.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokShared

struct LiveSessionAdminACPHandler: ACPAgentExtensionHandler, Sendable {
    /// Exact names from the upstream dispatch arm this handler serves
    /// (acp_agent.rs:4146-4150).
    static let methods: [String] = [
        "x.ai/session/rename",
        "x.ai/session/delete",
        "x.ai/session/fork",
    ]

    let openGrokHome: URL
    let gateway: ACPNotificationGateway
    /// The resident session's id — the one whose record the live history
    /// actor owns. `nil` for compositions without a live spine (tests).
    let liveSessionID: String?
    /// Rename through the live history actor (`LiveConversationHistory
    /// .rename`) for the resident session; see the file header for why the
    /// store write is not enough there.
    let renameLive: (@Sendable (String) async throws -> Void)?

    init(
        openGrokHome: URL,
        gateway: ACPNotificationGateway,
        liveSessionID: String? = nil,
        renameLive: (@Sendable (String) async throws -> Void)? = nil
    ) {
        self.openGrokHome = openGrokHome
        self.gateway = gateway
        self.liveSessionID = liveSessionID
        self.renameLive = renameLive
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "x.ai/session/rename":
            return try await handleRename(params)
        case "x.ai/session/delete":
            return try await handleDelete(params)
        case "x.ai/session/fork":
            return try await handleFork(params)
        default:
            // Registration and dispatch are generated from the same list;
            // refusing keeps a direct caller honest (the models-family
            // handler's same terminal arm).
            throw ACPExtensionMethodRouter.unknownExtensionMethodError(method)
        }
    }

    // MARK: Errors

    private func invalidRequest(_ detail: String) -> AcpError {
        AcpError(
            code: .invalidRequest,
            message: AcpErrorCode.invalidRequest.displayName,
            data: .string(detail)
        )
    }

    private func invalidParams(_ detail: String) -> AcpError {
        AcpError(
            code: .invalidParams,
            message: AcpErrorCode.invalidParams.displayName,
            data: .string(detail)
        )
    }

    private func internalError(_ detail: String) -> AcpError {
        AcpError(
            code: .internalError,
            message: AcpErrorCode.internalError.displayName,
            data: .string(detail)
        )
    }

    /// `SessionKind` (unified_list/envelope.rs:5-11): lowercase serde,
    /// default `build`. An unknown spelling fails upstream's serde inside
    /// `parse_params` — the prose after the prefix is serde-generated there
    /// and hand-written here, recorded.
    private func parseKind(_ params: JSONValue) throws -> String {
        guard let raw = params["kind"]?.stringValue else { return "build" }
        guard raw == "build" || raw == "chat" else {
            throw invalidParams("invalid params: unknown session kind '\(raw)'")
        }
        return raw
    }

    /// Load one persisted record, scoped to `cwd` when the caller sent one —
    /// the port of upstream's `list_summaries(cwd)`-then-find lookup: a
    /// session that exists under a different workspace is "not found", a
    /// malformed id matches nothing, and an unreadable file is skipped by
    /// the summary walk (so it too reads as "not found"). The error is
    /// folded deliberately — spelled with do/catch, not `try?`, so the
    /// flattening is a visible decision (AGENTS.md §2).
    private func lookupRecord(sessionID: String, cwd: String?) async -> LiveConversationRecord? {
        let store = LiveConversationStore(openGrokHome: openGrokHome)
        let record: LiveConversationRecord?
        do {
            record = try await store.loadIfPresent(sessionID: sessionID)
        } catch {
            record = nil
        }
        guard let record else { return nil }
        if let cwd, !cwd.isEmpty {
            let expected = URL(fileURLWithPath: cwd).standardizedFileURL.path
            guard URL(fileURLWithPath: record.workingDirectory).standardizedFileURL.path
                == expected else { return nil }
        }
        return record
    }

    // MARK: x.ai/session/rename

    /// `handle_session_rename` (session_admin.rs:80-200). Response is RAW
    /// `{"success": true}` — `to_raw_response`, no `ExtMethodResult`
    /// envelope (extensions/mod.rs:69-73).
    private func handleRename(_ params: JSONValue) async throws -> JSONValue {
        guard let sessionID = params["sessionId"]?.stringValue,
              let rawTitle = params["title"]?.stringValue else {
            throw invalidParams("invalid params: missing field `sessionId` or `title`")
        }
        // Manual titles must be non-blank (session_admin.rs:93-98).
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw invalidRequest("title must not be blank")
        }
        if try parseKind(params) == "chat" {
            // Byte-copy of the no-conversations-lane refusal
            // (session_admin.rs:228-231) — honest: this port has none.
            throw invalidRequest(
                "chat session rename requires the conversations lane (OIDC + chat feature)"
            )
        }

        let cwd = params["cwd"]?.stringValue
        guard await lookupRecord(sessionID: sessionID, cwd: cwd) != nil else {
            // session_admin.rs:111-116.
            throw invalidRequest("session not found: \(sessionID)")
        }

        if sessionID == liveSessionID, let renameLive {
            // The resident session's title lives in the history actor's
            // in-memory record; writing the file directly would be undone by
            // the next turn commit (file header).
            do {
                try await renameLive(title)
            } catch {
                throw internalError("failed to update session title: \(error)")
            }
        } else {
            let store = LiveConversationStore(openGrokHome: openGrokHome)
            do {
                let renamed = try await store.renameStored(sessionID: sessionID, title: title)
                guard renamed else {
                    throw invalidRequest("session not found: \(sessionID)")
                }
            } catch let error as AcpError {
                throw error
            } catch {
                // Upstream's storage-failure arm (session_admin.rs:130-136).
                throw internalError("failed to update session title: \(error)")
            }
        }

        // `SessionSummaryGenerated` so a connected client updates its title
        // (session_admin.rs:204-219; SessionUpdate serde: tag
        // `sessionUpdate`, snake_case variant, snake_case field —
        // notification.rs:580-583).
        await gateway.sendXaiSessionUpdate(
            sessionID: sessionID,
            update: .object([
                "sessionUpdate": .string("session_summary_generated"),
                "session_summary": .string(title),
            ])
        )

        return .object(["success": .bool(true)])
    }

    // MARK: x.ai/session/delete

    /// `handle_session_delete` (session_admin.rs:267-318) over
    /// `delete_session_history` (persistence.rs:3227-3280): idempotent — a
    /// locally-missing session still answers `{"success": true}`.
    private func handleDelete(_ params: JSONValue) async throws -> JSONValue {
        guard let sessionID = params["sessionId"]?.stringValue else {
            throw invalidParams("invalid params: missing field `sessionId`")
        }
        if try parseKind(params) == "chat" {
            // session_admin.rs:323-326, byte-copy.
            throw invalidRequest(
                "chat session delete requires the conversations lane (OIDC + chat feature)"
            )
        }
        if let liveSessionID, sessionID == liveSessionID {
            // Divergence 2 (file header): no live-teardown seam, and a
            // deleted file under a live spine resurrects at the next commit.
            throw internalError(
                "cannot delete session \(sessionID): it is the session this agent is currently serving"
            )
        }

        // A malformed id or a cwd mismatch matches no summary upstream —
        // local_removed:false, still success (persistence.rs:3260-3265).
        let cwd = params["cwd"]?.stringValue
        guard let record = await lookupRecord(sessionID: sessionID, cwd: cwd) else {
            return .object(["success": .bool(true)])
        }

        let catalog = LiveSessionCatalog(openGrokHome: openGrokHome)
        do {
            // The deletion is asserted at the step it happens: `delete`
            // reports whether the file was removed, and a record that was
            // just loaded but failed to delete is a real storage error.
            let removed = try catalog.delete(sessionID: record.sessionID)
            guard removed else {
                return .object(["success": .bool(true)])
            }
        } catch {
            // DeleteSessionError → internal_error (session_admin.rs:308-313).
            throw internalError("\(error)")
        }
        return .object(["success": .bool(true)])
    }

    // MARK: x.ai/session/fork

    /// `handle_session_fork` (session_admin.rs:799-810) over `fork_session`
    /// (fork.rs:65-169). Request/response are camelCase; the response is RAW
    /// (`to_raw_response(&response)`).
    private func handleFork(_ params: JSONValue) async throws -> JSONValue {
        guard let sourceSessionID = params["sourceSessionId"]?.stringValue,
              let sourceCwd = params["sourceCwd"]?.stringValue,
              let newCwd = params["newCwd"]?.stringValue else {
            throw invalidParams(
                "invalid params: missing field `sourceSessionId`, `sourceCwd` or `newCwd`"
            )
        }
        // Divergence 3 (file header): refuse the option arms this store
        // cannot honor rather than silently dropping their payloads.
        for unsupported in ["newModelId", "targetPromptIndex", "sessionKind", "sourceWorkspaceDir"] {
            if let value = params[unsupported], value != .null {
                throw internalError(
                    "fork option '\(unsupported)' is not supported by this build; "
                        + "the fork copies the full transcript on the source session's model route"
                )
            }
        }

        guard await lookupRecord(sessionID: sourceSessionID, cwd: sourceCwd) != nil else {
            // Upstream surfaces the storage adapter's io error through
            // internal_error (session_admin.rs:805-807); the prose is
            // adapter-specific there and hand-written here — recorded.
            throw internalError("session not found: \(sourceSessionID)")
        }

        let destinationID = params["newSessionId"]?.stringValue ?? UUID().uuidString
        let store = LiveConversationStore(openGrokHome: openGrokHome)
        let child: LiveConversationRecord
        do {
            child = try await store.fork(
                sourceSessionID: sourceSessionID,
                destinationSessionID: destinationID,
                workingDirectory: URL(fileURLWithPath: newCwd)
            )
        } catch {
            throw internalError("\(error)")
        }

        // `ForkSessionResponse` (fork.rs:40-54): camelCase; `newModelId`
        // omitted (no override arm here); the zero/false fields are literal
        // truth for this store (divergence 6).
        return .object([
            "newSessionId": .string(child.sessionID),
            "chatMessagesCopied": .number(.int64(Int64(child.items.count))),
            "updatesCopied": .number(.int64(0)),
            "planStateCopied": .bool(false),
            "newCwd": .string(newCwd),
            "parentSessionId": .string(sourceSessionID),
        ])
    }
}
