// PagerAgentsRender.swift
//
// Painting the agents/personas modal.
// Ports `render_agents_modal`
// (`xai-grok-pager/src/views/agents_modal.rs:1011-1758` at upstream
// 650c1db7): the tab bar, the inline message line (`:1946-1959`, painted
// first in each tab's content, `:1249-1251`/`:1519`), the `/ ` search
// row, the Agents tab's scope-header/agent/description/detail flat rows
// (`:1278-1494`), the Personas tab's blurb + name/description/tags/
// hint rows (`:1496-1758`), and — as of B9-b3 — the create-persona form
// (`render_persona_create_form`, `:1823-1896`) and the delete confirm
// dialog (`render_persona_confirm_dialog`, `:1898-1930`), each replacing
// the Personas tab body outright (`:1502-1515`). The footer carries only
// keys the overlay actually handles: `t toggle`/`s default` on the
// Agents tab (`:1080-1088`), `n new`/`d delete` on Personas
// (`:1163-1172`), and the form/confirm footers (`:1105-1135`).

import Foundation
import OpenGrokTerminalCore

// MARK: - Metrics

enum PagerAgentsMetrics {
    /// Upstream's `ModalSizing` for this modal (`agents_modal.rs:983-994`):
    /// width_pct 0.70, max 100, min 44, v_margin 4, h_pad 2, v_pad 1,
    /// footer 2.
    static let sizing = PagerModalSizing(
        widthFraction: 0.70,
        maximumWidth: 100,
        minimumWidth: 44,
        verticalMargin: 4,
        horizontalPadding: 2,
        verticalPadding: 1,
        footerLines: 2
    )

    /// Description indent under an agent row (`:1288`, `:1475`).
    static let agentDescriptionIndent = 6
    /// Description/tags/hint indent under a persona row (`:1562`, `:1698`).
    static let personaDescriptionIndent = 4
}

// MARK: - Glyphs (upstream's own, `agents_modal.rs`)

private enum AgentsGlyphs {
    /// Collapsed/expanded indicators (`:1367-1371`, `:1638-1642`).
    static let collapsed = "\u{25B6} "  // ▶
    static let expanded = "\u{25BC} "   // ▼
    /// Enabled/disabled status dots (`:1380-1384`; `filled_dot()` is
    /// U+25CF, `xai-grok-pager-render/src/glyphs.rs:345-351`).
    static let enabledDot = "\u{25CF} " // ●
    static let disabledDot = "\u{25CB} " // ○
}

// MARK: - Flat rows

/// `FlatRow` (`agents_modal.rs:1931-1937`) plus the persona flat rows
/// (`PersonaFlatRow`, `:1760-1766`), collapsed into one painter-facing
/// shape. `entryIndex` is nil only for rows that belong to no entry
/// (scope headers, blurbs).
private struct AgentsFlatRow {
    enum Kind {
        case scopeHeader(PagerAgentsScope)
        case agent(Int)
        case agentDescription(Int, String)
        case agentDetail(String)
        case personaName(Int)
        case personaDescription(Int, String)
        case personaTags(Int, String)
        case personaHint(Int, String)
        case blurb(String)
        case blank
    }

    var kind: Kind

    /// The selectable entry this row belongs to, for block-scroll math.
    var entryIndex: Int? {
        switch kind {
        case .agent(let index), .agentDescription(let index, _),
             .personaName(let index), .personaDescription(let index, _),
             .personaTags(let index, _), .personaHint(let index, _):
            return index
        case .agentDetail, .scopeHeader, .blurb, .blank:
            return nil
        }
    }
}

// MARK: - Body

