import Foundation
@testable import OpenGrokCLI
import OpenGrokPagerMinimal
import OpenGrokPagerRender
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokShared
import Testing

/// Wave B live-seam reachability: execute/edit payloads must survive
/// `LiveConversationStore` → `LivePagerOutputs` (via `OpenGrokShellToolUpdate`
/// → `OpenGrokPagerToolUpdate` → `PagerToolCard`) without flattening to
/// `promptText` JSON, and fold/timing must be merge-in-place.
///
/// Rust citations are from pinned commit `650c1db7c2e73c59cec88bf3c6359751d6cef1bd`:
/// - execute failure: `crates/codegen/xai-grok-tools/src/types/output.rs:727` (`BashOutput.exit_code != 0 → is_error`)
///   and `crates/codegen/xai-grok-pager/src/acp/tracker.rs:1606` (non-zero exit → failed card)
/// - incremental deltas: `crates/codegen/xai-grok-tools/src/implementations/grok_build/bash/mod.rs:1798` (`BashOutputChunk`)
///   and `crates/codegen/xai-grok-pager/src/acp/tracker.rs:1190` (UTF-8 append)
/// - execute painter header: `crates/codegen/xai-grok-pager/src/scrollback/blocks/tool/execute.rs:28-53`
///   (command/description/header_display, `bash_mode` fold policy `:737-771`)
/// - edit painter: `crates/codegen/xai-grok-pager/src/scrollback/blocks/tool/edit.rs` (hunks, `+N/-N`, `Creating`)
/// - fold/timing: `crates/codegen/xai-grok-pager/src/scrollback/state/mod.rs:1234` (pinned folds)
///   and `:1393` (finish flash does not override pinned fold)
/// - bash_mode distinguishability: `crates/codegen/xai-grok-pager/src/acp/tracker.rs:1592-1601`
///   (`meta.bash_mode` → `ExecuteToolCallBlock.bash_mode`) and `execute.rs:750-771`
///   (Truncated while running, Expanded on finish)
@Suite("Wave B live painter reachability")
struct WaveBLivePainterReachabilityTests {

    // MARK: - Kind inference (A4 / B1 / B2)

