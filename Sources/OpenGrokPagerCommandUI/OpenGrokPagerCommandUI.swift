import Foundation

public enum PagerCommandAvailability: Codable, Equatable, Hashable, Sendable {
    case available
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .available: return "Available"
        case .unavailable(let reason): return reason.isEmpty ? "Unavailable" : "Unavailable: \(reason)"
        }
    }
}

public struct PagerCommandDefinition: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let summary: String
    public let usage: String?
    public let availability: PagerCommandAvailability
    /// Resolvable by name but never listed in the dropdown or the palette —
    /// upstream's `SlashCommand::visible() == false`, which `/gboom` and the
    /// debug diagnostics use.
    public let isHidden: Bool
    /// Whether running this command rewrites the conversation the model is
    /// working from.
    ///
    /// Load-bearing safety flag, not bookkeeping. Most slash commands only
    /// touch the UI, so they can run the instant they are typed — including
    /// mid-turn, which is the only time `/queue` answers anything. A command
    /// that edits history cannot: firing `/compact` while a turn is streaming
    /// would rewrite the item list underneath the sampler. Upstream avoids
    /// this structurally — `/compact` alone returns `CommandResult::QueueCommand`
    /// (`slash/commands/compact.rs:49`) instead of resolving locally — and this
    /// flag is how the port keeps that guarantee while still dispatching the
    /// harmless majority inline.
    public let mutatesConversationHistory: Bool
    /// Tie-break for an ambiguous prefix, highest first. Zero — the default —
    /// leaves suggestions in plain name order.
    ///
    /// A prefix like `/q` matches both `quit` and `queue`, and which one the
    /// dropdown offers should be a decision, not an artifact of the alphabet.
    /// Upstream settles it with registration order (`slash/commands/mod.rs:78`
    /// registers `quit` first); this is the same decision made explicit, so a
    /// command added later cannot quietly take a prefix away from an older one.
    public let priority: Int

    public init(
        name: String,
        aliases: [String] = [],
        summary: String = "",
        usage: String? = nil,
        availability: PagerCommandAvailability = .available,
        isHidden: Bool = false,
        mutatesConversationHistory: Bool = false,
        priority: Int = 0
    ) {
        let normalizedName = Self.normalize(name)
        self.id = normalizedName
        self.name = normalizedName
        self.aliases = Array(Set(aliases.map(Self.normalize).filter { !$0.isEmpty && $0 != normalizedName })).sorted()
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.usage = usage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.availability = availability
        self.isHidden = isHidden
        self.mutatesConversationHistory = mutatesConversationHistory
        self.priority = priority
    }

    public var isValid: Bool {
        !name.isEmpty && !name.contains(where: { $0.isWhitespace || $0 == "/" })
    }

    public var allNames: [String] { [name] + aliases }

    public static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

public struct PagerCommandInvocation: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let arguments: [String]
    public let rawInput: String

    public init(name: String, arguments: [String] = [], rawInput: String = "") {
        self.name = PagerCommandDefinition.normalize(name)
        self.arguments = arguments
        self.rawInput = rawInput
    }
}

public enum PagerCommandParseError: Error, Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    case missingName
    case unterminatedQuote
    case danglingEscape

    public var description: String {
        switch self {
        case .missingName: return "Missing command name"
        case .unterminatedQuote: return "Unterminated quote"
        case .danglingEscape: return "Dangling escape"
        }
    }
}

public enum PagerCommandParseResult: Codable, Equatable, Hashable, Sendable {
    case prompt(String)
    case command(PagerCommandInvocation)
    case invalid(PagerCommandParseError)
}

public enum PagerCommandParser {
    public static func parse(_ input: String) -> PagerCommandParseResult {
        let leadingTrimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard leadingTrimmed.first == "/" else { return .prompt(input) }

        switch tokenize(leadingTrimmed) {
        case .failure(let error):
            return .invalid(error)
        case .success(let tokens):
            guard let command = tokens.first, command != "/" else {
                return .invalid(.missingName)
            }
            let normalized = PagerCommandDefinition.normalize(command)
            guard !normalized.isEmpty else { return .invalid(.missingName) }
            return .command(PagerCommandInvocation(
                name: normalized,
                arguments: Array(tokens.dropFirst()),
                rawInput: input
            ))
        }
    }

