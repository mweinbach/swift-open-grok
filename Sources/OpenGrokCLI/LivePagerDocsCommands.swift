// LivePagerDocsCommands.swift
//
// The live backing for the in-pager `/docs` command: the How-to Guides list
// overlay and the guide content viewer, both built over the compile-time
// corpus in `PagerDocs`. The dispatch itself lives on
// `LiveInteractiveControllerRenderer` (LiveComposition.swift); this file
// holds what tests must reach without a terminal.

import OpenGrokPager
import OpenGrokPagerRender

/// The bare-`/docs` guides browser — upstream's "How-to Guides" DocPicker
/// (`views/modal.rs:161-168`, painted by `app/modals.rs:1248-1324`) as this
/// port's `.list` overlay, and the DocViewer a selection opens
/// (`app/modals.rs:1327-1345`) as the read-only text modal `/view-plan`'s
/// preview uses.
enum LiveHowtoGuidesPicker {
    static let overlayID = "howto-guides"
    static let viewerID = "howto-doc-viewer"

    /// Rows are the whole corpus in upstream's order — title as the label,
    /// description right-aligned (upstream's `PickerRow` label/right_label,
    /// `modals.rs:1283-1284`). The description goes in `detail`, not
    /// `summary`: the list painter draws `label` + right-aligned `detail`
    /// and uses `summary` only as a filter haystack, so a `summary`-carried
    /// description is computed and never painted. Row ids are titles, which
    /// `PagerDocs.find(title:)` resolves back to the doc on selection.
    static func overlay() -> PagerOverlay {
        .list(
            id: overlayID,
            title: "How-to Guides",
            rows: PagerDocs.all.map { doc in
                PagerListRow(id: doc.title, label: doc.title, detail: doc.description)
            }
        )
    }

    /// The guide content, markdown-rendered, titled with the doc title —
    /// upstream's DocViewer (`modals.rs:1336-1344`). Markdown that renders
    /// to nothing paints raw, split on `Character.isNewline` (AGENTS.md §2:
    /// the corpus is LF today, but a `"\n"` split would silently glue a
    /// CRLF file into one line).
    static func viewerOverlay(title: String, content: String) -> PagerOverlay {
        let rendered = PagerMarkdownRenderer().render(content)
        let lines = rendered.isEmpty
            ? content
                .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                .map { PagerStyledLine(text: String($0)) }
            : rendered
        return .sessionInfo(id: viewerID, title: title, lines: lines)
    }
}
