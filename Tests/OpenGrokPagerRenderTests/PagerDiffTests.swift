// PagerDiffTests.swift
//
// Tests for PagerDiff.swift — port of xai-grok-pager-diff tests.

import Testing
@testable import OpenGrokPagerRender

@Suite("PagerDiff — Diff Hunk Construction")
struct PagerDiffTests {

    @Test("Simple replacement produces correct hunks")
    func simpleReplacement() {
        let details = [SearchReplaceEditDetail(
            oldString: "let x = 1;",
            newString: "let x = 2;",
            oldLine: 5,
            newLine: 5,
            contextBefore: "fn main() {\n",
            contextAfter: "}",
            linePrefix: ""
        )]

        let hunks = buildDiffHunks(details)
        #expect(hunks.count == 1)

        let hunk = hunks[0]
        #expect(hunk.count >= 3, "got \(hunk.count) lines")

        let deletes = hunk.filter { $0.tag == .delete }
        let inserts = hunk.filter { $0.tag == .insert }
        #expect(deletes.count == 1)
        #expect(inserts.count == 1)
        #expect(deletes[0].text.contains("let x = 1;"))
        #expect(inserts[0].text.contains("let x = 2;"))
    }

    @Test("Multiple edits produce multiple hunks")
    func multipleEditsProduceMultipleHunks() {
        let details = [
            SearchReplaceEditDetail(
                oldString: "foo",
                newString: "bar",
                oldLine: 1,
                newLine: 1
            ),
            SearchReplaceEditDetail(
                oldString: "baz",
                newString: "qux",
                oldLine: 10,
                newLine: 10
            ),
        ]

        let hunks = buildDiffHunks(details)
        #expect(hunks.count == 2)
    }

    @Test("No change produces no hunks")
    func noChangeProducesNoHunks() {
        let details = [SearchReplaceEditDetail(
            oldString: "same",
            newString: "same",
            oldLine: 1,
            newLine: 1
        )]

        let hunks = buildDiffHunks(details)
        #expect(hunks.count == 0, "identical text should produce no hunks")
    }

    @Test("Context lines are included")
    func contextLinesAreIncluded() {
        let details = [SearchReplaceEditDetail(
            oldString: "old",
            newString: "new",
            oldLine: 5,
            newLine: 5,
            contextBefore: "line3\nline4\n",
            contextAfter: "line6\nline7\n"
        )]

        let hunks = buildDiffHunks(details)
        #expect(hunks.count == 1)

        let hunk = hunks[0]
        let equalLines = hunk.filter { $0.tag == .equal }
        #expect(equalLines.count >= 2, "expected context lines, got \(equalLines.count)")
    }

    @Test("Line numbers are correct")
    func lineNumbersAreCorrect() {
        let details = [SearchReplaceEditDetail(
            oldString: "old",
            newString: "new",
            oldLine: 10,
            newLine: 10
        )]

        let hunks = buildDiffHunks(details)
        let hunk = hunks[0]
        let del = hunk.first(where: { $0.tag == .delete })!
        #expect(del.lo == 10)
        let ins = hunk.first(where: { $0.tag == .insert })!
        #expect(ins.ln == 10)
    }

    @Test("Context before line numbers precede edit")
    func contextBeforeLineNumbersPrecedeEdit() {
        let details = [SearchReplaceEditDetail(
            oldString: "old",
            newString: "new",
            oldLine: 5,
            newLine: 5,
            contextBefore: "ctx1\nctx2"
        )]

        let hunks = buildDiffHunks(details)
        let hunk = hunks[0]
        let ctx = hunk.filter { $0.tag == .equal }
        #expect(ctx.count == 2)
        #expect(ctx[0].lo == 3) // old_line - 2
        #expect(ctx[1].lo == 4) // old_line - 1
    }

    @Test("Diff hunks from strings — simple")
    func diffHunksFromStringsSimple() {
        let hunks = diffHunksFromStrings(oldText: "hello\nworld\n", newText: "hello\nearth\n", startLine: 1)
        #expect(hunks.count == 1)

        let hunk = hunks[0]
        let deletes = hunk.filter { $0.tag == .delete }
        let inserts = hunk.filter { $0.tag == .insert }
        #expect(deletes.count == 1)
        #expect(inserts.count == 1)
        #expect(deletes[0].text.contains("world"))
        #expect(inserts[0].text.contains("earth"))
    }

    @Test("Diff hunks from strings — identical")
    func diffHunksFromStringsIdentical() {
        let hunks = diffHunksFromStrings(oldText: "same\n", newText: "same\n", startLine: 1)
        #expect(hunks.count == 0)
    }

    @Test("Diff hunks from strings — empty old (new file creation)")
    func diffHunksFromStringsEmptyOld() {
        let hunks = diffHunksFromStrings(oldText: "", newText: "new content\n", startLine: 1)
        #expect(hunks.count == 1)
        let inserts = hunks[0].filter { $0.tag == .insert }
        #expect(!inserts.isEmpty)
    }