    private static func tokenize(_ input: String) -> Result<[String], PagerCommandParseError> {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false

        for character in input {
            if escaped {
                token.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    self.consumeToken(&tokens, &token)
                    quote = nil
                } else {
                    token.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                self.consumeToken(&tokens, &token)
            } else {
                token.append(character)
            }
        }

        if escaped { return .failure(.danglingEscape) }
        if quote != nil { return .failure(.unterminatedQuote) }
        self.consumeToken(&tokens, &token)
        return .success(tokens)
    }

    private static func consumeToken(_ tokens: inout [String], _ token: inout String) {
        guard !token.isEmpty else { return }
        tokens.append(token)
        token.removeAll(keepingCapacity: true)
    }

    private static func clearQuote(_ quote: inout Character?) { quote = nil }
}

public enum PagerCommandResolution: Equatable, Hashable, Sendable {
    case available(PagerCommandDefinition)
    case unavailable(PagerCommandDefinition, reason: String)
    case unknown(name: String)
}

public struct PagerCommandCompletion: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let commandName: String
    public let displayName: String
    public let summary: String
    public let availability: PagerCommandAvailability
    public let matchedAlias: String?
    /// Copied from the definition so the sort can tie-break without a lookup.
    public let priority: Int

    public init(
        commandName: String,
        displayName: String,
        summary: String,
        availability: PagerCommandAvailability,
        matchedAlias: String? = nil,
        priority: Int = 0
    ) {
        self.commandName = commandName
        self.displayName = displayName
        self.summary = summary
        self.availability = availability
        self.matchedAlias = matchedAlias
        self.priority = priority
        self.id = commandName
    }

    public var insertText: String { "/\(commandName)" }
}

public struct PagerCommandRegistry: Equatable, Hashable, Sendable {
    public let commands: [PagerCommandDefinition]
    public init(commands: [PagerCommandDefinition] = []) {
        var seen = Set<String>()
        self.commands = commands
            .filter { $0.isValid }
            .sorted { $0.name < $1.name }
            .filter { definition in
                guard !seen.contains(definition.name) else { return false }
                seen.insert(definition.name)
                return true
            }
    }

    public func resolve(_ invocation: PagerCommandInvocation) -> PagerCommandResolution {
        let normalized = PagerCommandDefinition.normalize(invocation.name)
        guard let command = commands.first(where: { $0.allNames.contains(normalized) }) else {
            return .unknown(name: normalized)
        }
        switch command.availability {
        case .available:
            return .available(command)
        case .unavailable(let reason):
            return .unavailable(command, reason: reason)
        }
    }

    public func completions(for input: String) -> [PagerCommandCompletion] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/", !trimmed.contains(where: { $0.isWhitespace }) else { return [] }
        let query = String(trimmed.dropFirst()).lowercased()
        return commands.compactMap { command in
            guard !command.isHidden else { return nil }
            let canonicalMatch = command.name.hasPrefix(query)
            let alias = command.aliases.first(where: { $0.hasPrefix(query) })
            guard canonicalMatch || alias != nil else { return nil }
            return PagerCommandCompletion(
                commandName: command.name,
                displayName: "/\(command.name)",
                summary: command.summary.isEmpty ? command.availability.label : command.summary,
                availability: command.availability,
                matchedAlias: canonicalMatch ? nil : alias,
                priority: command.priority
            )
        }
        .sorted { lhs, rhs in
            let lhsExact = lhs.commandName == query
            let rhsExact = rhs.commandName == query
            if lhsExact != rhsExact { return lhsExact }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.commandName < rhs.commandName
        }
    }

    public func autocompleteState(for input: String) -> PagerCommandAutocompleteState {
        PagerCommandAutocompleteState(registry: self, input: input)
    }
}

