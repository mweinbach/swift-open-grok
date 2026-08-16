import OpenGrokTerminalCore
import Testing
@testable import OpenGrokPagerRender

private func waveECommittedText(
    _ block: PagerTranscriptBlock,
    width: Int = 80
) -> String {
    let committed = MinimalCommitRender.committedLines(
        item: .block(block),
        displayMode: .expanded,
        width: width,
        theme: .grokNight
    )
    return (0..<committed.height)
        .map { committed.rowText($0) }
        .joined(separator: "\n")
}

private func waveEBufferText(_ buffer: CellBuffer) -> String {
    (0..<buffer.area.height).map { y in
        (0..<buffer.area.width).compactMap { x in
            guard let cell = buffer.cell(x: x, y: y), !cell.skip else { return nil }
            return cell.grapheme
        }.joined()
    }.joined(separator: "\n")
}

private func waveECell(
    containing needle: String,
    in frame: PagerRenderResult
) -> Cell? {
    for y in 0..<frame.buffer.area.height {
        let row = (0..<frame.buffer.area.width).compactMap { x in
            guard let cell = frame.buffer.cell(x: x, y: y), !cell.skip else { return nil }
            return cell.grapheme
        }.joined()
        guard let range = row.range(of: needle) else { continue }
        let column = row.distance(from: row.startIndex, to: range.lowerBound)
        return frame.buffer.cell(x: column, y: y)
    }
    return nil
}

