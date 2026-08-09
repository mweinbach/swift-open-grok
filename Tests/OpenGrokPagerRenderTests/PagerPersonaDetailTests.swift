// PagerPersonaDetailTests.swift
//
// The persona detail modal at the overlay seam (Wave 18 B9-b3):
// browse navigation with wrap (`persona_detail.rs:61-69` at upstream
// 650c1db7), the instructions expand/collapse/scroll machine
// (`:759-792`), the inline-edit mode with upstream's refusal arms
// (`:798-823`) and commit/cancel/unchanged semantics (`:839-873` —
// upstream's own `detail_edit_*` tests adapted to the save-outcome
// split), the `i`/$EDITOR arms (`:824-834`), the painted field view
// (`render_persona_detail`, `:375-668`), and the footer honesty
// (`build_shortcuts`, `:683-724`). The disk half of the save loop is
// exercised here through the same `saveDetail` the composition calls.

import Foundation
@testable import OpenGrokPagerRender
import OpenGrokTerminalCore
import Testing

// MARK: - Helpers

private func character(_ value: Character) -> KeyEvent {
    KeyEvent(key: .char(value), modifiers: [], character: value)
}

private func editableDetail(sourcePath: String? = "/tmp/home/personas/reviewer.toml")
    -> PagerPersonaDetailOverlay {
    // The shape of upstream's `editable_state()` fixture
    // (`persona_detail/tests.rs:4-21`).
    PagerPersonaDetailOverlay(
        name: "reviewer",
        description: "old description",
        model: "grok",
        reasoningEffort: "high",
        defaultIsolation: "worktree",
        instructions: "read only instructions",
        sourcePath: sourcePath,
        editable: true,
        scopeLabel: "project"
    )
}

private func detailFrame(_ detail: PagerPersonaDetailOverlay) -> String {
    renderPagerFrame(
        PagerRenderState(
            size: TerminalSize(width: 120, height: 40),
            conversation: [.message(PagerMessage(role: .assistant, text: "behind"))],
            input: PagerComposerState(text: ""),
            theme: .grokNight,
            showScrollbar: false,
            overlays: PagerOverlayStack([PagerOverlay.personaDetail(detail)])
        )
    ).snapshot()
}

// MARK: - Machine

@Suite("persona detail machine")
struct PagerPersonaDetailMachineTests {
    @Test("browse navigation wraps through the seven fields")
    func browseNavigationWraps() {
        // `PersonaField::next/prev` (`:61-69`) driven by j/k (`:781-796`).
        var detail = editableDetail()
        let forward: [PagerPersonaDetailField] = [
            .description, .model, .reasoningEffort, .isolation,
            .instructions, .instructionsFile, .name,
        ]
        for expected in forward {
            _ = detail.handle(character("j"))
            #expect(detail.selectedField == expected)
        }
        _ = detail.handle(character("k"))
        #expect(detail.selectedField == .instructionsFile, "k wraps backwards")
    }

    @Test("edit commit folds the value, marks dirty, emits save, and the store writes it")
    func editCommitSavesThroughTheStore() throws {
        // `detail_edit_save_updates_state_and_toml` adapted: the overlay
        // half (`:844-865`) plus the disk half through `saveDetail`.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-detail-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reviewer.toml")
        try "name = \"reviewer\"\ndescription = \"old description\"\n"
            .write(to: path, atomically: true, encoding: .utf8)

        var detail = editableDetail(sourcePath: path.path)
        detail.selectedField = .description
        #expect(detail.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(detail.isEditing)
        // Append/backspace editing (the recorded LineEditor divergence).
        for _ in 0..<"old description".count {
            _ = detail.handle(KeyEvent(key: .backspace))
        }
        for value in "new description" { _ = detail.handle(character(value)) }
        #expect(detail.handle(KeyEvent(key: .enter)) == .save)
        #expect(!detail.isEditing)
        #expect(detail.description == "new description")
        #expect(detail.dirty)
        try PagerPersonaFileStore.saveDetail(detail)
        let saved = try String(contentsOf: path, encoding: .utf8)
        #expect(saved.contains("description = \"new description\""))
    }

    @Test("edit cancel preserves the original and an unchanged commit writes nothing")
    func editCancelAndUnchanged() {
        // `detail_edit_cancel_preserves_original_and_file` and
        // `detail_unchanged_edit_does_not_write_or_mark_dirty`.
        var detail = editableDetail()
        detail.selectedField = .name
        _ = detail.handle(KeyEvent(key: .enter))
        _ = detail.handle(character("X"))
        #expect(detail.handle(KeyEvent(key: .escape)) == .redraw)
        #expect(!detail.isEditing)
        #expect(detail.name == "reviewer")
        #expect(!detail.dirty)

        detail.selectedField = .model
        _ = detail.handle(KeyEvent(key: .enter))
        // Enter with the text untouched: no save outcome, no dirty, no
        // message (`:854-864` — `changed` is false).
        #expect(detail.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(!detail.isEditing)
        #expect(!detail.dirty)
        #expect(detail.message == nil)
    }