/// Paint the modal body.
///
/// Deliberately publishes NO row bounds: the composition's click router
/// dispatches a row hit straight into the domain `select` channel, and
/// this modal's row ids are its `Enter`-view payloads — publishing them
/// would invent a click-opens-viewer affordance upstream explicitly
/// declines ("Mouse interactions don't trigger view/edit — ignore",
/// `agent_view/modals.rs:104-108`). Upstream's click-to-select/expand
/// (`agents_modal.rs:2465-2482`) has no port channel and is deferred with
/// the rest of the mouse surface; wheel scroll still navigates because it
/// rides the key channel.
func drawAgentsBody(
    _ overlay: PagerAgentsOverlay,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }
    var y = area.y

    // Tab bar. Upstream renders tabs inside the shared modal chrome
    // (`render_modal_window` with `tabs`, `:1028-1034`); this port's modal
    // chrome has no tab slot, so the bar is the first body row — the
    // extensions-modal precedent.
    if y < area.bottom {
        var spans: [PagerStyledSpan] = []
        for (index, tab) in PagerAgentsTab.all.enumerated() {
            if index > 0 {
                spans.append(PagerStyledSpan(text: " \u{2502} ", foreground: theme.grayDim))
            }
            let isActive = tab == overlay.activeTab
            spans.append(PagerStyledSpan(
                text: tab.label,
                foreground: isActive ? theme.accentUser : theme.gray,
                style: isActive ? [.bold] : []
            ))
        }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x, y: y, limit: area.right, background: theme.bgBase
        )
        y += 1
    }
    if y < area.bottom { y += 1 }

    // The create form and delete confirm replace the Personas tab body
    // outright (`render_personas_tab`, `:1502-1515`); the inline message
    // paints INSIDE the form (`:1507`), error-styled regardless of kind
    // (`:1839-1846`).
    if overlay.activeTab == .personas, let form = overlay.personaCreateForm {
        drawPersonaCreateForm(
            form,
            message: overlay.message?.text,
            in: TerminalRect(x: area.x, y: y, width: area.width, height: max(0, area.bottom - y)),
            buffer: &buffer,
            theme: theme
        )
        return []
    }
    if overlay.activeTab == .personas, let confirm = overlay.personaDeleteConfirm {
        drawPersonaConfirmDialog(
            confirm,
            in: TerminalRect(x: area.x, y: y, width: area.width, height: max(0, area.bottom - y)),
            buffer: &buffer,
            theme: theme
        )
        return []
    }

    // Body rows for the active tab, then upstream's search row placement
    // (the search paints ABOVE the list, after the blurbs on Personas —
    // `:1252-1262`, `:1528-1538`).
    let width = area.width
    var rows: [AgentsFlatRow] = []
    switch overlay.activeTab {
    case .agents:
        rows = agentsFlatRows(overlay, width: width)
    case .personas:
        rows = personasFlatRows(overlay, width: width)
    }

    // The inline message paints first in the tab content on BOTH tabs
    // (`:1249-1251`, `:1519`), before the Personas blurbs (`:1521-1527`)
    // and the search row.
    if let message = overlay.message {
        y = drawAgentsMessageLine(message, in: area, y: y, buffer: &buffer, theme: theme)
    }
    if overlay.activeTab == .personas {
        y = drawPersonaBlurbs(in: area, y: y, buffer: &buffer, theme: theme)
    }
    if overlay.searchActive || !overlay.searchQuery.isEmpty {
        y = drawAgentsSearchRow(overlay, in: area, y: y, buffer: &buffer, theme: theme)
    }

    let capacity = max(0, area.bottom - y)
    guard capacity > 0 else { return [] }

    // Empty states (`:1268-1276`, `:1544-1551`).
    if rows.isEmpty {
        let message: String
        switch overlay.activeTab {
        case .agents:
            message = overlay.searchQuery.isEmpty ? "No agents found" : "No matching agents"
        case .personas:
            message = overlay.personas.isEmpty ? "No personas available" : "No matching personas"
        }
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(message, width: width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
        return []
    }

    // Block scroll: keep the selected entry's whole block visible.
    // Upstream mutates a stored scroll during render (`:1303-1329`); this
    // port computes the offset from selection each frame, the extensions
    // modal's recorded approach — same observable rule for keyboard
    // browsing, no persistent free-scroll.
    let selectedEntry = overlay.activeTab == .agents
        ? overlay.selectedAgent
        : overlay.selectedPersona
    var blocks: [(height: Int, firstRow: Int)] = []
    var blockForEntry: [Int: Int] = [:]
    var index = 0
    while index < rows.count {
        let start = index
        let entry = rows[index].entryIndex
        index += 1
        // A block is one entry's rows plus any leading header and trailing
        // detail rows; headerless rows (blurb handled above) fold forward.
        while index < rows.count {
            let kind = rows[index].kind
            if case .scopeHeader = kind { break }
            if case .agent = kind { break }
            if case .personaName = kind { break }
            index += 1
        }
        blocks.append((height: index - start, firstRow: start))
        if case .scopeHeader = rows[start].kind {
            if start + 1 < index, let owner = rows[start + 1].entryIndex {
                blockForEntry[owner] = blocks.count - 1
            }
        } else if let entry, blockForEntry[entry] == nil {
            blockForEntry[entry] = blocks.count - 1
        }
    }
    let selectedBlock = blockForEntry[selectedEntry] ?? 0
    let offsetBlock = settingsScrollOffset(
        heights: blocks.map(\.height),
        selected: selectedBlock,
        capacity: capacity
    )
    let firstVisibleRow = blocks.indices.contains(offsetBlock) ? blocks[offsetBlock].firstRow : 0

    var cursor = y
    for row in rows[firstVisibleRow...] {
        guard cursor < area.bottom else { break }
        drawAgentsFlatRow(overlay, row: row, in: area, y: cursor, buffer: &buffer, theme: theme)
        cursor += 1
    }
    return []
}

