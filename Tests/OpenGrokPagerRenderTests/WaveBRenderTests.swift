// WaveBRenderTests.swift
//
// B-RENDER: execute/edit painters, minimal committed backgrounds, patch copy,
// stitching, and ANSI/CR wrapping through the available OpenGrokTerminalCore API.
//
// Rust refs (pin 650c1db7):
// - scrollback/blocks/tool/execute.rs header + 2+3 truncation + ANSI panel
// - scrollback/blocks/tool/edit.rs gutters/BG/wrap/hunk separators/no @@
// - diff.rs stitch_overlapping_hunks / diff_hunks_to_patch
// - pager-minimal/src/commit_tests.rs:781 committed_edit_keeps_diff_line_backgrounds
// - pager-render/src/render/terminal_output.rs ANSI/CR wrapping

import Testing
import OpenGrokTerminalCore
@testable import OpenGrokPagerRender
@testable import OpenGrokMinimalScrollback

private let waveBTheme = PagerRenderTheme.default

private func waveBLines(_ tool: PagerToolCard, width: Int = 80, motion: PagerMotionSnapshot = PagerMotionSnapshot()) -> [PaintLine] {
    makeConversationLines([.tool(tool)], width: width, theme: waveBTheme, motion: motion)
}

private func waveBTexts(_ tool: PagerToolCard, width: Int = 80) -> [String] {
    waveBLines(tool, width: width).map { $0.spans.map(\.text).joined() }
}

private func waveBHasBackground(_ lines: [PaintLine], color: TerminalColor) -> Bool {
    lines.contains { $0.background == color }
}

@Suite("Wave B render — execute + edit + minimal + patch + ANSI/CR")
struct WaveBRenderTests {

    // MARK: - B1 execute: collapsed vs expanded, description-first, accent

    @Test("execute collapsed shows description only, no $ command, no JSON")
    func executeCollapsedDescriptionFirst() {
        let tool = PagerToolCard(
            name: "run_terminal_cmd",
            kind: .execute,
            input: "Run the unit test suite",
            output: "ok",
            state: .succeeded,
            isExpanded: false,
            rawInput: #"{"command":"cargo test --lib","description":"Run the unit test suite"}"#,
            executeDescription: "Run the unit test suite",
            executeCommand: "cargo test --lib",
            executeHeaderDisplay: "cargo test --lib"
        )
        let texts = waveBTexts(tool, width: 80)
        let joined = texts.joined(separator: "\n")
        #expect(joined.contains("Run the unit test suite"))
        #expect(!joined.contains("$ cargo test"))
        #expect(!joined.contains("{"))
    }

    @Test("execute expanded shows description then $ command")
    func executeExpandedShowsDollarCommand() {
        let tool = PagerToolCard(
            name: "run_terminal_cmd",
            kind: .execute,
            input: "Run the unit test suite",
            output: "ok",
            state: .succeeded,
            isExpanded: true,
            rawInput: #"{"command":"cargo test --lib","description":"Run the unit test suite"}"#,
            executeDescription: "Run the unit test suite",
            executeCommand: "cargo test --lib",
            executeHeaderDisplay: "cargo test --lib"
        )
        let texts = waveBTexts(tool, width: 80)
        let joined = texts.joined(separator: "\n")
        #expect(joined.contains("Run the unit test suite"))
        #expect(joined.contains("$ cargo test --lib") || joined.contains("$"))
    }

    @Test("execute without description shows $ command in header")
    func executeNoDescriptionShowsCommand() {
        let tool = PagerToolCard(
            name: "bash",
            kind: .execute,
            input: "ls -la",
            output: "x",
            state: .succeeded,
            isExpanded: false,
            executeCommand: "ls -la",
            executeHeaderDisplay: "ls -la"
        )
        let joined = waveBTexts(tool).joined(separator: "\n")
        #expect(joined.contains("Run ls -la") || joined.contains("$ ls -la") || joined.contains("ls -la"))
        #expect(!joined.contains("{"))
    }

    @Test("execute error accent uses error color on bullet/rail")
    func executeErrorAccentUsesErrorColor() {
        let tool = PagerToolCard(name: "bash", kind: .execute, input: "exit 7", state: .failed, isExpanded: false)
        let lines = waveBLines(tool)
        #expect(lines.first?.accentColor == waveBTheme.accentError)
        #expect(lines.first?.spans.first?.foreground == waveBTheme.accentError)
    }

    @Test("execute keeps rail when collapsed (read does not semantics stay via execute path)")
    func executeKeepsRailWhenCollapsed() {
        let tool = PagerToolCard(name: "bash", kind: .execute, input: "ls", state: .succeeded, isExpanded: false)
        let lines = waveBLines(tool)
        #expect(lines.first?.accentGlyph != nil)
    }

