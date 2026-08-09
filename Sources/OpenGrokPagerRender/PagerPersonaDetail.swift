// PagerPersonaDetail.swift
//
// The persona detail/edit modal (Wave 18 B9-b3) — the structured view
// behind `Enter` on a persona in the agents modal. Ports
// `xai-grok-pager/src/views/persona_detail.rs` at upstream 650c1db7: the
// field enum with labels and the wrap cycle (`:26-78`), the browse/edit
// mode machine (`:84-92`, `:730-882`), the instructions expand/collapse
// with its own scroll (`:759-792`), inline editing for user/project
// personas with bundled read-only (`:798-823`), the `$EDITOR` hand-off on
// `i` (`:824-834`), and every message string byte-parity.
//
// The overlay owns no file IO (the b2/b3 convention): Enter-commit on a
// changed field folds the value into this state, marks it dirty, and
// emits `.save`; the composition runs `save_to_file`
// (`PagerPersonaFileStore.saveDetail`) and sets `"Saved"` /
// `"Save failed: {e}"` on the replacement overlay — upstream's
// `:855-864` split across the seam. Text entry is append/backspace, the
// b1 search-field convention in place of upstream's cursor-bearing
// `LineEditor` (recorded divergence: no cursor movement inside a field,
// and paste never arrives because the input router swallows it while a
// modal is up).

import Foundation
import OpenGrokTerminalCore

// MARK: - Fields

/// `PersonaField` (`persona_detail.rs:28-47`) with `label()` (`:49-59`)
/// and the wrapping `next()`/`prev()` (`:61-69`).
public enum PagerPersonaDetailField: Sendable, Equatable, CaseIterable {
    case name
    case description
    case model
    case reasoningEffort
    case isolation
    case instructions
    case instructionsFile

    public var label: String {
        switch self {
        case .name: return "Name"
        case .description: return "Description"
        case .model: return "Model"
        case .reasoningEffort: return "Effort"
        case .isolation: return "Isolation"
        case .instructions: return "Instructions"
        case .instructionsFile: return "Instr. file"
        }
    }

    public func next() -> PagerPersonaDetailField {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    public func previous() -> PagerPersonaDetailField {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + all.count - 1) % all.count]
    }

    /// `is_editable` (`:72-77`): the five scalar fields. Instructions is
    /// expand/collapse (`:786-792`), and the instructions file must be
    /// edited in the source (`:804-807`).
    public var isInlineEditable: Bool {
        switch self {
        case .name, .description, .model, .reasoningEffort, .isolation:
            return true
        case .instructions, .instructionsFile:
            return false
        }
    }
}

// MARK: - I/O entries

/// `PersonaIOEntry` (`persona_detail.rs:114-120`).
public struct PagerPersonaIOEntry: Sendable, Equatable {
    public var name: String
    public var ioType: String
    public var required: Bool
    public var description: String

    public init(name: String, ioType: String, required: Bool, description: String) {
        self.name = name
        self.ioType = ioType
        self.required = required
        self.description = description
    }
}

// MARK: - Outcome

/// What a keystroke decided (`PersonaDetailOutcome`, `:98-108`, with the
/// save split noted in the file header).
public enum PagerPersonaDetailOutcome: Sendable, Equatable {
    case redraw
    case consumed
    /// Close the detail, return to the list (the composition refreshes
    /// the personas snapshot, `agent_view/modals.rs:126-132`).
    case close
    /// A changed field was committed; the composition writes the whole
    /// snapshot to the source file (`save_to_file` writes every field).
    case save
    /// `i` on an editable, file-backed persona: open the source in
    /// `$EDITOR` over a suspended TUI (`:824-828`).
    case editInEditor
}

// MARK: - State