    @Test("the editing seed is the current value and Esc during edit never closes the modal")
    func editSeedAndEscape() {
        var detail = editableDetail()
        detail.selectedField = .model
        _ = detail.handle(KeyEvent(key: .enter))
        #expect(detail.editingText == "grok")
        #expect(detail.handle(KeyEvent(key: .escape)) == .redraw, "Esc cancels the edit, not the modal")
        #expect(detail.handle(KeyEvent(key: .escape)) == .close, "browse Esc closes")
    }

    @Test("upstream's three edit refusal arms carry byte-parity copy")
    func editRefusalArms() {
        // Bundled read-only (`:798-801`).
        var bundled = editableDetail()
        bundled.editable = false
        _ = bundled.handle(KeyEvent(key: .enter))
        #expect(!bundled.isEditing)
        #expect(bundled.message == "Bundled personas are read-only")
        // Not inline-editable (`:803-807`): the instructions file.
        var detail = editableDetail()
        detail.selectedField = .instructionsFile
        _ = detail.handle(character("e"))
        #expect(!detail.isEditing)
        #expect(detail.message == "This field cannot be edited inline")
        // Multiline value (`:808-813`) —
        // `multiline_values_require_source_file_editing`.
        detail.description = "first line\nsecond line"
        detail.selectedField = .description
        #expect(detail.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(!detail.isEditing)
        #expect(detail.description == "first line\nsecond line")
        #expect(detail.message == "Multiline values must be edited in the source file")
        // CRLF is ONE Swift Character (AGENTS.md §2) — the guard must
        // still catch a file that came off disk with Windows endings.
        detail.description = "first line\r\nsecond line"
        #expect(detail.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(!detail.isEditing)
        #expect(detail.message == "Multiline values must be edited in the source file")
        // The message clears on the next key (`:734`).
        _ = detail.handle(character("j"))
        #expect(detail.message == nil)
    }

    @Test("instructions expand and scroll instead of editing inline")
    func instructionsExpandCollapse() {
        // `detail_instructions_remain_read_only_inline` plus the scroll
        // arms (`:759-792`).
        var detail = editableDetail()
        detail.selectedField = .instructions
        #expect(detail.handle(KeyEvent(key: .enter)) == .redraw)
        #expect(!detail.isEditing)
        #expect(detail.instructionsExpanded)
        // j/k scroll while expanded; k saturates at zero.
        _ = detail.handle(character("j"))
        _ = detail.handle(character("j"))
        #expect(detail.instructionsScroll == 2)
        _ = detail.handle(character("k"))
        _ = detail.handle(character("k"))
        _ = detail.handle(character("k"))
        #expect(detail.instructionsScroll == 0)
        // Esc collapses first, then closes (`:764-772`).
        #expect(detail.handle(KeyEvent(key: .escape)) == .redraw)
        #expect(!detail.instructionsExpanded)
        #expect(detail.handle(KeyEvent(key: .escape)) == .close)
    }

    @Test("i emits EditInEditor only for editable file-backed personas")
    func editorKeyArms() {
        // `:824-834`.
        var detail = editableDetail()
        #expect(detail.handle(character("i")) == .editInEditor)
        var bundled = editableDetail()
        bundled.editable = false
        #expect(bundled.handle(character("i")) == .redraw)
        #expect(bundled.message == "Bundled personas are read-only")
        var pathless = editableDetail(sourcePath: nil)
        pathless.editable = false
        #expect(pathless.handle(character("i")) == .redraw)
        #expect(pathless.message == "No source file")
    }

    @Test("the stack routes save and edit-in-editor onto the selection channel and Esc dismisses")
    func stackPlumbing() {
        var stack = PagerOverlayStack([PagerOverlay.personaDetail(editableDetail())])
        #expect(stack.handle(character("i"))
            == .selected(id: "persona-detail", rowID: "edit-in-editor"))
        // An edit commit emits the save row.
        _ = stack.handle(KeyEvent(key: .enter)) // open the name editor
        _ = stack.handle(character("X"))
        #expect(stack.handle(KeyEvent(key: .enter))
            == .selected(id: "persona-detail", rowID: "save"))
        #expect(stack.handle(KeyEvent(key: .escape)) == .dismissed(id: "persona-detail"))
        #expect(stack.isEmpty)
    }
}

// MARK: - Paint

@Suite("persona detail paint")
struct PagerPersonaDetailPaintTests {
    @Test("the field view paints title, labels, values, empty markers, and the source line")
    func fieldViewPaints() {
        // `render_persona_detail` (`:375-668`): the seven labels
        // (`:49-59`), `—` for empty scalars (`:558-564`), `Source:`
        // (`:655-667`), and the modal title `persona: {name}` (`:382`).
        var detail = editableDetail()
        detail.instructionsFile = ""
        let frame = detailFrame(detail)
        #expect(frame.contains("persona: reviewer"))
        for label in ["Name", "Description", "Model", "Effort", "Isolation",
                      "Instructions", "Instr. file"] {
            #expect(frame.contains(label), "field label \(label) missing")
        }
        #expect(frame.contains("reviewer"))
        #expect(frame.contains("old description"))
        #expect(frame.contains("grok"))
        #expect(frame.contains("high"))
        #expect(frame.contains("worktree"))
        #expect(frame.contains("read only instructions"))
        #expect(frame.contains("\u{2014}"), "the empty instructions file paints an em dash")
        #expect(frame.contains("Source: /tmp/home/personas/reviewer.toml"))
    }