// MARK: - Flat-row construction

/// The Agents tab's flat rows (`render_agents_tab`, `:1278-1302`): a scope
/// header whenever the scope changes, the agent row, its word-wrapped
/// description (always shown, `:1287-1295`), and — when expanded — the
/// precomputed detail lines.
private func agentsFlatRows(_ overlay: PagerAgentsOverlay, width: Int) -> [AgentsFlatRow] {
    var rows: [AgentsFlatRow] = []
    var currentScope: PagerAgentsScope?
    for index in overlay.filteredAgentIndices() {
        let entry = overlay.agents[index]
        if currentScope != entry.scope {
            currentScope = entry.scope
            rows.append(AgentsFlatRow(kind: .scopeHeader(entry.scope)))
        }
        rows.append(AgentsFlatRow(kind: .agent(index)))
        if !entry.description.isEmpty {
            let descriptionWidth = max(0, width - PagerAgentsMetrics.agentDescriptionIndent)
            if descriptionWidth > 0 {
                for line in agentsWordWrap(entry.description, maxWidth: descriptionWidth) {
                    rows.append(AgentsFlatRow(kind: .agentDescription(index, line)))
                }
            }
        }
        if overlay.expandedAgents.contains(index) {
            for line in entry.detailLines {
                rows.append(AgentsFlatRow(kind: .agentDetail(line)))
            }
        }
    }
    return rows
}

/// The Personas tab's flat rows (`render_personas_tab`, `:1553-1584`):
/// name row, then — expanded only — wrapped description, capability tags,
/// and the view hint.
private func personasFlatRows(_ overlay: PagerAgentsOverlay, width: Int) -> [AgentsFlatRow] {
    var rows: [AgentsFlatRow] = []
    for index in overlay.filteredPersonaIndices() {
        rows.append(AgentsFlatRow(kind: .personaName(index)))
        guard overlay.expandedPersonas.contains(index) else { continue }
        let persona = overlay.personas[index]
        if let description = persona.description, !description.isEmpty {
            let descriptionWidth = max(0, width - PagerAgentsMetrics.personaDescriptionIndent)
            if descriptionWidth > 0 {
                for line in agentsWordWrap(description, maxWidth: descriptionWidth) {
                    rows.append(AgentsFlatRow(kind: .personaDescription(index, line)))
                }
            }
        }
        if persona.hasInputs || persona.hasOutputs {
            var tags: [String] = []
            if persona.hasInputs { tags.append("accepts structured inputs") }
            if persona.hasOutputs { tags.append("produces structured outputs") }
            rows.append(AgentsFlatRow(
                kind: .personaTags(index, tags.joined(separator: " \u{00B7} "))
            ))
        }
        rows.append(AgentsFlatRow(
            kind: .personaHint(index, "Enter to view full definition")
        ))
    }
    return rows
}

// MARK: - Row painting

