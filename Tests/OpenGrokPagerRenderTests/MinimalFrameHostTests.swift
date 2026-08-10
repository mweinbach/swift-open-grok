// MinimalFrameHostTests.swift
//
// Wave 18 B2-M4: the minimal frontend program, tested through the live
// seam — real `PagerRenderState` frames into `PagerMinimalFrameHost.draw`,
// asserted on the BYTES a capturing `PagerTerminalSink` received, because
// that is what lands on a user's terminal. Print-once is the load-bearing
// property everywhere: the capturing sink ACCUMULATES, so "committed
// exactly once" is an occurrence COUNT across repeated draws (the W3
// cumulative-sink trap, used deliberately here), and needles are single
// words. Includes the K6 guard (`guard.rs` at pin 650c1db7): minimal's
// sources must never call the history-re-emitting resize helpers.

import Foundation
import Testing
import OpenGrokMinimalScrollback
import OpenGrokTerminalCore
@testable import OpenGrokPagerRender

private final class CaptureSink: PagerTerminalSink {
    let capabilities = PagerTerminalCapabilities.standard
    private(set) var bytes: [UInt8] = []
    var failWrites = false

    func write(bytes: [UInt8]) throws {
        if failWrites { throw CocoaError(.fileWriteUnknown) }
        self.bytes.append(contentsOf: bytes)
    }

    func flush() throws {}

    var text: String { String(decoding: bytes, as: UTF8.self) }

    func occurrences(of needle: String) -> Int {
        var count = 0
        var search = text[...]
        while let range = search.range(of: needle) {
            count += 1
            search = search[range.upperBound...]
        }
        return count
    }
}

private func makeHost(
    sink: CaptureSink,
    size: TerminalSize = TerminalSize(width: 80, height: 24),
    welcome: MinimalWelcomeCardInfo? = nil
) throws -> PagerMinimalFrameHost {
    try PagerMinimalFrameHost(
        sink: sink,
        sizeProvider: { size },
        welcome: welcome
    )
}

private func frame(
    _ conversation: [PagerConversationItem],
    turnRunning: Bool = false,
    overlays: [PagerOverlay] = []
) -> PagerRenderState {
    PagerRenderState(
        size: TerminalSize(width: 80, height: 24),
        conversation: conversation,
        turnStatus: turnRunning ? PagerTurnStatus(label: "Thinking", tick: 1) : nil,
        input: PagerComposerState(text: ""),
        overlays: PagerOverlayStack(overlays)
    )
}