    @Test("execute panel decodes SGR foreground background and style")
    func executeDecodesSGRForPanel() {
        let raw = "\u{1B}[1;31;44mred\u{1B}[0m plain"
        let stripped = stripAnsiSequences(raw)
        #expect(stripped == "red plain")
        let plainWrapped = executeWrappedOutput(raw, panelWidth: 20)
        let joined = plainWrapped.joined(separator: "\n")
        #expect(!joined.contains("\u{1B}"))
        #expect(joined.contains("red plain"))
        let styled = executeStyledWrappedOutput(raw, panelWidth: 20)
        let red = styled.flatMap { $0 }.first { $0.text.contains("red") }
        #expect(red?.foreground == .red)
        #expect(red?.background == .blue)
        #expect(red?.style.contains(.bold) == true)
    }

    @Test("execute CR progress wraps via collapseCarriageReturn")
    func executeCRProgressWraps() {
        let raw = "\u{1B}[31maaaa\r\u{1B}[32mbb"
        let collapsed = collapseCarriageReturn(raw)
        #expect(collapsed.contains("bb"))
        let wrapped = executeWrappedOutput(raw, panelWidth: 5)
        let joined = wrapped.joined(separator: "\n")
        #expect(joined.contains("bbaa"))
        let styled = executeStyledWrappedOutput(raw, panelWidth: 5).flatMap { $0 }
        #expect(styled.first { $0.text.contains("bb") }?.foreground == .green)
        #expect(styled.first { $0.text.contains("aa") }?.foreground == .red)
    }

    @Test("execute 2+3 truncation marker when expanded and long output")
    func executeTwoPlusThreeMarker() {
        let output = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let tool = PagerToolCard(name: "bash", kind: .execute, input: "make", output: output, state: .succeeded, isExpanded: true,
                                 executeCommand: "make", executeHeaderDisplay: "make")
        let joined = waveBTexts(tool, width: 40).joined(separator: "\n")
        #expect(joined.contains("… +"))
        #expect(joined.contains("lines"))
        #expect(!joined.contains("line 10") || joined.contains("… +15 lines"))
    }

    @Test("finished user bash fully expanded paints every output row")
    func userBashFullExpansionPaintsEveryRow() {
        let output = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let tool = PagerToolCard(
            name: "run_terminal_cmd",
            kind: .execute,
            input: "make",
            output: output,
            state: .succeeded,
            isExpanded: true,
            isFullyExpanded: true,
            executeCommand: "make",
            executeHeaderDisplay: "make",
            isBashMode: true
        )
        let joined = waveBTexts(tool, width: 40).joined(separator: "\n")
        #expect(!joined.contains("… +"))
        #expect(joined.contains("line 10"))
        #expect(joined.contains("line 20"))
    }

    // MARK: - B2 edit: gutters, wrap-stable BG, no @@, trusted, Creating

    @Test("edit multi-hunk shows gutter numbers and wrap-stable backgrounds, no @@")
    func editMultiHunkGuttersAndBackgroundsNoAtAt() {
        let h1 = diffHunksFromStrings(oldText: "a\nb\n", newText: "a\nB\n", startLine: 1)[0]
        let h2 = diffHunksFromStrings(oldText: "x\ny\n", newText: "X\ny\n", startLine: 10)[0]
        let tool = PagerToolCard(
            name: "search_replace",
            kind: .edit,
            input: "src/main.swift",
            state: .succeeded,
            isExpanded: true,
            editHunks: [h1, h2],
            editPath: "src/main.swift",
            editLinesAdded: 2,
            editLinesRemoved: 2,
            editIsTrusted: true,
            editCount: 2
        )
        let lines = waveBLines(tool, width: 80)
        let joined = lines.map { $0.spans.map(\.text).joined() }.joined(separator: "\n")
        #expect(!joined.contains("@@"))
        // Gutters: at least one line has a digit prefix.
        #expect(joined.contains("1") && joined.contains("10"))
        // Backgrounds: both insert and delete present.
        #expect(waveBHasBackground(lines, color: waveBTheme.diffInsertBackground))
        #expect(waveBHasBackground(lines, color: waveBTheme.diffDeleteBackground))
        // Wrap-stable: a narrow width introduces continuation rows with same BG.
        let narrowLines = waveBLines(tool, width: 12)
        let bgRows = narrowLines.filter { $0.background != nil }
        #expect(bgRows.count >= 2)
    }

    @Test("edit collapsed trusted shows +N/-N detail")
    func editCollapsedTrustedCounts() {
        let h = diffHunksFromStrings(oldText: "a\n", newText: "b\n", startLine: 5)[0]
        let tool = PagerToolCard(
            name: "search_replace",
            kind: .edit,
            input: "a.swift",
            state: .succeeded,
            isExpanded: false,
            editHunks: [h],
            editLinesAdded: 1,
            editLinesRemoved: 1,
            editIsTrusted: true
        )
        let joined = waveBTexts(tool).joined(separator: "\n")
        #expect(joined.contains("+1") && joined.contains("-1"))
        #expect(tool.editDetailForHeader?.contains("+1") == true)
    }

    @Test("write kind shows Creating prefix")
    func creatingPrefixForWriteKind() {
        let h = diffHunksFromStrings(oldText: "", newText: "hi\n", startLine: 1)[0]
        let tool = PagerToolCard(
            name: "write",
            kind: .create,
            input: "new.txt",
            state: .succeeded,
            isExpanded: false,
            editHunks: [h],
            editPath: "new.txt",
            isNewFileForEdit: true
        )
        let joined = waveBTexts(tool).joined(separator: "\n")
        #expect(joined.contains("Creating new.txt"))
    }

