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
    /// Per-span background override; `nil` inherits the paint run's
    /// background (upstream spans carry their own `Style` bg — the context
    /// bar's unfilled cells are the first consumer, `context_bar.rs:245`).
    public var background: TerminalColor?

    public init(
        text: String,
        foreground: TerminalColor? = nil,
        style: CellStyle = [],
        url: String? = nil,
        background: TerminalColor? = nil
    ) {
        self.text = text
        self.foreground = foreground
        self.style = style
        self.url = url
        self.background = background
    }

    public var isEmpty: Bool { text.isEmpty }
}

public enum PagerStyledLineBackground: Sendable, Equatable, Hashable {
    case code
}

/// One pre-composed, styled logical line of conversation content.
///
/// Lines are already laid out by their producer (a markdown renderer, say);
/// the frame painter only wraps them to the content width and paints them.
public struct PagerStyledLine: Sendable, Equatable, Hashable {
    public var spans: [PagerStyledSpan]
    public var background: PagerStyledLineBackground?
    /// Optional copy/selection text when painted decoration differs from the
    /// semantic line (quote bars are the first consumer).
    public var selectionText: String?

    public init(
        spans: [PagerStyledSpan],
        background: PagerStyledLineBackground? = nil,
        selectionText: String? = nil
    ) {
        self.spans = spans
        self.background = background
        self.selectionText = selectionText
    }

    public init(
        text: String,
        foreground: TerminalColor? = nil,
        style: CellStyle = [],
        background: PagerStyledLineBackground? = nil,
        selectionText: String? = nil
    ) {
        self.init(
            spans: [PagerStyledSpan(text: text, foreground: foreground, style: style)],
            background: background,
            selectionText: selectionText
        )
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
            url: span.url,
            background: span.background
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
                    url: carried?.url ?? span.url,
                    background: carried?.background ?? span.background
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
