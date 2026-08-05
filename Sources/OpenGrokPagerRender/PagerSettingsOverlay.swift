// PagerSettingsOverlay.swift
//
// The settings modal's state and key handling.
// Ports `xai-grok-pager/src/views/settings_modal/state.rs` and `input.rs`
// at upstream 9ed09e2a.
//
// The modal is a value type that owns its own navigation, filter, expansion,
// and sub-sheet state, and reports what the user *decided* as an event. It
// never writes anything: `PagerSettingsStore` does the persisting, and keeping
// that out of here is what makes the whole surface testable by feeding it keys
// and reading frames back.

import Foundation
import OpenGrokTerminalCore

// MARK: - Events

/// What a keystroke decided. Everything that changes state outside the modal
/// leaves through here.
public enum PagerSettingsEvent: Sendable, Equatable {
    /// Commit `value` for `key`.
    case commit(key: String, value: PagerSettingValue)
    /// Show `value` for `key` without committing — the live theme preview.
    /// Always followed by either a `commit` or a `preview` back to the original.
    case preview(key: String, value: PagerSettingValue)
    /// A secret was entered. The plaintext is handed over exactly once and is
    /// not retained by the modal.
    case secret(key: String, value: String)
    /// Toggle one entry of a multi-select row.
    case toggleMultiSelect(key: String, choice: String, enabled: Bool)
    /// `d` — the caller confirms, then applies the row's default.
    case resetRequested(key: String)
}

/// The result of routing a key into the modal.
public enum PagerSettingsOutcome: Sendable, Equatable {
    case redraw
    /// Consumed with no state change. An active modal swallows every key.
    case consumed
    case close
    case event(PagerSettingsEvent)
    /// An event that also closes the modal — the deep-link entry points.
    case eventAndClose(PagerSettingsEvent)
}

// MARK: - Rows

/// One line in the browse list. Headers are painted and skipped by the cursor.
public enum PagerSettingsRow: Sendable, Equatable, Hashable {
    case header(PagerSettingCategory)
    case setting(String)

    public var settingKey: String? {
        if case .setting(let key) = self { return key }
        return nil
    }

    var isSelectable: Bool { settingKey != nil }
}

// MARK: - Modes

/// `SettingsMode` (`state.rs:151-181`).
public enum PagerSettingsMode: Sendable, Equatable, Hashable {
    case browse
    /// The filter field has focus. Distinct from browse-with-a-query: the
    /// reference keeps a committed query while returning focus to the list.
    case filtering
    case pickingEnum(key: String, choiceIndex: Int, originalValue: String)
    case pickingGroup(key: String, childIndex: Int)
    case editingString(key: String, buffer: String, cursor: Int, error: String?)
    case editingSecret(key: String, buffer: String, error: String?)
    case editingInt(key: String, value: Int)

    public var settingKey: String? {
        switch self {
        case .browse, .filtering: return nil
        case .pickingEnum(let key, _, _),
             .pickingGroup(let key, _),
             .editingString(let key, _, _, _),
             .editingSecret(let key, _, _),
             .editingInt(let key, _): return key
        }
    }

    var isSubPane: Bool { settingKey != nil }
}

// MARK: - Overlay state

/// The settings modal.
public struct PagerSettingsOverlay: Sendable, Equatable {
    public var registry: PagerSettingsRegistry
    /// Current value per key. A key with no entry falls back to its default,
    /// which is what lets a caller supply only what it has actually read.
    public var values: [String: PagerSettingValue]
    /// Choices for `dynamicEnum` / `dynamicMultiSelect` rows, keyed by source.
    public var dynamicChoices: [PagerSettingDynamicSource: [PagerSettingChoice]]
    /// Which multi-select entries are on, keyed by setting key.
    public var multiSelectEnabled: [String: Set<String>]
    /// Rows the user cannot change, and why.
    public var locks: [String: PagerSettingLock]
    /// Keys hidden by a runtime gate — voice without a voice backend, the
    /// Antigravity pair without the CLI installed (`state.rs:958-991`).
    public var hiddenKeys: Set<String>
    /// Choices hidden by a runtime gate (`enum_choice_gated_off`,
    /// `state.rs:1319-1329`), keyed by setting key.
    public var gatedChoices: [String: Set<String>]
    public var minimalMode: Bool

