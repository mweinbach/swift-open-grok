import Dispatch
import Foundation
import OpenGrokConfig
import OpenGrokDiagnostics
import OpenGrokPagerRender
import OpenGrokSystemPower
import OpenGrokTerminalCore

struct LiveTerminalNotificationConfiguration: Sendable, Equatable {
    enum Method: String, Sendable, Equatable {
        case auto
        case osc9
        case osc99
        case osc777
        case bel
        case none
    }

    enum Condition: String, Sendable, Equatable {
        case unfocused
        case always
        case never
    }

    enum Event: String, Sendable, Equatable, Hashable {
        case turnComplete = "turn_complete"
        case approvalRequired = "approval_required"
        case sessionReady = "session_ready"
        case taskComplete = "task_complete"
        case agentError = "agent_error"
    }

    enum TitleItem: String, Sendable, Equatable {
        case spinner
        case activity
        case sessionName = "session-name"
        case cwd
        case model
        case turnTimer = "turn-timer"
        case openGrok = "open-grok"
        case actionRequired = "action-required"

        init?(configurationValue: String) {
            if configurationValue == "grok" {
                self = .openGrok
            } else {
                self.init(rawValue: configurationValue)
            }
        }
    }

    struct Title: Sendable, Equatable {
        var enabled = true
        var items: [TitleItem] = [
            .actionRequired, .spinner, .activity, .sessionName, .openGrok,
        ]
    }

    struct Hook: Sendable, Equatable {
        var command: String
        var events: [Event] = []
        var onlyUnfocused = true
        var timeoutSeconds: UInt64 = 10
    }

    var method: Method = .auto
    var condition: Condition = .unfocused
    var idleThresholdSeconds: UInt64 = 3
    var events: [Event] = [.turnComplete, .approvalRequired]
    var sleepPrevention = true
    var progressBar = true
    var sessionRecap = true
    var sessionRecapThresholdSeconds: UInt64 = 30
    var title = Title()
    var hooks: [Hook] = []

    static func resolve(
        workingDirectory: URL,
        environment: [String: String]
    ) -> Self {
        guard let document = try? loadAuthorityComposition(
            cwd: workingDirectory,
            environment: environment
        ).effective() else { return Self() }
        return resolve(document: document)
    }

    static func resolve(document: TOMLValue) -> Self {
        guard let notificationTable = document[path: ["ui", "notifications"]]
        else { return Self() }
        return Self(notificationTable: notificationTable) ?? Self()
    }

    init() {}

    init?(notificationTable value: TOMLValue) {
        guard case .table(let table) = value else { return nil }
        self.init()

        if let value = table["method"] {
            guard let raw = value.stringValue, let parsed = Method(rawValue: raw) else {
                return nil
            }
            method = parsed
        }
        if let value = table["condition"] {
            guard let raw = value.stringValue, let parsed = Condition(rawValue: raw) else {
                return nil
            }
            condition = parsed
        }
        if let value = table["idle_threshold_secs"] {
            guard let parsed = Self.unsignedInteger(value) else { return nil }
            idleThresholdSeconds = parsed
        }
        if let value = table["events"] {
            guard let parsed = Self.parseEvents(value) else { return nil }
            events = parsed
        }
        if let value = table["sleep_prevention"] {
            guard let parsed = value.boolValue else { return nil }
            sleepPrevention = parsed
        }
        if let value = table["progress_bar"] {
            guard let parsed = value.boolValue else { return nil }
            progressBar = parsed
        }
        if let value = table["session_recap"] {
            guard let parsed = value.boolValue else { return nil }
            sessionRecap = parsed
        }
        if let value = table["session_recap_threshold_secs"] {
            guard let parsed = Self.unsignedInteger(value) else { return nil }
            sessionRecapThresholdSeconds = parsed
        }
        if let value = table["title"] {
            guard let parsed = Self.parseTitle(value) else { return nil }
            title = parsed
        }
        if let value = table["hooks"] {
            guard let parsed = Self.parseHooks(value) else { return nil }
            hooks = parsed
        }
    }

    private static func unsignedInteger(_ value: TOMLValue) -> UInt64? {
        guard let integer = value.int64Value, integer >= 0 else { return nil }
        return UInt64(integer)
    }

