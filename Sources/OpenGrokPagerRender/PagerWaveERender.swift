import Foundation
import OpenGrokTerminalCore

public func pagerWelcomeAuthDesiredRows(
    _ auth: PagerWelcomeAuthState,
    width: Int
) -> Int {
    let safeWidth = max(1, width)
    let urlRows = auth.url.map { url in
        max(1, url.filter { !$0.isNewline }.count).dividedRoundingUp(by: safeWidth)
    } ?? 0
    let deviceRows = auth.deviceCode == nil ? 0 : 2
    switch auth.phase {
    case .signingIn:
        return 3
    case .trust:
        return 5 + deviceRows + urlRows
    case .starting:
        return 2
    case .failed:
        return 3
    }
}

@discardableResult
public func renderPagerWelcomeAuth(
    _ auth: PagerWelcomeAuthState,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) -> [PagerOverlayBounds.Row] {
    guard area.width > 0, area.height > 0 else { return [] }
    paintBlank(
        &buffer,
        area: area,
        foreground: theme.textPrimary,
        background: theme.bgBase
    )
    var y = area.y
    let bottom = area.bottom

    func paintLine(_ spans: [PagerStyledSpan]) {
        guard y < bottom else { return }
        _ = paintSpans(
            &buffer,
            spans: spans,
            x: area.x,
            y: y,
            limit: area.right,
            background: theme.bgBase
        )
        y += 1
    }

    let heading: String
    switch auth.phase {
    case .signingIn:
        heading = "Sign in to \(auth.providerName)"
    case .trust:
        heading = "Approve in your browser to finish signing in."
    case .starting:
        heading = "Starting Open Grok…"
    case .failed:
        heading = "Sign-in failed"
    }
    paintLine([PagerStyledSpan(
        text: heading,
        foreground: auth.phase == .failed ? theme.accentError : theme.textPrimary,
        style: [.bold]
    )])

    if let message = auth.message, !message.isEmpty {
        paintLine([PagerStyledSpan(
            text: message,
            foreground: auth.phase == .failed ? theme.accentError : theme.gray
        )])
    }

    guard auth.phase == .trust else { return [] }
    paintLine([])
    if let code = auth.deviceCode {
        paintLine([PagerStyledSpan(
            text: code,
            foreground: theme.accentUser,
            style: [.bold]
        )])
        paintLine([PagerStyledSpan(
            text: "Make sure your browser shows this code.",
            foreground: theme.gray
        )])
    }
    if auth.rawURLMode {
        paintLine([PagerStyledSpan(
            text: "Mouse capture is off. Select the URL to copy it.",
            foreground: theme.gray
        )])
    }
    paintLine([])
    guard let url = auth.url, !url.isEmpty else { return [] }
    var column = 0
    for character in url where !character.isNewline {
        guard y < bottom else { break }
        if column >= area.width {
            column = 0
            y += 1
            guard y < bottom else { break }
        }
        _ = buffer.setString(
            x: area.x + column,
            y: y,
            text: String(character),
            foreground: theme.accentUser,
            background: theme.bgBase
        )
        column += 1
    }
    return []
}

private extension Int {
    func dividedRoundingUp(by divisor: Int) -> Int {
        guard divisor > 0 else { return self }
        return (self + divisor - 1) / divisor
    }
}

