// Terminal.swift
//
// Double-buffered terminal with inline viewport, hyperlink layer, and large-safe
// diff flush. Port of xai-ratatui-inline's forked Terminal.

import Foundation

/// Frame handle provided to a draw callback.
public struct TerminalFrame {
    public var cursorPosition: TerminalPoint?
    public private(set) var viewportArea: TerminalRect
    public var buffer: CellBuffer
    public var count: Int

    public init(viewportArea: TerminalRect, buffer: CellBuffer, count: Int) {
        self.cursorPosition = nil
        self.viewportArea = viewportArea
        self.buffer = buffer
        self.count = count
    }

    public mutating func setCursorPosition(_ p: TerminalPoint?) {
        cursorPosition = p
    }
}

/// Completed frame snapshot after a successful draw.
public struct CompletedFrame: Sendable {
    public var area: TerminalRect
    public var count: Int
}

/// An interface to draw frames on the user's terminal.
public final class Terminal {
    private var backend: TerminalBackend
    private var buffers: [CellBuffer]
    private var current: Int = 0
    private var hiddenCursor: Bool = false
    public private(set) var viewport: ViewportKind
    public private(set) var viewportArea: TerminalRect
    public private(set) var lastKnownArea: TerminalRect
    public private(set) var lastKnownCursorPos: TerminalPoint
    public private(set) var frameCount: Int = 0
    private var linkIds: [[UInt32]]
    private var linkTables: [[LinkRef]]

    public init(backend: TerminalBackend, options: TerminalOptions = TerminalOptions()) throws {
        self.backend = backend
        let size = try backend.size()
        let full = TerminalRect(x: 0, y: 0, width: size.width, height: size.height)
        let (area, cursor): (TerminalRect, TerminalPoint)
        switch options.viewport {
        case .fullscreen:
            area = full
            cursor = TerminalPoint(x: 0, y: 0)
        case .inline(let height):
            let h = min(max(height, 0), size.height)
            let y = max(0, size.height - h)
            area = TerminalRect(x: 0, y: y, width: size.width, height: h)
            cursor = TerminalPoint(x: 0, y: y)
        case .fixed(let rect):
            area = rect
            cursor = rect.asPosition()
        }
        self.viewport = options.viewport
        self.viewportArea = area
        self.lastKnownArea = full
        self.lastKnownCursorPos = cursor
        let len = area.width * area.height
        self.buffers = [CellBuffer.empty(area), CellBuffer.empty(area)]
        self.linkIds = [Array(repeating: 0, count: len), Array(repeating: 0, count: len)]
        self.linkTables = [[], []]
    }

    deinit {
        if hiddenCursor {
            try? backend.showCursor()
        }
    }

    public var backendRef: TerminalBackend { backend }

    public func currentBuffer() -> CellBuffer {
        buffers[current]
    }

    public func getFrame() -> TerminalFrame {
        TerminalFrame(viewportArea: viewportArea, buffer: buffers[current], count: frameCount)
    }

    /// Commit a rendered frame buffer into the current backing store without flushing.
    public func commitFrameBuffer(_ buffer: CellBuffer) {
        buffers[current] = buffer
    }

    // MARK: - Links

    public func setFrameLinks(_ spans: [LinkSpan]) {
        let area = viewportArea
        let width = area.width
        let len = width * area.height
        var ids = Array(repeating: UInt32(0), count: max(0, len))
        var table: [LinkRef] = []
        for span in spans {
            if span.row < area.y || span.row >= area.bottom { continue }
            let start = max(span.colStart, area.x)
            let end = min(span.colEnd, area.right)
            if start >= end { continue }
            let id = UInt32(table.count + 1)
            table.append(LinkRef(url: span.url, id: span.id))
            let row = span.row - area.y
            for col in start..<end {
                let idx = row * width + (col - area.x)
                if idx >= 0 && idx < ids.count {
                    ids[idx] = id
                }
            }
        }
        linkIds[current] = ids
        linkTables[current] = table
    }

    // MARK: - Flush