    public var mode: PagerSettingsMode
    /// Index into `visibleRows`.
    public var selectedIndex: Int
    public var scrollOffset: Int
    public var filterQuery: String
    /// Keys whose description is pinned open. Expansion survives filtering.
    public var expandedKeys: Set<String>

    public init(
        registry: PagerSettingsRegistry = .default,
        values: [String: PagerSettingValue] = [:],
        dynamicChoices: [PagerSettingDynamicSource: [PagerSettingChoice]] = [:],
        multiSelectEnabled: [String: Set<String>] = [:],
        locks: [String: PagerSettingLock] = [:],
        hiddenKeys: Set<String> = [],
        gatedChoices: [String: Set<String>] = [:],
        minimalMode: Bool = false,
        mode: PagerSettingsMode = .browse,
        selectedIndex: Int = 0,
        scrollOffset: Int = 0,
        filterQuery: String = "",
        expandedKeys: Set<String> = []
    ) {
        self.registry = registry
        self.values = values
        self.dynamicChoices = dynamicChoices
        self.multiSelectEnabled = multiSelectEnabled
        self.locks = locks
        self.hiddenKeys = hiddenKeys
        self.gatedChoices = gatedChoices
        self.minimalMode = minimalMode
        self.mode = mode
        self.selectedIndex = selectedIndex
        self.scrollOffset = scrollOffset
        self.filterQuery = filterQuery
        self.expandedKeys = expandedKeys
        clampSelection()
    }

    // MARK: Derived state

    /// The current value of a row, falling back to its registered default.
    public func value(for key: String) -> PagerSettingValue? {
        values[key] ?? registry.find(key)?.defaultValue
    }

    /// Whether a row is offered at all right now. Group children never appear
    /// at top level; hidden-in-minimal rows drop out in minimal mode.
    func isVisible(_ meta: PagerSettingMeta) -> Bool {
        if hiddenKeys.contains(meta.key) { return false }
        if minimalMode, meta.hiddenInMinimal { return false }
        return !registry.groupChildKeys.contains(meta.key)
    }

    /// The browse list: category headers over their matching rows, with a
    /// header emitted only when its section has at least one visible row
    /// (`build_rows`, `state.rs:993-1035`).
    public var visibleRows: [PagerSettingsRow] {
        let matched: Set<String>
        if filterQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            matched = Set(registry.entries.map(\.key))
        } else {
            matched = Set(registry.search(filterQuery).map(\.key))
        }