func appendWaveEBlock(
    _ block: PagerTranscriptBlock,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    let origin = lines.count
    switch block {
    case .sessionEvent(let event):
        appendSessionEvent(event, width: width, theme: theme, origin: origin, into: &lines)
    case .lifecycle(let lifecycle):
        appendLifecycle(lifecycle, width: width, theme: theme, origin: origin, into: &lines)
    case .backgroundTask(let task):
        let suffix = task.exitCode.map { " · exit \($0)" } ?? ""
        let duration = task.duration.map { " · \(pagerFormatDuration($0))" } ?? ""
        appendWaveEHeader(
            "Background \(task.kind.rawValue) \(task.id) · \(task.title)\(suffix)\(duration)",
            state: task.state,
            width: width,
            theme: theme,
            origin: origin,
            into: &lines
        )
    case .subagent(let agent):
        var detail = waveEActivityDetail(
            turns: agent.turnCount,
            tools: agent.toolCount,
            duration: agent.duration
        )
        if let activity = agent.activity, !activity.isEmpty { detail += " · \(activity)" }
        appendWaveEHeader(
            "Subagent \(agent.label)\(detail)",
            state: agent.state,
            width: width,
            theme: theme,
            origin: origin,
            into: &lines
        )
        if agent.isExpanded, let outcome = agent.outcome, !outcome.isEmpty {
            appendWaveEBody(outcome, width: width, color: theme.textSecondary, origin: origin, into: &lines)
        }
    case .swarm(let swarm):
        appendWaveEHeader(
            "Swarm · \(swarm.objective) · \(swarm.members.count) members",
            state: swarm.state,
            width: width,
            theme: theme,
            origin: origin,
            into: &lines
        )
        if swarm.isExpanded {
            for (index, member) in swarm.members.enumerated() {
                let branch = index == swarm.members.count - 1 ? "└─" : "├─"
                let detail = waveEActivityDetail(
                    turns: member.turnCount,
                    tools: member.toolCount,
                    duration: member.duration
                )
                let activity = member.activity.map { " · \($0)" } ?? ""
                appendWaveERow(
                    spans: [
                        PagerStyledSpan(text: "\(branch) \(waveEStateGlyph(member.state)) ", foreground: waveEStateColor(member.state, theme)),
                        PagerStyledSpan(text: member.label, foreground: theme.textPrimary, style: [.bold]),
                        PagerStyledSpan(text: "\(detail)\(activity)", foreground: theme.gray)
                    ],
                    width: width,
                    accent: waveEStateColor(swarm.state, theme),
                    origin: origin,
                    into: &lines
                )
                if let outcome = member.outcome, !outcome.isEmpty {
                    appendWaveEBody("   \(outcome)", width: width, color: theme.textSecondary, origin: origin, into: &lines)
                }
            }
            if let outcome = swarm.outcome, !outcome.isEmpty {
                appendWaveEBody(outcome, width: width, color: theme.textSecondary, origin: origin, into: &lines)
            }
        }
    case .workflow(let workflow):
        appendWaveEHeader(
            "Workflow \(workflow.name) · \(workflow.objective) · \(workflow.agentCount) agents",
            state: workflow.state,
            width: width,
            theme: theme,
            origin: origin,
            into: &lines
        )
        if workflow.isExpanded {
            if !workflow.phases.isEmpty {
                let trail = workflow.phases.map { "\(waveEStateGlyph($0.state)) \($0.label)" }.joined(separator: "  →  ")
                appendWaveEBody(trail, width: width, color: theme.grayBright, origin: origin, into: &lines)
            }
            if let outcome = workflow.outcome, !outcome.isEmpty {
                appendWaveEBody(outcome, width: width, color: theme.textSecondary, origin: origin, into: &lines)
            }
        }
    case .btw(let btw):
        appendWaveEHeader(
            "BTW · \(btw.question)",
            state: btw.answer == nil ? .running : .succeeded,
            width: width,
            theme: theme,
            accentOverride: theme.accentPlan,
            origin: origin,
            into: &lines
        )
        if btw.isExpanded {
            appendWaveEBody(
                btw.answer ?? "Waiting for side answer…",
                width: width,
                color: btw.answer == nil ? theme.gray : theme.textPrimary,
                origin: origin,
                into: &lines
            )
        }
    case .context(let context):
        appendWaveEHeader(
            "Context · \(pagerFormatTokens(context.totalTokens)) tokens",
            state: .succeeded,
            width: width,
            theme: theme,
            accentOverride: theme.accentSystem,
            origin: origin,
            into: &lines
        )
        let barWidth = width >= 60 ? 20 : 10
        for category in PagerContextCategory.allCases {
            let tokens = context.rows.first { $0.category == category }?.tokens ?? 0
            let fraction = context.totalTokens > 0 ? Double(tokens) / Double(context.totalTokens) : 0
            let filled = min(barWidth, max(0, Int((fraction * Double(barWidth)).rounded())))
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
            let label = category.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
            appendWaveERow(
                spans: [
                    PagerStyledSpan(text: "\(label) ", foreground: theme.grayBright),
                    PagerStyledSpan(text: bar, foreground: pagerContextColor(fraction: fraction, theme: theme)),
                    PagerStyledSpan(text: "  \(pagerFormatTokens(tokens))", foreground: theme.textSecondary)
                ],
                width: width,
                accent: theme.accentSystem,
                origin: origin,
                into: &lines
            )
        }
    case .usage(let usage):
        appendWaveEHeader(
            "Usage",
            state: .succeeded,
            width: width,
            theme: theme,
            accentOverride: theme.accentModel,
            origin: origin,
            into: &lines
        )
        for section in usage.sections {
            let limit = section.limit.map { " / \(waveENumber($0)) \(section.unit)" } ?? " \(section.unit)"
            let estimate = section.isAuthoritative ? "" : " · estimated"
            let reset = section.resetDescription.map { " · \($0)" } ?? ""
            appendWaveEBody(
                "\(section.provider.rawValue): \(waveENumber(section.used))\(limit)\(estimate)\(reset)",
                width: width,
                color: theme.textSecondary,
                origin: origin,
                into: &lines
            )
        }
    case .creditLimit(let credit):
        appendWaveEHeader(
            credit.action.rawValue,
            state: .failed,
            width: width,
            theme: theme,
            accentOverride: theme.warning,
            origin: origin,
            into: &lines
        )
        appendWaveEBody(credit.message, width: width, color: theme.textSecondary, origin: origin, into: &lines)
        appendWaveERow(
            spans: [PagerStyledSpan(text: credit.accountURL, foreground: theme.linkForeground, style: [.underline], url: credit.accountURL)],
            width: width,
            accent: theme.warning,
            origin: origin,
            into: &lines
        )
    case .plan(let plan):
        appendWaveEHeader(
            plan.title,
            state: .succeeded,
            width: width,
            theme: theme,
            accentOverride: theme.accentPlan,
            origin: origin,
            into: &lines
        )
        if plan.isExpanded {
            for (lineNumber, bodyLine) in plan.body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                appendWaveEBody(String(bodyLine), width: width, color: theme.textPrimary, origin: origin, into: &lines)
                if let comment = plan.comments[lineNumber + 1], !comment.isEmpty {
                    appendWaveEBody("  ↳ \(comment)", width: width, color: theme.accentFeedback, origin: origin, into: &lines)
                }
            }
        }
    }
}

