import Foundation
import OpenGrokTerminalCore

public final class PagerTerminalRenderer {
    private struct ProjectedFrame {
        var buffer: CellBuffer
        var links: [LinkSpan]
        var cursorPosition: TerminalPoint?
    }

    private let sink: any PagerTerminalSink
    private let configuration: PagerTerminalRendererConfiguration
    private let engine = PagerRenderEngine()

    private var previousFrame: ProjectedFrame?
    private var started = false
    private var restorationAttempted = false
    private var enteredAlternateScreen = false
    private var cursorVisible: Bool?
    private var synchronizedOutputActive = false
    private var pendingResize = false
    private var mouseReportingActive = false
    private var frameClock: PagerFrameClock
    /// Non-nil while a child owns the tty (`suspend_for_child`,
    /// event_loop.rs:356-423), carrying the modes `resumeFromChild` must
    /// re-enter. One optional instead of a flag pair: "suspended but unsure
    /// what to restore" is unrepresentable.
    private var suspendedModes: (alternateScreen: Bool, mouseReporting: Bool)?

    public init(
        sink: any PagerTerminalSink,
        configuration: PagerTerminalRendererConfiguration = PagerTerminalRendererConfiguration()
    ) {
        self.sink = sink
        self.configuration = configuration
        self.frameClock = PagerFrameClock(cadence: configuration.paintCadence)
    }

    public var isStarted: Bool { started }
    public var isRestored: Bool { restorationAttempted }

    public func start() throws {
        guard !started else { return }
        guard !restorationAttempted else {
            throw PagerTerminalRendererError.alreadyRestored
        }
        guard sink.capabilities.supportsCursorPositioning else {
            throw PagerTerminalRendererError.unsupportedCursorPositioning
        }

        started = true

        if case .fullscreen = configuration.mode,
           configuration.useAlternateScreen,
           sink.capabilities.supportsAlternateScreen
        {
            enteredAlternateScreen = true
            try sink.write("\u{1B}[?1049h")
        }

        if sink.capabilities.supportsCursorVisibility {
            try sink.write("\u{1B}[?25l")
            cursorVisible = false
        }

        // Enable strictly after `?1049h` so the matching disable in `restore()`
        // — which runs strictly before `?1049l` — lands on the same buffer.
        if configuration.useMouseReporting {
            mouseReportingActive = true
            try sink.write(ANSIMouse.enableReporting)
        }
        try sink.flush()
    }

    /// Turn SGR mouse reporting on or off mid-session. Disabling hands click
    /// and drag back to the terminal for native copy/paste, which is what
    /// `/toggle-mouse-reporting` is for. Idempotent; returns whether it wrote.
    @discardableResult
    public func setMouseReporting(_ enabled: Bool) throws -> Bool {
        guard started, !restorationAttempted else { return false }
        if suspendedModes != nil {
            // A toggle while a child owns the tty must not write into its
            // screen; retarget what `resumeFromChild` re-enters instead.
            suspendedModes?.mouseReporting = enabled
            return false
        }
        guard enabled != mouseReportingActive else { return false }
        // Write before flipping the latch: a thrown sink write must leave
        // `mouseReportingActive` matching the wire so a later toggle and
        // `restore()` still emit the correct enable/disable sequence.
        try sink.write(enabled ? ANSIMouse.enableReporting : ANSIMouse.disableReporting)
        try sink.flush()
        mouseReportingActive = enabled
        return true
    }

    public var isMouseReportingEnabled: Bool { mouseReportingActive }

    // MARK: - Suspend for a child process

    public var isSuspended: Bool { suspendedModes != nil }