    @Test("empty instructions paint the (empty) marker")
    func emptyInstructions() {
        var detail = editableDetail()
        detail.instructions = ""
        #expect(detailFrame(detail).contains("(empty)"))
    }

    @Test("long instructions collapse at eight lines with the expand hint, and expand with the scroll hint")
    func instructionsHints() {
        // `:496-556`: the collapsed `... (N more lines — e to expand...)`
        // and the expanded `(e to collapse, j/k to scroll [a–b/ total])`.
        var detail = editableDetail()
        detail.instructions = (1...20).map { "wrapline \($0) marker" }.joined(separator: "\n")
        detail.selectedField = .instructions
        let collapsed = detailFrame(detail)
        #expect(collapsed.contains("wrapline 1 marker"))
        #expect(collapsed.contains("wrapline 8 marker"))
        #expect(!collapsed.contains("wrapline 9 marker"))
        #expect(collapsed.contains("... (12 more lines \u{2014} e to expand, j/k to scroll)"))
        _ = detail.handle(character("e"))
        let expanded = detailFrame(detail)
        #expect(expanded.contains("(e to collapse, j/k to scroll"))
        // Scrolled: the first lines leave the viewport (the painter clamps
        // the stored scroll to the wrapped total).
        for _ in 0..<5 { _ = detail.handle(character("j")) }
        let scrolled = detailFrame(detail)
        #expect(!scrolled.contains("wrapline 1 marker"))
        #expect(!scrolled.contains("wrapline 2 marker"))
        #expect(scrolled.contains("wrapline 6 marker"))
    }

    @Test("inputs and outputs sections paint entries with type, required, and description")
    func ioSectionsPaint() {
        // `:599-653`.
        var detail = editableDetail()
        detail.inputs = [PagerPersonaIOEntry(
            name: "spec", ioType: "file", required: true,
            description: "The task specification to review."
        )]
        detail.outputs = [PagerPersonaIOEntry(
            name: "verdict", ioType: "text", required: false, description: ""
        )]
        let frame = detailFrame(detail)
        #expect(frame.contains("Inputs"))
        #expect(frame.contains("\u{2022} spec (file, required)"))
        #expect(frame.contains("The task specification to review."))
        #expect(frame.contains("Outputs"))
        #expect(frame.contains("\u{2022} verdict (text)"))
    }

    @Test("the editing row paints the live text and the message line paints above the fields")
    func editingAndMessagePaint() {
        var detail = editableDetail()
        detail.selectedField = .model
        _ = detail.handle(KeyEvent(key: .enter))
        for value in "-mini" { _ = detail.handle(character(value)) }
        #expect(detailFrame(detail).contains("grok-mini"))
        var messaged = editableDetail()
        messaged.message = "Saved"
        #expect(detailFrame(messaged).contains("Saved"))
    }

    @Test("footer hints follow mode and honesty: e and i only where backed")
    func footerHints() {
        // `build_shortcuts` (`:683-724`).
        let editable = editableDetail()
        #expect(pagerPersonaDetailHints(editable).map(\.key) == ["j/k", "e", "i", "Esc"])
        #expect(pagerPersonaDetailHints(editable).map(\.label)
            == ["nav", "edit field", "$EDITOR", "back"])
        var bundled = editableDetail()
        bundled.editable = false
        #expect(pagerPersonaDetailHints(bundled).map(\.key) == ["j/k", "Esc"])
        var pathless = editableDetail(sourcePath: nil)
        pathless.editable = true
        #expect(pagerPersonaDetailHints(pathless).map(\.key) == ["j/k", "e", "Esc"],
                "no $EDITOR hint without a source file")
        var editing = editableDetail()
        _ = editing.handle(KeyEvent(key: .enter))
        #expect(pagerPersonaDetailHints(editing).map(\.label) == ["save", "cancel"])
        // The painted footer follows the recomputed hints.
        #expect(detailFrame(editing).contains("Enter save"))
        #expect(detailFrame(editable).contains("i $EDITOR"))
    }

    @Test("word wrap keeps raw line structure and empty text yields one empty line")
    func wordWrapContract() {
        // `word_wrap_lines` (`:901-928`).
        #expect(personaDetailWordWrap("one two three", maxWidth: 7) == ["one two", "three"])
        #expect(personaDetailWordWrap("a\nb", maxWidth: 10) == ["a", "b"])
        #expect(personaDetailWordWrap("", maxWidth: 5) == [""])
        #expect(personaDetailWordWrap("superlongword ok", maxWidth: 5) == ["superlongword", "ok"])
    }
}