private func appendSessionEvent(
    _ block: PagerSessionEventBlock,
    width: Int,
    theme: PagerRenderTheme,
    origin: Int,
    into lines: inout [PaintLine]
) {
    let description: String
    let state: PagerActivityState
    let accent: TerminalColor?
    var body: String?
    switch block.event {
    case .turnCompleted(let elapsed):
        description = "Worked\(waveEElapsed(elapsed))"
        state = .succeeded
        accent = theme.accentSuccess
    case .turnCancelled(let elapsed):
        description = "Turn cancelled\(waveEElapsed(elapsed))"
        state = .cancelled
        accent = theme.gray
    case .turnHalted(let elapsed):
        description = "Turn halted\(waveEElapsed(elapsed))"
        state = .cancelled
        accent = theme.warning
    case .turnFailed(let error, let elapsed):
        description = "Turn failed\(waveEElapsed(elapsed))"
        body = error
        state = .failed
        accent = theme.accentError
    case .compactionStarted(let percentage):
        description = "Context \(percentage)% full. Compacting…"
        state = .running
        accent = theme.accentRunning
    case .compactionCompleted(let before, let after, let elapsedMilliseconds):
        description = "Compacted \(pagerFormatTokens(before)) → \(pagerFormatTokens(after)) tokens · \(elapsedMilliseconds)ms"
        state = .succeeded
        accent = theme.accentSuccess
    case .compactionFailed(let error):
        description = "Compaction failed"
        body = error
        state = .failed
        accent = theme.accentError
    case .compactionCancelled:
        description = "Compaction cancelled"
        state = .cancelled
        accent = theme.gray
    case .retryFailed(let error, let errorType):
        description = "Retry failed · \(errorType)"
        body = error
        state = .failed
        accent = theme.accentError
    case .reauthRequired:
        description = "Authentication required"
        body = "Sign in again to continue this session."
        state = .failed
        accent = theme.warning
    case .contextTooLarge:
        description = "Context is too large"
        body = "Compact the conversation or start a new session."
        state = .failed
        accent = theme.warning
    case .compactCompleted(let elapsed):
        description = "Compact completed\(waveEElapsed(elapsed))"
        state = .succeeded
        accent = theme.accentSuccess
    case .hookAnnotation(let message):
        description = message
        state = .succeeded
        accent = theme.accentSystem
    case .modelUnavailable(let previous, let next, let reason):
        description = "Model changed · \(previous) → \(next)"
        body = reason
        state = .failed
        accent = theme.warning
    case .memorySaved(let path, let trigger):
        description = "Memory saved · \(path)"
        body = trigger
        state = .succeeded
        accent = theme.accentRemember
    case .goalCompleted(let elapsed):
        description = "Goal completed\(waveEElapsed(elapsed))"
        state = .succeeded
        accent = theme.accentSuccess
    case .recap(let summary, let auto):
        description = summary == nil ? "Recapping…" : "Recap\(auto ? " · automatic" : "")"
        body = summary
        state = summary == nil ? .running : .succeeded
        accent = theme.accentVerify
    }
    let hookSuffix = waveEHookSuffix(block.stopHooks)
    appendWaveEHeader(
        description + hookSuffix,
        state: state,
        width: width,
        theme: theme,
        accentOverride: accent,
        origin: origin,
        into: &lines
    )
    if let body, !body.isEmpty, block.isExpanded || !block.isRecap {
        appendWaveEBody(body, width: width, color: theme.textSecondary, origin: origin, into: &lines)
    } else if let body, block.isRecap, !block.isExpanded {
        let preview = body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? body
        appendWaveEBody(preview, width: width, color: theme.gray, origin: origin, into: &lines)
    }
    if block.isExpanded, !block.stopHooks.isEmpty {
        appendHookSection("stop", hooks: block.stopHooks, width: width, theme: theme, origin: origin, into: &lines)
    }
}

