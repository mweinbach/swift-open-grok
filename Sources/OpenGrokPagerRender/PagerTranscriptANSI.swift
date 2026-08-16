import OpenGrokTerminalCore

public func pagerExpandedTranscriptANSI(
    items: [PagerConversationItem],
    width: Int,
    theme: PagerRenderTheme
) -> String {
    let contentWidth = max(1, width)
    var output = ""
    for (itemIndex, item) in items.enumerated() {
        let block = MinimalCommitRender.committedLines(
            item: item,
            displayMode: .expanded,
            width: contentWidth,
            theme: theme
        )
        for line in block.lines {
            if let accentGlyph = line.accentGlyph {
                output += pagerTranscriptSGR(
                    style: line.style,
                    foreground: line.accentColor ?? line.foreground,
                    background: line.background ?? .reset
                )
                output += accentGlyph
            }
            for span in line.spans {
                output += pagerTranscriptSGR(
                    style: line.style.union(span.style),
                    foreground: span.foreground ?? line.foreground,
                    background: span.background ?? line.background ?? .reset
                )
                output += span.text
            }
            output += "\u{1B}[0m\n"
        }
        if itemIndex < items.count - 1 {
            output += "\n"
        }
    }
    return output
}

private func pagerTranscriptSGR(
    style: CellStyle,
    foreground: TerminalColor,
    background: TerminalColor
) -> String {
    var codes = ["0"]
    if style.contains(.bold) { codes.append("1") }
    if style.contains(.dim) { codes.append("2") }
    if style.contains(.italic) { codes.append("3") }
    if style.contains(.underline) { codes.append("4") }
    if style.contains(.blink) { codes.append("5") }
    if style.contains(.reverse) { codes.append("7") }
    if style.contains(.hidden) { codes.append("8") }
    if style.contains(.strike) { codes.append("9") }
    codes.append(contentsOf: pagerTranscriptColorCodes(foreground, foreground: true))
    codes.append(contentsOf: pagerTranscriptColorCodes(background, foreground: false))
    return "\u{1B}[\(codes.joined(separator: ";"))m"
}

private func pagerTranscriptColorCodes(
    _ color: TerminalColor,
    foreground: Bool
) -> [String] {
    let base = foreground ? 30 : 40
    let bright = foreground ? 90 : 100
    switch color {
    case .reset: return []
    case .black: return ["\(base)"]
    case .red: return ["\(base + 1)"]
    case .green: return ["\(base + 2)"]
    case .yellow: return ["\(base + 3)"]
    case .blue: return ["\(base + 4)"]
    case .magenta: return ["\(base + 5)"]
    case .cyan: return ["\(base + 6)"]
    case .white: return ["\(base + 7)"]
    case .brightBlack: return ["\(bright)"]
    case .brightRed: return ["\(bright + 1)"]
    case .brightGreen: return ["\(bright + 2)"]
    case .brightYellow: return ["\(bright + 3)"]
    case .brightBlue: return ["\(bright + 4)"]
    case .brightMagenta: return ["\(bright + 5)"]
    case .brightCyan: return ["\(bright + 6)"]
    case .brightWhite: return ["\(bright + 7)"]
    case .indexed(let value):
        return [foreground ? "38" : "48", "5", "\(value)"]
    case .rgb(let red, let green, let blue):
        return [foreground ? "38" : "48", "2", "\(red)", "\(green)", "\(blue)"]
    }
}