    private static func parseEvents(_ value: TOMLValue) -> [Event]? {
        guard let values = value.arrayValue else { return nil }
        var result: [Event] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let raw = value.stringValue, let event = Event(rawValue: raw) else {
                return nil
            }
            result.append(event)
        }
        return result
    }

    private static func parseTitle(_ value: TOMLValue) -> Title? {
        guard case .table(let table) = value else { return nil }
        var title = Title()
        if let value = table["enabled"] {
            guard let enabled = value.boolValue else { return nil }
            title.enabled = enabled
        }
        if let value = table["items"] {
            guard let values = value.arrayValue else { return nil }
            var items: [TitleItem] = []
            items.reserveCapacity(values.count)
            for value in values {
                guard let raw = value.stringValue,
                      let item = TitleItem(configurationValue: raw)
                else { return nil }
                items.append(item)
            }
            title.items = items
        }
        return title
    }

    private static func parseHooks(_ value: TOMLValue) -> [Hook]? {
        guard let values = value.arrayValue else { return nil }
        var hooks: [Hook] = []
        hooks.reserveCapacity(values.count)
        for value in values {
            guard case .table(let table) = value,
                  let command = table["command"]?.stringValue
            else { return nil }
            var hook = Hook(command: command)
            if let value = table["events"] {
                guard let events = parseEvents(value) else { return nil }
                hook.events = events
            }
            if let value = table["only_unfocused"] {
                guard let onlyUnfocused = value.boolValue else { return nil }
                hook.onlyUnfocused = onlyUnfocused
            }
            if let value = table["timeout_secs"] {
                guard let timeoutSeconds = unsignedInteger(value) else { return nil }
                hook.timeoutSeconds = timeoutSeconds
            }
            hooks.append(hook)
        }
        return hooks
    }
}

struct LiveTerminalNotifications: Sendable {
    static let enableBracketedPaste = "\u{1B}[?2004h"
    static let disableBracketedPaste = "\u{1B}[?2004l"

    enum NotificationProtocol: String, Sendable, Equatable {
        case osc9
        case osc99
        case osc777
        case bel
        case none
    }

    let configuration: LiveTerminalNotificationConfiguration
    let terminalContext: TerminalContext
    let notificationProtocol: NotificationProtocol
    var sleepInhibition: LiveSleepInhibition

    private(set) var focused = true
    private(set) var focusLostAtNanoseconds: UInt64?
    private(set) var focusReportingEnabled = false
    private(set) var bracketedPasteEnabled = false
    private(set) var sessionStarted = false
    private(set) var recapShownThisAway = false
    private(set) var lastAutoRecapAttemptAtNanoseconds: UInt64?
    private(set) var approvalNotified = false
    private(set) var progressActive = false
    private(set) var progressLastSentNanoseconds: UInt64?
    private(set) var lastTitle: String?

    init(
        configuration: LiveTerminalNotificationConfiguration,
        terminalContext: TerminalContext,
        powerAdapter: any PowerAdapter = PlatformPowerAdapter()
    ) {
        self.configuration = configuration
        self.terminalContext = terminalContext
        self.notificationProtocol = Self.resolveProtocol(
            method: configuration.method,
            context: terminalContext
        )
        self.sleepInhibition = LiveSleepInhibition(
            enabled: configuration.sleepPrevention,
            adapter: powerAdapter
        )
    }

    static func resolveProtocol(
        method: LiveTerminalNotificationConfiguration.Method,
        context: TerminalContext
    ) -> NotificationProtocol {
        switch method {
        case .osc9: return .osc9
        case .osc99: return .osc99
        case .osc777: return .osc777
        case .bel: return .bel
        case .none: return .none
        case .auto:
            if context.multiplexer == .zellij { return .bel }
            switch context.brand {
            case .iterm2, .wezTerm, .warpTerminal: return .osc9
            case .kitty: return .osc99
            case .ghostty, .vte, .terminator, .foot: return .osc777
            case .grokDesktop: return .none
            default: return .bel
            }
        }
    }

    mutating func setFocusReportingEnabled(_ enabled: Bool) {
        focusReportingEnabled = enabled
        if enabled { sessionStarted = true }
    }

    mutating func setBracketedPasteEnabled(_ enabled: Bool) {
        bracketedPasteEnabled = enabled
        if enabled { sessionStarted = true }
    }