    /// Tear the TUI modes down so a child process can own the tty — the
    /// renderer half of `suspend_for_child` (event_loop.rs:394-398), emitted
    /// in `restore()`'s order and template. Unlike `restore()` this does not
    /// latch: `resumeFromChild` re-enters the same modes afterwards.
    ///
    /// The trailing flush is also the port of upstream's
    /// `writer_sync.wait_drained` (event_loop.rs:372-386): this port's sink
    /// writes are synchronous, so once the flush returns there is no queued
    /// frame left to drain.
    public func suspendToChild() throws {
        guard !restorationAttempted else {
            throw PagerTerminalRendererError.alreadyRestored
        }
        guard started, suspendedModes == nil else { return }

        let modes = (
            alternateScreen: enteredAlternateScreen,
            mouseReporting: mouseReportingActive
        )
        var output = ""
        if synchronizedOutputActive {
            output += ANSIOutput.endSynchronizedUpdate
            synchronizedOutputActive = false
        }
        output += "\u{1B}[0m"
        if sink.capabilities.supportsCursorVisibility {
            output += "\u{1B}[?25h"
            cursorVisible = true
        }
        // Same "unconditional when the session ever asked" reasoning as
        // `restore()`: a terminal that silently kept a mode must not feed the
        // child escape bursts.
        if mouseReportingActive || configuration.useMouseReporting {
            output += ANSIMouse.trackingReset
            mouseReportingActive = false
        }
        if enteredAlternateScreen {
            output += "\u{1B}[?1049l"
            enteredAlternateScreen = false
        }
        try sink.write(output)
        try sink.flush()
        suspendedModes = modes
        // The child owns the screen from here; the first frame after resume
        // must be a full repaint rather than a diff against a screen state we
        // can no longer vouch for (event_loop.rs:717-721).
        previousFrame = nil
    }

    /// Re-enter the modes `suspendToChild` recorded, in `start()`'s order —
    /// alt screen first, mouse enable last, so the enables land on the buffer
    /// the matching disables will run against.
    public func resumeFromChild() throws {
        guard let modes = suspendedModes else { return }
        var output = ""
        if modes.alternateScreen {
            output += "\u{1B}[?1049h"
            enteredAlternateScreen = true
        }
        if sink.capabilities.supportsCursorVisibility {
            output += "\u{1B}[?25l"
            cursorVisible = false
        }
        if modes.mouseReporting {
            output += ANSIMouse.enableReporting
            mouseReportingActive = true
        }
        try sink.write(output)
        try sink.flush()
        suspendedModes = nil
        // The terminal may have resized under the child.
        pendingResize = true
    }

    @discardableResult
    public func render(_ state: PagerRenderState) throws -> PagerTerminalRenderReport {
        try render(engine.render(state))
    }

    // MARK: - Coalesced painting

    /// When a folded repaint request is due to paint, or `nil` when nothing is
    /// pending. The caller arms a timer for this instant and calls
    /// `flushPendingFrame` when it fires — without that timer a request folded
    /// inside the cadence window would never paint.
    ///
    /// `nil` while suspended: a pre-suspend fold stays in the past forever,
    /// and a caller that kept arming timers for it would spin its flush loop
    /// at full speed for the child's whole runtime. The frame it folded is
    /// stale anyway — resume forces a full repaint.
    public var scheduledFrameAt: TimeInterval? {
        guard suspendedModes == nil else { return nil }
        return frameClock.isDirty ? (frameClock.scheduledPaintAt ?? 0) : nil
    }

    /// Paint through the frame clock: at most one frame per cadence window,
    /// with requests inside the window folded into one deferred frame — the
    /// `Presenter` (`event_loop.rs:425-517`) with `request_throttled`'s
    /// min-draw rule (`:480-489`).
    ///
    /// Returns `nil` when the request was coalesced; the frame it folded into
    /// paints when the caller services `scheduledFrameAt`. `now` is any
    /// monotonic seconds source — it only ever compares against itself.
    /// A tick loop without this half trades a frozen UI for a busy one:
    /// 30 fps of ticks plus per-event repaints must not become 30+ paints
    /// per second.
    @discardableResult
    public func requestFrame(
        _ state: PagerRenderState,
        at now: TimeInterval
    ) throws -> PagerTerminalRenderReport? {
        guard suspendedModes == nil else { return nil }
        guard frameClock.requestPaint(at: now) else { return nil }
        return try paintCoalescedFrame(state, at: now)
    }

    /// Paint the deferred frame scheduled by an earlier folded request, if it
    /// has come due. The caller passes the *latest* state — the whole point of
    /// folding is that only the newest frame is worth painting.
    @discardableResult
    public func flushPendingFrame(
        _ state: PagerRenderState,
        at now: TimeInterval
    ) throws -> PagerTerminalRenderReport? {
        guard suspendedModes == nil else { return nil }
        guard frameClock.isPaintDue(at: now) else { return nil }
        return try paintCoalescedFrame(state, at: now)
    }

    private func paintCoalescedFrame(
        _ state: PagerRenderState,
        at now: TimeInterval
    ) throws -> PagerTerminalRenderReport? {
        guard frameClock.beginFrame(at: now) else { return nil }
        defer { frameClock.endFrame() }
        return try render(state)
    }

