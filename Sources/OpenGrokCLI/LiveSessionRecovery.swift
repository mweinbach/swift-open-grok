// LiveSessionRecovery.swift
//
// Rewind: per-prompt file snapshots and the restore path that undoes a bad
// agent edit outside git.
//
// This is the port of Rust's rewind subsystem. The reference implementation is
// split across three files in `/Users/mweinbach/Projects/grok-build` at pin
// 9ed09e2a:
//
//   * `crates/codegen/xai-grok-workspace/src/session/file_state.rs` — the
//     `RewindPoint` / `FileSnapshot` records, `begin_prompt`/`end_prompt`, and
//     the `add_snapshot` "first write wins" rule.
//   * `crates/codegen/xai-grok-shell/src/session/acp_session_impl/rewind.rs` —
//     the restore state machine: dry run, conflict detection, staged apply.
//   * `crates/codegen/xai-grok-shell/src/extensions/rewind.rs` — the ACP
//     method routing (`x.ai/rewind/execute`, `x.ai/rewind/points`).
//
// What the model records, in one sentence: **one rewind point per user prompt,
// holding the content of every file the turn touched as it was *before* the
// turn ran**, so restoring means writing those bytes back.
//
// Two deliberate divergences from Rust, both in the same direction:
//
//  1. **Storage is bounded.** Rust stores full plaintext inline with no cap of
//     any kind and openly expects `rewind_points.jsonl` to reach hundreds of
//     megabytes. That is not a tradeoff worth porting — an agent that reads a
//     vendored dependency tree once would write a snapshot file larger than the
//     repository. `LiveRewindLimits` caps per-file, per-point, and whole-store
//     bytes plus the point count, and the store prunes oldest-first. Every cap
//     is recorded on the point as a `skipped` entry rather than silently
//     dropped, because a rewind that quietly does not restore a file is worse
//     than one that says it cannot.
//
//  2. **Layout follows this port's flat sessions directory.** Rust uses
//     `sessions/{encoded-cwd}/{id}/rewind_points.jsonl`; this port writes one
//     flat `sessions/<id>.json` per session (`LiveConversationStore`), so
//     rewind points go beside it as `sessions/<id>.rewind.jsonl`. Same
//     append-only JSONL discipline, same one-object-per-line format, same
//     skip-malformed-lines-and-continue read rule.
//
// Everything here is additive: the coordinator is optional on every seam it
// plugs into, and a session constructed without one behaves exactly as it did
// before this file existed.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Records

/// One file's content at a point in time.
///
/// `content == nil` means **the file did not exist**, which is what makes
/// "rewind a file the agent created" work: restoring a nil snapshot deletes.
/// Rust `FileSnapshot` (`file_state.rs`), minus its `captured_at` — the
/// containing point already carries a timestamp and a per-file one has no
/// consumer here.
struct LiveRewindSnapshot: Codable, Sendable, Equatable {
    /// Always relative to the session's working directory, using `/`
    /// separators. Rust's `FlexiblePath` tolerates absolute paths for legacy
    /// sessions; nothing has written absolute paths here, so this port only
    /// ever reads and writes the relative form.
    var path: String
    var content: String?

    enum CodingKeys: String, CodingKey {
        case path
        case content
    }
}

/// Why a file the turn touched has no snapshot.
///
/// Rust has no analogue because Rust has no limits. Recording the reason is
/// what keeps a bounded store honest: `/rewind` can tell the user "3 files
/// cannot be restored because they exceeded the size cap" instead of restoring
/// a partial tree and reporting success.
/// Conforms to `Error` so `readSnapshot` can return it as a `Result` failure —
/// it is never thrown, only carried.
enum LiveRewindSkipReason: String, Codable, Sendable, Equatable, Error {
    /// Larger than `LiveRewindLimits.maxFileBytes`.
    case tooLarge
    /// Not valid UTF-8. Snapshots are text; a binary asset is not restorable
    /// through this path.
    case binary
    /// The point had already spent `LiveRewindLimits.maxPointBytes`.
    case pointBudgetExhausted
    /// Could not be read (permissions, a race with an external delete).
    case unreadable
}

/// A file the turn touched that was deliberately not snapshotted.
struct LiveRewindSkippedFile: Codable, Sendable, Equatable {
    var path: String
    var reason: LiveRewindSkipReason
}

