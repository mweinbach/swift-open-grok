// FileSearchTests.swift
//
// Tests for @-completion context detection, file search state, and dropdown rendering.

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

@Suite("File Search Context Detection")
struct FileSearchContextTests {
    @Test("basic @-token detection")
    func basicAtToken() {
        let ctx = detect(text: "@foo", cursor: 4)
        #expect(ctx != nil)
        #expect(ctx?.range == 0..<4)
        #expect(ctx?.query == "foo")
        #expect(ctx?.isDirMode == false)
        #expect(ctx?.isHiddenMode == false)
        #expect(ctx?.matcherQuery == "foo")
    }

    @Test("@-token with prefix text")
    func atWithPrefixText() {
        let ctx = detect(text: "hello @bar/baz", cursor: 14)
        #expect(ctx != nil)
        #expect(ctx?.range == 6..<14)
        #expect(ctx?.query == "bar/baz")
        #expect(ctx?.isDirMode == false)
    }

    @Test("cursor placed mid-token")
    func cursorMidToken() {
        let ctx = detect(text: "@foo/bar", cursor: 5)
        #expect(ctx != nil)
        #expect(ctx?.range == 0..<8)
        #expect(ctx?.query == "foo/")
        #expect(ctx?.isDirMode == true)
    }

    @Test("cursor at @ sign only")
    func cursorAtSignOnly() {
        let ctx = detect(text: "@", cursor: 1)
        #expect(ctx != nil)
        #expect(ctx?.range == 0..<1)
        #expect(ctx?.query == "")
        #expect(ctx?.isDirMode == false)
        #expect(ctx?.isHiddenMode == false)
    }

    @Test("rejected email-like strings")
    func rejectedEmailLike() {
        #expect(detect(text: "user@example", cursor: 12) == nil)
        #expect(detect(text: "test_@foo", cursor: 9) == nil)
        #expect(detect(text: "foo123@bar", cursor: 10) == nil)
    }

    @Test("cursor placed past token")
    func cursorPastToken() {
        #expect(detect(text: "@foo bar", cursor: 5) == nil)
        #expect(detect(text: "@foo bar", cursor: 8) == nil)
    }

    @Test("hidden mode with leading !")
    func hiddenMode() {
        let ctx = detect(text: "@!foo", cursor: 5)
        #expect(ctx != nil)
        #expect(ctx?.isHiddenMode == true)
        #expect(ctx?.matcherQuery == "foo")
    }

    @Test("dir mode with trailing /")
    func dirMode() {
        let ctx = detect(text: "@src/", cursor: 5)
        #expect(ctx != nil)
        #expect(ctx?.isDirMode == true)
        #expect(ctx?.query == "src/")
        #expect(ctx?.matcherQuery == "src/")
    }

    @Test("hidden dir mode with ! and /")
    func hiddenDirMode() {
        let ctx = detect(text: "@!.config/", cursor: 10)
        #expect(ctx != nil)
        #expect(ctx?.isHiddenMode == true)
        #expect(ctx?.isDirMode == true)
        #expect(ctx?.matcherQuery == ".config/")
    }

    @Test("multiple @ picks rightmost before cursor")
    func multipleAtPicksRightmost() {
        let ctx = detect(text: "@first @second", cursor: 14)
        #expect(ctx != nil)
        #expect(ctx?.query == "second")
        #expect(ctx?.range == 7..<14)
    }

    @Test("@ after special characters triggers successfully")
    func atAfterSpecialChars() {
        #expect(detect(text: "(@foo", cursor: 5) != nil)
        #expect(detect(text: " @foo", cursor: 5) != nil)
        #expect(detect(text: ",@foo", cursor: 5) != nil)
        #expect(detect(text: ";@foo", cursor: 5) != nil)
    }

    @Test("empty text and zero cursor")
    func emptyTextAndZeroCursor() {
        #expect(detect(text: "", cursor: 0) == nil)
        #expect(detect(text: "@foo", cursor: 0) == nil)
    }