@Suite("Wave E typed block rendering")
struct WaveEBlockRenderTests {
    @Test("every session-event variant renders a non-empty typed row")
    func sessionEventVariants() {
        let events: [PagerSessionEventKind] = [
            .turnCompleted(elapsed: 1.25),
            .turnCancelled(elapsed: 2.5),
            .turnHalted(elapsed: nil),
            .turnFailed(error: "provider failed", elapsed: 3),
            .compactionStarted(percentage: 91),
            .compactionCompleted(tokensBefore: 10_000, tokensAfter: 4_000, elapsedMilliseconds: 250),
            .compactionFailed(error: "compact failed"),
            .compactionCancelled,
            .retryFailed(error: "retry failed", errorType: "transport"),
            .reauthRequired,
            .contextTooLarge,
            .compactCompleted(elapsed: 0.75),
            .hookAnnotation(message: "hook note"),
            .modelUnavailable(
                previousModelID: "old-model",
                newModelID: "new-model",
                reason: "capacity"
            ),
            .memorySaved(path: "/tmp/memory.md", trigger: "manual"),
            .goalCompleted(elapsed: 4),
            .recap(summary: "summary", auto: false),
        ]

        for (index, event) in events.enumerated() {
            let text = waveECommittedText(.sessionEvent(PagerSessionEventBlock(
                id: "event-\(index)",
                event: event,
                isExpanded: true
            )))
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("all non-tool transcript blocks keep their typed semantics")
    func typedBlocks() {
        let hooks = [
            PagerHookRun(name: "pre-ok", phase: .pre, state: .succeeded, output: "allowed"),
            PagerHookRun(name: "post-bad", phase: .post, state: .failed, output: "exit 2"),
        ]
        let blocks: [PagerTranscriptBlock] = [
            .sessionEvent(PagerSessionEventBlock(
                id: "recap",
                event: .recap(summary: "A durable recap", auto: true),
                isExpanded: true
            )),
            .lifecycle(PagerLifecycleBlock(
                id: "lifecycle",
                kind: .userPromptSubmit,
                state: .failed,
                hooks: hooks,
                isExpanded: true
            )),
            .backgroundTask(PagerBackgroundTaskBlock(
                id: "bg-1",
                kind: .process,
                title: "compile",
                state: .failed,
                outputTail: "compiler tail",
                exitCode: 7,
                duration: 1.5
            )),
            .subagent(PagerSubagentBlock(
                id: "sub-1",
                label: "explore · map tree",
                state: .succeeded,
                turnCount: 3,
                toolCount: 5,
                duration: 12,
                outcome: "mapped",
                isExpanded: true
            )),
            .swarm(PagerSwarmBlock(
                id: "swarm-1",
                objective: "review changes",
                state: .failed,
                members: [
                    PagerSwarmMember(
                        id: "member-1",
                        label: "reviewer",
                        state: .failed,
                        turnCount: 2,
                        toolCount: 4,
                        duration: 8,
                        outcome: "found issue"
                    ),
                    PagerSwarmMember(
                        id: "member-2",
                        label: "queued reviewer",
                        state: .queued,
                        activity: "Waiting to finish"
                    ),
                ],
                outcome: "failed 1",
                isExpanded: true
            )),
            .workflow(PagerWorkflowBlock(
                id: "workflow-1",
                name: "review",
                objective: "validate Wave E",
                state: .succeeded,
                phases: [
                    PagerWorkflowPhase(label: "audit", state: .succeeded),
                    PagerWorkflowPhase(label: "verify", state: .running),
                ],
                agentCount: 2,
                outcome: "complete"
            )),
            .btw(PagerBtwBlock(
                id: "btw-1",
                question: "Check one side issue",
                answer: "No issue found"
            )),
            .context(PagerContextBlock(
                id: "context",
                totalTokens: 100,
                rows: [
                    PagerContextUsage(category: .system, tokens: 10),
                    PagerContextUsage(category: .messages, tokens: 35),
                    PagerContextUsage(category: .reasoning, tokens: 15),
                    PagerContextUsage(category: .toolDefinitions, tokens: 20),
                    PagerContextUsage(category: .free, tokens: 20),
                ]
            )),
            .usage(PagerUsageBlock(id: "usage", sections: [
                PagerUsageSection(provider: .xai, used: 80, limit: 100, unit: "credits"),
                PagerUsageSection(
                    provider: .codex,
                    used: 20,
                    unit: "tokens",
                    isAuthoritative: false
                ),
                PagerUsageSection(provider: .antigravity, used: 4, limit: 10, unit: "requests"),
            ])),
            .creditLimit(PagerCreditLimitBlock(
                id: "credit",
                action: .purchaseCredits,
                message: "Credits exhausted",
                accountURL: "https://grok.com?_s=usage"
            )),
        ]
        let text = blocks.map { waveECommittedText($0) }.joined(separator: "\n")

        #expect(text.contains("Recap · automatic"))
        #expect(text.contains("A durable recap"))
        #expect(text.contains("[hooks: 1/2]"))
        #expect(text.contains("pre-ok"))
        #expect(text.contains("post-bad"))
        #expect(text.contains("Background process bg-1 · compile · exit 7"))
        #expect(text.contains("Subagent explore · map tree · 3 turns · 5 tools"))
        #expect(text.contains("mapped"))
        #expect(text.contains("Swarm · review changes · 2 members"))
        #expect(text.contains("reviewer · 2 turns · 4 tools"))
        #expect(text.contains("queued reviewer · Waiting to finish"))
        #expect(text.contains("Workflow review · validate Wave E · 2 agents"))
        #expect(text.contains("audit"))
        #expect(text.contains("verify"))
        #expect(text.contains("BTW · Check one side issue"))
        #expect(text.contains("No issue found"))
        #expect(text.contains("Context · 100 tokens"))
        #expect(text.contains("system"))
        #expect(text.contains("tools"))
        #expect(text.contains("xAI: 80 / 100 credits"))
        #expect(text.contains("Codex: 20 tokens · estimated"))
        #expect(text.contains("Antigravity: 4 / 10 requests"))
        #expect(text.contains("Purchase Credits"))
        #expect(text.contains("https://grok.com?_s=usage"))
    }

    @Test("context bars switch between twenty and ten cells")
    func contextBarWidths() throws {
        let block = PagerTranscriptBlock.context(PagerContextBlock(
            id: "context",
            totalTokens: 100,
            rows: [PagerContextUsage(category: .system, tokens: 50)]
        ))
        let wideLine = try #require(waveECommittedText(block, width: 80)
            .split(separator: "\n")
            .first { $0.contains("system") })
        let narrowLine = try #require(waveECommittedText(block, width: 40)
            .split(separator: "\n")
            .first { $0.contains("system") })
        let wideCells = wideLine.filter { $0 == "█" || $0 == "░" }.count
        let narrowCells = narrowLine.filter { $0 == "█" || $0 == "░" }.count
        #expect(wideCells == 20)
        #expect(narrowCells == 10)
    }