    /// `requestFrame` for a caller that has already run the frame function —
    /// the live adapter needs the `PagerRenderResult` for its own overlay
    /// hit-testing bookkeeping, and rendering the state a second time inside
    /// this class would double the cost of every painted frame.
    @discardableResult
    public func requestFrame(
        _ result: PagerRenderResult,
        at now: TimeInterval
    ) throws -> PagerTerminalRenderReport? {
        guard suspendedModes == nil else { return nil }
        guard frameClock.requestPaint(at: now) else { return nil }
        guard frameClock.beginFrame(at: now) else { return nil }
        defer { frameClock.endFrame() }
        return try render(result)
    }

    /// `flushPendingFrame` over a pre-rendered result. The caller re-renders
    /// at flush time so the deferred paint shows the *latest* state — the
    /// whole point of folding is that only the newest frame is worth painting.
    @discardableResult
    public func flushPendingFrame(
        _ result: PagerRenderResult,
        at now: TimeInterval
    ) throws -> PagerTerminalRenderReport? {
        guard suspendedModes == nil else { return nil }
        guard frameClock.isPaintDue(at: now) else { return nil }
        guard frameClock.beginFrame(at: now) else { return nil }
        defer { frameClock.endFrame() }
        return try render(result)
    }

    @discardableResult
    public func render(_ result: PagerRenderResult) throws -> PagerTerminalRenderReport {
        // Load-bearing gate, not an optimization: the port's motion ticker is
        // a separate task that keeps ticking through a suspension — unlike
        // upstream, where the blocked event loop is the only painter — so an
        // ungated render here would paint frames into the child's screen.
        guard suspendedModes == nil else {
            return PagerTerminalRenderReport(
                changedCellCount: 0,
                didUseFullRedraw: false,
                didResize: false,
                usedSynchronizedOutput: false
            )
        }
        try start()
        let projected = try project(result)
        let areaChanged = previousFrame?.buffer.area != projected.buffer.area
        let didResize = pendingResize || areaChanged
        let fullRedraw = previousFrame == nil || didResize
        let previous = fullRedraw
            ? CellBuffer.empty(projected.buffer.area)
            : previousFrame!.buffer
        let previousLinks = fullRedraw ? [] : previousFrame!.links
        let (previousIDs, previousTable) = linkMetadata(
            for: previousLinks,
            area: previous.area
        )
        let (nextIDs, nextTable) = linkMetadata(
            for: projected.links,
            area: projected.buffer.area
        )
        let updates = diffLargeWithLinks(
            previous: previous,
            next: projected.buffer,
            prevIds: previousIDs,
            nextIds: nextIDs,
            prevTable: previousTable,
            nextTable: nextTable
        )
        let synchronized = configuration.useSynchronizedOutput
            && sink.capabilities.supportsSynchronizedOutput

        do {
            try emitFrame(
                projected: projected,
                updates: updates,
                nextIDs: nextIDs,
                nextTable: nextTable,
                fullRedraw: fullRedraw,
                clearPreviousArea: didResize ? previousFrame?.buffer.area : nil,
                synchronized: synchronized
            )
            previousFrame = projected
            pendingResize = false
        } catch {
            previousFrame = nil
            throw error
        }

        return PagerTerminalRenderReport(
            changedCellCount: updates.count,
            didUseFullRedraw: fullRedraw,
            didResize: didResize,
            usedSynchronizedOutput: synchronized
        )
    }

    public func resize(to size: TerminalSize) throws {
        guard !restorationAttempted else {
            throw PagerTerminalRendererError.alreadyRestored
        }
        pendingResize = true
        guard started else { return }
        // A resize under the child is recorded (`pendingResize`) but painted
        // only after resume — the clear writes below would land in its screen.
        guard suspendedModes == nil else { return }

        let nextArea = try projectedArea(for: size)
        let oldArea = previousFrame?.buffer.area
        let synchronized = configuration.useSynchronizedOutput
            && sink.capabilities.supportsSynchronizedOutput

        do {
            try withSynchronizedOutput(enabled: synchronized) {
                try emitClear(
                    area: nextArea,
                    previousArea: oldArea,
                    forceFullScreenClear: configuration.mode == .fullscreen
                )
            }
            previousFrame = nil
        } catch {
            previousFrame = nil
            throw error
        }
    }

