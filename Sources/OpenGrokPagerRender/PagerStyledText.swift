import Foundation
import OpenGrokTerminalCore

/// A run of characters inside a conversation line that shares one set of paint
/// attributes.
///
/// `foreground == nil` means "inherit" — the frame painter substitutes the
/// foreground the surrounding item would otherwise have used (the message role
/// color), so producers only have to name the colors they actually override.
public struct PagerStyledSpan: Sendable, Equatable, Hashable {
    public var text: String
    public var foreground: TerminalColor?
    public var style: CellStyle
    /// Hyperlink target. Populated spans are emitted as `LinkSpan`s on the
    /// render result so terminals with OSC 8 support make them clickable.
    public var url: String?

    public init(
        text: String,
        foreground: TerminalColor? = nil,
        style: CellStyle = [],
        url: String? = nil
    ) {
        self.text = text
        self.foreground = foreground
        self.style = style
        self.url = url
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// One pre-composed, styled logical line of conversation content.
///
/// Lines are already laid out by their producer (a markdown renderer, say);
/// the frame painter only wraps them to the content width and paints them.
public struct PagerStyledLine: Sendable, Equatable, Hashable {
    public var spans: [PagerStyledSpan]

    public init(spans: [PagerStyledSpan]) {
        self.spans = spans
    }

    public init(text: String, foreground: TerminalColor? = nil, style: CellStyle = []) {
        self.init(spans: [PagerStyledSpan(text: text, foreground: foreground, style: style)])
    }

    /// The line with all styling dropped — the plain-text fallback.
    public var text: String {
        spans.map(\.text).joined()
    }

    public var isEmpty: Bool {
        spans.allSatisfy(\.isEmpty)
    }
}

/// Wrap styled spans to `width` display columns, splitting spans that straddle
/// a wrap point so every returned row is at most `width` columns wide.
///
/// Wrapping is grapheme-wise for the same reason `wrapDisplayLines` is: the
/// conversation pane has no word-wrap contract to preserve, and a mid-word
/// break is better than an overflowing row.
func wrapStyledSpans(_ spans: [PagerStyledSpan], width: Int) -> [[PagerStyledSpan]] {
    guard width > 0 else { return [] }
    var rows: [[PagerStyledSpan]] = []
    var currentRow: [PagerStyledSpan] = []
    var currentSpan: PagerStyledSpan?
    var currentWidth = 0

    func flushSpan() {
        if let currentSpan, !currentSpan.text.isEmpty {
            currentRow.append(currentSpan)
        }
        currentSpan = nil
    }

    func flushRow() {
        flushSpan()
        rows.append(currentRow)
        currentRow = []
        currentWidth = 0
    }

    for span in spans {
        if span.text.isEmpty { continue }
        if currentSpan != nil { flushSpan() }
        currentSpan = PagerStyledSpan(
            text: "",
            foreground: span.foreground,
            style: span.style,
            url: span.url
        )
        for grapheme in span.text {
            let string = String(grapheme)
            let graphemeWidth = max(0, UnicodeDisplayWidth.width(ofGrapheme: string))
            if graphemeWidth > 0, currentWidth + graphemeWidth > width, currentWidth > 0 {
                let carried = currentSpan
                flushRow()
                currentSpan = PagerStyledSpan(
                    text: "",
                    foreground: carried?.foreground ?? span.foreground,
                    style: carried?.style ?? span.style,
                    url: carried?.url ?? span.url
                )
            }
            currentSpan?.text += string
            currentWidth += graphemeWidth
        }
    }

    flushSpan()
    if !currentRow.isEmpty || rows.isEmpty {
        rows.append(currentRow)
    }
    return rows
}