    mutating func markSessionStopped() {
        focusReportingEnabled = false
        bracketedPasteEnabled = false
        sessionStarted = false
    }

    mutating func focusGained() {
        focused = true
        focusLostAtNanoseconds = nil
    }

    mutating func focusLost(nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        focused = false
        focusLostAtNanoseconds = nowNanoseconds
        recapShownThisAway = false
        lastAutoRecapAttemptAtNanoseconds = nil
    }

    func recapDue(nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard !focused, !recapShownThisAway, let lostAt = focusLostAtNanoseconds else {
            return false
        }
        if let attemptedAt = lastAutoRecapAttemptAtNanoseconds {
            let sinceAttempt = nowNanoseconds >= attemptedAt
                ? nowNanoseconds - attemptedAt
                : 0
            guard sinceAttempt >= 90_000_000_000 else { return false }
        }
        let elapsed = nowNanoseconds >= lostAt ? nowNanoseconds - lostAt : 0
        let (threshold, overflow) = configuration.sessionRecapThresholdSeconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        return !overflow && elapsed >= threshold
    }

    mutating func noteAutoRecapAttempt(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        lastAutoRecapAttemptAtNanoseconds = nowNanoseconds
    }

    mutating func markRecapShown() {
        recapShownThisAway = true
    }

    func shouldEmit(nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        switch configuration.condition {
        case .always: return true
        case .never: return false
        case .unfocused:
            guard !focused, let lostAt = focusLostAtNanoseconds else { return false }
            let elapsed = nowNanoseconds >= lostAt ? nowNanoseconds - lostAt : 0
            let (threshold, overflow) = configuration.idleThresholdSeconds
                .multipliedReportingOverflow(by: 1_000_000_000)
            return !overflow && elapsed >= threshold
        }
    }

