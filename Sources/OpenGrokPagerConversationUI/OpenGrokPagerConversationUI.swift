import Foundation

public enum PagerConversationRole: String, Codable, Equatable, Hashable, Sendable {
    case user
    case assistant
    case reasoning
    case tool
    case system
    case notice
}

public enum PagerConversationRowKind: String, Codable, Equatable, Hashable, Sendable {
    case message
    case reasoning
    case tool
    case result
    case error
    case notice
    case compaction
}

public enum PagerConversationRowStatus: String, Codable, Equatable, Hashable, Sendable {
    case queued
    case streaming
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .queued, .streaming: return false
        case .completed, .failed, .cancelled: return true
        }
    }

    public var label: String {
        switch self {
        case .queued: return "Queued"
        case .streaming: return "Streaming"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

public enum PagerConversationVisibility: String, Codable, Equatable, Hashable, Sendable {
    case visible
    case hiddenTransport
    case hiddenInternal

    public var isVisible: Bool { self == .visible }
}

public struct PagerConversationToolCard: Codable, Equatable, Hashable, Sendable {
    public var title: String
    public var body: String
    public var status: PagerConversationRowStatus

    public init(title: String, body: String = "", status: PagerConversationRowStatus = .completed) {
        self.title = title
        self.body = body
        self.status = status
    }
}

public enum PagerConversationContent: Codable, Equatable, Hashable, Sendable {
    case text(String)
    case code(language: String?, text: String)
    case citation(label: String, target: String)
    case image(altText: String, target: String)
    case diff(summary: String, additions: Int, deletions: Int)
    case toolCard(PagerConversationToolCard)

    private enum CodingKeys: String, CodingKey {
        case type, text, language, label, target, altText, summary, additions, deletions, card
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "code":
            self = .code(
                language: try container.decodeIfPresent(String.self, forKey: .language),
                text: try container.decode(String.self, forKey: .text)
            )
        case "citation":
            self = .citation(
                label: try container.decode(String.self, forKey: .label),
                target: try container.decode(String.self, forKey: .target)
            )
        case "image":
            self = .image(
                altText: try container.decode(String.self, forKey: .altText),
                target: try container.decode(String.self, forKey: .target)
            )
        case "diff":
            self = .diff(
                summary: try container.decode(String.self, forKey: .summary),
                additions: try container.decode(Int.self, forKey: .additions),
                deletions: try container.decode(Int.self, forKey: .deletions)
            )
        case "tool_card":
            self = .toolCard(try container.decode(PagerConversationToolCard.self, forKey: .card))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown conversation content type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .code(let language, let text):
            try container.encode("code", forKey: .type)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(text, forKey: .text)
        case .citation(let label, let target):
            try container.encode("citation", forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(target, forKey: .target)
        case .image(let altText, let target):
            try container.encode("image", forKey: .type)
            try container.encode(altText, forKey: .altText)
            try container.encode(target, forKey: .target)
        case .diff(let summary, let additions, let deletions):
            try container.encode("diff", forKey: .type)
            try container.encode(summary, forKey: .summary)
            try container.encode(additions, forKey: .additions)
            try container.encode(deletions, forKey: .deletions)
        case .toolCard(let card):
            try container.encode("tool_card", forKey: .type)
            try container.encode(card, forKey: .card)
        }
    }
}

public enum PagerConversationTextStyle: String, Codable, Equatable, Hashable, Sendable {
    case primary
    case secondary
    case accent
    case code
    case warning
    case error
    case dim
}

public struct PagerConversationRenderSegment: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var style: PagerConversationTextStyle
    public var selectable: Bool

    public init(text: String, style: PagerConversationTextStyle = .primary, selectable: Bool = true) {
        self.text = text
        self.style = style
        self.selectable = selectable
    }
}

public struct PagerConversationRenderLine: Codable, Equatable, Hashable, Sendable {
    public var segments: [PagerConversationRenderSegment]
    public var continuation: Bool

    public init(segments: [PagerConversationRenderSegment], continuation: Bool = false) {
        self.segments = segments
        self.continuation = continuation
    }

    public var plainText: String { segments.map(\.text).joined() }
}

public struct PagerConversationRenderDescription: Codable, Equatable, Hashable, Sendable {
    public var lines: [PagerConversationRenderLine]
    public var accessibilityLabel: String
    public var isVisible: Bool
    public var isSelectable: Bool
    public var isFoldable: Bool
    public var showsActivityIndicator: Bool

    public init(
        lines: [PagerConversationRenderLine],
        accessibilityLabel: String,
        isVisible: Bool,
        isSelectable: Bool,
        isFoldable: Bool,
        showsActivityIndicator: Bool
    ) {
        self.lines = lines
        self.accessibilityLabel = accessibilityLabel
        self.isVisible = isVisible
        self.isSelectable = isSelectable
        self.isFoldable = isFoldable
        self.showsActivityIndicator = showsActivityIndicator
    }
}

public struct PagerConversationRow: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var role: PagerConversationRole
    public var kind: PagerConversationRowKind
    public var title: String
    public var content: [PagerConversationContent]
    public var status: PagerConversationRowStatus
    public var visibility: PagerConversationVisibility
    public var isCollapsed: Bool
    public var isSelectable: Bool
    public var metadata: [String: String]

    public init(
        id: String,
        role: PagerConversationRole,
        kind: PagerConversationRowKind,
        title: String = "",
        content: [PagerConversationContent] = [],
        status: PagerConversationRowStatus = .completed,
        visibility: PagerConversationVisibility = .visible,
        isCollapsed: Bool = false,
        isSelectable: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.title = title
        self.content = content
        self.status = status
        self.visibility = visibility
        self.isCollapsed = isCollapsed
        self.isSelectable = isSelectable
        self.metadata = metadata
    }

    public var isFoldable: Bool { !content.isEmpty }

    public func renderDescription(maxBodyLines: Int? = nil) -> PagerConversationRenderDescription {
        guard visibility.isVisible else {
            return PagerConversationRenderDescription(
                lines: [], accessibilityLabel: "", isVisible: false, isSelectable: false,
                isFoldable: false, showsActivityIndicator: false
            )
        }

        let header = title.isEmpty ? roleLabel : title
        var lines = [PagerConversationRenderLine(segments: [
            PagerConversationRenderSegment(text: header, style: headerStyle)
        ])]
        if !isCollapsed {
            var bodyLines = content.flatMap(renderedLines(for:))
            if let maxBodyLines { bodyLines = Array(bodyLines.prefix(max(0, maxBodyLines))) }
            lines.append(contentsOf: bodyLines)
        }

        return PagerConversationRenderDescription(
            lines: lines,
            accessibilityLabel: lines.map(\.plainText).joined(separator: "\n"),
            isVisible: true,
            isSelectable: isSelectable,
            isFoldable: isFoldable,
            showsActivityIndicator: status == .queued || status == .streaming
        )
    }

    private var roleLabel: String {
        switch role {
        case .user: return "You"
        case .assistant: return "Grok"
        case .reasoning: return "Thinking"
        case .tool: return "Tool"
        case .system: return "System"
        case .notice: return "Notice"
        }
    }

    private var headerStyle: PagerConversationTextStyle {
        switch kind {
        case .error: return .error
        case .notice, .compaction: return .warning
        case .reasoning: return .secondary
        case .message, .tool, .result: return .accent
        }
    }

    private func renderedLines(for item: PagerConversationContent) -> [PagerConversationRenderLine] {
        switch item {
        case .text(let text):
            return text.split(separator: "\n", omittingEmptySubsequences: false).map {
                PagerConversationRenderLine(
                    segments: [PagerConversationRenderSegment(text: String($0))], continuation: true
                )
            }
        case .code(let language, let text):
            let label = language.map { "\($0):" } ?? "code:"
            return [PagerConversationRenderLine(segments: [
                PagerConversationRenderSegment(text: label, style: .code, selectable: false)
            ])] + text.split(separator: "\n", omittingEmptySubsequences: false).map {
                PagerConversationRenderLine(
                    segments: [PagerConversationRenderSegment(text: "│ \($0)", style: .code)],
                    continuation: true
                )
            }
        case .citation(let label, let target):
            return [PagerConversationRenderLine(segments: [
                PagerConversationRenderSegment(text: "↗ \(label)", style: .accent),
                PagerConversationRenderSegment(text: " — \(target)", style: .secondary)
            ])]
        case .image(let altText, let target):
            return [PagerConversationRenderLine(segments: [
                PagerConversationRenderSegment(text: "🖼 \(altText)", style: .accent),
                PagerConversationRenderSegment(text: " — \(target)", style: .secondary)
            ])]
        case .diff(let summary, let additions, let deletions):
            return [PagerConversationRenderLine(segments: [
                PagerConversationRenderSegment(text: summary, style: .accent),
                PagerConversationRenderSegment(text: " (+\(additions)/-\(deletions))", style: .secondary)
            ])]
        case .toolCard(let card):
            let titleLine = PagerConversationRenderLine(segments: [
                PagerConversationRenderSegment(text: "▸ \(card.title)", style: .accent),
                PagerConversationRenderSegment(text: " — \(card.status.label)", style: .secondary)
            ])
            let body = card.body.split(separator: "\n", omittingEmptySubsequences: false).map {
                PagerConversationRenderLine(
                    segments: [PagerConversationRenderSegment(text: "  \($0)", style: .secondary)],
                    continuation: true
                )
            }
            return [titleLine] + body
        }
    }
}