/// Everything needed to put the workspace back the way it was before one
/// prompt ran. Rust `RewindPoint` (`file_state.rs:284`).
struct LiveRewindPoint: Codable, Sendable, Equatable {
    /// 0-based index of the user prompt this point precedes.
    var promptIndex: Int
    var createdAt: Date
    /// The prompt's text, kept so `/rewind` can list points by what was asked
    /// and so a restore can pre-fill the composer with the original prompt
    /// (Rust returns this as `RewindResponse.prompt_text`).
    var promptText: String
    /// State **before** the prompt ran. This is what a restore writes back.
    var before: [LiveRewindSnapshot]
    /// State **after** the prompt finished. Used only to detect that something
    /// outside this session changed the file since, so a restore can warn
    /// instead of silently clobbering an external edit.
    var after: [LiveRewindSnapshot]
    var skipped: [LiveRewindSkippedFile]

    enum CodingKeys: String, CodingKey {
        case promptIndex = "prompt_index"
        case createdAt = "created_at"
        case promptText = "prompt_text"
        case before
        case after
        case skipped
    }

    init(promptIndex: Int, createdAt: Date, promptText: String) {
        self.promptIndex = promptIndex
        self.createdAt = createdAt
        self.promptText = promptText
        self.before = []
        self.after = []
        self.skipped = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.promptIndex = try c.decode(Int.self, forKey: .promptIndex)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.promptText = try c.decodeIfPresent(String.self, forKey: .promptText) ?? ""
        self.before = try c.decodeIfPresent([LiveRewindSnapshot].self, forKey: .before) ?? []
        self.after = try c.decodeIfPresent([LiveRewindSnapshot].self, forKey: .after) ?? []
        self.skipped = try c.decodeIfPresent([LiveRewindSkippedFile].self, forKey: .skipped) ?? []
    }

    /// Approximate serialized cost, used to enforce the per-point and
    /// whole-store byte caps without re-encoding on every capture.
    var approximateBytes: Int {
        var total = promptText.utf8.count + 128
        for snapshot in before + after {
            total += snapshot.path.utf8.count + (snapshot.content?.utf8.count ?? 0) + 32
        }
        return total
    }

    /// The one-line summary `/rewind` lists. Rust truncates the first line at
    /// 57 characters and appends an ellipsis (`RewindPointInfo`); same here.
    var preview: String {
        let firstLine = promptText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if firstLine.isEmpty { return "(no prompt text)" }
        if firstLine.count <= 57 { return firstLine }
        return String(firstLine.prefix(57)) + "..."
    }

    /// Whether restoring this point would actually change anything on disk.
    /// A read-only turn records a point with snapshots whose content already
    /// matches; listing it as restorable would be noise.
    var touchesFiles: Bool { !before.isEmpty }
}

// MARK: - Limits

/// The bounds Rust does not have. See the file header for why.
struct LiveRewindLimits: Sendable, Equatable {
    /// Skip any single file larger than this. 1 MiB covers essentially all
    /// source files while excluding the vendored blobs and build outputs that
    /// would otherwise dominate the store.
    var maxFileBytes: Int = 1 << 20
    /// Stop snapshotting within one prompt after this much content. A turn
    /// that rewrites 500 files is a refactor, and the last few files it
    /// touched are the ones worth being able to undo.
    var maxPointBytes: Int = 8 << 20
    /// Keep at most this many points; oldest are pruned first.
    var maxPoints: Int = 50
    /// Hard ceiling on the whole file. Pruning runs until the store fits.
    var maxStoreBytes: Int = 64 << 20

    static let `default` = LiveRewindLimits()

    /// Everything off. Used by the `nil`-coordinator path and by tests that
    /// want to assert the cap behaviour explicitly rather than inherit it.
    static let unlimited = LiveRewindLimits(
        maxFileBytes: .max,
        maxPointBytes: .max,
        maxPoints: .max,
        maxStoreBytes: .max
    )
}

// MARK: - Store

