import Foundation

public enum PagerToolKind: String, Codable, Equatable, Hashable, Sendable {
    case execute
    case read
    case edit
    case listDirectory
    case search
    case webFetch
    case webSearch
    case memorySearch
    case mcp
    case subagent
    case other

    public var noun: String {
        switch self {
        case .execute: return "command"
        case .read, .edit: return "file"
        case .listDirectory: return "directory"
        case .search: return "search"
        case .webFetch, .webSearch: return "website"
        case .memorySearch: return "memory"
        case .mcp: return "MCP tool"
        case .subagent: return "subagent"
        case .other: return "tool"
        }
    }

    public var presentVerb: String {
        switch self {
        case .execute, .subagent, .other: return "Running"
        case .read: return "Reading"
        case .edit: return "Editing"
        case .listDirectory: return "Listing"
        case .search, .webSearch, .memorySearch: return "Searching"
        case .webFetch: return "Fetching"
        case .mcp: return "Calling"
        }
    }

    public var pastVerb: String {
        switch self {
        case .execute, .subagent, .other: return "Ran"
        case .read: return "Read"
        case .edit: return "Edited"
        case .listDirectory: return "Listed"
        case .search, .webSearch, .memorySearch: return "Searched"
        case .webFetch: return "Fetched"
        case .mcp: return "Called"
        }
    }
}

public enum PagerOperationStatus: String, Codable, Equatable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .queued, .running: return false
        case .succeeded, .failed, .cancelled: return true
        }
    }
}

public enum PagerProgress: Codable, Equatable, Hashable, Sendable {
    case indeterminate(label: String = "Working…")
    case determinate(completed: Int64, total: Int64, label: String? = nil)

    public var fraction: Double? {
        switch self {
        case .indeterminate:
            return nil
        case .determinate(let completed, let total, _):
            guard total > 0 else { return nil }
            return min(1, max(0, Double(completed) / Double(total)))
        }
    }

    public var label: String {
        switch self {
        case .indeterminate(let label): return label
        case .determinate(let completed, let total, let label):
            if let label, !label.isEmpty { return label }
            return "\(max(0, completed))/\(max(0, total))"
        }
    }

    public func render(width: Int, tick: UInt64 = 0) -> PagerProgressRenderDescription {
        let safeWidth = max(1, width)
        switch self {
        case .indeterminate:
            let position = Int(tick % UInt64(safeWidth))
            var glyphs = Array(repeating: "░", count: safeWidth)
            glyphs[position] = "█"
            return PagerProgressRenderDescription(
                label: label,
                bar: glyphs.joined(),
                fraction: nil,
                isIndeterminate: true,
                accessibilityLabel: label
            )
        case .determinate:
            let currentFraction = fraction ?? 0
            let filled = min(safeWidth, max(0, Int((currentFraction * Double(safeWidth)).rounded(.down))))
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: safeWidth - filled)
            return PagerProgressRenderDescription(
                label: label,
                bar: bar,
                fraction: fraction,
                isIndeterminate: false,
                accessibilityLabel: "\(label) \(Int(currentFraction * 100)) percent"
            )
        }
    }
}

public struct PagerProgressRenderDescription: Codable, Equatable, Hashable, Sendable {
    public let label: String
    public let bar: String
    public let fraction: Double?
    public let isIndeterminate: Bool
    public let accessibilityLabel: String

    public init(
        label: String,
        bar: String,
        fraction: Double?,
        isIndeterminate: Bool,
        accessibilityLabel: String
    ) {
        self.label = label
        self.bar = bar
        self.fraction = fraction
        self.isIndeterminate = isIndeterminate
        self.accessibilityLabel = accessibilityLabel
    }
}

public enum PagerOperationResultKind: String, Codable, Equatable, Hashable, Sendable {
    case success
    case failure
    case cancelled
}

public struct PagerOperationResult: Codable, Equatable, Hashable, Sendable {
    public let kind: PagerOperationResultKind
    public let summary: String
    public let output: [String]
    public let exitCode: Int32?