        var rows: [PagerSettingsRow] = []
        for category in PagerSettingCategory.ordered {
            let section = registry.entries.filter {
                $0.category == category && isVisible($0) && matched.contains($0.key)
            }
            guard !section.isEmpty else { continue }
            rows.append(.header(category))
            rows.append(contentsOf: section.map { PagerSettingsRow.setting($0.key) })
        }
        return rows
    }

    public var selectedKey: String? {
        let rows = visibleRows
        guard rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex].settingKey
    }

    public var selectedMeta: PagerSettingMeta? {
        selectedKey.flatMap { registry.find($0) }
    }

    /// The choices a row offers right now: its static list, or the dynamic list
    /// for its source, minus anything gated off.
    public func choices(for meta: PagerSettingMeta) -> [PagerSettingChoice] {
        let base: [PagerSettingChoice]
        switch meta.kind {
        case .enumeration(_, let choices, _):
            base = choices
        case .dynamicEnum(_, let source, _), .dynamicMultiSelect(let source):
            base = dynamicChoices[source] ?? []
        default:
            return []
        }
        guard let gated = gatedChoices[meta.key], !gated.isEmpty else { return base }
        return base.filter { !gated.contains($0.canonical) }
    }

    /// The children of a group row, in registration order.
    public func children(of meta: PagerSettingMeta) -> [PagerSettingMeta] {
        guard case .group(let keys) = meta.kind else { return [] }
        return keys.compactMap { registry.find($0) }
    }

    public func isLocked(_ key: String) -> Bool { locks[key] != nil }

    // MARK: Selection

    mutating func clampSelection() {
        let rows = visibleRows
        guard !rows.isEmpty else {
            selectedIndex = 0
            scrollOffset = 0
            return
        }
        selectedIndex = min(max(0, selectedIndex), rows.count - 1)
        if !rows[selectedIndex].isSelectable {
            if let forward = rows[selectedIndex...].firstIndex(where: \.isSelectable) {
                selectedIndex = forward
            } else if let back = rows[...selectedIndex].lastIndex(where: \.isSelectable) {
                selectedIndex = back
            }
        }
        scrollOffset = max(0, scrollOffset)
    }

    mutating func move(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty, delta != 0 else { return }
        let step = delta > 0 ? 1 : -1
        var index = selectedIndex
        for _ in 0..<abs(delta) {
            var next = index + step
            while rows.indices.contains(next), !rows[next].isSelectable { next += step }
            guard rows.indices.contains(next) else { break }
            index = next
        }
        selectedIndex = index
    }

    mutating func moveToEdge(last: Bool) {
        let rows = visibleRows
        let target = last
            ? rows.lastIndex(where: \.isSelectable)
            : rows.firstIndex(where: \.isSelectable)
        guard let target else { return }
        selectedIndex = target
    }
}

// MARK: - Key handling

extension PagerSettingsOverlay {
    /// `PageUp` / `PageDown` advance by ten rows regardless of viewport height
    /// (`input.rs:987-1128`) — the reference uses a fixed step here, unlike the
    /// picker overlays.
    static let pageStep = 10

    /// Route a key. `viewportHeight` is unused by browse navigation for the
    /// reason above, and is threaded only so the signature matches the other
    /// overlay handlers.
    public mutating func handle(_ event: KeyEvent) -> PagerSettingsOutcome {
        // F2 and Ctrl+, close from anywhere, including inside a sub-sheet
        // (`is_close_key`, `input.rs:951-963`). Esc is deliberately not here:
        // it means "back out one level".
        if isCloseKey(event) { return .close }

        switch mode {
        case .browse: return handleBrowse(event)
        case .filtering: return handleFiltering(event)
        case .pickingEnum: return handlePickingEnum(event)
        case .pickingGroup: return handlePickingGroup(event)
        case .editingString: return handleEditingString(event)
        case .editingSecret: return handleEditingSecret(event)
        case .editingInt: return handleEditingInt(event)
        }
    }

    /// `is_close_key` (`input.rs:951-963`): F2, Ctrl+, and Cmd+,.
    private func isCloseKey(_ event: KeyEvent) -> Bool {
        if case .f(2) = event.key { return true }
        if case .char(",") = event.key,
           event.modifiers.contains(.control) || event.modifiers.contains(.superKey) {
            return true
        }
        return false
    }

    // MARK: Browse