    @discardableResult
    public func flush() throws -> Bool {
        let previous = buffers[1 - current]
        let cur = buffers[current]
        let updates = diffLarge(previous: previous, next: cur)
        if let last = updates.last {
            lastKnownCursorPos = TerminalPoint(x: last.x, y: last.y)
        }
        try backend.draw(updates)
        return !updates.isEmpty
    }

    /// Diff + emit the current frame with OSC 8 hyperlinks (Rust `flush_with_links`).
    ///
    /// Linked runs are wrapped once around a single `backend.draw` call; glyphs
    /// are never double-emitted.
    @discardableResult
    public func flushWithLinks() throws -> Bool {
        let cur = current
        let prev = 1 - cur
        if linkTables[cur].isEmpty && linkTables[prev].isEmpty {
            return try flush()
        }
        let updates = diffLargeWithLinks(
            previous: buffers[prev],
            next: buffers[cur],
            prevIds: linkIds[prev],
            nextIds: linkIds[cur],
            prevTable: linkTables[prev],
            nextTable: linkTables[cur]
        )
        if let last = updates.last {
            lastKnownCursorPos = TerminalPoint(x: last.x, y: last.y)
        }
        try backend.drawWithLinks(
            updates,
            linkIds: linkIds[cur],
            linkTable: linkTables[cur],
            area: buffers[cur].area
        )
        return !updates.isEmpty
    }

    // MARK: - Draw cycle

    @discardableResult
    public func draw(_ render: (inout TerminalFrame) throws -> Void) throws -> CompletedFrame {
        try drawInternal(withLinks: false, links: [], render)
    }

    /// Atomic render path: commit the rendered buffer, apply hyperlink spans,
    /// emit OSC 8 during the same frame flush, then swap buffers.
    @discardableResult
    public func drawWithLinks(
        _ links: [LinkSpan],
        _ render: (inout TerminalFrame) throws -> Void
    ) throws -> CompletedFrame {
        try drawInternal(withLinks: true, links: links, render)
    }

    private func drawInternal(
        withLinks: Bool,
        links: [LinkSpan],
        _ render: (inout TerminalFrame) throws -> Void
    ) throws -> CompletedFrame {
        try autoresize()
        var frame = getFrame()
        try render(&frame)
        buffers[current] = frame.buffer
        if withLinks {
            setFrameLinks(links)
            _ = try flushWithLinks()
        } else {
            _ = try flush()
        }
        if let position = frame.cursorPosition {
            try showCursor()
            try setCursorPosition(position)
        } else {
            try hideCursor()
        }
        swapBuffers()
        try backend.flush()
        let completed = CompletedFrame(area: lastKnownArea, count: frameCount)
        frameCount = frameCount &+ 1
        return completed
    }

    // MARK: - Cursor

    public func hideCursor() throws {
        try backend.hideCursor()
        hiddenCursor = true
    }

    public func showCursor() throws {
        try backend.showCursor()
        hiddenCursor = false
    }

    public func setCursorPosition(_ position: TerminalPoint) throws {
        try backend.setCursorPosition(position)
        lastKnownCursorPos = position
    }

    public func getCursorPosition() throws -> TerminalPoint {
        try backend.cursorPosition()
    }

    // MARK: - Clear / buffers

    public func clear() throws {
        switch viewport {
        case .fullscreen:
            try backend.clearRegion(.all)
        case .inline:
            try backend.setCursorPosition(viewportArea.asPosition())
            try backend.clearRegion(.afterCursor)
        case .fixed:
            let area = viewportArea
            for y in area.top..<area.bottom {
                try backend.setCursorPosition(TerminalPoint(x: 0, y: y))
                try backend.clearRegion(.afterCursor)
            }
        }
        buffers[1 - current].reset()
        resetBackLinks()
    }

    private func resetBackLinks() {
        let back = 1 - current
        for i in linkIds[back].indices {
            linkIds[back][i] = 0
        }
        linkTables[back].removeAll(keepingCapacity: true)
    }

    public func resetBackBuffer() {
        buffers[1 - current].reset()
        resetBackLinks()
    }