    @Test("normalize display path")
    func normalizePath() {
        #expect(normalizeDisplayPath("./foo/bar") == "foo/bar")
        #expect(normalizeDisplayPath("foo/bar") == "foo/bar")
        #expect(normalizeDisplayPath("./") == "")
    }

    @Test("token delimited by comma or semicolon")
    func tokenDelimitedByPunctuation() {
        let commaCtx = detect(text: "@foo,@bar", cursor: 4)
        #expect(commaCtx != nil)
        #expect(commaCtx?.range == 0..<4)
        #expect(commaCtx?.query == "foo")

        let semiCtx = detect(text: "@foo;rest", cursor: 4)
        #expect(semiCtx != nil)
        #expect(semiCtx?.range == 0..<4)
        #expect(semiCtx?.query == "foo")
    }

    @Test("pathRange calculation")
    func pathRangeCalculation() {
        let plain = detect(text: "@src/foo", cursor: 8)
        #expect(plain?.range == 0..<8)
        #expect(plain?.pathRange == 1..<8)

        let hidden = detect(text: "@!src/foo", cursor: 9)
        #expect(hidden?.isHiddenMode == true)
        #expect(hidden?.range == 0..<9)
        #expect(hidden?.pathRange == 2..<9)

        let withOffset = detect(text: "hello @bar", cursor: 10)
        #expect(withOffset?.range == 6..<10)
        #expect(withOffset?.pathRange == 7..<10)
    }
}

@Suite("File Search Drill-Aware Detection")
struct FileSearchDrillTests {
    @Test("drill prefix allows internal space")
    func drillPrefixAllowsInternalSpace() {
        let ctx = detectWithDrill(text: "@my dir", cursor: 7, drillPrefix: "my dir")
        #expect(ctx != nil)
        #expect(ctx?.range == 0..<7)
        #expect(ctx?.query == "my dir")
        #expect(ctx?.isDirMode == false)
    }

    @Test("drill prefix enters dir mode with trailing slash")
    func drillPrefixEntersDirModeWithTrailingSlash() {
        let ctx = detectWithDrill(text: "@my dir/", cursor: 8, drillPrefix: "my dir")
        #expect(ctx != nil)
        #expect(ctx?.query == "my dir/")
        #expect(ctx?.isDirMode == true)
    }

    @Test("drill prefix allows internal tab")
    func drillPrefixAllowsInternalTab() {
        let ctx = detectWithDrill(text: "@my\tdir", cursor: 7, drillPrefix: "my\tdir")
        #expect(ctx != nil)
        #expect(ctx?.range == 0..<7)
        #expect(ctx?.query == "my\tdir")
    }

    @Test("drill prefix with hidden mode")
    func drillPrefixWithHiddenMode() {
        let ctx = detectWithDrill(text: "@!my dir", cursor: 8, drillPrefix: "my dir")
        #expect(ctx != nil)
        #expect(ctx?.isHiddenMode == true)
        #expect(ctx?.matcherQuery == "my dir")
    }

    @Test("drill prefix mismatch falls back to whitespace terminator")
    func drillPrefixMismatchFallsBack() {
        #expect(detectWithDrill(text: "@foo bar", cursor: 8, drillPrefix: "my dir") == nil)
    }

    @Test("drill prefix whitespace after prefix terminates")
    func drillPrefixWhitespaceAfterTerminates() {
        #expect(detectWithDrill(text: "@my dir extra", cursor: 13, drillPrefix: "my dir") == nil)
    }

    @Test("drill prefix cursor mid token")
    func drillPrefixCursorMidToken() {
        let ctx = detectWithDrill(text: "@my dir/sub", cursor: 5, drillPrefix: "my dir")
        #expect(ctx != nil)
        #expect(ctx?.range == 0..<11)
        #expect(ctx?.query == "my d")
    }

    @Test("drill prefix inert when backspaced out of prefix")
    func drillPrefixInertWhenBackspaced() {
        #expect(detectWithDrill(text: "@my di", cursor: 6, drillPrefix: "my dir") == nil)
    }

