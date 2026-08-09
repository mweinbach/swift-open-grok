// PagerPrivacyBannerRender.swift
//
// The privacy banner's paint — `views/privacy_banner.rs` (435 lines at pin
// 650c1db7), ported whole. Upstream's header: the coding-data sharing
// upsell banner (Figma "Data Sharing Upsell", node 8698:3690), shared by
// the welcome tip slot and the agent-view banner slot, visibility gated by
// `AppView::privacy_banner_should_show` (the B9-c1 port,
// `PagerPrivacyBanner.swift`). In this port only the agent-view slot
// exists: the banner is the SECOND tenant of the frame chrome's
// announcement-banner slot (the B9 research's seam correction — frame
// chrome, not a `PagerOverlayContent` case), and the welcome tip-slot
// placement is deferred with the Wave 18 B2 welcome build-out. Cost of
// that deferral: upstream shows this banner on the welcome screen first
// (privacy_banner_e2e.rs drives it there); here the welcome overlay
// overpaints the slot, so the banner is first visible once the first turn
// dismisses the welcome hero.
//
// KEPT DIVERGENCE (the recorded E20/E21 missing-channel divergence):
// upstream's `render` takes `mouse_pos` and brightens hovered links and
// buttons (privacy_banner.rs:166-168, :223-228, :265-274). This port has
// no mouse-position channel into the frame builder, so every element
// paints its non-hovered style. Cost: no hover affordance; the click
// targets themselves are unchanged.

import Foundation
import OpenGrokTerminalCore

// MARK: - Copy (byte-parity with privacy_banner.rs:13-50)

/// Shares its row with the buttons (privacy_banner.rs:12-13).
let pagerPrivacyBannerTitle = "Help improve Open Grok"
/// Narrow-slot fallback so the title is never clipped (:14).
let pagerPrivacyBannerCompactTitle = "Improve Open Grok"

/// The fixed disclosure copy (:16-18; Rust's `\`-continuations splice to
/// one single-spaced line).
let pagerPrivacyBannerDescription = "Off by default. Opt-in to allow SpaceXAI "
    + "to retain coding data, e.g., prompts, traces, & metrics, for training "
    + "and debugging purposes. Change anytime via settings."

/// Public: the composition's click router opens these through the browser
/// seam (:20-21; the click resolution upstream is `Action::OpenUrl`,
/// agent_view/links.rs:635-651).
public let pagerPrivacyBannerTermsURL = "https://x.ai/legal/terms-of-service"
public let pagerPrivacyBannerPolicyURL = "https://x.ai/legal/privacy-policy"

let pagerPrivacyBannerOptOutLabel = "[Opt out]"
let pagerPrivacyBannerOptInLabel = "[Opt in]"

/// Title + legal (:52-53).
private let privacyBannerChromeRows = 2

/// `MIN_HEIGHT = CHROME_ROWS + 1` (:55). Below this the render paints
/// nothing and arms no hit rects.
let pagerPrivacyBannerMinHeight = privacyBannerChromeRows + 1

/// Caps banner growth on narrow terminals; overflow is elided with `…` so
/// the disclosure never looks complete when it isn't (:57-59).
private let privacyBannerMaxBodyRows = 4

/// Past this, the body abandons the button column for the full slot width:
/// a shorter banner beats a tidy right edge (:61-63).
private let privacyBannerPreferredBodyRows = 3

/// One legal-line segment: text plus the URL when it is a link (:23-24).
struct PagerPrivacyBannerLegalSegment: Sendable, Equatable {
    var text: String
    var url: String?
}

/// Widest first; the first that fits *whole* wins. A clipped line would
/// leave hit rects over unreadable link text, and every variant keeps both
/// links so neither document becomes unreachable (:26-47).
let pagerPrivacyBannerLegalVariants: [[PagerPrivacyBannerLegalSegment]] = [
    [
        PagerPrivacyBannerLegalSegment(text: "Read "),
        PagerPrivacyBannerLegalSegment(text: "Terms", url: pagerPrivacyBannerTermsURL),
        PagerPrivacyBannerLegalSegment(text: " and "),
        PagerPrivacyBannerLegalSegment(text: "Privacy Policy", url: pagerPrivacyBannerPolicyURL),
        PagerPrivacyBannerLegalSegment(text: "."),
    ],
    [
        PagerPrivacyBannerLegalSegment(text: "Terms", url: pagerPrivacyBannerTermsURL),
        PagerPrivacyBannerLegalSegment(text: " and "),
        PagerPrivacyBannerLegalSegment(text: "Privacy Policy", url: pagerPrivacyBannerPolicyURL),
    ],
    [
        PagerPrivacyBannerLegalSegment(text: "Terms", url: pagerPrivacyBannerTermsURL),
        PagerPrivacyBannerLegalSegment(text: " & "),
        PagerPrivacyBannerLegalSegment(text: "Privacy", url: pagerPrivacyBannerPolicyURL),
    ],
]

// MARK: - Hit rects