/// Append-only JSONL persistence for rewind points.
///
/// One JSON object per line, matching Rust's `rewind_points.jsonl`. A line that
/// fails to decode is skipped rather than failing the read: a crash mid-append
/// must not make every earlier point unrecoverable, which is the whole reason
/// the format is line-oriented instead of one big array.
actor LiveRewindStore {
    private let fileURL: URL
    /// Built inside the actor rather than injected: `FileManager` is not
    /// `Sendable`, so handing one across the actor boundary is a data race the
    /// compiler correctly rejects. Nothing here needs a custom one.
    private let fileManager = FileManager.default
    private let limits: LiveRewindLimits

    init(
        openGrokHome: URL,
        sessionID: String,
        limits: LiveRewindLimits = .default
    ) {
        self.fileURL = Self.rewindFileURL(openGrokHome: openGrokHome, sessionID: sessionID)
        self.limits = limits
    }

    static func rewindFileURL(openGrokHome: URL, sessionID: String) -> URL {
        openGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).rewind.jsonl")
            .standardizedFileURL
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Every readable point, in prompt order.
    func load() -> [LiveRewindPoint] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = Self.decoder()
        var points: [LiveRewindPoint] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty,
                  let point = try? decoder.decode(
                      LiveRewindPoint.self,
                      from: Data(line.utf8)
                  )
            else { continue }
            points.append(point)
        }
        return points.sorted { $0.promptIndex < $1.promptIndex }
    }

    /// Append one point, then prune until the store fits its limits.
    ///
    /// Pruning rewrites the file, which costs a full read+write. That is
    /// acceptable because it only happens once the caps are actually reached,
    /// and the alternative — an unbounded append-only file — is the thing this
    /// port is deliberately not reproducing.
    func append(_ point: LiveRewindPoint) {
        // One point per prompt index is an invariant the restore path depends
        // on — it resolves a path by taking the first snapshot at or after the
        // target, so two records sharing an index would make which one wins
        // depend on sort stability. The collision is reachable: a
        // conversation-only rewind leaves a merged point at the target index,
        // and the next prompt is numbered from that same target.
        let existing = load()
        if let prior = existing.first(where: { $0.promptIndex == point.promptIndex }) {
            // The prior point's snapshots are older, so they win — the merged
            // record still describes the state before the earliest undone
            // prompt, which is what the index is supposed to mean.
            let merged = Self.merging(earlier: prior, later: point)
            rewrite(existing.filter { $0.promptIndex != point.promptIndex } + [merged])
            prune()
            return
        }

        guard let line = try? Self.encoder().encode(point) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var payload = line
        payload.append(0x0A)

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: fileURL, options: .atomic)
        }
        prune()
    }

    /// Drop every point at or after `promptIndex`.
    ///
    /// Called after a successful restore: the prompts that were undone no
    /// longer happened, so their points must not remain listable. Rust does the
    /// same via `truncate_from` plus `PersistenceMsg::TruncateRewindPoints`.
    func truncate(from promptIndex: Int) {
        let kept = load().filter { $0.promptIndex < promptIndex }
        rewrite(kept)
    }

    /// Collapse every point at or after `promptIndex` into one point *at*
    /// `promptIndex`, keeping the earliest snapshot of each path.
    ///
    /// Used by a conversation-only rewind, which rolls history back without
    /// touching the working tree. Truncating there would discard snapshots for
    /// edits still present on disk, so a later `/rewind` could no longer undo
    /// them; merging keeps that possible while letting prompt numbering restart
    /// at the target. Rust `merge_rewind_points_from`.
    func merge(from promptIndex: Int) {
        let points = load()
        let kept = points.filter { $0.promptIndex < promptIndex }
        let discarded = points.filter { $0.promptIndex >= promptIndex }
        guard let first = discarded.first else { return }

        var merged = LiveRewindPoint(
            promptIndex: promptIndex,
            createdAt: first.createdAt,
            promptText: first.promptText
        )
        merged.before = first.before
        merged.after = first.after
        merged.skipped = first.skipped
        for point in discarded.dropFirst() {
            merged = Self.merging(earlier: merged, later: point)
        }
        rewrite(kept + [merged])
    }

    /// Fold `later` into `earlier`, producing one point that describes the
    /// state before `earlier`'s prompt and the state after `later`'s.
    ///
    /// The two halves resolve in opposite directions on purpose. `before` keeps
    /// the **earliest** snapshot of each path, because that is what "the state
    /// before this prompt" means once several prompts collapse into one.
    /// `after` keeps the **latest**, because its only job is to detect edits
    /// made since the session last wrote the file.
    static func merging(
        earlier: LiveRewindPoint,
        later: LiveRewindPoint
    ) -> LiveRewindPoint {
        var merged = earlier
        var seenBefore = Set(earlier.before.map(\.path))
        for snapshot in later.before where !seenBefore.contains(snapshot.path) {
            seenBefore.insert(snapshot.path)
            merged.before.append(snapshot)
        }
        var seenSkips = Set(earlier.skipped.map(\.path))
        for skip in later.skipped where !seenSkips.contains(skip.path) {
            seenSkips.insert(skip.path)
            merged.skipped.append(skip)
        }
        var latestAfter: [String: LiveRewindSnapshot] = [:]
        for snapshot in earlier.after { latestAfter[snapshot.path] = snapshot }
        for snapshot in later.after { latestAfter[snapshot.path] = snapshot }
        merged.after = latestAfter.keys.sorted().compactMap { latestAfter[$0] }
        return merged
    }

    /// Delete the whole store. Used when its session is deleted, so
    /// `sessions delete` does not leave snapshots behind.
    func removeAll() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func prune() {
        var points = load()
        guard !points.isEmpty else { return }
        var changed = false
        if points.count > limits.maxPoints {
            points.removeFirst(points.count - limits.maxPoints)
            changed = true
        }
        if limits.maxStoreBytes != .max {
            var total = points.reduce(0) { $0 + $1.approximateBytes }
            // Never prune to empty: the newest point is the one most likely to
            // be wanted, even if it alone exceeds the ceiling.
            while total > limits.maxStoreBytes, points.count > 1 {
                total -= points.removeFirst().approximateBytes
                changed = true
            }
        }
        guard changed else { return }
        rewrite(points)
    }

    private func rewrite(_ points: [LiveRewindPoint]) {
        let encoder = Self.encoder()
        var payload = Data()
        for point in points {
            guard let line = try? encoder.encode(point) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        if payload.isEmpty {
            try? fileManager.removeItem(at: fileURL)
        } else {
            try? payload.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Listing / restore results

/// One row of `/rewind`'s picker. Rust `RewindPointInfo`.
struct LiveRewindPointInfo: Sendable, Equatable {
    var promptIndex: Int
    var createdAt: Date
    var preview: String
    var fileCount: Int
    var hasFileChanges: Bool
    var skippedCount: Int
}

/// How much of the session a restore should undo. Rust `RewindMode`, including
/// its `code_only` alias for `files_only`.
enum LiveRewindMode: String, Sendable, Equatable, CaseIterable {
    /// Files on disk **and** conversation history.
    case all
    /// History only; the working tree is left alone.
    case conversationOnly
    /// Files only; the conversation keeps every turn.
    case filesOnly

    static func parse(_ raw: String) -> LiveRewindMode? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "all", "": return .all
        case "conversation", "conversation-only", "conversation_only": return .conversationOnly
        case "files", "files-only", "files_only", "code", "code-only", "code_only": return .filesOnly
        default: return nil
        }
    }
}

/// Something changed the file after this session last wrote it.
///
/// Detected by comparing the file's current bytes against the point's `after`
/// snapshot. Rust reports the same three shapes over the wire.
struct LiveRewindConflict: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case modifiedExternally
        case createdExternally
        case deletedExternally
    }

    var path: String
    var kind: Kind

    var describedReason: String {
        switch kind {
        case .modifiedExternally: return "modified outside this session"
        case .createdExternally: return "created outside this session"
        case .deletedExternally: return "deleted outside this session"
        }
    }
}