    @Test("drill prefix allows multibyte dir name")
    func drillPrefixAllowsMultibyte() {
        let ctx = detectWithDrill(text: "@café dir", cursor: 9, drillPrefix: "café dir")
        #expect(ctx != nil)
        #expect(ctx?.range == 0..<9)
        #expect(ctx?.query == "café dir")
    }

    @Test("drill prefix empty collapses to no prefix")
    func drillPrefixEmptyCollapses() {
        #expect(detectWithDrill(text: "@my dir", cursor: 7, drillPrefix: "") == nil)
    }

    @Test("drill prefix allows second-level space segment")
    func drillPrefixAllowsSecondLevelSpace() {
        let ctx = detectWithDrill(text: "@a b/c d", cursor: 8, drillPrefix: "a b/c d")
        #expect(ctx != nil)
        #expect(ctx?.range == 0..<8)
        #expect(ctx?.query == "a b/c d")
    }
}

@Suite("File Search State & Replacement")
struct FileSearchStateTests {
    @Test("tryReplace commits directory already present at end of prompt")
    func tryReplaceCommitsDirectoryAtEnd() {
        var state = FileSearchState(root: ".")
        let src = "@src/"
        let ctx = detect(text: src, cursor: src.count)!
        state.setTestState(
            context: ctx,
            results: [FuzzyMatchResult(path: "src", isDir: true)],
            selected: 0
        )

        let r = state.tryReplace(src: src)
        #expect(r != nil)
        #expect(r?.dismiss == true)
        #expect(r?.range == 1..<5)
        #expect(r?.text == "src/ ")
        #expect(r?.cursor == 6)
    }

    @Test("tryReplace commits directory mid-prompt")
    func tryReplaceCommitsDirectoryMidPrompt() {
        var state = FileSearchState(root: ".")
        let src = "@src/ tail"
        let ctx = detect(text: src, cursor: 5)!
        state.setTestState(
            context: ctx,
            results: [FuzzyMatchResult(path: "src", isDir: true)],
            selected: 0
        )

        let r = state.tryReplace(src: src)
        #expect(r != nil)
        #expect(r?.dismiss == true)
        #expect(r?.text == "src/")
        #expect(r?.cursor == 6)
    }

    @Test("tryReplace on non-dir or non-dir-mode returns nil")
    func tryReplaceNonDirReturnsNil() {
        var state = FileSearchState(root: ".")
        let src = "@src/file.swift"
        let ctx = detect(text: src, cursor: src.count)!

        // Result is not a directory
        state.setTestState(
            context: ctx,
            results: [FuzzyMatchResult(path: "src/file.swift", isDir: false)],
            selected: 0
        )
        #expect(state.tryReplace(src: src) == nil)

        // Context is not dir mode
        let plainSrc = "@src"
        let plainCtx = detect(text: plainSrc, cursor: plainSrc.count)!
        state.setTestState(
            context: plainCtx,
            results: [FuzzyMatchResult(path: "src", isDir: true)],
            selected: 0
        )
        #expect(state.tryReplace(src: plainSrc) == nil)
    }

    @Test("navigation methods: selectNext, selectPrevious, selectFirst, selectLast")
    func navigationSelection() {
        var state = FileSearchState(root: ".")
        let results = [
            FuzzyMatchResult(path: "a"),
            FuzzyMatchResult(path: "b"),
            FuzzyMatchResult(path: "c"),
        ]
        let ctx = detect(text: "@a", cursor: 2)!
        state.setTestState(context: ctx, results: results, selected: 0)

        #expect(state.selected == 0)
        state.selectNext()
        #expect(state.selected == 1)
        state.selectNext()
        #expect(state.selected == 2)
        state.selectNext() // clamped at max
        #expect(state.selected == 2)

        state.selectPrevious()
        #expect(state.selected == 1)
        state.selectFirst()
        #expect(state.selected == 0)
        state.selectPrevious() // clamped at 0
        #expect(state.selected == 0)

        state.selectLast()
        #expect(state.selected == 2)
    }