private func appendLifecycle(
    _ block: PagerLifecycleBlock,
    width: Int,
    theme: PagerRenderTheme,
    origin: Int,
    into lines: inout [PaintLine]
) {
    appendWaveEHeader(
        "Lifecycle · \(block.kind.rawValue)\(waveEHookSuffix(block.hooks))",
        state: block.state,
        width: width,
        theme: theme,
        accentOverride: theme.accentSystem,
        origin: origin,
        into: &lines
    )
    if block.isExpanded {
        appendHookSection("hooks", hooks: block.hooks, width: width, theme: theme, origin: origin, into: &lines)
    }
}

func appendToolHookSections(
    _ hooks: [PagerHookRun],
    width: Int,
    theme: PagerRenderTheme,
    origin: Int,
    into lines: inout [PaintLine]
) {
    let pre = hooks.filter { $0.phase == .pre }
    let post = hooks.filter { $0.phase == .post }
    if !pre.isEmpty { appendHookSection("pre", hooks: pre, width: width, theme: theme, origin: origin, into: &lines) }
    if !post.isEmpty { appendHookSection("post", hooks: post, width: width, theme: theme, origin: origin, into: &lines) }
}

func appendSpecializedToolHooks(
    _ tool: PagerToolCard,
    blockOrigin: Int,
    width: Int,
    theme: PagerRenderTheme,
    into lines: inout [PaintLine]
) {
    guard !tool.hooks.isEmpty, blockOrigin < lines.count else { return }
    let suffix = waveEHookSuffix(tool.hooks)
    lines[blockOrigin].spans.append(PagerStyledSpan(text: suffix, foreground: theme.grayDim))
    if var seed = lines[blockOrigin].selection {
        seed.text += suffix
        lines[blockOrigin].selection = seed
    }
    if tool.isExpanded {
        appendToolHookSections(tool.hooks, width: width, theme: theme, origin: blockOrigin, into: &lines)
    }
}