    @Test("Blank line insert produces visible hunk")
    func blankLineInsertProducesVisibleHunk() {
        let details = [SearchReplaceEditDetail(
            oldString: "",
            newString: "",
            oldLine: 4,
            newLine: 4,
            contextBefore: "    let y = 2;\n    let z = x + y;\n",
            contextAfter: "    if z > 2 {\n        println!(\"big\");\n"
        )]

        let hunks = buildDiffHunks(details)
        #expect(hunks.count == 1, "blank line insert should produce a visible hunk")

        let inserts = hunks[0].filter { $0.tag == .insert }
        #expect(inserts.count == 1, "should have exactly one inserted blank line")
    }

    @Test("Empty file write produces no hunks")
    func emptyFileWriteProducesNoHunks() {
        let hunks = diffHunksFromStrings(oldText: "", newText: "", startLine: 1)
        #expect(hunks.isEmpty, "empty-to-empty must diff to nothing")
    }

    @Test("Line prefix prepended to changed lines")
    func linePrefixPrependedToChangedLines() {
        let details = [SearchReplaceEditDetail(
            oldString: ".filter(|t| old)",
            newString: ".filter(|t| new)",
            oldLine: 5,
            newLine: 5,
            contextBefore: "            .values()\n",
            contextAfter: "            .count()\n",
            linePrefix: "            " // 12 spaces
        )]

        let hunks = buildDiffHunks(details)
        #expect(hunks.count == 1)
        let hunk = hunks[0]

        let del = hunk.filter { $0.tag == .delete }
        let ins = hunk.filter { $0.tag == .insert }
        #expect(del.count == 1)
        #expect(ins.count == 1)

        #expect(del[0].text.hasPrefix("            .filter"),
                "delete line should have leading indent, got: \(del[0].text)")
        #expect(ins[0].text.hasPrefix("            .filter"),
                "insert line should have leading indent, got: \(ins[0].text)")
    }

    @Test("Empty line prefix changes nothing")
    func emptyLinePrefixChangesNothing() {
        let details = [SearchReplaceEditDetail(
            oldString: "old_val",
            newString: "new_val",
            oldLine: 1,
            newLine: 1
        )]

        let hunks = buildDiffHunks(details)
        #expect(hunks.count == 1)

        let del = hunks[0].first(where: { $0.tag == .delete })!
        let ins = hunks[0].first(where: { $0.tag == .insert })!
        #expect(del.text.hasPrefix("old_val"))
        #expect(ins.text.hasPrefix("new_val"))
    }
}

@Suite("PagerDiff — Overlap Stitching")
struct PagerDiffStitchTests {

    private func editDetail(
        old: String,
        new: String,
        line: Int,
        before: String = "",
        after: String = ""
    ) -> SearchReplaceEditDetail {
        SearchReplaceEditDetail(
            oldString: old,
            newString: new,
            oldLine: line,
            newLine: line,
            contextBefore: before,
            contextAfter: after
        )
    }

    @Test("Stitch collapses double edit to original and final")
    func stitchCollapsesDoubleEditToOriginalAndFinal() {
        let first = buildDiffHunks([editDetail(old: "a", new: "b", line: 1, after: "x\n")])
        let second = buildDiffHunks([editDetail(old: "b", new: "c", line: 1, after: "x\n")])

        let stitched = stitchOverlappingHunks([first[0], second[0]])
        #expect(stitched.count == 1)
    }

    @Test("Stitch bails on content disagreement")
    func stitchBailsOnContentDisagreement() {
        let a: DiffHunk = [
            DiffLine(text: "alpha", lo: 1, ln: 1, tag: .equal),
            DiffLine(text: "beta", lo: 2, ln: 2, tag: .delete),
            DiffLine(text: "BETA", lo: 3, ln: 2, tag: .insert),
        ]
        let b: DiffHunk = [
            DiffLine(text: "omega", lo: 1, ln: 1, tag: .equal),
            DiffLine(text: "gamma", lo: 3, ln: 3, tag: .delete),
            DiffLine(text: "GAMMA", lo: 4, ln: 3, tag: .insert),
        ]

        let stitched = stitchOverlappingHunks([a, b])
        #expect(stitched.count == 2, "disagreement keeps hunks separate")
    }

    @Test("Stitch keeps disjoint hunks separate")
    func stitchKeepsDisjointHunksSeparate() {
        let far = { (line: Int) -> DiffHunk in
            diffHunksFromStrings(oldText: "old_\(line)\n", newText: "new_\(line)\n", startLine: line)[0]
        }

        #expect(stitchOverlappingHunks([far(5), far(40)]).count == 2)
        #expect(stitchOverlappingHunks([far(20), far(4)]).count == 2)
    }
}

@Suite("PagerDiff — Patch Generation")
struct PagerDiffPatchTests {

    @Test("Generate unified diff patch")
    func generateUnifiedDiffPatch() {
        let hunks = diffHunksFromStrings(oldText: "hello\nworld\n", newText: "hello\nearth\n", startLine: 1)
        let patch = diffHunksToPatch(path: "test.txt", hunks: hunks)

        #expect(patch.contains("--- a/test.txt"))
        #expect(patch.contains("+++ b/test.txt"))
        #expect(patch.contains("@@"))
        #expect(patch.contains("-world"))
        #expect(patch.contains("+earth"))
    }

    @Test("Empty hunks produce empty patch")
    func emptyHunksProduceEmptyPatch() {
        let patch = diffHunksToPatch(path: "test.txt", hunks: [])
        #expect(patch.isEmpty)
    }
}
