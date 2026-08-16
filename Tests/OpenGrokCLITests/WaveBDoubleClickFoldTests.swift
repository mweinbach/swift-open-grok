// WaveBDoubleClickFoldTests.swift
//
// B-INTERACTION Wave B3: single select, double toggle fold, triple toggle+scroll, non-foldable no-op.
// Rust: selection.rs:868 handle_scrollback_click at pin 650c1db7.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

@Suite("Wave B double-click fold (B-INTERACTION B3)", .serialized)
struct WaveBDoubleClickFoldTests {
    @Test("pure: isFoldable policy")
    func purePolicy() {
        let reasoning = PagerConversationItem.message(PagerMessage(role: .reasoning, text: "think"))
        let system = PagerConversationItem.message(PagerMessage(role: .system, text: "sys"))
        let assistant = PagerConversationItem.message(PagerMessage(role: .assistant, text: "ans"))
        let user = PagerConversationItem.message(PagerMessage(role: .user, text: "q"))
        let tool = PagerConversationItem.tool(PagerToolCard(
            name: "bash",
            input: "cmd",
            output: "done",
            state: .succeeded
        ))
        let emptyTool = PagerConversationItem.tool(PagerToolCard(name: "bash", input: "cmd"))
        let sep = PagerConversationItem.separator("x")
        #expect(reasoning.isFoldable && system.isFoldable)
        #expect(!assistant.isFoldable && !user.isFoldable && !sep.isFoldable)
        #expect(tool.isFoldable)
        #expect(!emptyTool.isFoldable)
    }

    @Test("pure: single not fold, double toggles, non-foldable no-op")
    func pureToggle() {
        var items: [PagerConversationItem] = (0..<4).map {
            .tool(PagerToolCard(name: "read", input: "file\($0).swift", output: "line", isExpanded: false))
        }
        var sel = LiveScrollbackSelection()
        let idx = 2
        sel.select(at: idx, itemCount: items.count)
        #expect(items[idx].isFolded)
        let doubleOutcome = sel.apply(.toggleFold, items: &items)
        #expect(doubleOutcome.notice == nil)
        #expect(!items[idx].isFolded, "double must toggle")
        let tripleOutcome = sel.apply(.toggleFold, items: &items)
        #expect(tripleOutcome.notice == nil)
        #expect(items[idx].isFolded, "triple toggles again")
        var mixed: [PagerConversationItem] = [
            .message(PagerMessage(role: .assistant, text: "ans", isCollapsed: false)),
            .separator("---"),
        ]
        for j in mixed.indices {
            sel.select(at: j, itemCount: mixed.count)
            let before = mixed[j].isFolded
            let outcome = sel.apply(.toggleFold, items: &mixed)
            #expect(outcome.notice == nil)
            #expect(mixed[j].isFolded == before, "non-foldable \(j) must not toggle")
        }
    }

    @Test("live: 1 selects only, 2 toggles fold, 3 toggles+scrolls, non-foldable never scrolls")
    func liveClicks() async throws {
        let f = try FoldFixture(width: 100, height: 18)
        defer { Task { try? await f.dispose() } }
        try await f.renderer.begin()
        try await f.renderer.testingDismissWelcomeOverlay()
        for i in 0..<24 {
            try await f.renderer.testingAppendConversationItem(.tool(PagerToolCard(name: "read", input: "f\(i).swift", output: "out", isExpanded: false)))
        }
        try await f.renderer.testingForcePaint()
        let model = try #require(await f.renderer.lastConversationHit)
        let target = try #require(f.firstVisibleContentPoint(in: model)?.index)

        await f.renderer.testingSetTextSelectionNowMs(1_000)
        #expect(try await f.click(blockIndex: target) == .focusScrollback)
        #expect(await f.renderer.testingScrollbackSelectedIndex() == target, "1× selects")
        #expect(await f.renderer.testingFollowsBottom() == false, "1× breaks follow")
        #expect(await f.renderer.readFolded(at: target) == true, "1× no fold")

        await f.renderer.testingSetTextSelectionNowMs(1_110)
        #expect(try await f.click(blockIndex: target) == .focusScrollback)
        #expect(await f.renderer.readFolded(at: target) == false, "2× toggles")

        await f.renderer.testingSetTextSelectionNowMs(1_220)
        #expect(try await f.click(blockIndex: target) == .focusScrollback)
        #expect(await f.renderer.readFolded(at: target) == true, "3× toggles again")
        #expect(await f.renderer.testingFollowsBottom() == false, "3× off tail")

        // Non-foldable: no scroll.
        let g = try FoldFixture(width: 100, height: 18)
        defer { Task { try? await g.dispose() } }
        try await g.renderer.begin()
        try await g.renderer.testingDismissWelcomeOverlay()
        for i in 0..<20 {
            try await g.renderer.testingAppendConversationItem(.tool(PagerToolCard(
                name: "read",
                input: "a\(i).swift",
                output: "line",
                isExpanded: false
            )))
        }
        try await g.renderer.testingAppendConversationItem(.message(PagerMessage(role: .assistant, text: "answer")))
        try await g.renderer.testingForcePaint()
        let nonFoldableIndex = 20
        await g.renderer.testingSetTextSelectionNowMs(5_000)
        #expect(try await g.click(blockIndex: nonFoldableIndex) == .focusScrollback)
        let off0 = await g.renderer.testingTranscriptScrollOffset()
        await g.renderer.testingSetTextSelectionNowMs(5_110)
        #expect(try await g.click(blockIndex: nonFoldableIndex) == .focusScrollback)
        await g.renderer.testingSetTextSelectionNowMs(5_220)
        #expect(try await g.click(blockIndex: nonFoldableIndex) == .focusScrollback)
        #expect(await g.renderer.testingTranscriptScrollOffset() == off0, "non-foldable must not scroll")
    }

