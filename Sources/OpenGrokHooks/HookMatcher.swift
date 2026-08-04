import Foundation

public struct HookMatcher: Sendable, Equatable, Hashable {
    private enum Kind: Sendable, Equatable, Hashable {
        case all
        case never
        case exact([String])
        case regex(String)
    }

    private let kind: Kind

    public init(pattern: String) throws {
        if pattern.isEmpty || pattern == "*" {
            kind = .all
        } else if pattern.utf8.allSatisfy({ (($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 || $0 == 124) }) {
            var names: [String] = []
            for term in pattern.split(separator: "|", omittingEmptySubsequences: true).map(String.init) {
                for name in [term] + Self.aliases(for: term) where !names.contains(name) {
                    names.append(name)
                }
            }
            kind = .exact(names)
        } else {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw HookMatcherError.invalidPattern(String(describing: error))
            }
            kind = .regex(pattern)
        }
    }

    private init(kind: Kind) { self.kind = kind }

    public static var never: HookMatcher { HookMatcher(kind: .never) }

    public func isMatch(_ value: String) -> Bool {
        switch kind {
        case .all: return true
        case .never: return false
        case .exact(let names): return names.contains(value)
        case .regex(let pattern):
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
            let values = [value] + Self.externalAliases(for: value)
            return values.contains { candidate in
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                return expression.firstMatch(in: candidate, range: range) != nil
            }
        }
    }

    private static func aliases(for value: String) -> [String] {
        switch value {
        case "Bash": return ["run_terminal_command"]
        case "Read": return ["read_file"]
        case "Write": return ["search_replace", "hashline_edit"]
        case "Edit": return ["search_replace", "hashline_edit"]
        case "Glob": return ["list_dir"]
        case "Grep": return ["search_files"]
        default: return []
        }
    }

    private static func externalAliases(for value: String) -> [String] {
        switch value {
        case "run_terminal_command": return ["Bash"]
        case "read_file": return ["Read"]
        case "search_replace": return ["Write", "Edit"]
        case "hashline_edit": return ["Write", "Edit"]
        case "list_dir": return ["Glob"]
        case "search_files": return ["Grep"]
        default: return []
        }
    }
}

public enum HookMatcherError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPattern(String)

    public var description: String {
        switch self { case .invalidPattern(let detail): return detail }
    }
}