    public func restore() throws {
        guard !restorationAttempted else { return }
        restorationAttempted = true
        guard started else { return }
        // Restoring mid-suspension still latches; the mode flags are already
        // false (suspendToChild undid them), so the writes below skip the
        // alt-screen leave and only re-assert the harmless resets.
        suspendedModes = nil

        var output = ""
        if synchronizedOutputActive {
            output += ANSIOutput.endSynchronizedUpdate
            synchronizedOutputActive = false
        }
        output += "\u{1B}[0m"
        if sink.capabilities.supportsCursorVisibility {
            output += "\u{1B}[?25h"
            cursorVisible = true
        }
        // Unconditional when the session ever asked for reporting: a terminal
        // that silently kept a mode we think we turned off must not be left
        // emitting escape bursts into the user's shell.
        if mouseReportingActive || configuration.useMouseReporting {
            output += ANSIMouse.trackingReset
            mouseReportingActive = false
        }
        if enteredAlternateScreen {
            output += "\u{1B}[?1049l"
            enteredAlternateScreen = false
        }

        if !output.isEmpty {
            try sink.write(output)
        }
        try sink.flush()
    }

    deinit {
        try? restore()
    }

    private func project(_ result: PagerRenderResult) throws -> ProjectedFrame {
        let source = result.buffer
        let sourceStart: Int
        switch configuration.mode {
        case .fullscreen:
            sourceStart = 0
        case .inline(let height):
            guard height > 0 else {
                throw PagerTerminalRendererError.invalidInlineHeight(height)
            }
            sourceStart = max(0, source.height - height)
        }

        let visibleHeight = max(0, source.height - sourceStart)
        let area = TerminalRect(
            x: source.area.x,
            y: source.area.y + sourceStart,
            width: source.width,
            height: visibleHeight
        )
        var buffer = CellBuffer(area: area)
        for row in 0..<visibleHeight {
            let sourceY = source.area.y + sourceStart + row
            for column in 0..<source.width {
                let x = source.area.x + column
                if let cell = source.cell(x: x, y: sourceY) {
                    buffer[row * area.width + column] = cell
                }
            }
        }

        let links = result.links.filter { span in
            span.row >= area.top && span.row < area.bottom
                && span.colStart < area.right
                && span.colEnd > area.left
        }
        let cursorPosition = result.cursorPosition.flatMap { position in
            area.contains(x: position.x, y: position.y) ? position : nil
        }
        return ProjectedFrame(
            buffer: buffer,
            links: links,
            cursorPosition: cursorPosition
        )
    }

    private func projectedArea(for size: TerminalSize) throws -> TerminalRect {
        switch configuration.mode {
        case .fullscreen:
            return TerminalRect(x: 0, y: 0, width: size.width, height: size.height)
        case .inline(let height):
            guard height > 0 else {
                throw PagerTerminalRendererError.invalidInlineHeight(height)
            }
            let visibleHeight = min(height, size.height)
            return TerminalRect(
                x: 0,
                y: max(0, size.height - visibleHeight),
                width: size.width,
                height: visibleHeight
            )
        }
    }

    private func emitFrame(
        projected: ProjectedFrame,
        updates: [CellUpdate],
        nextIDs: [UInt32],
        nextTable: [LinkRef],
        fullRedraw: Bool,
        clearPreviousArea: TerminalRect?,
        synchronized: Bool
    ) throws {
        try withSynchronizedOutput(enabled: synchronized) {
            if fullRedraw {
                try emitClear(
                    area: projected.buffer.area,
                    previousArea: clearPreviousArea,
                    forceFullScreenClear: configuration.mode == .fullscreen
                )
            }
            try sink.write(encode(
                updates: updates,
                ids: nextIDs,
                table: nextTable,
                area: projected.buffer.area
            ))
            try emitCursor(result: projected)
        }
    }

    private func emitClear(
        area: TerminalRect,
        previousArea: TerminalRect?,
        forceFullScreenClear: Bool
    ) throws {
        if forceFullScreenClear && area.x == 0 && area.y == 0 {
            try sink.write("\u{1B}[2J\u{1B}[H")
            return
        }

        if let previousArea {
            try clearRows(in: previousArea)
        }
        try clearRows(in: area)
    }

    private func clearRows(in area: TerminalRect) throws {
        guard area.width > 0, area.height > 0 else { return }
        for row in area.top..<area.bottom {
            try sink.write(ANSIOutput.moveTo(column: area.left, row: row))
            try sink.write("\u{1B}[2K")
        }
        try sink.write(ANSIOutput.moveTo(column: area.left, row: area.top))
    }