    @Test("live: outside 300ms window resets to single")
    func windowResets() async throws {
        let f = try FoldFixture(width: 100, height: 30)
        defer { Task { try? await f.dispose() } }
        try await f.renderer.begin()
        try await f.renderer.testingDismissWelcomeOverlay()
        for i in 0..<6 {
            try await f.renderer.testingAppendConversationItem(.tool(PagerToolCard(
                name: "read",
                input: "a\(i).swift",
                output: "line",
                isExpanded: false
            )))
        }
        try await f.renderer.testingForcePaint()
        let model = try #require(await f.renderer.lastConversationHit)
        let t = try #require(f.firstVisibleContentPoint(in: model)?.index)
        await f.renderer.testingSetTextSelectionNowMs(10_000)
        #expect(try await f.click(blockIndex: t) == .focusScrollback)
        await f.renderer.testingSetTextSelectionNowMs(10_110)
        #expect(try await f.click(blockIndex: t) == .focusScrollback)
        await f.renderer.testingSetTextSelectionNowMs(10_800)
        #expect(try await f.click(blockIndex: t) == .focusScrollback)
        #expect(await f.renderer.testingScrollbackSelectedIndex() == t)
    }
}

private extension LiveInteractiveControllerRenderer {
    func readFolded(at index: Int) -> Bool {
        conversation.items.indices.contains(index) ? conversation.items[index].isFolded : true
    }
}

private final class FoldFixture: @unchecked Sendable {
    let home: URL
    let sink: FoldSink
    let renderer: LiveInteractiveControllerRenderer
    init(width: Int, height: Int) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("b-fold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = FoldSink()
        let env = ["HOME": home.path, "OPENGROK_HOME": home.path]
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(isTTY: { false }, size: { OpenGrokLiveTerminalSize(width: width, height: height) }, write: { _ in }),
            sink: sink, workingDirectory: home.path, modelName: "m",
            uiConfiguration: LiveInteractiveControllerRenderer.resolveUIConfig(workingDirectory: home, environment: env),
            openGrokHome: home, paintCadence: PagerMotion.minimumPaintCadence, environment: env)
    }
    func dispose() async throws { try await renderer.restoreTerminal(); try? FileManager.default.removeItem(at: home) }
    func click(blockIndex: Int) async throws -> OpenGrokPagerInputRouting {
        guard let m = await renderer.lastConversationHit else { Issue.record("no hit"); return .consumed }
        guard let p = point(in: m, blockIndex: blockIndex) else { Issue.record("no point"); return .consumed }
        let down = try await renderer.handleInput(.mouse(MouseEvent(kind: .down, x: p.x, y: p.y, button: .left)))
        #expect(down == .consumed)
        return try await renderer.handleInput(.mouse(MouseEvent(kind: .up, x: p.x, y: p.y, button: .left)))
    }
    private func point(in m: PagerConversationHitModel, blockIndex: Int) -> (x: Int, y: Int)? {
        let x = m.conversation.x + PagerLayoutMetrics.chromeWidth + 2
        if m.sticky.hasHeader { for r in 0..<m.sticky.headerScreenRows where m.sticky.entryAtHeaderRow(r) == blockIndex { return (x, m.conversation.y + r) } }
        guard m.blockStartLines.indices.contains(blockIndex), m.blockHeights.indices.contains(blockIndex) else { return nil }
        let cy = m.blockStartLines[blockIndex]
        let vy = cy - m.scrollOffset
        let hdr = m.sticky.hasHeader ? m.sticky.headerScreenRows : 0
        guard vy >= hdr, vy < m.conversation.height else { return nil }
        let sy = m.conversation.y + vy
        guard m.blockIndex(atScreenY: sy) == blockIndex else { return nil }
        return (x, sy)
    }

    func firstVisibleContentPoint(in model: PagerConversationHitModel) -> (index: Int, x: Int, y: Int)? {
        let count = min(model.blockStartLines.count, model.blockHeights.count)
        for index in 0..<count {
            if let point = point(in: model, blockIndex: index) {
                return (index, point.x, point.y)
            }
        }
        return nil
    }
}
private final class FoldSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }
    private var bytes: [UInt8] = []
    func write(bytes: [UInt8]) throws { self.bytes.append(contentsOf: bytes) }
    func flush() throws {}
}