    @Test("minimal todo panes hide completed rows, cap at eight, and can force show")
    func minimalTodoPane() {
        let items = (0..<10).map { index in
            PagerTodoItem(
                id: "todo-\(index)",
                content: "todo \(index)",
                status: index == 2 ? .completed : (index == 0 ? .inProgress : .pending)
            )
        }
        let pane = PagerTodoPane(
            items: items,
            showCompleted: false,
            isMinimal: true
        )
        #expect(pane.visibleItems.count == 8)
        #expect(!pane.visibleItems.contains { $0.status == .completed })
        #expect(pane.desiredHeight(viewHeight: 30) == 8)

        var buffer = CellBuffer.empty(TerminalRect(x: 0, y: 0, width: 30, height: 8))
        renderPagerTodoPane(pane, in: buffer.area, buffer: &buffer, theme: .grokNight)
        let text = waveEBufferText(buffer)
        #expect(text.contains("◆ todo 0"))
        #expect(!text.contains("todo 2"))
        #expect(PagerTodoPane(
            items: [],
            forceVisible: true,
            isMinimal: true
        ).desiredHeight(viewHeight: 30) == 1)
    }

    @Test("turn stop and credit warnings reflect actionable state")
    func statusChrome() throws {
        func frame(used: Double, canCancel: Bool) -> PagerRenderResult {
            renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 80, height: 14),
                statusBar: PagerStatusBar(credit: PagerCreditStatus(
                    provider: .xai,
                    used: used,
                    limit: 100
                )),
                turnStatus: PagerTurnStatus(label: "Thinking…", canCancel: canCancel),
                input: PagerComposerState(text: "", isFocused: false),
                showScrollbar: false
            ))
        }

        let normal = frame(used: 79, canCancel: false)
        let warning = frame(used: 80, canCancel: true)
        let exhausted = frame(used: 100, canCancel: true)
        #expect(!waveEBufferText(normal.buffer).contains("[stop]"))
        #expect(waveEBufferText(warning.buffer).contains("[stop]"))
        #expect(waveEBufferText(normal.buffer).contains("xAI 79%"))
        #expect(waveEBufferText(warning.buffer).contains("xAI 80%"))
        #expect(waveEBufferText(exhausted.buffer).contains("xAI 100%"))

        let normalCell = try #require(waveECell(containing: "xAI 79%", in: normal))
        let warningCell = try #require(waveECell(containing: "xAI 80%", in: warning))
        let exhaustedCell = try #require(waveECell(containing: "xAI 100%", in: exhausted))
        #expect(normalCell.foreground == PagerRenderTheme.grokNight.accentModel)
        #expect(!normalCell.style.contains(.bold))
        #expect(warningCell.foreground == PagerRenderTheme.grokNight.warning)
        #expect(warningCell.style.contains(.bold))
        #expect(exhaustedCell.foreground == PagerRenderTheme.grokNight.accentError)
        #expect(exhaustedCell.style.contains(.bold))
    }

    @Test("credit action links activate only safe schemes")
    func creditLinkSafety() {
        func frame(url: String) -> PagerRenderResult {
            renderPagerFrame(PagerRenderState(
                size: TerminalSize(width: 80, height: 14),
                conversation: [.block(.creditLimit(PagerCreditLimitBlock(
                    id: "credit",
                    action: .enablePayAsYouGo,
                    message: "Enable billing",
                    accountURL: url
                )))],
                input: PagerComposerState(text: "", isFocused: false),
                showScrollbar: false
            ))
        }
        #expect(frame(url: "https://grok.com?_s=usage").links.map(\.url)
            .contains("https://grok.com?_s=usage"))
        #expect(frame(url: "javascript:alert(1)").links.isEmpty)
    }

    @Test("scroll debug HUD paints normalized state")
    func scrollDebugHUD() {
        var buffer = CellBuffer.empty(TerminalRect(x: 0, y: 0, width: 50, height: 4))
        renderPagerScrollDebugHud(
            PagerScrollDebugOverlay(
                rawDelta: -12,
                normalizedDelta: -3,
                scrollOffset: 4,
                maximumOffset: 20,
                followingTail: false
            ),
            area: buffer.area,
            buffer: &buffer,
            theme: .grokNight
        )
        let text = waveEBufferText(buffer)
        #expect(text.contains("scroll raw=-12 norm=-3"))
        #expect(text.contains("offset=4/20 manual"))
    }

    @Test("quote decoration is excluded from copied text")
    func quoteCopy() {
        #expect(pagerStripQuoteDecoration("│ quoted") == "quoted")
        #expect(pagerStripQuoteDecoration("│ │ nested") == "nested")
        #expect(pagerStripQuoteDecoration("plain") == "plain")
    }
}