    private func emitCursor(result: ProjectedFrame) throws {
        guard sink.capabilities.supportsCursorPositioning else {
            throw PagerTerminalRendererError.unsupportedCursorPositioning
        }
        guard sink.capabilities.supportsCursorVisibility else {
            return
        }

        let position = result.cursorPosition
        if let position {
            if cursorVisible != true {
                try sink.write("\u{1B}[?25h")
                cursorVisible = true
            }
            try sink.write(ANSIOutput.moveTo(column: position.x, row: position.y))
        } else if cursorVisible != false {
            try sink.write("\u{1B}[?25l")
            cursorVisible = false
        }
    }

    private func encode(
        updates: [CellUpdate],
        ids: [UInt32],
        table: [LinkRef],
        area: TerminalRect
    ) -> String {
        guard !updates.isEmpty else { return "" }
        let width = max(area.width, 1)
        var output = ""
        var currentAttributes = CellAttributes.empty
        var index = 0

        func link(at update: CellUpdate) -> LinkRef? {
            guard sink.capabilities.supportsHyperlinks else { return nil }
            let linkIndex = (update.y - area.y) * width + (update.x - area.x)
            return resolveLink(ids: ids, table: table, index: linkIndex)
        }

        while index < updates.count {
            let currentLink = link(at: updates[index])
            var end = index + 1
            while end < updates.count && link(at: updates[end]) == currentLink {
                end += 1
            }

            if let currentLink {
                output += ANSIOutput.osc8Open(url: currentLink.url, id: currentLink.id)
            }
            for updateIndex in index..<end {
                let update = updates[updateIndex]
                guard !update.cell.skip else { continue }
                output += ANSIOutput.moveTo(column: update.x, row: update.y)
                if update.cell.attributes != currentAttributes {
                    output += sgr(for: update.cell.attributes)
                    currentAttributes = update.cell.attributes
                }
                output += update.cell.grapheme
            }
            if currentLink != nil {
                output += ANSIOutput.osc8Close
            }
            index = end
        }

        if currentAttributes != .empty {
            output += "\u{1B}[0m"
        }
        return output
    }

    private func sgr(for attributes: CellAttributes) -> String {
        var parameters = ["0"]
        if attributes.style.contains(.bold) { parameters.append("1") }
        if attributes.style.contains(.dim) { parameters.append("2") }
        if attributes.style.contains(.italic) { parameters.append("3") }
        if attributes.style.contains(.underline) { parameters.append("4") }
        if attributes.style.contains(.blink) { parameters.append("5") }
        if attributes.style.contains(.reverse) { parameters.append("7") }
        if attributes.style.contains(.hidden) { parameters.append("8") }
        if attributes.style.contains(.strike) { parameters.append("9") }
        parameters.append(contentsOf: colorParameters(attributes.foreground, foreground: true))
        parameters.append(contentsOf: colorParameters(attributes.background, foreground: false))
        return "\u{1B}[\(parameters.joined(separator: ";"))m"
    }

    private func colorParameters(_ color: TerminalColor, foreground: Bool) -> [String] {
        let base = foreground ? 38 : 48
        switch sink.capabilities.colorDepth {
        case .monochrome:
            return []
        case .sixteenColor:
            guard let code = sixteenColorCode(color, foreground: foreground) else { return [] }
            return [String(code)]
        case .twoFiftySixColor:
            switch color {
            case .reset:
                return []
            case .indexed(let value):
                return [String(base), "5", String(value)]
            case .rgb(let red, let green, let blue):
                return [String(base), "5", String(xtermIndex(red: red, green: green, blue: blue))]
            default:
                guard let code = sixteenColorCode(color, foreground: foreground) else { return [] }
                return [String(base), "5", String(codeToXtermIndex(code))]
            }
        case .trueColor:
            switch color {
            case .reset:
                return []
            case .rgb(let red, let green, let blue):
                return [String(base), "2", String(red), String(green), String(blue)]
            case .indexed(let value):
                return [String(base), "5", String(value)]
            default:
                guard let code = sixteenColorCode(color, foreground: foreground) else { return [] }
                return [String(code)]
            }
        }
    }