    public init(
        kind: PagerOperationResultKind,
        summary: String = "",
        output: [String] = [],
        exitCode: Int32? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.output = output
        self.exitCode = exitCode
    }
}

public enum PagerOperationState: Equatable, Hashable, Sendable {
    case queued
    case running(progress: PagerProgress?)
    case succeeded(PagerOperationResult)
    case failed(PagerOperationResult)
    case cancelled(PagerOperationResult)

    public var status: PagerOperationStatus {
        switch self {
        case .queued: return .queued
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    public var progress: PagerProgress? {
        if case .running(let progress) = self { return progress }
        return nil
    }

    public var result: PagerOperationResult? {
        switch self {
        case .succeeded(let result), .failed(let result), .cancelled(let result): return result
        case .queued, .running: return nil
        }
    }
}

public enum PagerOperationEvent: Equatable, Hashable, Sendable {
    case start
    case updateProgress(PagerProgress)
    case succeed(PagerOperationResult)
    case fail(PagerOperationResult)
    case cancel(PagerOperationResult)
}

public enum PagerOperationTransitionError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidTransition(from: PagerOperationStatus, event: PagerOperationEvent)
    case mismatchedResult(expected: PagerOperationResultKind, actual: PagerOperationResultKind)

    public var description: String {
        switch self {
        case .invalidTransition(let from, let event): return "Cannot apply \(event) while operation is \(from.rawValue)"
        case .mismatchedResult(let expected, let actual): return "Expected \(expected.rawValue) result, received \(actual.rawValue)"
        }
    }
}

public struct PagerPermissionRequest: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let toolName: String
    public let summary: String
    public let inputJSON: String
    public let destructive: Bool
    public let options: [PagerPermissionOption]

    public init(
        id: String,
        toolName: String,
        summary: String = "",
        inputJSON: String = "",
        destructive: Bool = false,
        options: [PagerPermissionOption] = PagerPermissionOption.defaultOptions
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.inputJSON = inputJSON
        self.destructive = destructive
        self.options = options
    }
}

public enum PagerPermissionOptionAction: String, Codable, Equatable, Hashable, Sendable {
    case allowOnce
    case allowSession
    case allowProject
    case deny
}

public struct PagerPermissionOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let action: PagerPermissionOptionAction
    public let isRecommended: Bool

    public init(
        id: String,
        title: String,
        action: PagerPermissionOptionAction,
        isRecommended: Bool = false
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.isRecommended = isRecommended
    }

    public static let defaultOptions: [PagerPermissionOption] = [
        PagerPermissionOption(id: "once", title: "Allow once", action: .allowOnce, isRecommended: true),
        PagerPermissionOption(id: "session", title: "Allow for session", action: .allowSession),
        PagerPermissionOption(id: "project", title: "Allow for project", action: .allowProject),
        PagerPermissionOption(id: "deny", title: "Deny", action: .deny)
    ]
}

public enum PagerPermissionDecision: Codable, Equatable, Hashable, Sendable {
    case allowOnce
    case allowSession
    case allowProject
    case deny(reason: String)
}

public enum PagerPermissionPromptPhase: String, Codable, Equatable, Hashable, Sendable {
    case options
    case followup
}

public enum PagerPermissionResolutionError: Error, Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    case noOptions
    case missingDenialReason

    public var description: String {
        switch self {
        case .noOptions: return "No permission options are available"
        case .missingDenialReason: return "A denial reason is required"
        }
    }
}

public struct PagerPermissionPromptRenderOption: Codable, Equatable, Hashable, Sendable {
    public let shortcut: String
    public let title: String
    public let isSelected: Bool
    public let isRecommended: Bool

    public init(shortcut: String, title: String, isSelected: Bool, isRecommended: Bool) {
        self.shortcut = shortcut
        self.title = title
        self.isSelected = isSelected
        self.isRecommended = isRecommended
    }
}