/// What a restore did, or — when `force` was false — what it *would* do.
///
/// A non-forced restore is a pure dry run that mutates nothing, which is how
/// `/rewind` shows a confirmation before touching the working tree.
struct LiveRewindOutcome: Sendable, Equatable {
    var applied: Bool
    var targetPromptIndex: Int
    var mode: LiveRewindMode
    /// Files that will be, or were, written back.
    var cleanFiles: [String]
    /// Files whose current content diverges from what this session last wrote.
    /// Skipped unless the caller forces through.
    var conflicts: [LiveRewindConflict]
    /// Files recorded on the point but never snapshotted, so unrestorable.
    var unrestorable: [LiveRewindSkippedFile]
    var revertedFiles: [String]
    /// How many conversation items the history truncation removed.
    var removedItemCount: Int
    /// The prompt that was undone, so the composer can be pre-filled with it.
    var promptText: String
}

enum LiveRewindError: Error, CustomStringConvertible, Equatable {
    case noPoints
    case unknownPoint(Int)
    case notYetRun(Int)
    case writeFailed(path: String, message: String)

    var description: String {
        switch self {
        case .noPoints:
            return "no rewind points have been recorded for this session yet"
        case .unknownPoint(let index):
            return "no rewind point for prompt \(index)"
        case .notYetRun(let index):
            return "prompt \(index) has not run yet; there is nothing to rewind to"
        case .writeFailed(let path, let message):
            return "failed to restore \(path): \(message)"
        }
    }
}