    private mutating func handleBrowse(_ event: KeyEvent) -> PagerSettingsOutcome {
        switch event.key {
        case .escape:
            return .close
        case .up:
            move(by: -1); return .redraw
        case .down:
            move(by: 1); return .redraw
        case .pageUp:
            move(by: -Self.pageStep); return .redraw
        case .pageDown:
            move(by: Self.pageStep); return .redraw
        case .right:
            return expandSelected(true)
        case .left:
            return expandSelected(false)
        case .enter:
            return activateSelected()
        case .backspace:
            // Edits the committed query in place without taking focus back
            // (`input.rs:1120`), so a typo does not cost a mode switch.
            guard !filterQuery.isEmpty else { return .consumed }
            filterQuery.removeLast()
            selectedIndex = 0
            clampSelection()
            return .redraw
        case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
            switch character {
            case "j": move(by: 1); return .redraw
            case "k": move(by: -1); return .redraw
            case "g": moveToEdge(last: false); return .redraw
            case "G": moveToEdge(last: true); return .redraw
            case "l": return expandSelected(true)
            case "h": return expandSelected(false)
            case " ": return toggleSelectedBool()
            case "/", "i":
                mode = .filtering
                return .redraw
            case "d":
                // Headers, group rows, and locked rows have no default to
                // restore, so `d` is a no-op rather than an error.
                guard let meta = selectedMeta,
                      meta.kind.isEditable,
                      !isLocked(meta.key)
                else { return .consumed }
                return .event(.resetRequested(key: meta.key))
            default:
                return .consumed
            }
        default:
            return .consumed
        }
    }

    private mutating func expandSelected(_ expand: Bool) -> PagerSettingsOutcome {
        guard let key = selectedKey else { return .consumed }
        let changed = expand ? expandedKeys.insert(key).inserted : expandedKeys.remove(key) != nil
        return changed ? .redraw : .consumed
    }

    private mutating func toggleSelectedBool() -> PagerSettingsOutcome {
        guard let meta = selectedMeta, !isLocked(meta.key),
              case .bool = meta.kind,
              case .bool(let current)? = value(for: meta.key)
        else { return .consumed }
        let next = !current
        values[meta.key] = .bool(next)
        return .event(.commit(key: meta.key, value: .bool(next)))
    }

    /// `Enter` (`input.rs:1063-1091`): Bool toggles in place, everything else
    /// opens the matching sub-pane.
    private mutating func activateSelected() -> PagerSettingsOutcome {
        guard let meta = selectedMeta else { return .consumed }
        guard !isLocked(meta.key) else { return .consumed }

        switch meta.kind {
        case .bool:
            return toggleSelectedBool()

        case .group:
            guard !children(of: meta).isEmpty else { return .consumed }
            mode = .pickingGroup(key: meta.key, childIndex: 0)
            return .redraw

        case .dynamicMultiSelect:
            guard !choices(for: meta).isEmpty else { return .consumed }
            mode = .pickingGroup(key: meta.key, childIndex: 0)
            return .redraw

        case .enumeration, .dynamicEnum:
            let list = choices(for: meta)
            guard !list.isEmpty else { return .consumed }
            let current = stringValue(for: meta.key)
            let index = list.firstIndex { $0.canonical == current } ?? 0
            mode = .pickingEnum(key: meta.key, choiceIndex: index, originalValue: current)
            return .redraw

        case .integer(_, let minimum, let maximum):
            let current: Int
            if case .integer(let stored)? = value(for: meta.key) { current = stored } else { current = minimum }
            mode = .editingInt(key: meta.key, value: min(max(current, minimum), maximum))
            return .redraw

        case .string:
            mode = .editingString(
                key: meta.key,
                buffer: stringValue(for: meta.key),
                cursor: stringValue(for: meta.key).count,
                error: nil
            )
            return .redraw

        case .secret:
            // The editor starts empty on purpose: there is nothing to show, and
            // pre-filling it with a mask would make Enter mean "save the mask".
            mode = .editingSecret(key: meta.key, buffer: "", error: nil)
            return .redraw
        }
    }

    func stringValue(for key: String) -> String {
        if case .string(let text)? = value(for: key) { return text }
        return ""
    }

    // MARK: Filtering