@Suite("Minimal frame host — live seam")
struct MinimalFrameHostTests {
    // The core print-once proof: a finalized block reaches native
    // scrollback through insertBefore exactly once, no matter how many
    // frames follow (`commit_leading_run` + the committed id-set).
    @Test("a finalized block commits exactly once across repeated draws")
    func aFinalizedBlockCommitsExactlyOnceAcrossRepeatedDraws() throws {
        let sink = CaptureSink()
        let host = try makeHost(sink: sink)
        try host.begin()
        let items: [PagerConversationItem] = [
            .message(PagerMessage(role: .assistant, text: "UNIQUEANSWER"))
        ]
        host.draw(frame(items))
        #expect(sink.occurrences(of: "UNIQUEANSWER") == 1, "committed on the first draw")
        host.draw(frame(items))
        host.draw(frame(items))
        #expect(
            sink.occurrences(of: "UNIQUEANSWER") == 1,
            "print-once: later frames must not re-emit the committed block"
        )
    }

    // While a block streams it lives in the tail — its GROWTH reaches the
    // terminal (the frame path is cell-diffed, so a still frame honestly
    // emits nothing; new content is the live signal). Finalizing commits
    // the whole block once via insertBefore, and from then on it is frozen.
    @Test("a streaming block stays live in the tail, then commits once")
    func aStreamingBlockStaysLiveInTheTailThenCommitsOnce() throws {
        let sink = CaptureSink()
        let host = try makeHost(sink: sink)
        try host.begin()
        host.draw(frame(
            [.message(PagerMessage(role: .assistant, text: "STREAMONE", isStreaming: true))],
            turnRunning: true
        ))
        #expect(sink.occurrences(of: "STREAMONE") == 1, "the tail shows the stream")
        host.draw(frame(
            [.message(PagerMessage(
                role: .assistant, text: "STREAMONE STREAMTWO", isStreaming: true
            ))],
            turnRunning: true
        ))
        #expect(
            sink.occurrences(of: "STREAMTWO") >= 1,
            "still live: streamed growth reaches the terminal"
        )

        let beforeCommit = sink.occurrences(of: "STREAMONE")
        let finalized: [PagerConversationItem] = [
            .message(PagerMessage(role: .assistant, text: "STREAMONE STREAMTWO"))
        ]
        host.draw(frame(finalized))
        let afterCommit = sink.occurrences(of: "STREAMONE")
        #expect(
            afterCommit > beforeCommit,
            "the commit emits the finalized block into scrollback"
        )
        host.draw(frame(finalized))
        host.draw(frame(finalized))
        #expect(
            sink.occurrences(of: "STREAMONE") == afterCommit,
            "after the commit the block never prints again"
        )
    }

    // welcome.rs:24-46 — the card prints once, above the first block, only
    // on a fresh session.
    @Test("the welcome card prints once and lands above the first block")
    func theWelcomeCardPrintsOnceAndLandsAboveTheFirstBlock() throws {
        let sink = CaptureSink()
        let host = try makeHost(
            sink: sink,
            welcome: MinimalWelcomeCardInfo(
                version: "9.9.9", workingDirectory: "/tmp/project", model: "grok-4"
            )
        )
        host.setWelcomePending(true)
        try host.begin()
        host.draw(frame([.message(PagerMessage(role: .assistant, text: "FIRSTBLOCK"))]))
        #expect(sink.occurrences(of: "9.9.9") == 1, "the card printed")
        let cardAt = sink.text.range(of: "9.9.9")!.lowerBound
        let blockAt = sink.text.range(of: "FIRSTBLOCK")!.lowerBound
        #expect(cardAt < blockAt, "the card lands above the first conversation block")

        host.draw(frame([.message(PagerMessage(role: .assistant, text: "FIRSTBLOCK"))]))
        #expect(sink.occurrences(of: "9.9.9") == 1, "one card per session")
    }

    @Test("a resumed session gets no card and replays into scrollback")
    func aResumedSessionGetsNoCardAndReplaysIntoScrollback() throws {
        let sink = CaptureSink()
        let host = try makeHost(
            sink: sink,
            welcome: MinimalWelcomeCardInfo(version: "9.9.9", workingDirectory: "/tmp")
        )
        // The composition root arms the card only for an EMPTY session.
        host.setWelcomePending(false)
        try host.begin()
        host.draw(frame([
            .message(PagerMessage(role: .user, text: "REPLAYEDPROMPT")),
            .message(PagerMessage(role: .assistant, text: "REPLAYEDANSWER")),
        ]))
        #expect(sink.occurrences(of: "9.9.9") == 0, "no card on resume")
        // Resume/attach replay falls through to the normal commit pass
        // (commit.rs:400-406): a resumed session must be visible.
        #expect(sink.occurrences(of: "REPLAYEDANSWER") == 1)
    }

    // guard.rs stance: main screen, mouse capture OFF. What begin+draw must
    // NOT emit is the whole assertion.
    @Test("the host never enters the alt screen or captures the mouse")
    func theHostNeverEntersTheAltScreenOrCapturesTheMouse() throws {
        let sink = CaptureSink()
        let host = try makeHost(sink: sink)
        try host.begin()
        host.draw(frame([.message(PagerMessage(role: .assistant, text: "hello"))]))
        let text = sink.text
        #expect(!text.contains("\u{1B}[?1049h"), "no alternate screen — the terminal owns history")
        for mode in ["1000", "1002", "1003", "1006"] {
            #expect(!text.contains("\u{1B}[?\(mode)h"), "no mouse capture (mode \(mode))")
        }
    }

    // The mid-stream permission hold (§6.8 / risk #3): while the prompt is
    // open its running tool stays in the live region — repainted, never
    // committed; resolving the prompt releases exactly one commit.
    @Test("a permission prompt holds its tool live until resolved")
    func aPermissionPromptHoldsItsToolLiveUntilResolved() throws {
        let sink = CaptureSink()
        let host = try makeHost(sink: sink)
        try host.begin()
        let pendingTool = PagerConversationItem.tool(PagerToolCard(
            name: "Edit", kind: .edit, input: "HELDFILE.rs", state: .running
        ))
        let prompt = PagerOverlay.permission(
            PagerPermissionRequest(toolName: "Edit", targetPath: "HELDFILE.rs")
        )
        host.draw(frame([pendingTool], turnRunning: true, overlays: [prompt]))
        #expect(
            sink.occurrences(of: "HELDFILE") >= 1,
            "the held tool is visible in the live region"
        )
        // The discriminator: a mutation to the held tool still reaches the
        // terminal — a COMMITTED (print-once) block could never change
        // again. This is exactly the frozen-waiting-form hazard the pending
        // hold exists to prevent (commit.rs:96-100).
        let mutatedTool = PagerConversationItem.tool(PagerToolCard(
            name: "Edit", kind: .edit, input: "HELDFILE.rs", detail: "RUNNINGMARK",
            state: .running
        ))
        host.draw(frame([mutatedTool], turnRunning: true, overlays: [prompt]))
        #expect(
            sink.occurrences(of: "RUNNINGMARK") >= 1,
            "still live under the prompt: the tail shows the tool's updates"
        )

        let beforeCommit = sink.occurrences(of: "HELDFILE")
        let resolvedTool = PagerConversationItem.tool(PagerToolCard(
            name: "Edit", kind: .edit, input: "HELDFILE.rs", state: .succeeded
        ))
        host.draw(frame([resolvedTool]))
        let afterCommit = sink.occurrences(of: "HELDFILE")
        #expect(afterCommit > beforeCommit, "resolving the prompt releases the commit")
        host.draw(frame([resolvedTool]))
        host.draw(frame([resolvedTool]))
        #expect(
            sink.occurrences(of: "HELDFILE") == afterCommit,
            "resolved: committed once, never re-emitted"
        )
    }

    // commit_active's app-modal hold (commit.rs:418-422): a centered
    // overlay owns the live region, so commits wait for it to close.
    @Test("a centered overlay holds commits until it closes")
    func aCenteredOverlayHoldsCommitsUntilItCloses() throws {
        let sink = CaptureSink()
        let host = try makeHost(sink: sink)
        try host.begin()
        let finalized: [PagerConversationItem] = [
            .message(PagerMessage(role: .assistant, text: "MODALHELD"))
        ]
        let modal = PagerOverlay.list(
            id: "test-list", title: "Picker",
            rows: [PagerListRow(id: "row", label: "row")]
        )
        host.draw(frame(finalized, overlays: [modal]))
        let heldCount = sink.occurrences(of: "MODALHELD")
        host.draw(frame(finalized, overlays: [modal]))
        #expect(
            sink.occurrences(of: "MODALHELD") >= heldCount,
            "the block may repaint in the tail but must not commit"
        )

        host.draw(frame(finalized))
        let committed = sink.occurrences(of: "MODALHELD")
        host.draw(frame(finalized))
        host.draw(frame(finalized))
        #expect(
            sink.occurrences(of: "MODALHELD") == committed,
            "deferred commits flush once after the modal closes, then freeze"
        )
    }

    // The invisible-modal regression: an overlay that CAPTURES INPUT must
    // paint inside the live viewport — a picker that owns the keyboard while
    // painting nowhere is the "succeeds, does nothing" class (§3). Upstream
    // renders its modals into the minimal region the same way
    // (`render_app_modal`, live.rs:163-166).
    @Test("an open picker overlay is visible in the live region")
    func anOpenPickerOverlayIsVisibleInTheLiveRegion() throws {
        let sink = CaptureSink()
        let host = try makeHost(sink: sink)
        try host.begin()
        let picker = PagerOverlay.list(
            id: "resume", title: "PICKERTITLE",
            rows: [PagerListRow(id: "s1", label: "PICKERROW")]
        )
        host.draw(frame(
            [.message(PagerMessage(role: .assistant, text: "before"))],
            overlays: [picker]
        ))
        #expect(sink.occurrences(of: "PICKERROW") >= 1, "the overlay's rows must land on screen")
    }

    // insert_committed's error contract, end to end: a failed write leaves
    // the entry uncommitted and a later frame retries it.
    @Test("a failed terminal write retries the commit next frame")
    func aFailedTerminalWriteRetriesTheCommitNextFrame() throws {
        let sink = CaptureSink()
        let host = try makeHost(sink: sink)
        try host.begin()
        let items: [PagerConversationItem] = [
            .message(PagerMessage(role: .assistant, text: "RETRIEDBLOCK"))
        ]
        sink.failWrites = true
        host.draw(frame(items))
        #expect(sink.occurrences(of: "RETRIEDBLOCK") == 0, "nothing landed while writes fail")

        sink.failWrites = false
        host.draw(frame(items))
        #expect(sink.occurrences(of: "RETRIEDBLOCK") == 1, "the commit retried and landed once")
        host.draw(frame(items))
        #expect(sink.occurrences(of: "RETRIEDBLOCK") == 1, "and only once")
    }

    // A rewind (`removeFrom`) must not wedge the frontier: new blocks after
    // the truncation still commit (the M1 cursor clamp, end to end).
    @Test("a rewind truncation still commits the blocks that follow")
    func aRewindTruncationStillCommitsTheBlocksThatFollow() throws {
        let sink = CaptureSink()
        let host = try makeHost(sink: sink)
        try host.begin()
        host.draw(frame([
            .message(PagerMessage(role: .user, text: "KEPTPROMPT")),
            .message(PagerMessage(role: .assistant, text: "DROPPEDANSWER")),
        ]))
        // Rewind drops the answer, then a new one arrives.
        host.draw(frame([.message(PagerMessage(role: .user, text: "KEPTPROMPT"))]))
        host.draw(frame([
            .message(PagerMessage(role: .user, text: "KEPTPROMPT")),
            .message(PagerMessage(role: .assistant, text: "SECONDANSWER")),
        ]))
        #expect(sink.occurrences(of: "SECONDANSWER") == 1, "the post-rewind block commits")
        #expect(sink.occurrences(of: "KEPTPROMPT") == 1, "the kept prefix never re-emits")
    }
}