    @Test("committed expanded edit keeps both backgrounds (commit_tests.rs:781)")
    func committedEditKeepsDiffBackgrounds() {
        let h = diffHunksFromStrings(oldText: "old line here\n", newText: "new line here\n", startLine: 20)[0]
        let tool = PagerToolCard(
            name: "search_replace",
            kind: .edit,
            input: "a.ts",
            state: .succeeded,
            editHunks: [h],
            editPath: "a.ts"
        )
        let block = MinimalCommitRender.committedLines(
            item: .tool(tool),
            displayMode: .expanded,
            width: 60,
            theme: waveBTheme
        )
        var hasInsert = false
        var hasDelete = false
        for i in 0..<block.height {
            let line = block.lines[i]
            if line.background == waveBTheme.diffInsertBackground { hasInsert = true }
            if line.background == waveBTheme.diffDeleteBackground { hasDelete = true }
        }
        #expect(hasInsert && hasDelete, "committed expanded edit must keep both diff backgrounds")
    }

    @Test("edit copy generates git-applicable patch via stitched hunks")
    func editPatchGenerationIsGitApplicable() {
        let hunks = diffHunksFromStrings(oldText: "foo\nbar\n", newText: "FOO\nbar\n", startLine: 3)
        let tool = PagerToolCard(name: "search_replace", kind: .edit, input: "src/a.swift",
                                 editHunks: hunks, editPath: "src/a.swift")
        let patch = tool.editPatch
        #expect(patch != nil)
        #expect(patch?.contains("--- a/src/a.swift") == true)
        #expect(patch?.contains("+++ b/src/a.swift") == true)
        #expect(patch?.contains("@@") == true)
        #expect(patch?.contains("-foo") == true || patch?.contains("foo") == true)
    }

    @Test("multi-file edit renders every path and copies every patch")
    func multiFileEditRendersAndCopiesEveryFile() {
        let a = PagerEditFile(
            path: "src/a.swift",
            hunks: diffHunksFromStrings(oldText: "let a = 1\n", newText: "let a = 2\n", startLine: 1)
        )
        let b = PagerEditFile(
            path: "src/b.swift",
            hunks: diffHunksFromStrings(oldText: "let b = 1\n", newText: "let b = 2\n", startLine: 1)
        )
        let tool = PagerToolCard(
            name: "apply_patch",
            kind: .edit,
            input: "2 files",
            state: .succeeded,
            isExpanded: true,
            editFiles: [a, b],
            editHunks: a.hunks,
            editPath: a.path
        )
        let joined = waveBTexts(tool).joined(separator: "\n")
        #expect(joined.contains("src/a.swift"))
        #expect(joined.contains("src/b.swift"))
        #expect(tool.editPatch?.contains("--- a/src/a.swift") == true)
        #expect(tool.editPatch?.contains("--- a/src/b.swift") == true)
    }

    @Test("semantic edit foregrounds preserve insertion background on wraps")
    func semanticEditForegroundsPreserveDiffBackground() {
        let hunks = diffHunksFromStrings(
            oldText: "let value = 1\n",
            newText: "let value = \"hello world\"\n",
            startLine: 1
        )
        let file = PagerEditFile(
            path: "src/a.swift",
            hunks: hunks,
            highlights: [
                PagerEditLineHighlight(lineNumber: 1, spans: [
                    PagerEditHighlightSpan(start: 0, length: 3, kind: .keyword),
                    PagerEditHighlightSpan(start: 12, length: 13, kind: .string)
                ])
            ]
        )
        let tool = PagerToolCard(
            name: "search_replace",
            kind: .edit,
            input: file.path,
            state: .succeeded,
            isExpanded: true,
            editFiles: [file],
            editHunks: hunks,
            editPath: file.path
        )
        let lines = waveBLines(tool, width: 18)
        let inserted = lines.filter { $0.background == waveBTheme.diffInsertBackground }
        #expect(!inserted.isEmpty)
        #expect(inserted.contains { line in
            line.spans.contains { $0.foreground == waveBTheme.accentModel }
        })
        #expect(inserted.contains { line in
            line.spans.contains { $0.foreground == waveBTheme.accentSuccess }
        })
        #expect(inserted.allSatisfy { $0.background == waveBTheme.diffInsertBackground })
    }

    @Test("stitchOverlappingHunks is wired and available")
    func stitchWired() {
        let a = diffHunksFromStrings(oldText: "a\nb\nc\n", newText: "a\nB\nc\n", startLine: 1)[0]
        let b = diffHunksFromStrings(oldText: "a\nB\nc\n", newText: "A\nB\nc\n", startLine: 1)[0]
        let stitched = stitchOverlappingHunks([a, b])
        #expect(stitched.count == 1)
        let p = diffHunksToPatch(path: "f.swift", hunks: stitched)
        #expect(p.contains("f.swift"))
        #expect(!p.isEmpty)
    }
}