    @Test("scroll navigation: scrollUp, scrollDown, ensureVisible, pageMove")
    func scrollNavigation() {
        var state = FileSearchState(root: ".")
        let results = (0..<10).map { FuzzyMatchResult(path: "item_\($0)") }
        let ctx = detect(text: "@item", cursor: 5)!
        state.setTestState(context: ctx, results: results, selected: 0)

        state.scrollDown(rows: 2)
        #expect(state.scrollOffset == 2)
        state.scrollUp(rows: 1)
        #expect(state.scrollOffset == 1)

        state.moveSelection(delta: 8)
        #expect(state.selected == 8)
        state.ensureVisible(visibleRows: 4)
        #expect(state.scrollOffset == 5) // 8 + 1 - 4 = 5

        state.pageMove(delta: -1, visibleRows: 4) // moves by -2
        #expect(state.selected == 6)
    }

    @Test("hover selection and selection updates")
    func hoverSelection() {
        var state = FileSearchState(root: ".")
        let results = [FuzzyMatchResult(path: "first"), FuzzyMatchResult(path: "second")]
        let ctx = detect(text: "@f", cursor: 2)!
        state.setTestState(context: ctx, results: results, selected: 0)

        #expect(state.setHovered(1) == true)
        #expect(state.hovered == 1)
        #expect(state.setHovered(1) == false) // no change

        #expect(state.selectHovered() == true)
        #expect(state.selected == 1)

        state.setHovered(nil)
        #expect(state.selectHovered() == false)
    }

    @Test("stale generation fence via minGeneration")
    func staleGenerationFence() {
        var state = FileSearchState(root: ".")
        let ctx = detect(text: "@a", cursor: 2)!
        state.updateContext(text: "@a", cursor: 2)
        let gen1 = state.minGeneration

        let staleResults = FuzzyMatcherDaemonResults(
            topk: [FuzzyMatchResult(path: "old")],
            numItems: 1,
            isDone: true,
            generation: gen1 - 1
        )
        #expect(state.setResults(staleResults) == false)

        let freshResults = FuzzyMatcherDaemonResults(
            topk: [FuzzyMatchResult(path: "new")],
            numItems: 1,
            isDone: true,
            generation: gen1
        )
        #expect(state.setResults(freshResults) == true)
        #expect(state.results.topk.first?.path == "new")
    }

    @Test("context update transitions and retarget")
    func contextTransitionsAndRetarget() {
        var state = FileSearchState(root: "/tmp")
        #expect(state.isVisible == false)

        state.updateContext(text: "@foo", cursor: 4)
        #expect(state.context != nil)
        #expect(state.context?.query == "foo")

        state.setTestState(
            context: state.context!,
            results: [FuzzyMatchResult(path: "foo.txt")],
            selected: 0
        )
        #expect(state.isVisible == true)
        #expect(state.resultCount == 1)
        #expect(state.totalItems == 1)

        state.updateContext(text: "plain text", cursor: 5)
        #expect(state.context == nil)
        #expect(state.isVisible == false)

        state.retarget(root: "/new/path")
        #expect(state.root == "/new/path")
        #expect(state.context == nil)
    }
}

@Suite("File Search Dropdown Rendering")
struct FileSearchDropdownRenderTests {
    @Test("dropdown height calculation")
    func dropdownHeightCalculation() {
        #expect(FileSearchDropdown.dropdownHeight(resultCount: 0, isVisible: false) == 0)
        #expect(FileSearchDropdown.dropdownHeight(resultCount: 5, isVisible: false) == 0)
        #expect(FileSearchDropdown.dropdownHeight(resultCount: 0, isVisible: true) == 0)
        #expect(FileSearchDropdown.dropdownHeight(resultCount: 3, isVisible: true) == 4) // 1 + 3
        #expect(FileSearchDropdown.dropdownHeight(resultCount: 15, isVisible: true, maxRows: 8) == 9) // 1 + 8
    }