    private func sixteenColorCode(
        _ color: TerminalColor,
        foreground: Bool
    ) -> Int? {
        let normalBase = foreground ? 30 : 40
        let brightBase = foreground ? 90 : 100
        switch color {
        case .black: return normalBase
        case .red: return normalBase + 1
        case .green: return normalBase + 2
        case .yellow: return normalBase + 3
        case .blue: return normalBase + 4
        case .magenta: return normalBase + 5
        case .cyan: return normalBase + 6
        case .white: return normalBase + 7
        case .brightBlack: return brightBase
        case .brightRed: return brightBase + 1
        case .brightGreen: return brightBase + 2
        case .brightYellow: return brightBase + 3
        case .brightBlue: return brightBase + 4
        case .brightMagenta: return brightBase + 5
        case .brightCyan: return brightBase + 6
        case .brightWhite: return brightBase + 7
        case .indexed(let value):
            return normalBase + Int(value % 8)
        case .rgb(let red, let green, let blue):
            return nearestBasicColorCode(red: red, green: green, blue: blue, foreground: foreground)
        case .reset:
            return nil
        }
    }

    private func nearestBasicColorCode(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        foreground: Bool
    ) -> Int {
        let palette: [(Int, Int, Int, Int)] = [
            (0, 0, 0, 0),
            (1, 128, 0, 0),
            (2, 0, 128, 0),
            (3, 128, 128, 0),
            (4, 0, 0, 128),
            (5, 128, 0, 128),
            (6, 0, 128, 128),
            (7, 192, 192, 192),
            (8, 128, 128, 128),
            (9, 255, 0, 0),
            (10, 0, 255, 0),
            (11, 255, 255, 0),
            (12, 0, 0, 255),
            (13, 255, 0, 255),
            (14, 0, 255, 255),
            (15, 255, 255, 255)
        ]
        let target = (Int(red), Int(green), Int(blue))
        let best = palette.min { lhs, rhs in
            colorDistance(lhs: lhs, target: target) < colorDistance(lhs: rhs, target: target)
        }!.0
        if best < 8 {
            return (foreground ? 30 : 40) + best
        }
        return (foreground ? 90 : 100) + (best - 8)
    }

    private func colorDistance(
        lhs: (Int, Int, Int, Int),
        target: (Int, Int, Int)
    ) -> Int {
        let red = lhs.1 - target.0
        let green = lhs.2 - target.1
        let blue = lhs.3 - target.2
        return red * red + green * green + blue * blue
    }

    private func codeToXtermIndex(_ code: Int) -> UInt8 {
        let basic = max(0, min(15, code >= 90 ? code - 90 + 8 : code - 30))
        return UInt8(basic)
    }

    private func xtermIndex(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        if red == green, green == blue {
            if red < 8 { return 16 }
            if red > 248 { return 231 }
            return UInt8(232 + (Int(red) - 8) * 24 / 247)
        }
        let redIndex = Int(red) * 5 / 255
        let greenIndex = Int(green) * 5 / 255
        let blueIndex = Int(blue) * 5 / 255
        return UInt8(16 + 36 * redIndex + 6 * greenIndex + blueIndex)
    }

    private func linkMetadata(
        for spans: [LinkSpan],
        area: TerminalRect
    ) -> ([UInt32], [LinkRef]) {
        guard sink.capabilities.supportsHyperlinks, area.width > 0, area.height > 0 else {
            return ([], [])
        }
        var ids = Array(repeating: UInt32(0), count: area.width * area.height)
        var table: [LinkRef] = []
        for span in spans {
            // Defense in depth: never emit OSC 8 for a scheme Standard rejects,
            // even if a stale LinkSpan slipped past paint-time filtering
            // (`link_opener.rs:261-278` / `hyperlinks.rs:28-46` at pin 650c1db7).
            guard pagerURLIsSafeToOpen(span.url) else { continue }
            let start = max(area.left, span.colStart)
            let end = min(area.right, span.colEnd)
            guard span.row >= area.top, span.row < area.bottom, start < end else { continue }
            let id = UInt32(table.count + 1)
            table.append(LinkRef(url: span.url, id: span.id))
            let row = span.row - area.top
            for column in start..<end {
                ids[row * area.width + (column - area.left)] = id
            }
        }
        return (ids, table)
    }

    private func withSynchronizedOutput(
        enabled: Bool,
        _ body: () throws -> Void
    ) throws {
        if enabled {
            try sink.write(ANSIOutput.beginSynchronizedUpdate)
            synchronizedOutputActive = true
        }
        do {
            try body()
            if enabled {
                try sink.write(ANSIOutput.endSynchronizedUpdate)
                synchronizedOutputActive = false
            }
            try sink.flush()
        } catch {
            if enabled {
                try? sink.write(ANSIOutput.endSynchronizedUpdate)
                synchronizedOutputActive = false
            }
            try? sink.flush()
            throw error
        }
    }
}
