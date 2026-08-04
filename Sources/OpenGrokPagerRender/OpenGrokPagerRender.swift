import Foundation
import OpenGrokTerminalCore

public enum PagerMessageRole: Sendable, Equatable, Hashable {
    case user
    case assistant
    case system
    case reasoning
    case error

    fileprivate var label: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Grok"
        case .system: return "System"
        case .reasoning: return "Reasoning"
        case .error: return "Error"
        }
    }
}

public struct PagerMessage: Sendable, Equatable, Hashable {
    public var role: PagerMessageRole
    public var text: String
    public var isStreaming: Bool

    public init(role: PagerMessageRole, text: String, isStreaming: Bool = false) {
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

public enum PagerToolState: Sendable, Equatable, Hashable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled

    fileprivate var label: String {
        switch self {
        case .pending: return "pending"
        case .running: return "running"
        case .succeeded: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

public struct PagerToolCard: Sendable, Equatable, Hashable {
    public var name: String
    public var input: String
    public var output: String?
    public var state: PagerToolState
    public var isExpanded: Bool

    public init(
        name: String,
        input: String = "",
        output: String? = nil,
        state: PagerToolState = .pending,
        isExpanded: Bool = true
    ) {
        self.name = name
        self.input = input
        self.output = output
        self.state = state
        self.isExpanded = isExpanded
    }
}

public enum PagerConversationItem: Sendable, Equatable, Hashable {
    case message(PagerMessage)
    case tool(PagerToolCard)
    case separator(String)
}

public struct PagerHeader: Sendable, Equatable, Hashable {
    public var title: String
    public var subtitle: String?
    public var trailing: String?

    public init(title: String, subtitle: String? = nil, trailing: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }
}

public struct PagerStatusLine: Sendable, Equatable, Hashable {
    public var text: String
    public var isStreaming: Bool
    public var detail: String?

    public init(text: String, isStreaming: Bool = false, detail: String? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.detail = detail
    }
}

public struct PagerInputState: Sendable, Equatable, Hashable {
    public var prompt: String
    public var text: String
    public var cursorCharacterOffset: Int?
    public var isFocused: Bool
    public var cursorVisible: Bool
    public var maximumHeight: Int

    public init(
        prompt: String = "› ",
        text: String = "",
        cursorCharacterOffset: Int? = nil,
        isFocused: Bool = true,
        cursorVisible: Bool = true,
        maximumHeight: Int = 3
    ) {
        self.prompt = prompt
        self.text = text
        self.cursorCharacterOffset = cursorCharacterOffset
        self.isFocused = isFocused
        self.cursorVisible = cursorVisible
        self.maximumHeight = max(1, maximumHeight)
    }
}

public struct PagerFooter: Sendable, Equatable, Hashable {
    public var leading: String
    public var trailing: String?

    public init(leading: String, trailing: String? = nil) {
        self.leading = leading
        self.trailing = trailing
    }
}

public enum PagerScrollPosition: Sendable, Equatable, Hashable {
    case followTail
    case offset(Int)
}

public struct PagerRenderTheme: Sendable, Equatable, Hashable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var headerForeground: TerminalColor
    public var accentForeground: TerminalColor
    public var userForeground: TerminalColor
    public var assistantForeground: TerminalColor
    public var systemForeground: TerminalColor
    public var reasoningForeground: TerminalColor
    public var errorForeground: TerminalColor
    public var borderForeground: TerminalColor
    public var toolForeground: TerminalColor
    public var scrollbarForeground: TerminalColor
    public var headerStyle: CellStyle
    public var accentStyle: CellStyle
    public var toolStyle: CellStyle

    public init(
        foreground: TerminalColor = .white,
        background: TerminalColor = .reset,
        headerForeground: TerminalColor = .brightCyan,
        accentForeground: TerminalColor = .brightYellow,
        userForeground: TerminalColor = .brightGreen,
        assistantForeground: TerminalColor = .white,
        systemForeground: TerminalColor = .brightBlue,
        reasoningForeground: TerminalColor = .brightMagenta,
        errorForeground: TerminalColor = .brightRed,
        borderForeground: TerminalColor = .brightBlack,
        toolForeground: TerminalColor = .brightCyan,
        scrollbarForeground: TerminalColor = .brightBlack,
        headerStyle: CellStyle = [.bold],
        accentStyle: CellStyle = [.bold],
        toolStyle: CellStyle = [.bold]
    ) {
        self.foreground = foreground
        self.background = background
        self.headerForeground = headerForeground
        self.accentForeground = accentForeground
        self.userForeground = userForeground
        self.assistantForeground = assistantForeground
        self.systemForeground = systemForeground
        self.reasoningForeground = reasoningForeground
        self.errorForeground = errorForeground
        self.borderForeground = borderForeground
        self.toolForeground = toolForeground
        self.scrollbarForeground = scrollbarForeground
        self.headerStyle = headerStyle
        self.accentStyle = accentStyle
        self.toolStyle = toolStyle
    }

    public static let `default` = PagerRenderTheme()
}

public struct PagerRenderState: Sendable, Equatable {
    public var size: TerminalSize
    public var header: PagerHeader?
    public var conversation: [PagerConversationItem]
    public var status: PagerStatusLine?
    public var input: PagerInputState
    public var footer: PagerFooter?
    public var scrollPosition: PagerScrollPosition
    public var theme: PagerRenderTheme
    public var showScrollbar: Bool

    public init(
        size: TerminalSize,
        header: PagerHeader? = nil,
        conversation: [PagerConversationItem] = [],
        status: PagerStatusLine? = nil,
        input: PagerInputState = PagerInputState(),
        footer: PagerFooter? = nil,
        scrollPosition: PagerScrollPosition = .followTail,
        theme: PagerRenderTheme = .default,
        showScrollbar: Bool = true
    ) {
        self.size = size
        self.header = header
        self.conversation = conversation
        self.status = status
        self.input = input
        self.footer = footer
        self.scrollPosition = scrollPosition
        self.theme = theme
        self.showScrollbar = showScrollbar
    }
}

public struct PagerFrameLayout: Sendable, Equatable {
    public var bounds: TerminalRect
    public var header: TerminalRect
    public var conversation: TerminalRect
    public var status: TerminalRect
    public var input: TerminalRect
    public var footer: TerminalRect
    public var contentWidth: Int
    public var totalContentLines: Int
    public var visibleContentLines: Range<Int>
    public var scrollOffset: Int
    public var hasScrollbar: Bool

    public init(
        bounds: TerminalRect,
        header: TerminalRect,
        conversation: TerminalRect,
        status: TerminalRect,
        input: TerminalRect,
        footer: TerminalRect,
        contentWidth: Int,
        totalContentLines: Int,
        visibleContentLines: Range<Int>,
        scrollOffset: Int,
        hasScrollbar: Bool
    ) {
        self.bounds = bounds
        self.header = header
        self.conversation = conversation
        self.status = status
        self.input = input
        self.footer = footer
        self.contentWidth = contentWidth
        self.totalContentLines = totalContentLines
        self.visibleContentLines = visibleContentLines
        self.scrollOffset = scrollOffset
        self.hasScrollbar = hasScrollbar
    }
}

public struct PagerRenderResult: Sendable, Equatable {
    public var buffer: CellBuffer
    public var layout: PagerFrameLayout
    public var cursorPosition: TerminalPoint?
    public var links: [LinkSpan]

    public init(
        buffer: CellBuffer,
        layout: PagerFrameLayout,
        cursorPosition: TerminalPoint?,
        links: [LinkSpan] = []
    ) {
        self.buffer = buffer
        self.layout = layout
        self.cursorPosition = cursorPosition
        self.links = links
    }

    public func snapshot(includeTrailingSpaces: Bool = false) -> String {
        guard buffer.width > 0, buffer.height > 0 else { return "" }
        var rows: [String] = []
        rows.reserveCapacity(buffer.height)
        for y in buffer.area.top..<buffer.area.bottom {
            var row = ""
            for x in buffer.area.left..<buffer.area.right {
                guard let cell = buffer.cell(x: x, y: y), !cell.skip else { continue }
                row += cell.grapheme
            }
            if !includeTrailingSpaces {
                while row.last == " " {
                    row.removeLast()
                }
            }
            rows.append(row)
        }
        return rows.joined(separator: "\n")
    }
}

public struct PagerRenderEngine: Sendable {
    public init() {}

    public func render(_ state: PagerRenderState) -> PagerRenderResult {
        renderPagerFrame(state)
    }
}

public enum PagerRenderer {
    public static func render(_ state: PagerRenderState) -> PagerRenderResult {
        renderPagerFrame(state)
    }
}

public func renderPagerFrame(_ state: PagerRenderState) -> PagerRenderResult {
    let bounds = TerminalRect(x: 0, y: 0, width: state.size.width, height: state.size.height)
    let inputText = inputTextWithCursor(state.input)
    let requestedInputHeight = min(
        max(1, state.input.maximumHeight),
        max(1, wrapDisplayLines(inputText, width: max(1, bounds.width)).count)
    )

    let chrome = makeChromeLayout(
        bounds: bounds,
        hasHeader: state.header != nil,
        hasStatus: state.status != nil,
        inputHeight: requestedInputHeight,
        hasFooter: state.footer != nil
    )

    let baseContentWidth = chrome.conversation.width
    var contentLines = makeConversationLines(
        state.conversation,
        width: max(1, baseContentWidth),
        theme: state.theme
    )
    let hasScrollbar = state.showScrollbar && baseContentWidth > 1
        && contentLines.count > chrome.conversation.height
    if hasScrollbar {
        contentLines = makeConversationLines(
            state.conversation,
            width: max(1, baseContentWidth - 1),
            theme: state.theme
        )
    }

    let contentWidth = max(0, baseContentWidth - (hasScrollbar ? 1 : 0))
    let visibleHeight = chrome.conversation.height
    let maximumOffset = max(0, contentLines.count - visibleHeight)
    let scrollOffset: Int
    switch state.scrollPosition {
    case .followTail:
        scrollOffset = maximumOffset
    case .offset(let requested):
        scrollOffset = min(max(requested, 0), maximumOffset)
    }
    let visibleEnd = min(contentLines.count, scrollOffset + visibleHeight)
    let visibleRange = scrollOffset..<visibleEnd
    let layout = PagerFrameLayout(
        bounds: bounds,
        header: chrome.header,
        conversation: chrome.conversation,
        status: chrome.status,
        input: chrome.input,
        footer: chrome.footer,
        contentWidth: contentWidth,
        totalContentLines: contentLines.count,
        visibleContentLines: visibleRange,
        scrollOffset: scrollOffset,
        hasScrollbar: hasScrollbar
    )

    var buffer = CellBuffer(area: bounds)
    fill(&buffer, area: bounds, theme: state.theme)
    renderHeader(state.header, in: chrome.header, buffer: &buffer, theme: state.theme)
    renderConversation(
        contentLines,
        visibleRange: visibleRange,
        in: chrome.conversation,
        contentWidth: contentWidth,
        hasScrollbar: hasScrollbar,
        scrollOffset: scrollOffset,
        buffer: &buffer,
        theme: state.theme
    )
    renderStatus(state.status, in: chrome.status, buffer: &buffer, theme: state.theme)
    let cursorPosition = renderInput(
        state.input,
        in: chrome.input,
        buffer: &buffer,
        theme: state.theme
    )
    renderFooter(state.footer, in: chrome.footer, buffer: &buffer, theme: state.theme)

    return PagerRenderResult(
        buffer: buffer,
        layout: layout,
        cursorPosition: cursorPosition
    )
}

private struct ChromeLayout {
    var header: TerminalRect
    var conversation: TerminalRect
    var status: TerminalRect
    var input: TerminalRect
    var footer: TerminalRect
}

private func makeChromeLayout(
    bounds: TerminalRect,
    hasHeader: Bool,
    hasStatus: Bool,
    inputHeight: Int,
    hasFooter: Bool
) -> ChromeLayout {
    var remaining = bounds.height
    let headerHeight = hasHeader && remaining > 0 ? 1 : 0
    remaining -= headerHeight

    let footerHeight = hasFooter && remaining > 0 ? 1 : 0
    remaining -= footerHeight

    let inputHeight = remaining > 0 ? min(max(1, inputHeight), remaining) : 0
    remaining -= inputHeight

    let statusHeight = hasStatus && remaining > 0 ? 1 : 0
    remaining -= statusHeight

    let header = TerminalRect(x: bounds.x, y: bounds.y, width: bounds.width, height: headerHeight)
    let conversation = TerminalRect(
        x: bounds.x,
        y: header.bottom,
        width: bounds.width,
        height: max(0, remaining)
    )
    let status = TerminalRect(
        x: bounds.x,
        y: conversation.bottom,
        width: bounds.width,
        height: statusHeight
    )
    let input = TerminalRect(
        x: bounds.x,
        y: status.bottom,
        width: bounds.width,
        height: inputHeight
    )
    let footer = TerminalRect(
        x: bounds.x,
        y: input.bottom,
        width: bounds.width,
        height: footerHeight
    )
    return ChromeLayout(
        header: header,
        conversation: conversation,
        status: status,
        input: input,
        footer: footer
    )
}

private struct PaintLine {
    var text: String
    var foreground: TerminalColor
    var style: CellStyle

    init(
        _ text: String,
        foreground: TerminalColor,
        style: CellStyle = []
    ) {
        self.text = text
        self.foreground = foreground
        self.style = style
    }
}

private func makeConversationLines(
    _ items: [PagerConversationItem],
    width: Int,
    theme: PagerRenderTheme
) -> [PaintLine] {
    guard width > 0 else { return [] }
    var lines: [PaintLine] = []
    for item in items {
        switch item {
        case .message(let message):
            let prefix = "\(message.role.label): "
            let body = message.text + (message.isStreaming ? "▌" : "")
            let foreground = messageForeground(message.role, theme: theme)
            let style: CellStyle = message.role == .error ? [.bold] : []
            appendPrefixedText(
                prefix: prefix,
                body: body,
                width: width,
                foreground: foreground,
                style: style,
                into: &lines
            )
        case .tool(let tool):
            appendToolCard(tool, width: width, theme: theme, into: &lines)
        case .separator(let text):
            let separator = text.isEmpty ? String(repeating: "─", count: width) : text
            lines.append(PaintLine(separator, foreground: theme.borderForeground))
        }
    }
    return lines
}

private func appendPrefixedText(
    prefix: String,
    body: String,
    width: Int,
    foreground: TerminalColor,
    style: CellStyle,
    into lines: inout [PaintLine]
) {
    let prefixWidth = UnicodeDisplayWidth.width(of: prefix)
    if prefixWidth >= width {
        lines.append(PaintLine(prefix, foreground: foreground, style: style))
        return
    }
    let bodyWidth = width - prefixWidth
    let physicalLines = body.split(separator: "\n", omittingEmptySubsequences: false)
    let physical = physicalLines.isEmpty ? [""] : physicalLines.map(String.init)
    let indentation = String(repeating: " ", count: prefixWidth)
    for part in physical {
        let wrapped = wrapDisplayLines(part, width: bodyWidth)
        let rows = wrapped.isEmpty ? [""] : wrapped
        for (index, row) in rows.enumerated() {
            let rowPrefix = index == 0 ? prefix : indentation
            lines.append(PaintLine(rowPrefix + row, foreground: foreground, style: style))
        }
    }
}

private func appendToolCard(
    _ tool: PagerToolCard,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    let title = "┌─ Tool: \(tool.name) [\(tool.state.label)]"
    lines.append(PaintLine(title, foreground: theme.toolForeground, style: theme.toolStyle))
    guard tool.isExpanded else {
        lines.append(PaintLine("└─", foreground: theme.toolForeground, style: theme.toolStyle))
        return
    }
    if !tool.input.isEmpty {
        appendCardField("input", value: tool.input, width: width, theme: theme, into: &lines)
    }
    if let output = tool.output, !output.isEmpty {
        appendCardField("result", value: output, width: width, theme: theme, into: &lines)
    }
    lines.append(PaintLine("└─", foreground: theme.toolForeground, style: theme.toolStyle))
}

private func appendCardField(
    _ label: String,
    value: String,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    let prefix = "│ \(label): "
    let prefixWidth = UnicodeDisplayWidth.width(of: prefix)
    let fieldWidth = max(1, width - prefixWidth)
    let indentation = String(repeating: " ", count: prefixWidth)
    let physicalLines = value.split(separator: "\n", omittingEmptySubsequences: false)
    for part in physicalLines {
        let wrapped = wrapDisplayLines(String(part), width: fieldWidth)
        let rows = wrapped.isEmpty ? [""] : wrapped
        for (index, row) in rows.enumerated() {
            lines.append(PaintLine(
                (index == 0 ? prefix : indentation) + row,
                foreground: theme.toolForeground
            ))
        }
    }
}

private func renderHeader(
    _ header: PagerHeader?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let header, area.height > 0 else { return }
    paintRow(&buffer, area: area, text: "", foreground: theme.headerForeground, style: theme.headerStyle, theme: theme)
    var leading = header.title
    if let subtitle = header.subtitle, !subtitle.isEmpty {
        leading += " · " + subtitle
    }
    drawAlignedRow(
        leading: leading,
        trailing: header.trailing,
        area: area,
        buffer: &buffer,
        foreground: theme.headerForeground,
        style: theme.headerStyle,
        theme: theme
    )
}

private func renderStatus(
    _ status: PagerStatusLine?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let status, area.height > 0 else { return }
    var text = status.text
    if status.isStreaming { text += "  • streaming" }
    if let detail = status.detail, !detail.isEmpty { text += "  (detail)" }
    paintRow(&buffer, area: area, text: text, foreground: theme.accentForeground, style: [], theme: theme)
}

private func renderFooter(
    _ footer: PagerFooter?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard let footer, area.height > 0 else { return }
    drawAlignedRow(
        leading: footer.leading,
        trailing: footer.trailing,
        area: area,
        buffer: &buffer,
        foreground: theme.foreground,
        style: [],
        theme: theme
    )
}

private func renderConversation(
    _ lines: [PaintLine],
    visibleRange: Range<Int>,
    in area: TerminalRect,
    contentWidth: Int,
    hasScrollbar: Bool,
    scrollOffset: Int,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.height > 0 else { return }
    for row in 0..<area.height {
        let y = area.y + row
        paintRow(
            &buffer,
            area: TerminalRect(x: area.x, y: y, width: contentWidth, height: 1),
            text: "",
            foreground: theme.foreground,
            style: [],
            theme: theme
        )
    }
    for (row, lineIndex) in visibleRange.enumerated() {
        guard row < area.height, lines.indices.contains(lineIndex) else { continue }
        let line = lines[lineIndex]
        paintRow(
            &buffer,
            area: TerminalRect(x: area.x, y: area.y + row, width: contentWidth, height: 1),
            text: line.text,
            foreground: line.foreground,
            style: line.style,
            theme: theme
        )
    }
    guard hasScrollbar, contentWidth < area.width, area.height > 0 else { return }
    let scrollbarX = area.x + contentWidth
    let total = max(lines.count, 1)
    let thumbHeight = max(1, (area.height * area.height) / total)
    let maximumOffset = max(0, lines.count - area.height)
    let trackTravel = max(0, area.height - thumbHeight)
    let thumbStart = maximumOffset == 0
        ? 0
        : min(trackTravel, (scrollOffset * trackTravel) / maximumOffset)
    for row in 0..<area.height {
        let glyph = row >= thumbStart && row < thumbStart + thumbHeight ? "█" : "│"
        _ = buffer.setString(
            x: scrollbarX,
            y: area.y + row,
            text: glyph,
            style: [],
            foreground: theme.scrollbarForeground,
            background: theme.background
        )
    }
}

private func renderInput(
    _ input: PagerInputState,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> TerminalPoint? {
    guard area.height > 0 else { return nil }
    let renderedText = inputTextWithCursor(input)
    let lines = wrapDisplayLines(renderedText, width: max(1, area.width))
    for row in 0..<area.height {
        let text = row < lines.count ? lines[row] : ""
        paintRow(
            &buffer,
            area: TerminalRect(x: area.x, y: area.y + row, width: area.width, height: 1),
            text: text,
            foreground: input.isFocused ? theme.foreground : theme.borderForeground,
            style: input.isFocused ? [] : [.dim],
            theme: theme
        )
    }
    guard input.isFocused, input.cursorVisible, area.width > 0 else { return nil }
    for (row, line) in lines.enumerated() where line.contains("▌") {
        let prefix = String(line.split(separator: "▌", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let column = min(area.width - 1, UnicodeDisplayWidth.width(of: prefix))
        return TerminalPoint(x: area.x + column, y: area.y + row)
    }
    return TerminalPoint(x: area.x + area.width - 1, y: area.y + min(area.height - 1, lines.count - 1))
}

private func inputTextWithCursor(_ input: PagerInputState) -> String {
    guard input.isFocused, input.cursorVisible else {
        return input.prompt + input.text
    }
    let characters = Array(input.text)
    let offset = min(max(input.cursorCharacterOffset ?? characters.count, 0), characters.count)
    let before = String(characters[..<offset])
    let after = String(characters[offset...])
    return input.prompt + before + "▌" + after
}

private func messageForeground(_ role: PagerMessageRole, theme: PagerRenderTheme) -> TerminalColor {
    switch role {
    case .user: return theme.userForeground
    case .assistant: return theme.assistantForeground
    case .system: return theme.systemForeground
    case .reasoning: return theme.reasoningForeground
    case .error: return theme.errorForeground
    }
}

private func fill(
    _ buffer: inout CellBuffer,
    area: TerminalRect,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    let blank = Cell(
        grapheme: " ",
        foreground: theme.foreground,
        background: theme.background,
        displayWidth: 1
    )
    for y in area.y..<area.bottom {
        for x in area.x..<area.right {
            buffer.setCell(blank, x: x, y: y)
        }
    }
}

private func paintRow(
    _ buffer: inout CellBuffer,
    area: TerminalRect,
    text: String,
    foreground: TerminalColor,
    style: CellStyle,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    let blank = Cell(
        grapheme: " ",
        style: style,
        foreground: foreground,
        background: theme.background,
        displayWidth: 1
    )
    for x in area.x..<area.right {
        buffer.setCell(blank, x: x, y: area.y)
    }
    _ = buffer.setString(
        x: area.x,
        y: area.y,
        text: text,
        style: style,
        foreground: foreground,
        background: theme.background
    )
}

private func drawAlignedRow(
    leading: String,
    trailing: String?,
    area: TerminalRect,
    buffer: inout CellBuffer,
    foreground: TerminalColor,
    style: CellStyle,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    paintRow(&buffer, area: area, text: leading, foreground: foreground, style: style, theme: theme)
    guard let trailing, !trailing.isEmpty else { return }
    let trailingWidth = UnicodeDisplayWidth.width(of: trailing)
    let x = max(area.x, area.right - trailingWidth)
    _ = buffer.setString(
        x: x,
        y: area.y,
        text: trailing,
        style: style,
        foreground: foreground,
        background: theme.background
    )
}

private func wrapDisplayLines(_ text: String, width: Int) -> [String] {
    guard width > 0 else { return [] }
    let physicalLines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let physical = physicalLines.isEmpty ? [""] : physicalLines.map(String.init)
    var result: [String] = []
    for line in physical {
        if line.isEmpty {
            result.append("")
            continue
        }
        var current = ""
        var currentWidth = 0
        for grapheme in line {
            let string = String(grapheme)
            let graphemeWidth = max(0, UnicodeDisplayWidth.width(ofGrapheme: string))
            if graphemeWidth > 0 && !current.isEmpty && currentWidth + graphemeWidth > width {
                result.append(current)
                current = ""
                currentWidth = 0
            }
            current += string
            currentWidth += graphemeWidth
            if graphemeWidth > width {
                result.append(current)
                current = ""
                currentWidth = 0
            }
        }
        if !current.isEmpty || result.isEmpty { result.append(current) }
    }
    return result
}