private func drawAgentsFlatRow(
    _ overlay: PagerAgentsOverlay,
    row: AgentsFlatRow,
    in area: TerminalRect,
    y: Int,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    let rowArea = TerminalRect(x: area.x, y: y, width: area.width, height: 1)
    switch row.kind {
    case .blank:
        return
    case .blurb(let text):
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(text, width: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
        return
    case .scopeHeader(let scope):
        // `:1337-1347` — bold, dim.
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(scope.headerLabel, width: area.width),
            style: [.bold], foreground: theme.grayDim, background: theme.bgBase
        )
        return
    case .agent(let index):
        let entry = overlay.agents[index]
        let isSelected = index == overlay.selectedAgent
        let background = isSelected ? theme.bgHighlight : theme.bgBase
        if isSelected {
            paintBlank(&buffer, area: rowArea, foreground: theme.textPrimary, background: background)
        }
        // Row shape (`:1366-1465`): indicator, status dot, bold name,
        // ` default` marker, ` [off]` marker, then the scope badge one
        // column later. The session-active ` active` marker (`:1409-1427`)
        // is the recorded B9 deferral — no session-agent-name channel.
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(
                text: overlay.expandedAgents.contains(index)
                    ? AgentsGlyphs.expanded
                    : AgentsGlyphs.collapsed,
                foreground: theme.grayDim
            ),
            PagerStyledSpan(
                text: entry.enabled ? AgentsGlyphs.enabledDot : AgentsGlyphs.disabledDot,
                foreground: entry.enabled ? theme.accentSuccess : theme.grayDim
            ),
            PagerStyledSpan(text: entry.name, foreground: theme.textPrimary, style: [.bold])
        ]
        if entry.name == overlay.defaultAgentName {
            spans.append(PagerStyledSpan(
                text: " default",
                foreground: theme.textPrimary,
                style: [.bold, .dim]
            ))
        }
        if !entry.enabled {
            spans.append(PagerStyledSpan(text: " [off]", foreground: theme.grayDim))
        }
        spans.append(PagerStyledSpan(text: " ", foreground: theme.grayDim))
        spans.append(PagerStyledSpan(
            text: entry.scope.badgeLabel,
            foreground: agentsScopeBadgeColor(entry.scope, theme: theme)
        ))
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x, y: y, limit: area.right, background: background
        )
        return
    case .agentDescription(let index, let line):
        let isSelected = index == overlay.selectedAgent
        let background = isSelected ? theme.bgHighlight : theme.bgBase
        if isSelected {
            paintBlank(&buffer, area: rowArea, foreground: theme.gray, background: background)
        }
        let indent = PagerAgentsMetrics.agentDescriptionIndent
        _ = buffer.setString(
            x: area.x + indent, y: y,
            text: truncateToWidth(line, width: max(0, area.width - indent)),
            style: [], foreground: theme.gray, background: background
        )
        return
    case .agentDetail(let line):
        // `:1487-1491` — plain dim lines, never highlighted.
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(line, width: area.width),
            style: [], foreground: theme.gray, background: theme.bgBase
        )
        return
    case .personaName(let index):
        let persona = overlay.personas[index]
        let isSelected = index == overlay.selectedPersona
        let isExpanded = overlay.expandedPersonas.contains(index)
        let background = isSelected ? theme.bgHighlight : theme.bgBase
        if isSelected {
            paintBlank(&buffer, area: rowArea, foreground: theme.textPrimary, background: background)
        }
        // `:1637-1688`: indicator, bold name, ` {scope} ` badge, and —
        // collapsed only — ` — description` truncated to the row.
        var spans: [PagerStyledSpan] = [
            PagerStyledSpan(
                text: isExpanded ? AgentsGlyphs.expanded : AgentsGlyphs.collapsed,
                foreground: theme.grayDim
            ),
            PagerStyledSpan(text: persona.name, foreground: theme.textPrimary, style: [.bold])
        ]
        if let scope = persona.scopeLabel {
            spans.append(PagerStyledSpan(text: " \(scope) ", foreground: theme.accentUser))
        }
        if !isExpanded, let description = persona.description, !description.isEmpty {
            spans.append(PagerStyledSpan(text: " \u{2014} ", foreground: theme.gray))
            spans.append(PagerStyledSpan(text: description, foreground: theme.gray))
        }
        paintSpans(
            &buffer,
            spans: truncateSpans(spans, to: area.width),
            x: area.x, y: y, limit: area.right, background: background
        )
        return
    case .personaDescription(let index, let line):
        let isSelected = index == overlay.selectedPersona
        let background = isSelected ? theme.bgHighlight : theme.bgBase
        if isSelected {
            paintBlank(&buffer, area: rowArea, foreground: theme.gray, background: background)
        }
        let indent = PagerAgentsMetrics.personaDescriptionIndent
        _ = buffer.setString(
            x: area.x + indent, y: y,
            text: truncateToWidth(line, width: max(0, area.width - indent)),
            style: [], foreground: theme.gray, background: background
        )
        return
    case .personaTags(let index, let tags):
        let isSelected = index == overlay.selectedPersona
        let background = isSelected ? theme.bgHighlight : theme.bgBase
        if isSelected {
            paintBlank(&buffer, area: rowArea, foreground: theme.grayDim, background: background)
        }
        let indent = PagerAgentsMetrics.personaDescriptionIndent
        _ = buffer.setString(
            x: area.x + indent, y: y,
            text: truncateToWidth("[\(tags)]", width: max(0, area.width - indent)),
            style: [], foreground: theme.grayDim, background: background
        )
        return
    case .personaHint(let index, let text):
        let isSelected = index == overlay.selectedPersona
        let background = isSelected ? theme.bgHighlight : theme.bgBase
        if isSelected {
            paintBlank(&buffer, area: rowArea, foreground: theme.grayDim, background: background)
        }
        let indent = PagerAgentsMetrics.personaDescriptionIndent
        _ = buffer.setString(
            x: area.x + indent, y: y,
            text: truncateToWidth(text, width: max(0, area.width - indent)),
            style: [], foreground: theme.grayDim, background: background
        )
        return
    }
}