/// `PersonaDetailState` (`persona_detail.rs:126-148`).
public struct PagerPersonaDetailOverlay: Sendable, Equatable {
    public var name: String
    public var description: String
    public var model: String
    public var reasoningEffort: String
    public var defaultIsolation: String
    public var instructions: String
    public var instructionsFile: String
    public var inputs: [PagerPersonaIOEntry]
    public var outputs: [PagerPersonaIOEntry]
    public var sourcePath: String?
    public var editable: Bool
    public var scopeLabel: String
    public var selectedField: PagerPersonaDetailField
    /// Non-nil while a field edit is open (`PersonaDetailMode::Editing`).
    public var editingField: PagerPersonaDetailField?
    public var editingText: String
    /// The value at edit start — an unchanged commit writes nothing
    /// (`:854-864`).
    var editingOriginal: String
    public var dirty: Bool
    public var instructionsExpanded: Bool
    /// First visible wrapped line of the expanded instructions. Saturating
    /// in the key handler; the painter clamps to the wrapped total each
    /// frame (upstream clamps stored state during render, `:521-524` —
    /// this port's painters take state by value, so overscroll past the
    /// end needs matching `k` presses before the view moves; cost carried).
    public var instructionsScroll: Int
    public var message: String?

    public init(
        name: String,
        description: String = "",
        model: String = "",
        reasoningEffort: String = "",
        defaultIsolation: String = "",
        instructions: String = "",
        instructionsFile: String = "",
        inputs: [PagerPersonaIOEntry] = [],
        outputs: [PagerPersonaIOEntry] = [],
        sourcePath: String? = nil,
        editable: Bool = false,
        scopeLabel: String = "bundled",
        selectedField: PagerPersonaDetailField = .name,
        editingField: PagerPersonaDetailField? = nil,
        editingText: String = "",
        dirty: Bool = false,
        instructionsExpanded: Bool = false,
        instructionsScroll: Int = 0,
        message: String? = nil
    ) {
        self.name = name
        self.description = description
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.defaultIsolation = defaultIsolation
        self.instructions = instructions
        self.instructionsFile = instructionsFile
        self.inputs = inputs
        self.outputs = outputs
        self.sourcePath = sourcePath
        self.editable = editable
        self.scopeLabel = scopeLabel
        self.selectedField = selectedField
        self.editingField = editingField
        self.editingText = editingText
        self.editingOriginal = editingText
        self.dirty = dirty
        self.instructionsExpanded = instructionsExpanded
        self.instructionsScroll = instructionsScroll
        self.message = message
    }

    public var isEditing: Bool { editingField != nil }

    /// `field_value` (`:255-265`).
    public func fieldValue(_ field: PagerPersonaDetailField) -> String {
        switch field {
        case .name: return name
        case .description: return description
        case .model: return model
        case .reasoningEffort: return reasoningEffort
        case .isolation: return defaultIsolation
        case .instructions: return instructions
        case .instructionsFile: return instructionsFile
        }
    }

    /// `set_field_value` (`:267-277`).
    mutating func setFieldValue(_ field: PagerPersonaDetailField, _ value: String) {
        switch field {
        case .name: name = value
        case .description: description = value
        case .model: model = value
        case .reasoningEffort: reasoningEffort = value
        case .isolation: defaultIsolation = value
        case .instructions: instructions = value
        case .instructionsFile: instructionsFile = value
        }
    }

    // MARK: Key handling

    /// `handle_persona_detail_key` (`:730-741`): the message clears on
    /// every key, then editing and browse split.
    public mutating func handle(_ event: KeyEvent) -> PagerPersonaDetailOutcome {
        message = nil
        if isEditing { return handleEditingKey(event) }
        return handleBrowseKey(event)
    }

