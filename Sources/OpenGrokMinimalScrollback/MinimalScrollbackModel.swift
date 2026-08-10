// MinimalScrollbackModel.swift
//
// The entry/block model consumed by minimal mode's commit pipeline
// (`MinimalCommit.swift`). Ported from the pin (650c1db7):
// `xai-grok-pager/src/scrollback/entry.rs` (entry flags + constructors),
// `scrollback/types.rs:55-60` (`DisplayMode`), and the classification
// surface of `scrollback/block.rs` / `blocks/tool/mod.rs:342-358`
// (`ToolCallBlock::is_success`).
//
// Deliberately small: this target is the PURE commit pipeline (Wave 18
// B2-M1). A block here carries only what `isCommittable` and the
// display-mode policy actually read — its kind, its success, and enough
// text for tests to prove content integrity at commit time. The
// renderer-facing payloads (hunks, outputs, markdown) belong to the paint
// path (M2), which bridges the live transcript model onto this one.

/// Identity of one scrollback entry. Upstream `EntryId` (`entry.rs:48`);
/// ids start at 1 so 0 stays a pre-push sentinel (`state/mod.rs:239`).
public struct MinimalEntryID: Hashable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }
}

/// How a block is folded when rendered. Upstream `DisplayMode`
/// (`types.rs:55-60`; `Expanded` is upstream's default).
public enum MinimalDisplayMode: Sendable, Equatable {
    case collapsed
    case truncated
    case expanded
}

/// The tool-call kinds the commit policy distinguishes — one case per
/// upstream `ToolCallBlock` variant (`blocks/tool/mod.rs`). `other` carries
/// the raw tool name the way upstream's `Other` block does.
public enum MinimalToolKind: Sendable, Equatable {
    case execute
    case read
    case edit
    case search
    case listDir
    case webFetch
    case webSearch
    case integrationSearch
    case useTool
    case memorySearch
    case skill
    case lifecycle
    case other(String)
}

/// A finalized-content block, reduced to the distinctions the commit
/// pipeline reads. Upstream `RenderBlock` (`block.rs`).
public enum MinimalBlock: Sendable, Equatable {
    /// The generic scaffold block (`RenderBlock::Stub`, `block.rs:580`) —
    /// deliberately none of the special-cased kinds below, which is exactly
    /// why the ported frontier tests use it.
    case stub(String)
    case userPrompt(String)
    case agentMessage(String)
    case thinking(String)
    case system(String)
    /// A background-task lifecycle event (`RenderBlock::BgTask`). Its
    /// content never changes after push — completion is a SEPARATE block —
    /// so its running flag is animation-only (`commit.rs:67-77`).
    case bgTask(command: String, taskID: String)
    /// `error == nil` means the call succeeded; `lifecycle` events are
    /// always successful (`tool/mod.rs:342-358`).
    case toolCall(kind: MinimalToolKind, error: String?)
    /// A side-question block (`RenderBlock::Btw`).
    case btw(question: String, answer: String)

    /// `ToolCallBlock::is_success` (`tool/mod.rs:342-358`): error-free, with
    /// lifecycle events unconditionally successful. `nil` for non-tool blocks.
    public var toolCallSucceeded: Bool? {
        guard case let .toolCall(kind, error) = self else { return nil }
        if case .lifecycle = kind { return true }
        return error == nil
    }
}

/// One scrollback entry: a block plus the lifecycle flags the frontier walk
/// judges. Upstream `ScrollbackEntry` (`entry.rs:76-115`).
public struct MinimalScrollbackEntry: Sendable, Equatable {
    /// Assigned by `MinimalScrollbackState.push`; 0 until then.
    public internal(set) var id: MinimalEntryID
    public var block: MinimalBlock
    /// Still streaming/animating. The tracker can leave this stale (see
    /// `isCommittable`), so the pipeline never trusts it alone.
    public internal(set) var isRunning: Bool
    /// Blocked on a permission / `ask_user_question` prompt. Holds the
    /// commit frontier in EVERY turn state (`commit.rs:96-100`).
    public internal(set) var isPendingUserInput: Bool
    public private(set) var displayMode: MinimalDisplayMode

    /// A finalized entry (`ScrollbackEntry::new`, `entry.rs:179`).
    public init(_ block: MinimalBlock) {
        self.id = MinimalEntryID(0)
        self.block = block
        self.isRunning = false
        self.isPendingUserInput = false
        self.displayMode = .expanded
    }

    /// A still-streaming entry (`ScrollbackEntry::running`, `entry.rs:211`).
    public static func running(_ block: MinimalBlock) -> MinimalScrollbackEntry {
        var entry = MinimalScrollbackEntry(block)
        entry.isRunning = true
        return entry
    }

    /// `ScrollbackEntry::set_display_mode` (`entry.rs:282`).
    public mutating func setDisplayMode(_ mode: MinimalDisplayMode) {
        displayMode = mode
    }

    /// `ScrollbackEntry::mark_completed` (`entry.rs:293-297`): also clears
    /// the pending mark — a completed tool cannot be awaiting an answer, and
    /// a lingering mark would wedge the commit frontier forever.
    public mutating func markCompleted() {
        isRunning = false
        isPendingUserInput = false
    }
}