/// The four click targets a painted banner arms — upstream's
/// `PrivacyBannerRects` (:65-81) with `nil` where upstream returns
/// `Rect::default()`: an absent rect can never hit-test true, and an
/// Optional makes "no target" unmistakable at the click router.
public struct PagerPrivacyBannerHitRects: Sendable, Equatable {
    public var optIn: TerminalRect?
    public var optOut: TerminalRect?
    public var terms: TerminalRect?
    public var policy: TerminalRect?

    public init(
        optIn: TerminalRect? = nil,
        optOut: TerminalRect? = nil,
        terms: TerminalRect? = nil,
        policy: TerminalRect? = nil
    ) {
        self.optIn = optIn
        self.optOut = optOut
        self.terms = terms
        self.policy = policy
    }
}

// MARK: - Geometry (all copy is ASCII, so `count` is display width, as
// upstream's `len()` is)

private func privacyBannerButtonBlockWidth() -> Int {
    pagerPrivacyBannerOptOutLabel.count + 1 + pagerPrivacyBannerOptInLabel.count
}

private func privacyBannerLegalWidth(_ variant: [PagerPrivacyBannerLegalSegment]) -> Int {
    variant.reduce(0) { $0 + $1.text.count }
}

/// Buttons render whole or not at all, and never at the cost of the title:
/// a clipped/overflowing `[Opt in]` must not leave a click target in the
/// blank margin (a stray click there would silently opt the user in)
/// (:91-96).
func pagerPrivacyBannerButtonsFit(width: Int) -> Bool {
    width >= pagerPrivacyBannerTitle.count + 1 + privacyBannerButtonBlockWidth()
}

func pagerPrivacyBannerTitleWidth(width: Int) -> Int {
    if pagerPrivacyBannerButtonsFit(width: width) {
        return width - privacyBannerButtonBlockWidth() - 1
    }
    return width
}

func pagerPrivacyBannerTitleText(width: Int) -> String {
    if pagerPrivacyBannerTitleWidth(width: width) >= pagerPrivacyBannerTitle.count {
        return pagerPrivacyBannerTitle
    }
    return pagerPrivacyBannerCompactTitle
}

// MARK: - Body wrap (textwrap FirstFit, :114-120)

/// A wrap unit: a whole word, or a hyphen-split piece of one. `glued`
/// means "continues the previous fragment mid-word" — no space before it.
private struct PrivacyBannerWrapFragment {
    var text: String
    var glued: Bool
}

/// Split the description the way `textwrap::wrap` with `FirstFit` does:
/// whitespace-separated words, each further split after an internal hyphen
/// flanked by alphanumerics (textwrap's default `HyphenSplitter` — the one
/// word this matters for here is `Opt-in`).
private func privacyBannerWrapFragments() -> [PrivacyBannerWrapFragment] {
    var fragments: [PrivacyBannerWrapFragment] = []
    for word in pagerPrivacyBannerDescription.split(separator: " ") {
        let characters = Array(word)
        var start = 0
        var pieceIndex = 0
        for index in characters.indices {
            guard characters[index] == "-",
                  index > start,
                  index + 1 < characters.count,
                  characters[index - 1].isLetter || characters[index - 1].isNumber,
                  characters[index + 1].isLetter || characters[index + 1].isNumber
            else { continue }
            fragments.append(PrivacyBannerWrapFragment(
                text: String(characters[start...index]),
                glued: pieceIndex > 0
            ))
            start = index + 1
            pieceIndex += 1
        }
        fragments.append(PrivacyBannerWrapFragment(
            text: String(characters[start...]),
            glued: pieceIndex > 0
        ))
    }
    return fragments
}