    public func swapBuffers() {
        buffers[1 - current].reset()
        resetBackLinks()
        current = 1 - current
    }

    public func size() throws -> TerminalSize {
        try backend.size()
    }

    // MARK: - Viewport

    public func setViewportArea(_ area: TerminalRect) {
        buffers[current].resize(area)
        buffers[1 - current].resize(area)
        let len = area.width * area.height
        for i in 0..<2 {
            linkIds[i] = Array(repeating: 0, count: max(0, len))
            linkTables[i].removeAll(keepingCapacity: true)
        }
        viewportArea = area
    }

    public func resize(area: TerminalRect) throws {
        let nextArea: TerminalRect
        switch viewport {
        case .inline(let height)
            where viewportArea.y == 0 && viewportArea.height >= lastKnownArea.height:
            // Full-height inline: track entire terminal.
            _ = height
            nextArea = area
        case .inline(let height):
            let offset = max(0, lastKnownCursorPos.y - viewportArea.top)
            nextArea = try computeInlineSize(height: height, size: area.asSize(), offsetInPrevious: offset).0
        case .fixed, .fullscreen:
            nextArea = area
        }
        setViewportArea(nextArea)
        try clear()
        lastKnownArea = area
    }

    public func autoresize() throws {
        switch viewport {
        case .fullscreen, .inline:
            let size = try backend.size()
            let area = TerminalRect(x: 0, y: 0, width: size.width, height: size.height)
            if area != lastKnownArea {
                try resize(area: area)
            }
        case .fixed:
            break
        }
    }

    /// Set the height of an inline viewport and resize accordingly.
    public func setViewportHeight(_ newHeight: Int) throws {
        guard case .inline = viewport else { return }
        let oldHeight = viewportArea.height
        viewport = .inline(height: newHeight)
        if oldHeight == newHeight { return }
        try clear()

        let newY: Int
        if newHeight > oldHeight {
            let overflow = max(0, (viewportArea.y + newHeight) - lastKnownArea.height)
            if overflow > 0 {
                try scrollUp(overflow)
                newY = max(0, viewportArea.y - overflow)
            } else {
                newY = viewportArea.y
            }
        } else {
            newY = viewportArea.y
        }
        setViewportArea(TerminalRect(
            x: viewportArea.x,
            y: newY,
            width: viewportArea.width,
            height: newHeight
        ))
        try clear()
    }

    // MARK: - Insert before (native scrollback injection)