public struct PagerPermissionPromptRenderDescription: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let detail: [String]
    public let warning: String?
    public let options: [PagerPermissionPromptRenderOption]
    public let phase: PagerPermissionPromptPhase

    public init(
        title: String,
        detail: [String],
        warning: String?,
        options: [PagerPermissionPromptRenderOption],
        phase: PagerPermissionPromptPhase
    ) {
        self.title = title
        self.detail = detail
        self.warning = warning
        self.options = options
        self.phase = phase
    }
}

public struct PagerPermissionPromptViewModel: Equatable, Hashable, Sendable {
    public let request: PagerPermissionRequest
    public private(set) var selectedIndex: Int
    public private(set) var phase: PagerPermissionPromptPhase
    public private(set) var followupText: String

    public init(request: PagerPermissionRequest) {
        self.request = request
        self.selectedIndex = request.options.firstIndex(where: \.isRecommended) ?? 0
        self.phase = .options
        self.followupText = ""
    }

    public var selectedOption: PagerPermissionOption? {
        guard request.options.indices.contains(selectedIndex) else { return nil }
        return request.options[selectedIndex]
    }

    public mutating func moveSelection(by offset: Int) {
        guard !request.options.isEmpty else { return }
        selectedIndex = (selectedIndex + offset).positiveModulo(request.options.count)
    }

    public mutating func beginFollowup() -> Bool {
        guard selectedOption?.action == .deny else { return false }
        phase = .followup
        return true
    }

    public mutating func updateFollowup(_ text: String) {
        followupText = text
    }

    public func resolve() throws -> PagerPermissionDecision {
        guard let selectedOption else { throw PagerPermissionResolutionError.noOptions }
        switch selectedOption.action {
        case .allowOnce: return .allowOnce
        case .allowSession: return .allowSession
        case .allowProject: return .allowProject
        case .deny:
            let reason = followupText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { throw PagerPermissionResolutionError.missingDenialReason }
            return .deny(reason: reason)
        }
    }

    public func renderDescription() -> PagerPermissionPromptRenderDescription {
        let options = request.options.enumerated().map { index, option in
            PagerPermissionPromptRenderOption(
                shortcut: index < 9 ? "\(index + 1)" : "",
                title: option.title,
                isSelected: index == selectedIndex,
                isRecommended: option.isRecommended
            )
        }
        let detail = [request.summary, request.inputJSON].filter { !$0.isEmpty }
        return PagerPermissionPromptRenderDescription(
            title: "Allow \(request.toolName)?",
            detail: detail,
            warning: request.destructive ? "This operation can change or delete data." : nil,
            options: options,
            phase: phase
        )
    }
}

public struct PagerToolOperationRenderLine: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let style: PagerOperationTextStyle
    public let selectable: Bool

    public init(text: String, style: PagerOperationTextStyle = .primary, selectable: Bool = true) {
        self.text = text
        self.style = style
        self.selectable = selectable
    }
}

public enum PagerOperationTextStyle: String, Codable, Equatable, Hashable, Sendable {
    case primary
    case secondary
    case accent
    case warning
    case error
    case success
    case code
}

public struct PagerToolOperationRenderDescription: Codable, Equatable, Hashable, Sendable {
    public let lines: [PagerToolOperationRenderLine]
    public let accessibilityLabel: String
    public let isSelectable: Bool
    public let isFoldable: Bool
    public let showsProgress: Bool

    public init(
        lines: [PagerToolOperationRenderLine],
        accessibilityLabel: String,
        isSelectable: Bool,
        isFoldable: Bool,
        showsProgress: Bool
    ) {
        self.lines = lines
        self.accessibilityLabel = accessibilityLabel
        self.isSelectable = isSelectable
        self.isFoldable = isFoldable
        self.showsProgress = showsProgress
    }
}