/// Greedy first-fit wrap of the fixed description (:114-120). A zero
/// width wraps to nothing, exactly upstream's early return.
func pagerPrivacyBannerWrap(width: Int) -> [String] {
    guard width > 0 else { return [] }
    var lines: [String] = []
    var current = ""
    for fragment in privacyBannerWrapFragments() {
        let separator = (current.isEmpty || fragment.glued) ? "" : " "
        if !current.isEmpty, current.count + separator.count + fragment.text.count > width {
            lines.append(current)
            current = ""
        }
        var text = fragment.text
        // textwrap's default `break_words`: a fragment wider than the whole
        // line is hard-broken so wrapping always terminates. Unreachable
        // for this description at any width the invariants pin, kept so a
        // pathological slot cannot loop.
        while current.isEmpty, text.count > width {
            lines.append(String(text.prefix(width)))
            text = String(text.dropFirst(width))
        }
        current += (current.isEmpty ? "" : separator) + text
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// The wrapped body for a slot `width` (:122-146): the title-column wrap
/// when it stays within the preferred rows, else whichever of the
/// full-width and column wraps is shorter, capped at `MAX_BODY_ROWS` with
/// the overflow elided to `…`.
func pagerPrivacyBannerBodyLines(width: Int) -> [String] {
    let column = pagerPrivacyBannerWrap(width: pagerPrivacyBannerTitleWidth(width: width))
    var lines: [String]
    if column.count <= privacyBannerPreferredBodyRows {
        lines = column
    } else {
        let full = pagerPrivacyBannerWrap(width: width)
        lines = full.count < column.count ? full : column
    }
    if lines.count > privacyBannerMaxBodyRows {
        lines.removeSubrange(privacyBannerMaxBodyRows...)
        if var last = lines.last {
            while last.hasSuffix(" ") { last.removeLast() }
            // Upstream measures the ellipsis room against the FULL slot
            // width, not the wrap column (:138) — port the same read.
            while last.count + 1 > width { last.removeLast() }
            last.append("\u{2026}")
            lines[lines.count - 1] = last
        }
    }
    return lines
}

/// Rows needed at `width` — the body wraps, so the slot owner must size
/// from this rather than a constant (:148-152).
func pagerPrivacyBannerHeight(width: Int) -> Int {
    privacyBannerChromeRows + max(1, pagerPrivacyBannerBodyLines(width: width).count)
}

// MARK: - Paint (:154-295)

/// Needs `area.height >= pagerPrivacyBannerMinHeight`; give it
/// `pagerPrivacyBannerHeight(width:)` rows for the full body.
func renderPagerPrivacyBanner(
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> PagerPrivacyBannerHitRects {
    guard area.height >= pagerPrivacyBannerMinHeight, area.width > 0 else {
        return PagerPrivacyBannerHitRects()
    }
    paintBlank(&buffer, area: area, foreground: theme.textPrimary, background: theme.bgBase)

    // Title, clipped to its column exactly as `set_stringn` clips
    // (:170-177; Figma node 8698:3806).
    let titleWidth = pagerPrivacyBannerTitleWidth(width: area.width)
    buffer.setString(
        x: area.x,
        y: area.y,
        text: truncateToWidth(pagerPrivacyBannerTitleText(width: area.width), width: titleWidth),
        style: [],
        foreground: theme.textPrimary,
        background: theme.bgBase
    )

    // Body rows between the title and the legal line (:179-194).
    let bodyRows = area.height - privacyBannerChromeRows
    for (index, line) in pagerPrivacyBannerBodyLines(width: area.width)
        .prefix(bodyRows).enumerated() {
        buffer.setString(
            x: area.x,
            y: area.y + 1 + index,
            text: truncateToWidth(line, width: area.width),
            style: [],
            foreground: theme.grayBright,
            background: theme.bgBase
        )
    }

    // Last row, so it gets the full width — no buttons to dodge (:196-243).
    let legalY = area.y + area.height - 1
    var termsRect: TerminalRect?
    var policyRect: TerminalRect?
    if let variant = pagerPrivacyBannerLegalVariants
        .first(where: { privacyBannerLegalWidth($0) <= area.width }) {
        var x = area.x
        for segment in variant {
            let segmentWidth = segment.text.count
            if let url = segment.url {
                let rect = TerminalRect(x: x, y: legalY, width: segmentWidth, height: 1)
                if url == pagerPrivacyBannerTermsURL {
                    termsRect = rect
                } else {
                    policyRect = rect
                }
                buffer.setString(
                    x: x,
                    y: legalY,
                    text: segment.text,
                    style: [.underline],
                    foreground: theme.gray,
                    background: theme.bgBase
                )
            } else {
                buffer.setString(
                    x: x,
                    y: legalY,
                    text: segment.text,
                    style: [],
                    foreground: theme.gray,
                    background: theme.bgBase
                )
            }
            x += segmentWidth
        }
    }

    // Buttons render whole or not at all — a clipped `[Opt in]` must not
    // leave a click target in the blank margin where a stray click would
    // silently opt the user in (:245-252 over the :91-93 guard).
    guard pagerPrivacyBannerButtonsFit(width: area.width) else {
        return PagerPrivacyBannerHitRects(terms: termsRect, policy: policyRect)
    }
    let optOutRect = TerminalRect(
        x: area.x + area.width - privacyBannerButtonBlockWidth(),
        y: area.y,
        width: pagerPrivacyBannerOptOutLabel.count,
        height: 1
    )
    let optInRect = TerminalRect(
        x: optOutRect.x + optOutRect.width + 1,
        y: area.y,
        width: pagerPrivacyBannerOptInLabel.count,
        height: 1
    )
    buffer.setString(
        x: optOutRect.x,
        y: optOutRect.y,
        text: pagerPrivacyBannerOptOutLabel,
        style: [],
        foreground: theme.grayBright,
        background: theme.bgBase
    )
    buffer.setString(
        x: optInRect.x,
        y: optInRect.y,
        text: pagerPrivacyBannerOptInLabel,
        style: [],
        foreground: theme.textPrimary,
        background: theme.bgBase
    )
    return PagerPrivacyBannerHitRects(
        optIn: optInRect,
        optOut: optOutRect,
        terms: termsRect,
        policy: policyRect
    )
}