    /// Insert `height` rows of content before the current inline viewport,
    /// scrolling them into the terminal's NATIVE scrollback. No effect on
    /// fullscreen/fixed viewports. Port of xai-ratatui-inline's
    /// `insert_before_no_scrolling_regions`
    /// (`xai-ratatui-inline/src/terminal.rs:812-993` at pin 650c1db7) — the
    /// pager builds WITHOUT the `scrolling-regions` feature (upstream's own
    /// note at `terminal.rs:882-884`), so the scrolling-regions variant is
    /// deliberately not ported.
    ///
    /// `drawFn` paints into a `height`-row buffer at the viewport's width.
    /// While the viewport is above the screen bottom, inserted rows push it
    /// down; once it reaches the bottom, the screen above it scrolls up (each
    /// scrolled row lands in native scrollback). Content taller than the
    /// screen is drawn in screen-sized chunks, scrolling between chunks.
    ///
    /// Errors PROPAGATE (never swallowed): the minimal-mode commit pipeline
    /// is print-once, and it must not mark an entry committed when the write
    /// failed — a marked-but-unprinted block can never be re-emitted
    /// (upstream's bugbot note at `commit.rs:335-337`).
    public func insertBefore(_ height: Int, draw drawFn: (inout CellBuffer) -> Void) throws {
        guard case .inline = viewport else { return }
        let width = viewportArea.width
        var buffer = CellBuffer.empty(TerminalRect(x: 0, y: 0, width: width, height: max(0, height)))
        drawFn(&buffer)

        // Signed arithmetic like upstream's i32 walk (`terminal.rs:923-928`),
        // so intermediate subtraction cannot trap.
        var drawnHeight = viewportArea.top
        var bufferHeight = max(0, height)
        let viewportHeight = viewportArea.height
        let screenHeight = lastKnownArea.height
        var consumedRows = 0

        // Chunked walk (`terminal.rs:930-956`): draw up to a screenful per
        // iteration until the remainder plus the viewport fits on screen,
        // scrolling just enough each round for the chunk being drawn.
        while bufferHeight + viewportHeight > screenHeight {
            let toDraw = min(bufferHeight, screenHeight)
            let scroll = max(0, drawnHeight + toDraw - screenHeight)
            try scrollUp(scroll)
            consumedRows = try drawBufferRows(
                buffer,
                startRow: consumedRows,
                rowCount: toDraw,
                atY: drawnHeight - scroll
            )
            drawnHeight += toDraw - scroll
            bufferHeight -= toDraw
        }

        // Final chunk: scroll exactly enough that content + viewport fill the
        // screen bottom-aligned, never negative when the viewport was not at
        // the bottom and the insert did not reach it (`terminal.rs:958-979`).
        let scroll = max(0, drawnHeight + bufferHeight + viewportHeight - screenHeight)
        try scrollUp(scroll)
        _ = try drawBufferRows(
            buffer,
            startRow: consumedRows,
            rowCount: bufferHeight,
            atY: drawnHeight - scroll
        )
        drawnHeight += bufferHeight - scroll

        setViewportArea(TerminalRect(
            x: viewportArea.x,
            y: drawnHeight,
            width: viewportArea.width,
            height: viewportArea.height
        ))

        // Clear the viewport off the screen LAST — deliberately deferred.
        // Upstream's two reasons (`terminal.rs:986-989`): the inserted buffer
        // is not sparse so it already overwrote what was on screen, and "there
        // is a weird bug with tmux where a full screen clear plus immediate
        // scrolling causes some garbage to go into the scrollback". Clearing
        // before the scroll re-introduces that artifact — do not reorder.
        try clear()
    }

    /// Draw `rowCount` rows of `buffer` starting at `startRow`, placed at
    /// screen row `atY`. Every cell is emitted (the buffer is not sparse — the
    /// draw itself overwrites stale screen content, which is what lets
    /// `insertBefore` defer its clear). Returns the next unconsumed row.
    /// Upstream's `draw_lines` (`terminal.rs:1077-1094`), which flushes per
    /// chunk so a scroll can never overtake an undrawn chunk.
    private func drawBufferRows(
        _ buffer: CellBuffer,
        startRow: Int,
        rowCount: Int,
        atY: Int
    ) throws -> Int {
        guard rowCount > 0 else { return startRow }
        let width = buffer.area.width
        var updates: [CellUpdate] = []
        updates.reserveCapacity(rowCount * width)
        for row in 0..<rowCount {
            for x in 0..<width {
                if let cell = buffer.cell(x: x, y: startRow + row) {
                    updates.append(CellUpdate(x: x, y: atY + row, cell: cell))
                }
            }
        }
        try backend.draw(updates)
        try backend.flush()
        return startRow + rowCount
    }

    private func scrollUp(_ lines: Int) throws {
        guard lines > 0 else { return }
        try setCursorPosition(TerminalPoint(x: 0, y: max(0, lastKnownArea.height - 1)))
        try backend.appendLines(lines)
    }

    private func computeInlineSize(
        height: Int,
        size: TerminalSize,
        offsetInPrevious: Int
    ) throws -> (TerminalRect, TerminalPoint) {
        let pos = try backend.cursorPosition()
        var row = pos.y
        let maxHeight = min(size.height, height)
        let linesAfter = max(0, height - offsetInPrevious - 1)
        try backend.appendLines(linesAfter)
        let available = max(0, size.height - row - 1)
        let missing = max(0, linesAfter - available)
        if missing > 0 {
            row = max(0, row - missing)
        }
        row = max(0, row - offsetInPrevious)
        return (
            TerminalRect(x: 0, y: row, width: size.width, height: maxHeight),
            pos
        )
    }
}