    /// `handle_browse_key` (`:758-837`).
    private mutating func handleBrowseKey(_ event: KeyEvent) -> PagerPersonaDetailOutcome {
        let instructionsScrolling =
            selectedField == .instructions && instructionsExpanded
        switch event.key {
        case .escape, .char("q"):
            // Expanded instructions collapse first instead of closing
            // (`:764-772`).
            if instructionsScrolling {
                instructionsExpanded = false
                instructionsScroll = 0
                return .redraw
            }
            return .close
        case .down, .char("j"):
            if instructionsScrolling {
                instructionsScroll += 1
                return .redraw
            }
            selectedField = selectedField.next()
            return .redraw
        case .up, .char("k"):
            if instructionsScrolling {
                instructionsScroll = max(0, instructionsScroll - 1)
                return .redraw
            }
            selectedField = selectedField.previous()
            return .redraw
        case .enter, .char("e"):
            // Instructions: toggle expand/collapse (`:785-792`).
            if selectedField == .instructions {
                instructionsExpanded.toggle()
                instructionsScroll = 0
                return .redraw
            }
            // Other fields: open the inline editor, with upstream's three
            // refusal arms in order (`:798-813`).
            if !editable {
                message = "Bundled personas are read-only"
                return .redraw
            }
            if !selectedField.isInlineEditable {
                message = "This field cannot be edited inline"
                return .redraw
            }
            let current = fieldValue(selectedField)
            // Scalar-level scan, not Character equality: CRLF is ONE Swift
            // Character that equals neither "\n" nor "\r" (AGENTS.md §2),
            // and upstream's `contains(['\n','\r'])` is a scalar check.
            if current.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
                message = "Multiline values must be edited in the source file"
                return .redraw
            }
            editingField = selectedField
            editingText = current
            editingOriginal = current
            return .redraw
        case .char("i"):
            // `:824-834`.
            if sourcePath != nil {
                if editable { return .editInEditor }
                message = "Bundled personas are read-only"
            } else {
                message = "No source file"
            }
            return .redraw
        default:
            return .consumed
        }
    }

    /// `handle_editing_key` (`:839-873`): Esc discards, Enter commits —
    /// changed values fold into state, mark dirty, and emit `.save`;
    /// unchanged commits leave state, disk, and message untouched.
    private mutating func handleEditingKey(_ event: KeyEvent) -> PagerPersonaDetailOutcome {
        if event.key == .escape {
            editingField = nil
            editingText = ""
            editingOriginal = ""
            return .redraw
        }
        if event.key == .enter {
            guard let field = editingField else { return .consumed }
            let newValue = editingText
            let changed = newValue != editingOriginal
            editingField = nil
            editingText = ""
            editingOriginal = ""
            if changed {
                setFieldValue(field, newValue)
                dirty = true
                return .save
            }
            return .redraw
        }
        switch event.key {
        case .backspace:
            guard !editingText.isEmpty else { return .consumed }
            editingText.removeLast()
            return .redraw
        case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
            guard !character.isNewline,
                  character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
            else { return .consumed }
            editingText.append(character)
            return .redraw
        default:
            return .consumed
        }
    }
}

// MARK: - Word wrap

/// `word_wrap_lines` (`persona_detail.rs:901-928`): wraps each raw line
/// independently at spaces; a word longer than the width gets its own
/// line; empty text yields one empty line. Split on `Character.isNewline`
/// because values come off disk and may carry CRLF (AGENTS.md §2).
func personaDetailWordWrap(_ text: String, maxWidth: Int) -> [String] {
    var lines: [String] = []
    for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        let raw = String(rawLine)
        if UnicodeDisplayWidth.width(of: raw) <= maxWidth {
            lines.append(raw)
            continue
        }
        var current = ""
        var currentWidth = 0
        for word in raw.split(whereSeparator: { $0.isWhitespace }) {
            let wordWidth = UnicodeDisplayWidth.width(of: String(word))
            if current.isEmpty {
                current = String(word)
                currentWidth = wordWidth
            } else if currentWidth + 1 + wordWidth <= maxWidth {
                current += " " + word
                currentWidth += 1 + wordWidth
            } else {
                lines.append(current)
                current = String(word)
                currentWidth = wordWidth
            }
        }
        if !current.isEmpty { lines.append(current) }
    }
    if lines.isEmpty { lines.append("") }
    return lines
}
