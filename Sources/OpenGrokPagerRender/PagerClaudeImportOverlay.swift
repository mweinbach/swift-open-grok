import Foundation

/// The two destinations exposed by the upstream Claude import modal.
public enum PagerClaudeImportScope: String, CaseIterable, Sendable, Equatable, Hashable {
    case global
    case project

    public var label: String {
        switch self {
        case .global: "Global"
        case .project: "Project"
        }
    }
}

/// Stable upstream grouping order (`import_claude_modal.rs:96-140`).
public enum PagerClaudeImportCategory: String, CaseIterable, Sendable, Equatable, Hashable {
    case permission
    case environment
    case mcpServer
    case hook
    case path

    public var label: String {
        switch self {
        case .permission: "Permissions"
        case .environment: "Env vars"
        case .mcpServer: "MCP servers"
        case .hook: "Hooks"
        case .path: "Paths"
        }
    }
}

/// A render-only, secret-scrubbed preview. Raw environment values, transport
/// headers, and executable hook payloads never cross into the pager target.
public struct PagerClaudeImportItem: Sendable, Equatable, Hashable {
    public var id: String
    public var scope: PagerClaudeImportScope
    public var category: PagerClaudeImportCategory
    public var label: String
    public var detail: String?
    public var isEnabled: Bool
    public var blockedReason: String?

    public init(
        id: String,
        scope: PagerClaudeImportScope,
        category: PagerClaudeImportCategory,
        label: String,
        detail: String? = nil,
        isEnabled: Bool = true,
        blockedReason: String? = nil
    ) {
        self.id = id
        self.scope = scope
        self.category = category
        self.label = label
        self.detail = detail
        self.isEnabled = isEnabled
        self.blockedReason = blockedReason
    }
}

/// Stateful categorized checkbox list layered on the production list painter.
/// Group rows stay selectable for upstream's scope/category bulk toggles;
/// policy-blocked leaf rows never become selected.
public struct PagerClaudeImportOverlay: Sendable, Equatable {
    public static let overlayID = "import-claude"

    public var items: [PagerClaudeImportItem]
    public private(set) var selectedIDs: Set<String>

    public init(items: [PagerClaudeImportItem], selectedIDs: Set<String>? = nil) {
        self.items = items
        let eligible = Set(items.filter(\.isEnabled).map(\.id))
        self.selectedIDs = selectedIDs?.intersection(eligible) ?? eligible
    }

    public var selectedCount: Int { selectedIDs.count }
    public var totalCount: Int { items.count }

    public var title: String {
        "Import Claude settings (\(selectedCount)/\(totalCount))"
    }

    public var rows: [PagerListRow] {
        var result: [PagerListRow] = []
        for scope in PagerClaudeImportScope.allCases {
            let scoped = items.filter { $0.scope == scope }
            guard !scoped.isEmpty else { continue }
            result.append(PagerListRow(
                id: "scope:\(scope.rawValue)",
                label: "\(selectionMark(scoped)) \(scope.label)",
                detail: "\(selectedCount(in: scoped))/\(scoped.count)"
            ))

            for category in PagerClaudeImportCategory.allCases {
                let grouped = scoped.filter { $0.category == category }
                guard !grouped.isEmpty else { continue }
                result.append(PagerListRow(
                    id: "category:\(scope.rawValue):\(category.rawValue)",
                    label: "  \(selectionMark(grouped)) \(category.label)",
                    detail: "\(selectedCount(in: grouped))/\(grouped.count)"
                ))
                for item in grouped {
                    let mark = item.isEnabled
                        ? (selectedIDs.contains(item.id) ? "[x]" : "[ ]")
                        : "[!]"
                    result.append(PagerListRow(
                        id: "item:\(item.id)",
                        label: "    \(mark) \(item.label)",
                        detail: item.blockedReason ?? item.detail,
                        isSelectable: item.isEnabled
                    ))
                }
            }
        }
        return result
    }

    public func makeOverlay() -> PagerOverlay {
        PagerOverlay.list(
            id: Self.overlayID,
            title: title,
            rows: rows,
            isFilterable: false,
            sizing: .large,
            hints: [
                PagerOverlayHint(key: "↑/↓", label: "navigate"),
                PagerOverlayHint(key: "Space", label: "toggle"),
                PagerOverlayHint(key: "a", label: "all"),
                PagerOverlayHint(key: "n", label: "none"),
                PagerOverlayHint(key: "Enter", label: "import"),
                PagerOverlayHint(key: "Esc", label: "cancel"),
            ]
        )
    }

    @discardableResult
    public mutating func toggle(rowID: String) -> Bool {
        let targets: [PagerClaudeImportItem]
        if let item = rowID.stripPrefix("item:") {
            targets = items.filter { $0.id == item && $0.isEnabled }
        } else if let value = rowID.stripPrefix("scope:"),
                  let scope = PagerClaudeImportScope(rawValue: value) {
            targets = items.filter { $0.scope == scope && $0.isEnabled }
        } else if let value = rowID.stripPrefix("category:") {
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let scope = PagerClaudeImportScope(rawValue: parts[0]),
                  let category = PagerClaudeImportCategory(rawValue: parts[1])
            else { return false }
            targets = items.filter {
                $0.scope == scope && $0.category == category && $0.isEnabled
            }
        } else {
            return false
        }
        guard !targets.isEmpty else { return false }
        let shouldSelect = targets.contains { !selectedIDs.contains($0.id) }
        for item in targets {
            if shouldSelect {
                selectedIDs.insert(item.id)
            } else {
                selectedIDs.remove(item.id)
            }
        }
        return true
    }

    public mutating func selectAll() {
        selectedIDs = Set(items.filter(\.isEnabled).map(\.id))
    }

    public mutating func selectNone() {
        selectedIDs.removeAll()
    }

    private func selectedCount(in group: [PagerClaudeImportItem]) -> Int {
        group.filter { selectedIDs.contains($0.id) }.count
    }

    private func selectionMark(_ group: [PagerClaudeImportItem]) -> String {
        let eligible = group.filter(\.isEnabled)
        guard !eligible.isEmpty else { return "[!]" }
        let selected = selectedCount(in: eligible)
        if selected == 0 { return "[ ]" }
        if selected == eligible.count { return "[x]" }
        return "[-]"
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