public struct PagerConversationTranscriptViewModel: Equatable, Hashable, Sendable {
    public private(set) var rows: [PagerConversationRow]
    public private(set) var selectedRowID: String?
    public var followTail: Bool

    public init(rows: [PagerConversationRow] = [], followTail: Bool = true, selectedRowID: String? = nil) {
        self.rows = rows
        self.followTail = followTail
        self.selectedRowID = selectedRowID
    }

    public var visibleRows: [PagerConversationRow] { rows.filter { $0.visibility.isVisible } }

    public func renderDescriptions(maxBodyLines: Int? = nil) -> [PagerConversationRenderDescription] {
        visibleRows.map { $0.renderDescription(maxBodyLines: maxBodyLines) }
    }

    public mutating func upsert(_ row: PagerConversationRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
        if followTail, row.isSelectable, row.visibility.isVisible { selectedRowID = row.id }
    }

    @discardableResult
    public mutating func remove(rowID: String) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return false }
        rows.remove(at: index)
        if selectedRowID == rowID {
            selectedRowID = rows.last(where: { $0.isSelectable && $0.visibility.isVisible })?.id
        }
        return true
    }

    @discardableResult
    public mutating func setCollapsed(_ collapsed: Bool, rowID: String) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == rowID }), rows[index].isFoldable else { return false }
        rows[index].isCollapsed = collapsed
        return true
    }

    public mutating func select(rowID: String?) {
        guard let rowID else {
            selectedRowID = nil
            return
        }
        guard rows.contains(where: { $0.id == rowID && $0.isSelectable && $0.visibility.isVisible }) else { return }
        selectedRowID = rowID
        followTail = false
    }
}