// The K6 guard (`guard.rs:13-45` at the pin): the terminal owns committed
// history, so minimal's sources must never call the inline layer's
// history-re-emitting helpers — `resizePurgeRerender` re-prints (or, with
// ED3, wipes) scrollback the terminal already has, and `emitToScrollback`
// is the same double-print through the raw path. Anchored to `#filePath`
// (never `Bundle` — the swiftpm-testing-helper trap).
@Suite("Minimal K6 resize guard")
struct MinimalResizeGuardTests {
    @Test("minimal sources never call the history re-emitting helpers")
    func minimalSourcesNeverCallTheHistoryReEmittingHelpers() throws {
        let forbidden = ["resizePurgeRerender", "emitToScrollback"]
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let renderSources = testsDirectory
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/OpenGrokPagerRender")
        let minimalSources = [
            "PagerMinimalCommitRender.swift",
            "PagerMinimalLiveRender.swift",
            "PagerMinimalFrameHost.swift",
        ]
        for name in minimalSources {
            let source = try String(
                contentsOf: renderSources.appendingPathComponent(name), encoding: .utf8
            )
            for needle in forbidden {
                #expect(
                    !source.contains(needle),
                    "minimal/\(name) references forbidden resize helper \(needle) — it would double-print committed scrollback (design K6 / risk #2); use autoresize / setViewportHeight instead"
                )
            }
        }
    }
}