    @Test("renderDropdown basic row with prompt arrow and matched chars")
    func renderDropdownBasic() {
        let area = TerminalRect(x: 0, y: 0, width: 30, height: 3)
        var buffer = CellBuffer(area: area)
        let theme = PagerRenderTheme()

        let items = [
            FuzzyMatchResult(path: "Sources/OpenGrokPager/FileSearch.swift", score: 100, indices: [0, 1, 2], isDir: false),
            FuzzyMatchResult(path: "Tests/FileSearchTests.swift", score: 80, indices: [0, 1], isDir: false),
        ]

        FileSearchDropdown.renderDropdown(
            buffer: &buffer,
            area: area,
            results: items,
            selected: 0,
            hovered: nil,
            scrollOffset: 0,
            isDirMode: false,
            theme: theme
        )

        // Row 0 is selected: should have prompt arrow ("❯ ")
        let arrowCell0 = buffer.cell(x: 0, y: 0)
        let arrowCell1 = buffer.cell(x: 1, y: 0)
        #expect(arrowCell0?.grapheme == "❯")
        #expect(arrowCell1?.grapheme == " ")
        #expect(arrowCell0?.background == theme.bgVisual)

        // Matched chars in row 0 should have fuzzyAccent foreground
        let charCell0 = buffer.cell(x: 2, y: 0) // 'S' in Sources
        #expect(charCell0?.grapheme == "S")
        #expect(charCell0?.foreground == theme.fuzzyAccent)

        // Row 1 is not selected: blank prefix ("  ")
        let nonSelectedPrefix0 = buffer.cell(x: 0, y: 1)
        let nonSelectedPrefix1 = buffer.cell(x: 1, y: 1)
        #expect(nonSelectedPrefix0?.grapheme == " ")
        #expect(nonSelectedPrefix1?.grapheme == " ")
        #expect(nonSelectedPrefix0?.background == theme.bgLight)
    }

    @Test("renderDropdown renders scrollbar when items exceed height")
    func renderDropdownScrollbar() {
        let area = TerminalRect(x: 0, y: 0, width: 20, height: 2)
        var buffer = CellBuffer(area: area)
        let theme = PagerRenderTheme()

        let items = (0..<10).map { FuzzyMatchResult(path: "path_\($0)") }

        FileSearchDropdown.renderDropdown(
            buffer: &buffer,
            area: area,
            results: items,
            selected: 0,
            hovered: nil,
            scrollOffset: 0,
            isDirMode: false,
            theme: theme
        )

        // Scrollbar should be painted at x = 19 (area.right - 1)
        let scrollbarCell = buffer.cell(x: 19, y: 0)
        #expect(scrollbarCell != nil)
        #expect(scrollbarCell?.grapheme == "█")
        #expect(scrollbarCell?.background == theme.bgDark)
    }

    @Test("renderDropdown truncates long paths with ellipsis")
    func renderDropdownTruncation() {
        let area = TerminalRect(x: 0, y: 0, width: 10, height: 1)
        var buffer = CellBuffer(area: area)
        let theme = PagerRenderTheme()

        let items = [
            FuzzyMatchResult(path: "very_long_path_that_will_be_truncated.swift", isDir: false)
        ]

        FileSearchDropdown.renderDropdown(
            buffer: &buffer,
            area: area,
            results: items,
            selected: 0,
            hovered: nil,
            scrollOffset: 0,
            isDirMode: false,
            theme: theme
        )

        // Last visible character before right edge should be '…'
        let lastCharCell = buffer.cell(x: 9, y: 0)
        #expect(lastCharCell?.grapheme == PagerGlyphs.ellipsis)
    }

    @Test("renderDropdown appends slash in directory mode")
    func renderDropdownDirMode() {
        let area = TerminalRect(x: 0, y: 0, width: 20, height: 1)
        var buffer = CellBuffer(area: area)
        let theme = PagerRenderTheme()

        let items = [
            FuzzyMatchResult(path: "Sources", isDir: true)
        ]

        FileSearchDropdown.renderDropdown(
            buffer: &buffer,
            area: area,
            results: items,
            selected: 0,
            hovered: nil,
            scrollOffset: 0,
            isDirMode: true,
            theme: theme
        )

        // After prefix (2) + "Sources" (7) = column 9, there should be '/'
        let slashCell = buffer.cell(x: 9, y: 0)
        #expect(slashCell?.grapheme == "/")
    }
}