public struct PagerToolOperationViewModel: Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: PagerToolKind
    public let title: String
    public let detail: String
    public let permission: PagerPermissionRequest?
    public private(set) var state: PagerOperationState
    public private(set) var isExpanded: Bool

    public init(
        id: String,
        kind: PagerToolKind,
        title: String,
        detail: String = "",
        permission: PagerPermissionRequest? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.permission = permission
        self.state = .queued
        self.isExpanded = false
    }

    public var status: PagerOperationStatus { state.status }

    public mutating func apply(_ event: PagerOperationEvent) throws {
        switch (state.status, event) {
        case (.queued, .start):
            state = .running(progress: nil)
        case (.queued, .cancel(let result)):
            guard result.kind == .cancelled else {
                throw PagerOperationTransitionError.mismatchedResult(expected: .cancelled, actual: result.kind)
            }
            state = .cancelled(result)
        case (.running, .updateProgress(let progress)):
            state = .running(progress: progress)
        case (.running, .succeed(let result)):
            guard result.kind == .success else {
                throw PagerOperationTransitionError.mismatchedResult(expected: .success, actual: result.kind)
            }
            state = .succeeded(result)
        case (.running, .fail(let result)):
            guard result.kind == .failure else {
                throw PagerOperationTransitionError.mismatchedResult(expected: .failure, actual: result.kind)
            }
            state = .failed(result)
        case (.running, .cancel(let result)):
            guard result.kind == .cancelled else {
                throw PagerOperationTransitionError.mismatchedResult(expected: .cancelled, actual: result.kind)
            }
            state = .cancelled(result)
        default:
            throw PagerOperationTransitionError.invalidTransition(from: state.status, event: event)
        }
    }

    public mutating func toggleExpanded() {
        guard state.result?.output.isEmpty == false else { return }
        isExpanded.toggle()
    }

    public func renderDescription(outputLineLimit: Int = 3, progressWidth: Int = 20, tick: UInt64 = 0) -> PagerToolOperationRenderDescription {
        let safeLimit = max(0, outputLineLimit)
        let verb = status == .running ? kind.presentVerb : kind.pastVerb
        let statusLabel: String
        switch status {
        case .queued: statusLabel = "Queued"
        case .running: statusLabel = "Running"
        case .succeeded: statusLabel = "Completed"
        case .failed: statusLabel = "Failed"
        case .cancelled: statusLabel = "Cancelled"
        }

        var lines = [PagerToolOperationRenderLine(
            text: "\(verb) \(title) — \(statusLabel)",
            style: status == .failed ? .error : .accent
        )]
        if !detail.isEmpty {
            lines.append(PagerToolOperationRenderLine(text: detail, style: .secondary))
        }
        if let progress = state.progress {
            let rendered = progress.render(width: progressWidth, tick: tick)
            lines.append(PagerToolOperationRenderLine(text: "\(rendered.label) [\(rendered.bar)]", style: .accent))
        }
        if let result = state.result {
            if !result.summary.isEmpty {
                lines.append(PagerToolOperationRenderLine(
                    text: result.summary,
                    style: result.kind == .failure ? .error : result.kind == .cancelled ? .warning : .success
                ))
            }
            if let exitCode = result.exitCode {
                lines.append(PagerToolOperationRenderLine(text: "Exit code: \(exitCode)", style: exitCode == 0 ? .secondary : .error))
            }
            if isExpanded {
                lines.append(contentsOf: result.output.map { PagerToolOperationRenderLine(text: $0, style: .code) })
            } else if result.output.count > safeLimit {
                lines.append(contentsOf: result.output.prefix(safeLimit).map { PagerToolOperationRenderLine(text: $0, style: .code) })
                lines.append(PagerToolOperationRenderLine(text: "… \(result.output.count - safeLimit) more lines", style: .secondary, selectable: false))
            }
        }

        return PagerToolOperationRenderDescription(
            lines: lines,
            accessibilityLabel: lines.map(\.text).joined(separator: "\n"),
            isSelectable: true,
            isFoldable: state.result?.output.isEmpty == false,
            showsProgress: state.progress != nil
        )
    }
}

private extension Int {
    func positiveModulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