public struct PagerCommandCompletionRenderRow: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let isSelected: Bool
    public let isAvailable: Bool

    public init(text: String, isSelected: Bool, isAvailable: Bool) {
        self.text = text
        self.isSelected = isSelected
        self.isAvailable = isAvailable
    }
}

public struct PagerCommandCompletionRenderDescription: Codable, Equatable, Hashable, Sendable {
    public let rows: [PagerCommandCompletionRenderRow]
    public let height: Int
    public let scrollOffset: Int

    public init(rows: [PagerCommandCompletionRenderRow], height: Int, scrollOffset: Int) {
        self.rows = rows
        self.height = height
        self.scrollOffset = scrollOffset
    }
}

public struct PagerCommandAutocompleteState: Equatable, Hashable, Sendable {
    public let registry: PagerCommandRegistry
    public private(set) var input: String
    public private(set) var suggestions: [PagerCommandCompletion]
    public private(set) var selectedIndex: Int?
    public let maxVisibleRows: Int

    public init(
        registry: PagerCommandRegistry,
        input: String = "",
        maxVisibleRows: Int = 6
    ) {
        self.registry = registry
        self.input = input
        self.suggestions = registry.completions(for: input)
        self.selectedIndex = suggestions.isEmpty ? nil : 0
        self.maxVisibleRows = max(1, maxVisibleRows)
    }

    public var isOpen: Bool { !suggestions.isEmpty }

    public var selectedSuggestion: PagerCommandCompletion? {
        guard let selectedIndex, suggestions.indices.contains(selectedIndex) else { return nil }
        return suggestions[selectedIndex]
    }

    public mutating func update(input: String) {
        self.input = input
        suggestions = registry.completions(for: input)
        selectedIndex = suggestions.isEmpty ? nil : min(selectedIndex ?? 0, suggestions.count - 1)
    }

    public mutating func moveSelection(by offset: Int) {
        guard !suggestions.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex ?? 0
        selectedIndex = (current + offset).positiveModulo(suggestions.count)
    }

    public mutating func acceptSelected() -> String? {
        guard let selectedSuggestion else { return nil }
        guard selectedSuggestion.availability.isAvailable else { return nil }
        let replacement = selectedSuggestion.insertText
        if let whitespace = input.firstIndex(where: { $0.isWhitespace }) {
            input = replacement + String(input[whitespace...])
        } else {
            input = replacement
        }
        suggestions = []
        selectedIndex = nil
        return input
    }

    public var scrollOffset: Int {
        guard let selectedIndex, suggestions.count > maxVisibleRows else { return 0 }
        if selectedIndex < maxVisibleRows / 2 { return 0 }
        if selectedIndex + maxVisibleRows / 2 >= suggestions.count {
            return suggestions.count - maxVisibleRows
        }
        return selectedIndex - maxVisibleRows / 2
    }

    public func renderDescription() -> PagerCommandCompletionRenderDescription {
        guard isOpen else { return PagerCommandCompletionRenderDescription(rows: [], height: 0, scrollOffset: 0) }
        let offset = scrollOffset
        let end = min(suggestions.count, offset + maxVisibleRows)
        let rows = suggestions[offset..<end].enumerated().map { index, completion in
            let absoluteIndex = offset + index
            let availability = completion.availability.isAvailable ? "" : " — \(completion.availability.label)"
            return PagerCommandCompletionRenderRow(
                text: "\(absoluteIndex == selectedIndex ? "❯" : " ") \(completion.displayName) — \(completion.summary)\(availability)",
                isSelected: absoluteIndex == selectedIndex,
                isAvailable: completion.availability.isAvailable
            )
        }
        return PagerCommandCompletionRenderDescription(
            rows: rows,
            height: rows.count + 1,
            scrollOffset: offset
        )
    }
}

private extension Int {
    func positiveModulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