func waveEHookSuffix(_ hooks: [PagerHookRun]) -> String {
    guard !hooks.isEmpty else { return "" }
    let succeeded = hooks.filter { $0.state == .succeeded }.count
    return " [hooks: \(succeeded)/\(hooks.count)]"
}

private func appendHookSection(
    _ title: String,
    hooks: [PagerHookRun],
    width: Int,
    theme: PagerRenderTheme,
    origin: Int,
    into lines: inout [PaintLine]
) {
    guard !hooks.isEmpty else { return }
    appendWaveEBody("\(title):", width: width, color: theme.grayBright, origin: origin, into: &lines)
    for hook in hooks {
        let output = hook.output.map { " · \($0)" } ?? ""
        appendWaveERow(
            spans: [
                PagerStyledSpan(text: "  \(waveEStateGlyph(hook.state)) ", foreground: waveEStateColor(hook.state, theme)),
                PagerStyledSpan(text: hook.name, foreground: theme.textSecondary),
                PagerStyledSpan(text: output, foreground: theme.gray)
            ],
            width: width,
            accent: theme.accentSystem,
            origin: origin,
            into: &lines
        )
    }
}

private func appendWaveEHeader(
    _ text: String,
    state: PagerActivityState,
    width: Int,
    theme: PagerRenderTheme,
    accentOverride: TerminalColor? = nil,
    origin: Int,
    into lines: inout [PaintLine]
) {
    let accent = accentOverride ?? waveEStateColor(state, theme)
    appendWaveERow(
        spans: [
            PagerStyledSpan(text: "\(waveEStateGlyph(state)) ", foreground: accent),
            PagerStyledSpan(text: text, foreground: theme.textSecondary, style: [.bold])
        ],
        width: width,
        accent: accent,
        origin: origin,
        into: &lines
    )
}

private func appendWaveEBody(
    _ text: String,
    width: Int,
    color: TerminalColor,
    origin: Int,
    into lines: inout [PaintLine]
) {
    for row in wrapDisplayLines(text, width: max(1, width)) {
        let semantic = pagerTrimEndDisplay(row)
        lines.append(PaintLine(
            row,
            foreground: color,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: color,
            selection: semantic.isEmpty ? nil : PaintLineSelectionSeed(
                rangeID: 0,
                blockLineIndex: lines.count - origin,
                text: semantic,
                selectableColStart: 0,
                joinerToPrevious: lines.count == origin ? nil : "\n"
            )
        ))
    }
}

private func appendWaveERow(
    spans: [PagerStyledSpan],
    width: Int,
    accent: TerminalColor,
    origin: Int,
    into lines: inout [PaintLine]
) {
    for row in wrapStyledSpans(spans, width: max(1, width)) {
        let semantic = pagerTrimEndDisplay(row.map(\.text).joined())
        lines.append(PaintLine(
            spans: row,
            foreground: accent,
            accentGlyph: PagerGlyphs.accentBar,
            accentColor: accent,
            selection: semantic.isEmpty ? nil : PaintLineSelectionSeed(
                rangeID: 0,
                blockLineIndex: lines.count - origin,
                text: semantic,
                selectableColStart: 0,
                joinerToPrevious: lines.count == origin ? nil : "\n"
            )
        ))
    }
}