    func notificationSequence(
        event: LiveTerminalNotificationConfiguration.Event,
        title: String,
        body: String,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> String? {
        guard configuration.events.contains(event), shouldEmit(nowNanoseconds: nowNanoseconds)
        else { return nil }

        let safeTitle = Self.sanitize(title)
        let safeBody = Self.sanitize(body)
        let sequence: String
        switch notificationProtocol {
        case .osc9:
            sequence = "\u{1B}]9;\(safeBody) · \(safeTitle)\u{07}"
        case .osc99:
            sequence = "\u{1B}]99;i=open-grok;\(safeBody) · \(safeTitle)\u{1B}\\"
        case .osc777:
            sequence = "\u{1B}]777;notify;Open Grok;\(safeBody)\u{1B}\\"
        case .bel:
            sequence = "\u{07}"
        case .none:
            return nil
        }
        return terminalContext.isTmuxBacked ? Self.tmuxPassthrough(sequence) : sequence
    }

    mutating func approvalNotificationSequence() -> String? {
        guard !approvalNotified else { return nil }
        approvalNotified = true
        return notificationSequence(
            event: .approvalRequired,
            title: "Open Grok",
            body: "Approval required"
        )
    }

    mutating func clearApprovalNotification() {
        approvalNotified = false
    }

    mutating func presentationSequence(
        sessionName: String?,
        model: String?,
        activity: String?,
        pendingApproval: Bool,
        workingDirectory: String?,
        turnElapsed: TimeInterval?,
        busy: Bool,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> String? {
        var sequences = ""
        if let title = titleSequence(
            sessionName: sessionName,
            model: model,
            activity: activity,
            pendingApproval: pendingApproval,
            workingDirectory: workingDirectory,
            turnElapsed: turnElapsed,
            busy: busy
        ) {
            sequences += title
        }
        if let progress = progressSequence(busy: busy, nowNanoseconds: nowNanoseconds) {
            sequences += progress
        }
        return sequences.isEmpty ? nil : sequences
    }

    mutating func shutdownSequence() -> String {
        let title = "\u{1B}]0;Open Grok\u{07}"
        lastTitle = "Open Grok"
        return title + (
            progressSequence(busy: false, nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
                ?? ""
        )
    }

    mutating func suspendProgressSequence() -> String? {
        progressSequence(busy: false, nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    private mutating func titleSequence(
        sessionName: String?,
        model: String?,
        activity: String?,
        pendingApproval: Bool,
        workingDirectory: String?,
        turnElapsed: TimeInterval?,
        busy: Bool
    ) -> String? {
        guard configuration.title.enabled else { return nil }
        var parts: [String] = []
        for item in configuration.title.items {
            switch item {
            case .actionRequired:
                if pendingApproval { parts.append("⚠ Action Required") }
            case .spinner:
                if busy || activity != nil { parts.append("⠋") }
            case .activity:
                if let activity, !activity.isEmpty {
                    parts.append(activity)
                } else if busy {
                    parts.append("Waiting")
                }
            case .sessionName:
                if let sessionName, !sessionName.isEmpty {
                    parts.append(Self.truncate(sessionName, limit: 40))
                }
            case .cwd:
                if let workingDirectory {
                    let leaf = workingDirectory.split(separator: "/").last.map(String.init)
                    if let leaf, !leaf.isEmpty {
                        parts.append(Self.truncate(leaf, limit: 30))
                    }
                }
            case .model:
                if let model, !model.isEmpty {
                    parts.append(Self.truncate(model, limit: 30))
                }
            case .turnTimer:
                if let turnElapsed, turnElapsed >= 1 {
                    parts.append("\(UInt64(turnElapsed))s")
                }
            case .openGrok:
                parts.append("Open Grok")
            }
        }
        let title = Self.sanitize(parts.isEmpty ? "Open Grok" : parts.joined(separator: " - "))
        guard title != lastTitle else { return nil }
        lastTitle = title
        return "\u{1B}]0;\(title)\u{07}"
    }

    private mutating func progressSequence(busy: Bool, nowNanoseconds: UInt64) -> String? {
        guard configuration.progressBar, supportsProgressBar else { return nil }
        if busy, progressActive, let lastSent = progressLastSentNanoseconds {
            let elapsed = nowNanoseconds >= lastSent ? nowNanoseconds - lastSent : 0
            guard elapsed >= 5_000_000_000 else { return nil }
        } else if busy == progressActive {
            return nil
        }
        progressActive = busy
        progressLastSentNanoseconds = busy ? nowNanoseconds : nil
        let sequence = busy ? "\u{1B}]9;4;1;-1\u{07}" : "\u{1B}]9;4;0;0\u{07}"
        if terminalContext.isTmuxBacked,
           terminalContext.isTmuxVersionOrLater(3, 3) {
            return Self.tmuxPassthrough(sequence)
        }
        return sequence
    }

    var supportsProgressBar: Bool {
        switch terminalContext.brand {
        case .ghostty, .wezTerm:
            return true
        case .iterm2:
            guard let version = terminalContext.termProgramVersion else { return false }
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  let major = UInt32(parts[0]),
                  let minor = UInt32(parts[1])
            else { return false }
            return major > 3 || (major == 3 && minor >= 6)
        default:
            return false
        }
    }

    static func sanitize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
    }

    static func tmuxPassthrough(_ sequence: String) -> String {
        "\u{1B}Ptmux;"
            + sequence.replacingOccurrences(of: "\u{1B}", with: "\u{1B}\u{1B}")
            + "\u{1B}\\"
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > limit else { return value }
        return String(String.UnicodeScalarView(scalars.prefix(limit))) + "…"
    }
}

extension LiveInteractiveControllerRenderer {
    func startTerminalNotificationReporting() throws {
        terminalNotifications.sleepInhibition.resume(
            anyAgentBusy: anyTerminalNotificationAgentBusy
        )
        guard terminal.isTTY(),
              !terminalNotifications.focusReportingEnabled
                  || !terminalNotifications.bracketedPasteEnabled
        else { return }
        do {
            if !terminalNotifications.focusReportingEnabled {
                try sink.write(ANSIMouse.enableFocusReporting)
                terminalNotifications.setFocusReportingEnabled(true)
            }
            if !terminalNotifications.bracketedPasteEnabled {
                try sink.write(LiveTerminalNotifications.enableBracketedPaste)
                terminalNotifications.setBracketedPasteEnabled(true)
            }
            if let presentation = terminalNotificationPresentationSequence() {
                try sink.write(presentation)
            }
            try sink.flush()
        } catch {
            terminalNotifications.sleepInhibition.suspend()
            if terminalNotifications.bracketedPasteEnabled {
                try? sink.write(LiveTerminalNotifications.disableBracketedPaste)
            }
            if terminalNotifications.focusReportingEnabled {
                try? sink.write(ANSIMouse.disableFocusReporting)
            }
            try? sink.flush()
            terminalNotifications.markSessionStopped()
            try? frontendRestore()
            throw error
        }
    }

    func suspendTerminalNotificationReporting() throws {
        terminalNotifications.sleepInhibition.suspend()
        guard terminalNotifications.focusReportingEnabled
            || terminalNotifications.bracketedPasteEnabled
        else { return }
        if let clearProgress = terminalNotifications.suspendProgressSequence() {
            try sink.write(clearProgress)
        }
        if terminalNotifications.bracketedPasteEnabled {
            try sink.write(LiveTerminalNotifications.disableBracketedPaste)
            terminalNotifications.setBracketedPasteEnabled(false)
        }
        if terminalNotifications.focusReportingEnabled {
            try sink.write(ANSIMouse.disableFocusReporting)
            terminalNotifications.setFocusReportingEnabled(false)
        }
        try sink.flush()
    }

    func stopTerminalNotificationReporting() throws {
        terminalNotifications.sleepInhibition.shutdown()
        guard terminalNotifications.sessionStarted else { return }
        try sink.write(terminalNotifications.shutdownSequence())
        if terminalNotifications.bracketedPasteEnabled {
            try sink.write(LiveTerminalNotifications.disableBracketedPaste)
            terminalNotifications.setBracketedPasteEnabled(false)
        }
        if terminalNotifications.focusReportingEnabled {
            try sink.write(ANSIMouse.disableFocusReporting)
            terminalNotifications.setFocusReportingEnabled(false)
        }
        try sink.flush()
        terminalNotifications.markSessionStopped()
    }

    func updateTerminalNotificationPresentation() {
        synchronizeTerminalSleepInhibition()
        guard terminalNotifications.focusReportingEnabled,
              let presentation = terminalNotificationPresentationSequence()
        else { return }
        writeTerminalNotification(presentation)
    }

    func emitTerminalNotification(
        _ event: LiveTerminalNotificationConfiguration.Event,
        title: String = "Open Grok",
        body: String
    ) {
        guard terminalNotifications.focusReportingEnabled,
              let notification = terminalNotifications.notificationSequence(
                  event: event,
                  title: title,
                  body: body
              )
        else { return }
        writeTerminalNotification(notification)
    }

    func emitTerminalApprovalNotification() {
        guard terminalNotifications.focusReportingEnabled,
              let notification = terminalNotifications.approvalNotificationSequence()
        else { return }
        writeTerminalNotification(notification)
    }

    var terminalNotificationSessionName: String? {
        guard let title = sessionTabs.first(where: { $0.sessionID == sessionID })?.title,
              !title.isEmpty, title != "New session"
        else { return nil }
        return title
    }

    func synchronizeTerminalSleepInhibition() {
        terminalNotifications.sleepInhibition.synchronize(
            anyAgentBusy: anyTerminalNotificationAgentBusy
        )
    }

    private var anyTerminalNotificationAgentBusy: Bool {
        turnPhase != nil || activeBackgroundWork.count(of: .subagent) > 0
    }

    private func terminalNotificationPresentationSequence() -> String? {
        terminalNotifications.presentationSequence(
            sessionName: terminalNotificationSessionName,
            model: modelName,
            activity: terminalNotificationActivity,
            pendingApproval: currentPermissionRequestID != nil,
            workingDirectory: workingDirectory,
            turnElapsed: currentTurnElapsed(),
            busy: turnPhase != nil
        )
    }

    private var terminalNotificationActivity: String? {
        switch turnPhase {
        case .thinking: return "Thinking"
        case .responding: return "Responding"
        case .compacting: return "Compacting"
        case .retrying(let attempt, let maximum, _):
            return "Retrying (\(attempt)/\(maximum))"
        case .tool(let name):
            return name.isEmpty ? "Running tool" : "Running: \(name)"
        default:
            return turnActivity
        }
    }

    private func writeTerminalNotification(_ sequence: String) {
        do {
            try sink.write(sequence)
            try sink.flush()
        } catch {
            // Notification delivery is best-effort and never aborts a model turn.
        }
    }
}