/// Scope badge colors (`scope_badge`, `:1002-1007`).
private func agentsScopeBadgeColor(
    _ scope: PagerAgentsScope,
    theme: PagerRenderTheme
) -> TerminalColor {
    switch scope {
    case .builtIn: return theme.accentAssistant
    case .project: return theme.accentUser
    case .user: return theme.textSecondary
    case .bundled: return theme.grayDim
    }
}

/// `render_modal_message_line` (`:1946-1959`): one line, char-truncated
/// to the content width, colored by kind (`message_line_style`,
/// `:1938-1945`), followed by upstream's blank separator (`y + 1` then
/// `+ 1` again).
private func drawAgentsMessageLine(
    _ message: PagerAgentsMessage,
    in area: TerminalRect,
    y: Int,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> Int {
    guard y < area.bottom else { return y }
    let foreground: TerminalColor
    switch message.kind {
    case .error: foreground = theme.accentError
    case .success: foreground = theme.accentSuccess
    case .info: foreground = theme.textSecondary
    }
    _ = buffer.setString(
        x: area.x, y: y,
        // Upstream truncates by chars (`msg.text.chars().take(w)`), not
        // display columns.
        text: String(message.text.prefix(area.width)),
        style: [], foreground: foreground, background: theme.bgBase
    )
    return min(y + 2, area.bottom)
}

/// The `/ ` search row (`render_agents_search`, `:1188-1239`), followed by
/// upstream's blank spacer row (`y += 1; y += 1`, `:1260-1261`).
private func drawAgentsSearchRow(
    _ overlay: PagerAgentsOverlay,
    in area: TerminalRect,
    y: Int,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> Int {
    guard y < area.bottom else { return y }
    var spans: [PagerStyledSpan] = [
        PagerStyledSpan(text: "/ ", foreground: theme.accentUser)
    ]
    if !overlay.searchQuery.isEmpty {
        spans.append(PagerStyledSpan(text: overlay.searchQuery, foreground: theme.accentUser))
    }
    if overlay.searchActive {
        // The port's block cursor stand-in for upstream's inverted cell
        // (`:1231-1238`) — the extensions search row's convention.
        spans.append(PagerStyledSpan(text: "\u{258F}", foreground: theme.accentUser))
    }
    paintSpans(
        &buffer,
        spans: truncateSpans(spans, to: area.width),
        x: area.x, y: y, limit: area.right, background: theme.bgBase
    )
    return min(y + 2, area.bottom)
}

/// The Personas tab's two-line blurb + blank spacer (`:1521-1527`),
/// byte-exact copy.
private func drawPersonaBlurbs(
    in area: TerminalRect,
    y: Int,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> Int {
    var cursor = y
    let blurbs = [
        "Personas shape subagent behavior via the persona parameter on spawn_subagent.",
        "Used by skills (e.g. /implement) and by the model when spawning subagents."
    ]
    for blurb in blurbs {
        guard cursor < area.bottom else { return cursor }
        _ = buffer.setString(
            x: area.x, y: cursor,
            text: truncateToWidth(blurb, width: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
        cursor += 1
    }
    return min(cursor + 1, area.bottom)
}

// MARK: - Create form / delete confirm (B9-b3)

/// One labeled single-line text field of the create form
/// (`render_create_text_field`, `:1783-1821`): accent label when active,
/// the value, and — active only — the port's block-cursor glyph standing
/// in for upstream's inverted cursor cell (the append-only editor keeps
/// the cursor at the end). Returns the next row (`y + 2`).
private func drawPersonaCreateField(
    label: String,
    text: String,
    active: Bool,
    in area: TerminalRect,
    y: Int,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> Int {
    guard y < area.bottom else { return y }
    var spans: [PagerStyledSpan] = [
        PagerStyledSpan(
            text: label,
            foreground: active ? theme.accentUser : theme.gray
        ),
        PagerStyledSpan(text: text, foreground: theme.textPrimary)
    ]
    if active {
        spans.append(PagerStyledSpan(text: "\u{258F}", foreground: theme.textPrimary))
    }
    paintSpans(
        &buffer,
        spans: truncateSpans(spans, to: area.width),
        x: area.x, y: y, limit: area.right, background: theme.bgBase
    )
    return y + 2
}

/// `render_persona_create_form` (`agents_modal.rs:1823-1896`): title,
/// error line, the three text fields, the scope row, and the hint line —
/// copy byte-parity.
func drawPersonaCreateForm(
    _ form: PagerPersonaCreateForm,
    message: String?,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    var y = area.y
    _ = buffer.setString(
        x: area.x, y: y,
        text: truncateToWidth("Create New Persona", width: area.width),
        style: [.bold], foreground: theme.textPrimary, background: theme.bgBase
    )
    y += 2
    if let message, y < area.bottom {
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(message, width: area.width),
            style: [], foreground: theme.accentError, background: theme.bgBase
        )
        y += 2
    }
    y = drawPersonaCreateField(
        label: "Name: ", text: form.name,
        active: form.activeField == .name,
        in: area, y: y, buffer: &buffer, theme: theme
    )
    y = drawPersonaCreateField(
        label: "Description: ", text: form.description,
        active: form.activeField == .description,
        in: area, y: y, buffer: &buffer, theme: theme
    )
    y = drawPersonaCreateField(
        label: "Instructions: ", text: form.instructions,
        active: form.activeField == .instructions,
        in: area, y: y, buffer: &buffer, theme: theme
    )
    if y < area.bottom {
        // The scope row (`:1878-1892`).
        let scopeActive = form.activeField == .scope
        paintSpans(
            &buffer,
            spans: truncateSpans([
                PagerStyledSpan(
                    text: "Scope: ",
                    foreground: scopeActive ? theme.accentUser : theme.gray
                ),
                PagerStyledSpan(text: "[\(form.scope.label)]", foreground: theme.textPrimary)
            ], to: area.width),
            x: area.x, y: y, limit: area.right, background: theme.bgBase
        )
    }
    y += 2
    if y < area.bottom {
        let hint = "Tab/\u{2191}\u{2193}: field | Space/\u{2190}\u{2192} on scope: "
            + "user/project | Enter: create | Esc: cancel"
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth(hint, width: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
    }
}

/// `render_persona_confirm_dialog` (`agents_modal.rs:1898-1930`), copy
/// byte-parity.
func drawPersonaConfirmDialog(
    _ confirm: PagerPersonaDeleteConfirm,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    var y = area.y
    _ = buffer.setString(
        x: area.x, y: y,
        text: truncateToWidth("Delete Persona", width: area.width),
        style: [.bold], foreground: theme.accentError, background: theme.bgBase
    )
    y += 2
    if y < area.bottom {
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth("Delete persona '\(confirm.name)'?", width: area.width),
            style: [], foreground: theme.textPrimary, background: theme.bgBase
        )
    }
    y += 1
    if y < area.bottom {
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth("  \(confirm.path)", width: area.width),
            style: [], foreground: theme.gray, background: theme.bgBase
        )
    }
    y += 2
    if y < area.bottom {
        _ = buffer.setString(
            x: area.x, y: y,
            text: truncateToWidth("y: confirm | n/Esc: cancel", width: area.width),
            style: [], foreground: theme.grayDim, background: theme.bgBase
        )
    }
}

/// `word_wrap` (`agents_modal.rs:830-856`): break at spaces; a word longer
/// than the width gets its own line, never hard-broken; empty text yields
/// one empty line.
func agentsWordWrap(_ text: String, maxWidth: Int) -> [String] {
    var lines: [String] = []
    var current = ""
    var currentWidth = 0
    for word in text.split(whereSeparator: { $0.isWhitespace }) {
        let wordWidth = UnicodeDisplayWidth.width(of: String(word))
        if currentWidth == 0 {
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
    if lines.isEmpty { lines.append("") }
    return lines
}

// MARK: - Footer

/// The footer lists exactly the keys `PagerAgentsOverlay.handle` acts on,
/// per tab and mode. The Agents tab is upstream's full set
/// (`build_agents_tab_shortcuts`, `:1052-1101`) including the b2 verbs
/// `t toggle` (`:1080-1083`) and `s default` (`:1084-1088`). The
/// Personas tab is `build_personas_tab_shortcuts` (`:1103-1187`): the
/// create-form footer (`:1105-1122`), the confirm footer (`:1123-1135`),
/// and the browse set including `n new` (`:1163-1167`) and `d delete`
/// (`:1168-1172`) — advertised only now that B9-b3 backs them.
func pagerAgentsHints(_ overlay: PagerAgentsOverlay) -> [PagerOverlayHint] {
    if overlay.activeTab == .personas, overlay.personaCreateForm != nil {
        return [
            PagerOverlayHint(key: "Tab", label: "switch field"),
            PagerOverlayHint(key: "Enter", label: "create"),
            PagerOverlayHint(key: "Esc", label: "cancel")
        ]
    }
    if overlay.activeTab == .personas, overlay.personaDeleteConfirm != nil {
        return [
            PagerOverlayHint(key: "y", label: "confirm"),
            PagerOverlayHint(key: "n/Esc", label: "cancel")
        ]
    }
    if overlay.searchActive {
        return [
            PagerOverlayHint(key: "type", label: "to search"),
            PagerOverlayHint(key: "Enter", label: "commit"),
            PagerOverlayHint(key: "Tab", label: "switch tab"),
            PagerOverlayHint(key: "Esc", label: "clear")
        ]
    }
    var hints = [
        PagerOverlayHint(key: "j/k", label: "nav"),
        PagerOverlayHint(key: "e/\u{2192}", label: "expand"),
        PagerOverlayHint(key: "E/\u{2190}", label: "collapse"),
        PagerOverlayHint(key: "Enter", label: "view"),
        PagerOverlayHint(key: "/", label: "search")
    ]
    if overlay.activeTab == .agents {
        hints.append(PagerOverlayHint(key: "t", label: "toggle"))
        hints.append(PagerOverlayHint(key: "s", label: "default"))
    }
    if overlay.activeTab == .personas {
        hints.append(PagerOverlayHint(key: "n", label: "new"))
        hints.append(PagerOverlayHint(key: "d", label: "delete"))
    }
    hints.append(PagerOverlayHint(key: "Tab", label: "switch tab"))
    hints.append(PagerOverlayHint(key: "Esc", label: "close"))
    return hints
}