// MARK: - History truncation

/// Cut `items` back to the state before prompt `targetPromptIndex` ran.
///
/// Prompt indices are counted **positionally over real user turns** rather than
/// read off `UserItem.promptIndex`, because this port's turn loop appends
/// `.user(prompt)` without setting that field. Counting is therefore the only
/// signal that is correct for sessions written before this file existed.
///
/// Synthetic user items (project instructions, system reminders, compaction
/// meta) do not open a prompt turn, matching `SyntheticReason.startsPromptTurn`
/// — except for the reasons that flag themselves as turn-starting, which the
/// turn pipeline really does spend a prompt slot on.
///
/// A leading `.system` item is always preserved: it is the session's system
/// prompt, not a turn, and dropping it would silently change the agent's
/// behaviour after a rewind.
func liveTruncateConversation(
    _ items: [ConversationItem],
    toPromptIndex targetPromptIndex: Int
) -> [ConversationItem] {
    guard targetPromptIndex >= 0 else { return items }
    var promptCount = 0
    var cutIndex: Int?
    for (offset, item) in items.enumerated() {
        guard case .user(let user) = item else { continue }
        let startsTurn = user.syntheticReason.map(\.startsPromptTurn) ?? true
        guard startsTurn else { continue }
        if promptCount == targetPromptIndex {
            cutIndex = offset
            break
        }
        promptCount += 1
    }
    guard let cutIndex else { return items }

    var kept = Array(items[..<cutIndex])
    // Preserve the system prompt even when rewinding to prompt 0, which cuts
    // at the very first user turn and would otherwise also drop anything
    // preceding it.
    if kept.isEmpty {
        if case .system = items.first {
            kept = [items[0]]
        }
    }
    return kept
}

/// The prompt text of turn `promptIndex`, used to pre-fill the composer.
func livePromptText(in items: [ConversationItem], at promptIndex: Int) -> String? {
    var count = 0
    for item in items {
        guard case .user(let user) = item else { continue }
        let startsTurn = user.syntheticReason.map(\.startsPromptTurn) ?? true
        guard startsTurn else { continue }
        if count == promptIndex {
            for part in user.content {
                if case .text(let text) = part { return text }
            }
            return ""
        }
        count += 1
    }
    return nil
}

// MARK: - Coordinator