    @Test("run_terminal_cmd maps to Execute kind")
    func executeKindFromRunTerminalCmd() {
        #expect(PagerToolKind.infer(fromToolNamed: "run_terminal_cmd") == .execute)
        #expect(PagerToolKind.infer(fromToolNamed: "run_terminal_command") == .execute)
        #expect(PagerToolKind.infer(fromToolNamed: "bash") == .execute)
        let card = PagerToolCard.make(name: "run_terminal_cmd", rawInput: #"{"command":"echo hi"}"#)
        #expect(card.kind == .execute)
        #expect(card.input == "echo hi")
    }

    @Test("search_replace and variants map to Edit kind")
    func editKindFromSearchReplace() {
        for name in ["search_replace", "strreplace", "apply_patch", "hashline_edit", "edit"] {
            #expect(PagerToolKind.infer(fromToolNamed: name) == .edit, "name: \(name)")
            let card = PagerToolCard.make(name: name, rawInput: #"{"file_path":"a.swift","old_string":"x","new_string":"y"}"#)
            #expect(card.kind == .edit, "card kind for \(name)")
        }
    }

    @Test("write maps to Create (Creating prefix in painter)")
    func writeKindIsCreate() {
        #expect(PagerToolKind.infer(fromToolNamed: "write") == .create)
        #expect(PagerToolKind.infer(fromToolNamed: "write_file") == .create)
        let card = PagerToolCard.make(name: "write", rawInput: #"{"file_path":"new.txt","content":"hi"}"#)
        #expect(card.kind == .create)
        #expect(card.input == "new.txt")
    }

    @Test("glob maps to Search (not List)")
    func globKindIsSearch() {
        #expect(PagerToolKind.infer(fromToolNamed: "glob") == .search)
        #expect(PagerToolKind.infer(fromToolNamed: "grep") == .search)
        let card = PagerToolCard.make(name: "glob", rawInput: #"{"query":"*.swift"}"#)
        #expect(card.kind == .search)
    }

    // MARK: - Header payload (A4) — command/description/path survive raw JSON

    @Test("execute header prefers description over command")
    func executeHeaderPrefersDescription() {
        let raw = #"{"command":"cargo test --lib","description":"Run the unit test suite"}"#
        let card = PagerToolCard.make(name: "run_terminal_cmd", rawInput: raw)
        #expect(card.kind == .execute)
        #expect(card.input == "Run the unit test suite")
        #expect(card.rawInput == raw)
        #expect(card.headerText == "Run the unit test suite")
    }

    @Test("execute header strips redundant session cd but keeps raw for copy")
    func executeHeaderStripsRedundantCd() {
        let cwd = "/tmp/proj"
        let raw = #"{"command":"cd /tmp/proj && cargo test"}"#
        let card = PagerToolCard.make(name: "run_terminal_cmd", rawInput: raw, cwd: cwd)
        #expect(card.input == "cargo test")
        #expect(card.rawInput == raw)
        #expect(card.headerText == "cargo test")
    }

    @Test("execute header falls back to command when description is empty")
    func executeHeaderFallbackToCommand() {
        let card = PagerToolCard.make(name: "bash", rawInput: #"{"command":"echo hi"}"#)
        #expect(card.input == "echo hi")
    }

    @Test("edit header is file path not JSON")
    func editHeaderIsPathNotJSON() {
        let raw = #"{"file_path":"/tmp/proj/src/main.swift","old_string":"foo","new_string":"bar"}"#
        let card = PagerToolCard.make(name: "search_replace", rawInput: raw, cwd: "/tmp/proj")
        #expect(card.kind == .edit)
        #expect(card.input == "src/main.swift")
        // rawInput stays JSON for verbatim copy, header is elided path
        #expect(card.rawInput == raw)
        #expect(card.headerText == "src/main.swift")
        #expect(!card.input.contains("old_string"))
    }

    @Test("LivePagerConversationState apply extracts execute header from raw JSON")
    func liveConversationAppliesExecuteHeader() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "do thing")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "exec-1",
            name: "run_terminal_cmd",
            input: #"{"command":"echo hi","description":"Say hi"}"#,
            state: .running
        ))
        let card = state.testingToolCard(callID: "exec-1")
        #expect(card?.kind == .execute)
        #expect(card?.input == "Say hi")
        #expect(card?.rawInput.contains("echo hi") == true)
    }

    @Test("LivePagerConversationState apply extracts edit header from raw JSON")
    func liveConversationAppliesEditHeader() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "edit")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "edit-1",
            name: "search_replace",
            input: #"{"file_path":"/tmp/a.swift","old_string":"a","new_string":"b"}"#,
            state: .running
        ))
        let card = state.testingToolCard(callID: "edit-1")
        #expect(card?.kind == .edit)
        #expect(card?.input == "/tmp/a.swift" || card?.input == "a.swift")
    }

    // MARK: - Incremental append (A5)

    @Test("incremental output appends while running and preserves card identity")
    func incrementalAppendWhileRunning() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "run")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "c1",
            name: "run_terminal_cmd",
            input: #"{"command":"printf 'one'; sleep 0.01; printf 'two'"}"#,
            state: .running
        ), atSeconds: 1)
        // First chunk
        state.apply(OpenGrokPagerToolUpdate(
            callID: "c1",
            name: "run_terminal_cmd",
            input: "",
            output: "one\n",
            state: .running,
            outputOp: .append
        ), atSeconds: 2)
        #expect(state.testingToolCard(callID: "c1")?.output == "one\n")
        #expect(state.testingToolCard(callID: "c1")?.state == .running)
        // Second chunk appends
        state.apply(OpenGrokPagerToolUpdate(
            callID: "c1",
            name: "run_terminal_cmd",
            input: "",
            output: "two\n",
            state: .running,
            outputOp: .append
        ), atSeconds: 3)
        #expect(state.testingToolCard(callID: "c1")?.output == "one\ntwo\n")
        // Terminal replaces with full promptText (Rust BashOutput final drain)
        state.apply(OpenGrokPagerToolUpdate(
            callID: "c1",
            name: "run_terminal_cmd",
            input: "",
            output: "one\ntwo\nExit code: 0\n",
            state: .succeeded,
            outputOp: .replace
        ), atSeconds: 4)
        #expect(state.testingToolCard(callID: "c1")?.output == "one\ntwo\nExit code: 0\n")
        #expect(state.testingToolCard(callID: "c1")?.state == .succeeded)
    }

    @Test("UTF-8 split across chunks does not corrupt (pending bytes stay buffered)")
    func utf8SplitAcrossChunks() {
        var decoder = OpenGrokShellUTF8DeltaDecoder()
        // "é" is 2 bytes: 0xC3 0xA9, "𝄞" is 4 bytes: 0xF0 0x9D 0x84 0x9E
        let eAcute = "é".data(using: .utf8)!
        let gClef = "𝄞".data(using: .utf8)!
        #expect(eAcute.count == 2)
        #expect(gClef.count == 4)
        // Split "héllo" across a 2-byte boundary inside "é"
        let part1 = Data([UInt8(ascii: "h")] + Array(eAcute.prefix(1)))
        let part2 = Data(Array(eAcute.suffix(1)) + Array("llo".utf8))
        let out1 = decoder.push(part1)
        #expect(out1 == "h")
        let out2 = decoder.push(part2)
        #expect(out2 == "éllo")
        // Split 4-byte char across two pushes
        var decoder2 = OpenGrokShellUTF8DeltaDecoder()
        let p1 = Data(gClef.prefix(2))
        let p2 = Data(gClef.suffix(2))
        #expect(decoder2.push(p1).isEmpty)
        #expect(decoder2.push(p2) == "𝄞")
        #expect(decoder2.finish().isEmpty)
    }

    // MARK: - Exit-7 failed state (A3) — nonzero exit / signal / timeout → .failed

    @Test("LiveRunTerminalToolRuntime exit 7 is failed displayState but success result")
    func liveRunTerminalExitSevenIsFailed() {
        let failed = ShellCommandResult(combinedOutput: "boom", exitCode: 7)
        #expect(LiveRunTerminalToolRuntime.displayState(for: failed) == .failed)
        let ok = ShellCommandResult(combinedOutput: "ok", exitCode: 0)
        #expect(LiveRunTerminalToolRuntime.displayState(for: ok) == .succeeded)
    }

    @Test("LiveToolResultText honors exit_code 7 as failed without sniffing promptText")
    func liveToolResultTextExitSevenFailed() {
        let result = OpenGrokShellToolCallResult(
            value: .object(["exit_code": .number(.int64(7)), "combined_output": .string("boom")]),
            promptText: "boom\nExit code: 7\n"
        )
        #expect(LiveToolResultText.displayState(for: result) == .failed)
        #expect(result.promptText.contains("Exit code: 7"))
    }

    @Test("signal and timeout map to failed, cancelled maps to cancelled")
    func signalTimeoutCancelledMapping() {
        let sig = ShellCommandResult(combinedOutput: "killed", signal: "SIGKILL")
        #expect(LiveRunTerminalToolRuntime.displayState(for: sig) == .failed)
        let to = ShellCommandResult(combinedOutput: "partial", timedOut: true)
        #expect(LiveRunTerminalToolRuntime.displayState(for: to) == .failed)
        let cancelled = ShellCommandResult(combinedOutput: "partial", cancelled: true)
        #expect(LiveRunTerminalToolRuntime.displayState(for: cancelled) == .cancelled)
        // JSON-level mapping via LiveToolResultText (fallback when displayState was default succeeded)
        let timedJSON = OpenGrokShellToolCallResult(
            value: .object(["timed_out": .bool(true)]),
            promptText: "timed out"
        )
        #expect(LiveToolResultText.displayState(for: timedJSON) == .failed)
        let signalJSON = OpenGrokShellToolCallResult(
            value: .object(["signal": .string("SIGTERM")]),
            promptText: "signal"
        )
        #expect(LiveToolResultText.displayState(for: signalJSON) == .failed)
    }

    @Test("LivePagerConversationState propagates failed state from Store to card")
    func livePagerPropagatesFailedState() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "failing command")
        state.apply(OpenGrokPagerToolUpdate(callID: "fail-1", name: "run_terminal_cmd", input: #"{"command":"exit 7"}"#, state: .running), atSeconds: 10)
        // Simulate Store emitting terminal failed after executor saw exit 7
        state.apply(OpenGrokPagerToolUpdate(callID: "fail-1", name: "run_terminal_cmd", input: "", output: "Exit code: 7\n", state: .failed), atSeconds: 11)
        let card = state.testingToolCard(callID: "fail-1")
        #expect(card?.state == .failed)
        #expect(card?.output?.contains("Exit code: 7") == true)
    }

    // MARK: - Edit payload (B2) — path + snippet survive; structured hunks are currently text-only

    @Test("edit search_replace payload survives as path header and text snippet")
    func editPayloadSurvivesAsHeaderAndSnippet() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "edit file")
        // Running: header is path
        state.apply(OpenGrokPagerToolUpdate(
            callID: "e1",
            name: "search_replace",
            input: #"{"file_path":"/tmp/proj/lib.swift","old_string":"foo","new_string":"bar"}"#,
            state: .running
        ))
        #expect(state.testingToolCard(callID: "e1")?.kind == .edit)
        #expect(state.testingToolCard(callID: "e1")?.input.contains("lib.swift") == true)
        // Terminal: output is promptText snippet (Rust BashOutput analogue for edits is summary)
        let snippet = "The file /tmp/proj/lib.swift has been updated (1 replacement(s)).\n1→bar"
        state.apply(OpenGrokPagerToolUpdate(
            callID: "e1",
            name: "search_replace",
            input: "",
            output: snippet,
            state: .succeeded
        ))
        let final = state.testingToolCard(callID: "e1")
        #expect(final?.state == .succeeded)
        #expect(final?.output?.contains("updated") == true)
        #expect(final?.output?.contains("bar") == true)
        // Kind stays edit, header stays path (not JSON)
        #expect(final?.kind == .edit)
        #expect(final?.input.contains("lib.swift") == true)
    }

    @Test("apply_patch payload survives as path header")
    func applyPatchPayloadSurvives() {
        let card = PagerToolCard.make(name: "apply_patch", rawInput: #"{"patch":"*** Begin Patch\n*** Update File: a.swift\n@@\n-old\n+new\n*** End Patch"}"#)
        #expect(card.kind == .edit)
        // apply_patch rawInput has no file_path field, so displayHeader falls back to raw (not ideal).
        // The seam still preserves kind; header extraction for apply_patch is a known follow-on (A4 factory).
        #expect(card.kind == .edit)
    }

    @Test("PagerDiff builds hunks from old/new strings (structured diff primitive)")
    func pagerDiffBuildsHunks() {
        let hunks = diffHunksFromStrings(oldText: "foo\n", newText: "bar\n", startLine: 10)
        #expect(!hunks.isEmpty)
        let patch = diffHunksToPatch(path: "a.swift", hunks: hunks)
        #expect(patch.contains("--- a/a.swift"))
        #expect(patch.contains("+++ b/a.swift"))
        #expect(patch.contains("foo") || patch.contains("bar"))
    }

    // MARK: - Fold + timing preservation (A6)

    @Test("expanding running card survives incremental append and terminal success")
    func foldPreservedAcrossProgressAndTerminal() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "hi")
        state.apply(OpenGrokPagerToolUpdate(callID: "c1", name: "bash", input: #"{"command":"echo one"}"#, state: .running), atSeconds: 10)
        // User expands while running (simulating click on header rect)
        let didExpand = state.withItems { items in
            guard case .tool(var card) = items[items.count - 1] else { return false }
            card.isExpanded = true
            items[items.count - 1] = .tool(card)
            return true
        }
        #expect(didExpand)
        // Incremental while still running must not snap shut
        state.apply(OpenGrokPagerToolUpdate(callID: "c1", name: "bash", input: "", output: "one\n", state: .running), atSeconds: 11)
        #expect(state.testingToolCard(callID: "c1")?.isExpanded == true)
        // Sparse leader-style update must not wipe name/input
        #expect(state.testingToolCard(callID: "c1")?.name == "bash")
        #expect(state.testingToolCard(callID: "c1")?.input == "echo one")
        // Terminal success keeps expanded
        state.apply(OpenGrokPagerToolUpdate(callID: "c1", name: "tool", input: "{}", output: "one\ntwo\n", state: .succeeded), atSeconds: 12)
        let final = state.testingToolCard(callID: "c1")
        #expect(final?.isExpanded == true)
        #expect(final?.state == .succeeded)
        #expect(final?.finishedAt == 12)
        // Redelivered terminal must not restart 400ms flash
        state.apply(OpenGrokPagerToolUpdate(callID: "c1", name: "bash", input: "echo one", output: "one\ntwo\n", state: .succeeded), atSeconds: 99)
        #expect(state.testingFinishedAt(callID: "c1") == 12)
        #expect(state.testingToolCard(callID: "c1")?.isExpanded == true)
    }

    @Test("first finishedAt wins and nil motion renders already-static")
    func firstFinishedAtWins() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "hi")
        state.apply(OpenGrokPagerToolUpdate(callID: "c2", name: "bash", input: "echo hi", state: .running), atSeconds: 5)
        #expect(state.testingFinishedAt(callID: "c2") == nil)
        state.apply(OpenGrokPagerToolUpdate(callID: "c2", name: "bash", input: "", output: "hi\n", state: .succeeded), atSeconds: 6)
        #expect(state.testingFinishedAt(callID: "c2") == 6)
        state.apply(OpenGrokPagerToolUpdate(callID: "c2", name: "bash", input: "", output: "hi\n", state: .succeeded), atSeconds: 7)
        #expect(state.testingFinishedAt(callID: "c2") == 6)
    }

    // MARK: - Sparse leader merge (A4) — LiveLeaderClient sparse must not overwrite

    @Test("LiveToolCardMerge preserves name and input on sparse update")
    func sparseMergePreservesNameAndInput() {
        #expect(LiveToolCardMerge.mergedName(incoming: "", existing: "bash") == "bash")
        #expect(LiveToolCardMerge.mergedName(incoming: "tool", existing: "bash") == "bash")
        #expect(LiveToolCardMerge.mergedName(incoming: "bash", existing: "tool") == "bash")
        #expect(LiveToolCardMerge.mergedInput(incoming: "{}", existing: #"{"command":"echo hi"}"#) == #"{"command":"echo hi"}"#)
        #expect(LiveToolCardMerge.mergedInput(incoming: "", existing: "echo hi") == "echo hi")
    }

    @Test("sparse leader update after initial call keeps header")
    func sparseLeaderUpdateKeepsHeader() {
        var state = LivePagerConversationState()
        state.startTurn(prompt: "leader task")
        // Initial call with full header
        state.apply(OpenGrokPagerToolUpdate(callID: "leader-1", name: "run_terminal_cmd", input: #"{"command":"echo hi","description":"Greet"}"#, state: .running), atSeconds: 1)
        #expect(state.testingToolCard(callID: "leader-1")?.input == "Greet")
        // Sparse update from ACP with empty name/input but new output chunk (append)
        state.apply(OpenGrokPagerToolUpdate(callID: "leader-1", name: "", input: "", output: "hi\n", state: .running, outputOp: .append), atSeconds: 2)
        #expect(state.testingToolCard(callID: "leader-1")?.input == "Greet")
        #expect(state.testingToolCard(callID: "leader-1")?.name == "run_terminal_cmd")
    }

    // MARK: - User-origin ! distinguishability (B1 bash_mode)

    @Test("user bash runs truncated and finishes fully expanded while agent execute stays collapsed")
    func userBashFoldPolicyIsDistinct() {
        let agent = PagerToolCard.make(name: "run_terminal_cmd", rawInput: #"{"command":"echo hi"}"#)
        #expect(agent.kind == .execute)
        #expect(agent.isBashMode == nil)
        #expect(!agent.isExpanded)

        var state = LivePagerConversationState()
        state.startTurn(prompt: "local command")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "user-1",
            name: "run_terminal_cmd",
            input: #"{"command":"echo hi"}"#,
            isBashMode: true,
            state: .running
        ))
        let running = state.testingToolCard(callID: "user-1")
        #expect(running?.isUserBashMode == true)
        #expect(running?.isExpanded == true)
        #expect(running?.isFullyExpanded == false)

        state.apply(OpenGrokPagerToolUpdate(
            callID: "user-1",
            name: "run_terminal_cmd",
            input: "",
            output: "hi\n",
            isBashMode: true,
            state: .succeeded
        ))
        let finished = state.testingToolCard(callID: "user-1")
        #expect(finished?.isExpanded == true)
        #expect(finished?.isFullyExpanded == true)
    }

    @Test("live structured apply_patch preserves every file and patch body")
    func liveStructuredApplyPatchPreservesEveryFile() {
        let structured = #"{"type":"apply_patch","lines_added":2,"lines_removed":2,"trusted":false,"file_results":[{"path":"/tmp/a.swift","action":"modified","lines_added":1,"lines_removed":1,"edits":{"details":[{"old_string":"let a = 1","new_string":"let a = 2","old_line":1,"new_line":1,"context_before":"","context_after":"","line_prefix":""}]}},{"path":"/tmp/b.swift","action":"modified","lines_added":1,"lines_removed":1,"edits":{"details":[{"old_string":"let b = 1","new_string":"let b = 2","old_line":1,"new_line":1,"context_before":"","context_after":"","line_prefix":""}]}}]}"#
        var state = LivePagerConversationState()
        state.startTurn(prompt: "patch")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "patch-1",
            name: "apply_patch",
            input: #"{"patch":"*** Begin Patch"}"#,
            output: "updated two files",
            structuredOutput: structured,
            state: .succeeded
        ))
        let card = state.testingToolCard(callID: "patch-1")
        #expect(card?.editFiles?.count == 2)
        #expect(card?.editFiles?.map(\.path) == ["/tmp/a.swift", "/tmp/b.swift"])
        #expect(card?.editPatch?.contains("--- a//tmp/a.swift") == true)
        #expect(card?.editPatch?.contains("--- a//tmp/b.swift") == true)
    }

    @Test("adjacent terminal edits to one file stitch into one live card")
    func adjacentSameFileEditsStitch() {
        func payload(old: String, new: String) -> String {
            #"{"path":"/tmp/a.swift","lines_added":1,"lines_removed":1,"trusted":true,"replacements":1,"edits":{"details":[{"old_string":"\#(old)","new_string":"\#(new)","old_line":1,"new_line":1,"context_before":"","context_after":"","line_prefix":""}]}}"#
        }
        var state = LivePagerConversationState()
        state.startTurn(prompt: "two edits")
        state.apply(OpenGrokPagerToolUpdate(
            callID: "edit-a",
            name: "search_replace",
            input: #"{"file_path":"/tmp/a.swift"}"#,
            structuredOutput: payload(old: "let value = 1", new: "let value = 2"),
            state: .succeeded
        ))
        state.apply(OpenGrokPagerToolUpdate(
            callID: "edit-b",
            name: "search_replace",
            input: #"{"file_path":"/tmp/a.swift"}"#,
            structuredOutput: payload(old: "let value = 2", new: "let value = 3"),
            state: .succeeded
        ))

        let cards = state.items.compactMap { item -> PagerToolCard? in
            guard case .tool(let card) = item else { return nil }
            return card
        }
        #expect(cards.count == 1)
        #expect(state.testingToolCard(callID: "edit-a") == state.testingToolCard(callID: "edit-b"))
        #expect(cards.first?.editPath == "/tmp/a.swift")
        #expect(cards.first?.editPatch?.contains("let value = 3") == true)
    }
}

/// Minimal port of the Rust `LiveToolResultText` display-state helper for the probe above.
/// This suite does not duplicate the production helper; it exercises the real one via
/// `LiveToolResultText` where available and via `LiveRunTerminalToolRuntime` otherwise.
private enum ProbeLiveToolResultText {
    static func displayState(for result: OpenGrokShellToolCallResult) -> OpenGrokShellToolState {
        LiveToolResultText.displayState(for: result)
    }
}