func renderPagerTodoPane(
    _ pane: PagerTodoPane,
    in area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.width > 0, area.height > 0 else { return }
    paintBlank(&buffer, area: area, foreground: theme.textSecondary, background: theme.bgDark)
    let items = pane.visibleItems
    if items.isEmpty {
        _ = paintSpans(
            &buffer,
            spans: [PagerStyledSpan(text: "  No active todos", foreground: theme.gray)],
            x: area.x,
            y: area.y,
            limit: area.right,
            background: theme.bgDark
        )
        return
    }
    for (row, item) in items.prefix(area.height).enumerated() {
        let state: PagerActivityState
        switch item.status {
        case .pending: state = .pending
        case .inProgress: state = .running
        case .completed: state = .succeeded
        case .cancelled: state = .cancelled
        }
        _ = paintSpans(
            &buffer,
            spans: [
                PagerStyledSpan(text: "  \(waveEStateGlyph(state)) ", foreground: waveEStateColor(state, theme)),
                PagerStyledSpan(text: item.content, foreground: item.status == .completed ? theme.gray : theme.textSecondary)
            ],
            x: area.x,
            y: area.y + row,
            limit: area.right,
            background: theme.bgDark
        )
    }
}

func renderPagerScrollDebugHud(
    _ hud: PagerScrollDebugOverlay,
    area: TerminalRect,
    buffer: inout CellBuffer,
    theme: PagerRenderTheme
) {
    guard area.width >= 20, area.height >= 2 else { return }
    let first = "scroll raw=\(hud.rawDelta) norm=\(hud.normalizedDelta)"
    let second = "offset=\(hud.scrollOffset)/\(hud.maximumOffset) \(hud.followingTail ? "follow" : "manual")"
    let width = min(area.width, max(first.count, second.count) + 2)
    let rect = TerminalRect(x: area.right - width, y: area.y, width: width, height: 2)
    paintBlank(&buffer, area: rect, foreground: theme.textSecondary, background: theme.bgDark)
    _ = paintSpans(&buffer, spans: [PagerStyledSpan(text: " " + first, foreground: theme.accentSystem)], x: rect.x, y: rect.y, limit: rect.right, background: theme.bgDark)
    _ = paintSpans(&buffer, spans: [PagerStyledSpan(text: " " + second, foreground: theme.grayBright)], x: rect.x, y: rect.y + 1, limit: rect.right, background: theme.bgDark)
}

private func waveEStateColor(_ state: PagerActivityState, _ theme: PagerRenderTheme) -> TerminalColor {
    switch state {
    case .pending, .queued: return theme.gray
    case .running, .waiting: return theme.accentRunning
    case .succeeded: return theme.accentSuccess
    case .failed: return theme.accentError
    case .cancelled: return theme.grayDim
    }
}

private func waveEStateGlyph(_ state: PagerActivityState) -> String {
    switch state {
    case .pending, .queued: return "○"
    case .running: return "◆"
    case .waiting: return "◌"
    case .succeeded: return "✓"
    case .failed: return "✗"
    case .cancelled: return "–"
    }
}

private func waveEActivityDetail(turns: Int, tools: Int, duration: TimeInterval?) -> String {
    var parts: [String] = []
    if turns > 0 { parts.append("\(turns) turns") }
    if tools > 0 { parts.append("\(tools) tools") }
    if let duration { parts.append(pagerFormatDuration(duration)) }
    return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
}

private func waveEElapsed(_ elapsed: TimeInterval?) -> String {
    elapsed.map { " for \(pagerFormatDuration($0))" } ?? ""
}

private func waveENumber(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
}

func pagerStripQuoteDecoration(_ text: String) -> String {
    var remaining = text[...]
    while remaining.first == "│" {
        remaining = remaining.dropFirst()
        if remaining.first == " " { remaining = remaining.dropFirst() }
    }
    return String(remaining)
}