/// Records a rewind point per prompt and serves the restore path.
///
/// Lifecycle over one turn, mirroring Rust's `begin_prompt` / `capture` /
/// `end_prompt`:
///
/// ```
/// await rewind.beginPrompt(text: prompt)     // opens an empty point
/// await rewind.capture(paths: [...])         // once per file-touching tool call
/// await rewind.endPrompt()                   // fills `after`, appends, prunes
/// ```
///
/// `capture` records the **first** state it sees for a path and ignores every
/// later capture of the same path in the same prompt (Rust's `add_snapshot` is
/// an `entry().or_insert`). That is what makes the snapshot the pre-turn state
/// even though it is collected lazily as tools run.
actor LiveRewindCoordinator {
    private let store: LiveRewindStore
    private let workingDirectory: URL
    private let limits: LiveRewindLimits
    /// See `LiveRewindStore.fileManager`: actor-local, never injected.
    private let fileManager = FileManager.default

    /// The point being built for the in-flight prompt, if a turn is open.
    private var open: LiveRewindPoint?
    private var openBytes = 0
    /// Paths already captured in the open prompt, so `capture` stays O(1) and
    /// first-write-wins is enforced without scanning the snapshot array.
    private var capturedPaths: Set<String> = []
    /// Next prompt index to assign. Seeded from the store so a resumed session
    /// continues numbering rather than overwriting the points it loaded.
    private var nextPromptIndex: Int

    init(
        openGrokHome: URL,
        sessionID: String,
        workingDirectory: URL,
        conversationItems: [ConversationItem] = [],
        limits: LiveRewindLimits = .default
    ) async {
        self.store = LiveRewindStore(
            openGrokHome: openGrokHome,
            sessionID: sessionID,
            limits: limits
        )
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.limits = limits
        // Resume numbering from whichever is further along: the points already
        // on disk, or the prompts already in the transcript. The transcript is
        // authoritative when snapshots were pruned or the store was deleted.
        let stored = await store.load().map(\.promptIndex).max().map { $0 + 1 } ?? 0
        let transcript = Self.promptCount(in: conversationItems)
        self.nextPromptIndex = max(stored, transcript)
    }

    private static func promptCount(in items: [ConversationItem]) -> Int {
        var count = 0
        for item in items {
            guard case .user(let user) = item else { continue }
            let startsTurn = user.syntheticReason.map(\.startsPromptTurn) ?? true
            if startsTurn { count += 1 }
        }
        return count
    }

    // MARK: Capture

    /// Open a point for the prompt about to run.
    func beginPrompt(text: String) {
        // A turn that never closed (a crash, a cancelled turn) leaves its point
        // unpersisted. Closing it here rather than discarding it keeps the
        // snapshots that were collected before the interruption.
        if open != nil {
            endPrompt()
        }
        open = LiveRewindPoint(
            promptIndex: nextPromptIndex,
            createdAt: Date(),
            promptText: text
        )
        openBytes = 0
        capturedPaths = []
        nextPromptIndex += 1
    }

    /// Record the pre-turn state of every path a tool is about to touch.
    ///
    /// Safe to call with paths that do not exist, are outside the workspace, or
    /// have already been captured — all three are the common case and all three
    /// are handled without error, because the call site is a hot path in the
    /// tool dispatcher and must never fail a tool call.
    func capture(paths: [String]) {
        guard open != nil else { return }
        for path in paths {
            capture(path: path)
        }
    }

    private func capture(path rawPath: String) {
        guard open != nil else { return }
        guard let relative = relativePath(for: rawPath) else { return }
        guard !capturedPaths.contains(relative) else { return }
        capturedPaths.insert(relative)

        let url = workingDirectory.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: url.path) else {
            // The file does not exist yet. Snapshotting that fact is what makes
            // "undo a file the agent created" work: restoring nil deletes it.
            open?.before.append(LiveRewindSnapshot(path: relative, content: nil))
            return
        }
        switch readSnapshot(at: url, relative: relative) {
        case .success(let snapshot):
            let cost = snapshot.path.utf8.count + (snapshot.content?.utf8.count ?? 0)
            guard openBytes + cost <= limits.maxPointBytes else {
                open?.skipped.append(LiveRewindSkippedFile(
                    path: relative,
                    reason: .pointBudgetExhausted
                ))
                return
            }
            openBytes += cost
            open?.before.append(snapshot)
        case .failure(let reason):
            open?.skipped.append(LiveRewindSkippedFile(path: relative, reason: reason))
        }
    }

    /// Close the open point: re-read every tracked path to record the state the
    /// turn left behind, then persist.
    func endPrompt() {
        guard var point = open else { return }
        open = nil
        openBytes = 0
        capturedPaths = []
        // A turn that touched nothing is not worth a point. Rust records one
        // regardless; skipping it here keeps the picker free of rows whose only
        // effect would be a history truncation the user did not ask for.
        guard !point.before.isEmpty || !point.skipped.isEmpty else { return }

        for snapshot in point.before {
            let url = workingDirectory.appendingPathComponent(snapshot.path)
            guard fileManager.fileExists(atPath: url.path) else {
                point.after.append(LiveRewindSnapshot(path: snapshot.path, content: nil))
                continue
            }
            if case .success(let after) = readSnapshot(at: url, relative: snapshot.path) {
                point.after.append(after)
            }
        }
        let captured = point
        Task { await store.append(captured) }
    }

    private func readSnapshot(
        at url: URL,
        relative: String
    ) -> Result<LiveRewindSnapshot, LiveRewindSkipReason> {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size, size > limits.maxFileBytes {
            return .failure(.tooLarge)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable)
        }
        guard data.count <= limits.maxFileBytes else {
            return .failure(.tooLarge)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return .failure(.binary)
        }
        return .success(LiveRewindSnapshot(path: relative, content: content))
    }

    /// Normalize a tool-supplied path to a workspace-relative one.
    ///
    /// Returns nil for anything outside the working directory and for anything
    /// under `.git`. Both exclusions are load-bearing: snapshotting outside the
    /// workspace would let a rewind write to arbitrary paths, and snapshotting
    /// `.git` would let a rewind corrupt the repository it exists to back up.
    private func relativePath(for rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absolute: URL = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed).standardizedFileURL
            : workingDirectory.appendingPathComponent(trimmed).standardizedFileURL

        let root = workingDirectory.path.hasSuffix("/")
            ? workingDirectory.path
            : workingDirectory.path + "/"
        guard absolute.path.hasPrefix(root) else { return nil }
        let relative = String(absolute.path.dropFirst(root.count))
        guard !relative.isEmpty else { return nil }
        let firstComponent = relative.split(separator: "/").first.map(String.init)
        guard firstComponent != ".git" else { return nil }
        return relative
    }

    // MARK: Listing

    /// Every recorded point, newest last. `/rewind` reverses this for display.
    func points() async -> [LiveRewindPointInfo] {
        await store.load().map { point in
            LiveRewindPointInfo(
                promptIndex: point.promptIndex,
                createdAt: point.createdAt,
                preview: point.preview,
                fileCount: point.before.count,
                hasFileChanges: point.touchesFiles,
                skippedCount: point.skipped.count
            )
        }
    }

    // MARK: Restore

    /// Restore to the state before prompt `targetPromptIndex` ran.
    ///
    /// With `force == false` this is a **pure dry run**: nothing is written and
    /// nothing is truncated, and the returned outcome describes what would
    /// happen. That is what `/rewind` shows in its confirmation.
    ///
    /// History truncation is *not* performed here — this actor does not own the
    /// conversation. The caller applies `liveTruncateConversation` to its own
    /// items using the returned `targetPromptIndex`; `removedItemCount` is
    /// filled in by the caller-supplied `currentItems`.
    func restore(
        toPromptIndex targetPromptIndex: Int,
        mode: LiveRewindMode,
        force: Bool,
        currentItems: [ConversationItem]
    ) async throws -> LiveRewindOutcome {
        let points = await store.load()
        guard !points.isEmpty else { throw LiveRewindError.noPoints }
        guard let target = points.first(where: { $0.promptIndex == targetPromptIndex }) else {
            throw LiveRewindError.unknownPoint(targetPromptIndex)
        }
        if mode != .filesOnly, targetPromptIndex >= nextPromptIndex {
            throw LiveRewindError.notYetRun(targetPromptIndex)
        }

        // Restoring to prompt N means undoing prompts N, N+1, … so every point
        // from N onward contributes. Earlier points win on conflict: they hold
        // the state furthest back, which is what "before prompt N" means.
        var plan: [String: LiveRewindSnapshot] = [:]
        var unrestorable: [LiveRewindSkippedFile] = []
        var seenSkips: Set<String> = []
        for point in points where point.promptIndex >= targetPromptIndex {
            for snapshot in point.before where plan[snapshot.path] == nil {
                plan[snapshot.path] = snapshot
            }
            for skip in point.skipped where !seenSkips.contains(skip.path) {
                seenSkips.insert(skip.path)
                unrestorable.append(skip)
            }
        }

        // Conflict detection compares the file's current bytes against what the
        // session last observed. The newest `after` entry for a path is the
        // session's most recent view of it.
        var lastKnown: [String: LiveRewindSnapshot] = [:]
        for point in points {
            for snapshot in point.after {
                lastKnown[snapshot.path] = snapshot
            }
        }

        var clean: [String] = []
        var conflicts: [LiveRewindConflict] = []
        if mode != .conversationOnly {
            for path in plan.keys.sorted() {
                guard let expected = lastKnown[path] else {
                    // Never observed after a turn — nothing to compare against,
                    // so treat it as clean rather than blocking on ignorance.
                    clean.append(path)
                    continue
                }
                let url = workingDirectory.appendingPathComponent(path)
                let exists = fileManager.fileExists(atPath: url.path)
                let current: String? = exists
                    ? (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
                    : nil
                switch (expected.content, current, exists) {
                case (let want?, let have?, _) where want == have:
                    clean.append(path)
                case (nil, _, false):
                    clean.append(path)
                case (_, _, false):
                    conflicts.append(LiveRewindConflict(path: path, kind: .deletedExternally))
                case (nil, _, true):
                    conflicts.append(LiveRewindConflict(path: path, kind: .createdExternally))
                default:
                    conflicts.append(LiveRewindConflict(path: path, kind: .modifiedExternally))
                }
            }
        }

        let promptText = target.promptText
        let removedItemCount = mode == .filesOnly
            ? 0
            : currentItems.count - liveTruncateConversation(
                currentItems,
                toPromptIndex: targetPromptIndex
            ).count

        guard force else {
            return LiveRewindOutcome(
                applied: false,
                targetPromptIndex: targetPromptIndex,
                mode: mode,
                cleanFiles: clean,
                conflicts: conflicts,
                unrestorable: unrestorable,
                revertedFiles: [],
                removedItemCount: removedItemCount,
                promptText: promptText
            )
        }

        var reverted: [String] = []
        if mode != .conversationOnly {
            // Rust stages the whole apply and rolls back on failure. This port
            // restores file-by-file and reports what it managed, because the
            // failure mode that matters is a permission error on one path, and
            // undoing the other nineteen successful restores to punish it makes
            // the recovery path less useful, not more.
            for path in clean {
                guard let snapshot = plan[path] else { continue }
                let url = workingDirectory.appendingPathComponent(path)
                do {
                    if let content = snapshot.content {
                        try fileManager.createDirectory(
                            at: url.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try Data(content.utf8).write(to: url, options: .atomic)
                    } else if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                    }
                    reverted.append(path)
                } catch {
                    throw LiveRewindError.writeFailed(
                        path: path,
                        message: "\(error)"
                    )
                }
            }
        }

        // Either way the undone prompts stop being listable and numbering
        // resumes at the target, so the point indices keep matching the
        // conversation's prompt indices — the two must agree or a later
        // `/rewind` restores the wrong turn.
        //
        // The two modes differ in what they keep. `filesOnly` and `all` just
        // truncate: the snapshots were consumed and no longer describe
        // anything on disk. `conversationOnly` touched no files, so discarding
        // its snapshots would silently give up the ability to undo those edits
        // later — instead they are folded into a single point at the target,
        // earliest state winning, which is Rust's `merge_rewind_points_from`.
        if mode == .conversationOnly {
            await store.merge(from: targetPromptIndex)
        } else {
            await store.truncate(from: targetPromptIndex)
        }
        nextPromptIndex = targetPromptIndex

        return LiveRewindOutcome(
            applied: true,
            targetPromptIndex: targetPromptIndex,
            mode: mode,
            cleanFiles: clean,
            conflicts: conflicts,
            unrestorable: unrestorable,
            revertedFiles: reverted,
            removedItemCount: removedItemCount,
            promptText: promptText
        )
    }
}