    private mutating func handleFiltering(_ event: KeyEvent) -> PagerSettingsOutcome {
        switch event.key {
        case .escape:
            // Clears the query and returns to the list. It does **not** close
            // the modal — losing every setting because you cleared a search is
            // the kind of thing users only forgive once.
            filterQuery = ""
            mode = .browse
            selectedIndex = 0
            clampSelection()
            return .redraw
        case .enter:
            mode = .browse
            clampSelection()
            return .redraw
        case .up:
            move(by: -1); return .redraw
        case .down:
            move(by: 1); return .redraw
        case .pageUp:
            move(by: -Self.pageStep); return .redraw
        case .pageDown:
            move(by: Self.pageStep); return .redraw
        case .tab:
            return .consumed
        case .backspace:
            guard !filterQuery.isEmpty else { return .consumed }
            filterQuery.removeLast()
            selectedIndex = 0
            clampSelection()
            return .redraw
        case .char("u") where event.modifiers.contains(.control):
            guard !filterQuery.isEmpty else { return .consumed }
            filterQuery = ""
            selectedIndex = 0
            clampSelection()
            return .redraw
        case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
            guard !character.isNewline, character.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint }) else {
                return .consumed
            }
            filterQuery.append(character)
            selectedIndex = 0
            clampSelection()
            return .redraw
        default:
            return .consumed
        }
    }

    // MARK: Enum chooser

    private mutating func handlePickingEnum(_ event: KeyEvent) -> PagerSettingsOutcome {
        guard case .pickingEnum(let key, let index, let original) = mode,
              let meta = registry.find(key)
        else { return .consumed }
        let list = choices(for: meta)
        guard !list.isEmpty else { mode = .browse; return .redraw }

        func moveChoice(_ delta: Int) -> PagerSettingsOutcome {
            let next = min(max(0, index + delta), list.count - 1)
            guard next != index else { return .consumed }
            mode = .pickingEnum(key: key, choiceIndex: next, originalValue: original)
            // Only the three theme rows preview live; everything else waits for
            // Enter, because previewing a permission mode would apply it.
            guard supportsPreview(meta) else { return .redraw }
            return .event(.preview(key: key, value: .string(list[next].canonical)))
        }

        switch event.key {
        case .escape:
            mode = .browse
            guard supportsPreview(meta), list[index].canonical != original else { return .redraw }
            // Walk the preview back before leaving, or the user keeps whatever
            // they last hovered over.
            return .event(.preview(key: key, value: .string(original)))
        case .up: return moveChoice(-1)
        case .down: return moveChoice(1)
        case .home:
            return moveChoice(-index)
        case .end:
            return moveChoice(list.count - 1 - index)
        case .enter:
            let chosen = list[index].canonical
            values[key] = .string(chosen)
            mode = .browse
            return .event(.commit(key: key, value: .string(chosen)))
        case .char(let character) where event.modifiers.isEmpty:
            switch character {
            case "j": return moveChoice(1)
            case "k": return moveChoice(-1)
            case "d":
                // A consent chooser has no "default" worth offering — opting a
                // user back in by pressing `d` would be a privacy bug.
                guard !isConsentChooser(key) else { return .consumed }
                mode = .browse
                return .event(.resetRequested(key: key))
            default: return .consumed
            }
        default:
            return .consumed
        }
    }

    func supportsPreview(_ meta: PagerSettingMeta) -> Bool {
        switch meta.kind {
        case .enumeration(_, _, let preview), .dynamicEnum(_, _, let preview): return preview
        default: return false
        }
    }

    /// `is_consent_chooser` (`registry.rs:955`).
    func isConsentChooser(_ key: String) -> Bool { key == "coding_data_sharing" }

    // MARK: Group / multi-select sheet

    private mutating func handlePickingGroup(_ event: KeyEvent) -> PagerSettingsOutcome {
        guard case .pickingGroup(let key, let index) = mode,
              let meta = registry.find(key)
        else { return .consumed }

        let childCount: Int
        if case .dynamicMultiSelect = meta.kind {
            childCount = choices(for: meta).count
        } else {
            childCount = children(of: meta).count
        }
        guard childCount > 0 else { mode = .browse; return .redraw }

        func moveChild(_ delta: Int) -> PagerSettingsOutcome {
            let next = min(max(0, index + delta), childCount - 1)
            guard next != index else { return .consumed }
            mode = .pickingGroup(key: key, childIndex: next)
            return .redraw
        }

        func toggleChild() -> PagerSettingsOutcome {
            if case .dynamicMultiSelect = meta.kind {
                let choice = choices(for: meta)[index].canonical
                var enabled = multiSelectEnabled[key] ?? []
                let turningOn = !enabled.contains(choice)
                if turningOn { enabled.insert(choice) } else { enabled.remove(choice) }
                multiSelectEnabled[key] = enabled
                return .event(.toggleMultiSelect(key: key, choice: choice, enabled: turningOn))
            }
            let child = children(of: meta)[index]
            guard case .bool(let current)? = value(for: child.key) else { return .consumed }
            values[child.key] = .bool(!current)
            return .event(.commit(key: child.key, value: .bool(!current)))
        }

        switch event.key {
        case .escape:
            mode = .browse
            return .redraw
        case .up: return moveChild(-1)
        case .down: return moveChild(1)
        case .enter: return toggleChild()
        case .char(let character) where event.modifiers.isEmpty:
            switch character {
            case "j": return moveChild(1)
            case "k": return moveChild(-1)
            case " ": return toggleChild()
            default: return .consumed
            }
        default:
            return .consumed
        }
    }

    // MARK: String editor

    private mutating func handleEditingString(_ event: KeyEvent) -> PagerSettingsOutcome {
        guard case .editingString(let key, var buffer, var cursor, _) = mode,
              let meta = registry.find(key)
        else { return .consumed }

        func setMode(error: String? = nil) {
            mode = .editingString(key: key, buffer: buffer, cursor: cursor, error: error)
        }

        switch event.key {
        case .escape:
            // A pure cancel: nothing was committed, so nothing needs undoing.
            mode = .browse
            return .redraw
        case .enter:
            if let error = validate(buffer, for: meta) {
                setMode(error: error)
                return .redraw
            }
            values[key] = .string(buffer)
            mode = .browse
            return .event(.commit(key: key, value: .string(buffer)))
        case .backspace:
            guard cursor > 0 else { return .consumed }
            buffer.remove(at: buffer.index(buffer.startIndex, offsetBy: cursor - 1))
            cursor -= 1
            setMode(error: validate(buffer, for: meta))
            return .redraw
        case .delete:
            guard cursor < buffer.count else { return .consumed }
            buffer.remove(at: buffer.index(buffer.startIndex, offsetBy: cursor))
            setMode(error: validate(buffer, for: meta))
            return .redraw
        case .left:
            guard cursor > 0 else { return .consumed }
            cursor -= 1
            setMode()
            return .redraw
        case .right:
            guard cursor < buffer.count else { return .consumed }
            cursor += 1
            setMode()
            return .redraw
        case .home:
            guard cursor != 0 else { return .consumed }
            cursor = 0
            setMode()
            return .redraw
        case .end:
            guard cursor != buffer.count else { return .consumed }
            cursor = buffer.count
            setMode()
            return .redraw
        case .up, .down, .pageUp, .pageDown, .tab:
            return .consumed
        case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
            guard isSafeSettingsCharacter(character) else { return .consumed }
            buffer.insert(character, at: buffer.index(buffer.startIndex, offsetBy: cursor))
            cursor += 1
            setMode(error: validate(buffer, for: meta))
            return .redraw
        default:
            return .consumed
        }
    }

    func validate(_ text: String, for meta: PagerSettingMeta) -> String? {
        guard case .string(_, let validator) = meta.kind else { return nil }
        switch validator {
        case .any:
            return nil
        case .nonEmptyToken:
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? "Value cannot be empty" : nil
        case .knownModel:
            // Empty clears the override, which is a legitimate answer.
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let known = (dynamicChoices[.activeModelCatalog] ?? []).map(\.canonical)
            guard known.isEmpty || known.contains(text) else { return "Unknown model: \(text)" }
            return nil
        }
    }

    // MARK: Secret editor

    /// `MAX_SECRET_INPUT_BYTES` (`input.rs:476`).
    static let maximumSecretBytes = 4096

    private mutating func handleEditingSecret(_ event: KeyEvent) -> PagerSettingsOutcome {
        guard case .editingSecret(let key, var buffer, _) = mode else { return .consumed }

        switch event.key {
        case .escape:
            mode = .browse
            return .redraw
        case .enter:
            // Enter on an empty buffer preserves whatever is already stored
            // rather than clearing it — clearing is what `d` (reset) is for.
            guard !buffer.isEmpty else {
                mode = .browse
                return .redraw
            }
            if let error = validateSecret(buffer) {
                mode = .editingSecret(key: key, buffer: buffer, error: error)
                return .redraw
            }
            mode = .browse
            values[key] = .secret(.stored)
            // The plaintext leaves in the event and is not retained here.
            let plaintext = buffer
            buffer = ""
            return .event(.secret(key: key, value: plaintext))
        case .backspace:
            guard !buffer.isEmpty else { return .consumed }
            buffer.removeLast()
            mode = .editingSecret(key: key, buffer: buffer, error: nil)
            return .redraw
        case .char(let character) where event.modifiers.subtracting(.shift).isEmpty:
            guard buffer.utf8.count < Self.maximumSecretBytes,
                  isSafeSettingsCharacter(character), !character.isWhitespace
            else { return .consumed }
            buffer.append(character)
            mode = .editingSecret(key: key, buffer: buffer, error: nil)
            return .redraw
        default:
            return .consumed
        }
    }

    /// `validate_secret` (`input.rs:478-492`).
    func validateSecret(_ text: String) -> String? {
        if text.utf8.count > Self.maximumSecretBytes { return "Key is too long" }
        if text.contains(where: \.isWhitespace) { return "Key cannot contain whitespace" }
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "Key contains control characters"
        }
        return nil
    }

    // MARK: Int stepper

    private mutating func handleEditingInt(_ event: KeyEvent) -> PagerSettingsOutcome {
        guard case .editingInt(let key, let current) = mode,
              let meta = registry.find(key),
              case .integer(_, let minimum, let maximum) = meta.kind
        else { return .consumed }

        // Modifier-bearing events are not steps (`handle_int_stepper`,
        // `input.rs:760-864`).
        guard event.modifiers.subtracting(.shift).isEmpty else { return .consumed }
        let (small, large) = PagerSettingsOverlay.stepSizes(minimum: minimum, maximum: maximum)

        func step(_ delta: Int) -> PagerSettingsOutcome {
            let next = min(max(current + delta, minimum), maximum)
            guard next != current else { return .consumed }
            mode = .editingInt(key: key, value: next)
            return .redraw
        }

        switch event.key {
        case .escape:
            mode = .browse
            return .redraw
        case .enter:
            values[key] = .integer(current)
            mode = .browse
            return .event(.commit(key: key, value: .integer(current)))
        case .up: return step(small)
        case .down: return step(-small)
        case .right: return step(large)
        case .left: return step(-large)
        case .char(let character):
            switch character {
            case "k": return step(small)
            case "j": return step(-small)
            case "l": return step(large)
            case "h": return step(-large)
            case "d":
                mode = .browse
                return .event(.resetRequested(key: key))
            default:
                // Digits are deliberately ignored: this is a stepper, not a
                // text field, so a stray `4` cannot become the whole value.
                return .consumed
            }
        default:
            return .consumed
        }
    }

    /// `int_step_sizes` (`render.rs:1558-1570`).
    static func stepSizes(minimum: Int, maximum: Int) -> (small: Int, large: Int) {
        let span = maximum - minimum
        if span <= 20 { return (1, max(span / 5, 1)) }
        if span <= 100 { return (1, 5) }
        return (5, 10)
    }
}

/// `safe_settings_char` — printable, non-control, and not a line break.
func isSafeSettingsCharacter(_ character: Character) -> Bool {
    guard !character.isNewline else { return false }
    return character.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
}