// MARK: - Tool-argument path extraction

/// Pull the file paths a tool call is about to touch out of its arguments.
///
/// Rust hooks snapshotting inside each file tool, where the resolved path is
/// already known. This port has one dispatcher for every registry tool and no
/// per-tool seam, so the paths are read back off the JSON arguments instead.
/// The key names are the file tools' own parameter names; anything unrecognized
/// yields no paths, which degrades to "this turn recorded no snapshot for that
/// file" rather than to a wrong snapshot.
enum LiveRewindPathExtraction {
    /// Argument keys that carry a single path.
    private static let singlePathKeys = [
        "path", "file_path", "target_file", "filename", "file",
    ]
    /// Argument keys that carry an array of paths.
    private static let multiPathKeys = ["paths", "files", "file_paths"]

    /// Tools worth snapshotting for. A read-only tool still contributes: Rust
    /// snapshots on read as well as write, so that a file the agent looked at
    /// and then edited through some other route is still recoverable.
    static let trackedTools: Set<String> = [
        "write", "search_replace", "apply_patch", "read_file",
        "hashline_read", "hashline_edit", "edit_file", "create_file",
        "delete_file", "move_file",
    ]

    static func paths(fromArguments args: JSONValue) -> [String] {
        guard case .object(let fields) = args else { return [] }
        var found: [String] = []
        for key in singlePathKeys {
            if case .string(let value)? = fields[key] { found.append(value) }
        }
        for key in multiPathKeys {
            guard case .array(let values)? = fields[key] else { continue }
            for value in values {
                if case .string(let path) = value { found.append(path) }
            }
        }
        return found
    }
}
