import Foundation

public extension AgentDefinition {
    static func parse(_ content: String) throws -> AgentDefinition {
        let frontmatter = try AgentFrontmatterParser.parse(content)
        let data = try frontmatter.values.stableJSONData()
        var definition: AgentDefinition
        do {
            definition = try JSONDecoder().decode(AgentDefinition.self, from: data)
        } catch let error as AgentBuildError {
            throw error
        } catch {
            throw AgentBuildError.parseError(error.localizedDescription)
        }
        definition.promptBody = frontmatter.body
        return definition
    }

    static func fromFile(_ url: URL) throws -> AgentDefinition {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var definition = try parse(content)
            definition.sourcePath = url.standardizedFileURL.path
            definition.scope = AgentDefinitionScope.scope(for: url)
            return definition
        } catch let error as AgentBuildError {
            throw error
        } catch {
            throw AgentBuildError.ioError(error.localizedDescription)
        }
    }

    static func fromFileFrontmatterOnly(_ url: URL) throws -> AgentDefinition {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let frontmatter = try AgentFrontmatterParser.parse(content)
            let data = try frontmatter.values.stableJSONData()
            var definition = try JSONDecoder().decode(AgentDefinition.self, from: data)
            definition.sourcePath = url.standardizedFileURL.path
            definition.scope = AgentDefinitionScope.scope(for: url)
            definition.promptBody = nil
            definition.systemPrompt = .none
            return definition
        } catch let error as AgentBuildError {
            throw error
        } catch {
            throw AgentBuildError.ioError(error.localizedDescription)
        }
    }

    static func fromJSONData(_ data: Data) throws -> AgentDefinition {
        do {
            let value = try JSONDecoder().decode(AgentJSONValue.self, from: data)
            guard case let .object(object) = value else { throw AgentBuildError.parseError("agent JSON must be an object") }
            return try fromJSON(object)
        } catch let error as AgentBuildError {
            throw error
        } catch {
            throw AgentBuildError.parseError(error.localizedDescription)
        }
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentBuildError.missingField("name") }
        guard !name.contains("/") && !name.contains("\\") else { throw AgentBuildError.invalidConfig("agent name cannot contain path separators") }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentBuildError.missingField("description") }
        if let maxTurns, maxTurns <= 0 { throw AgentBuildError.invalidConfig("maxTurns must be greater than 0") }
        if case let .custom(template) = systemPrompt, template.isEmpty { throw AgentBuildError.invalidConfig("systemPrompt custom template cannot be empty") }
        if case let .custom(template) = userMessageTemplate, template.isEmpty { throw AgentBuildError.invalidConfig("userMessageTemplate custom template cannot be empty") }
    }
}

private enum AgentDefinitionScope {
    static func scope(for url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> AgentScope {
        let path = url.standardizedFileURL.path
        let grokHome = AgentEnvironmentValue.grokHome(environment: environment).standardizedFileURL.path
        let home = environment["HOME"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if path.hasPrefix(grokHome + "/bundled/agents/") || path.contains("/.opengrok/bundled/agents/") { return .bundled }
        if path.hasPrefix(grokHome + "/agents/") || (home.map { path.hasPrefix($0 + "/.claude/agents/") } ?? false) { return .user }
        if path.contains("/.opengrok/agents/") || path.contains("/.claude/agents/") { return .project }
        return .builtIn
    }
}

private enum AgentEnvironmentValue {
    static func grokHome(environment: [String: String]) -> URL {
        if let configured = environment["OPENGROK_HOME"], !configured.isEmpty { return URL(fileURLWithPath: configured) }
        if let home = environment["HOME"], !home.isEmpty { return URL(fileURLWithPath: home).appendingPathComponent(".opengrok") }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".opengrok")
    }
}

private struct AgentFrontmatter {
    var values: AgentJSONValue
    var body: String?
}

private enum AgentFrontmatterParser {
    private struct Line {
        let indent: Int
        let text: String
    }

    static func parse(_ content: String) throws -> AgentFrontmatter {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var first = 0
        while first < lines.count && lines[first].trimmingCharacters(in: .whitespaces).isEmpty { first += 1 }
        guard first < lines.count, lines[first].trimmingCharacters(in: .whitespaces) == "---" else { throw AgentBuildError.parseError("missing frontmatter delimiters") }
        var closing: Int?
        if first + 1 < lines.count {
            for index in (first + 1)..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                closing = index
                break
            }
        }
        guard let closing else { throw AgentBuildError.parseError("missing closing frontmatter delimiter") }
        let yaml = Array(lines[(first + 1)..<closing]).joined(separator: "\n")
        let body = Array(lines.dropFirst(closing + 1)).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = try parseYAML(yaml)
        guard case .object = value else { throw AgentBuildError.parseError("frontmatter must be a mapping") }
        return AgentFrontmatter(values: value, body: body.isEmpty ? nil : body)
    }

    private static func parseYAML(_ yaml: String) throws -> AgentJSONValue {
        let lines = yaml.components(separatedBy: "\n").compactMap { raw -> Line? in
            let withoutComment = stripComment(raw)
            guard !withoutComment.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let indent = withoutComment.prefix { $0 == " " || $0 == "\t" }.count
            return Line(indent: indent, text: String(withoutComment.dropFirst(indent)).trimmingCharacters(in: .whitespaces))
        }
        guard !lines.isEmpty else { return .object([:]) }
        var index = 0
        return try parseBlock(lines, index: &index, indent: lines[0].indent)
    }

    private static func parseBlock(_ lines: [Line], index: inout Int, indent: Int) throws -> AgentJSONValue {
        guard index < lines.count else { return .null }
        if lines[index].indent == indent, lines[index].text.hasPrefix("-") {
            var result: [AgentJSONValue] = []
            while index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("-") {
                let item = String(lines[index].text.dropFirst()).trimmingCharacters(in: .whitespaces)
                index += 1
                if item.isEmpty {
                    if index < lines.count, lines[index].indent > indent { result.append(try parseBlock(lines, index: &index, indent: lines[index].indent)) }
                    else { result.append(.null) }
                } else if let pair = splitKeyValue(item) {
                    var object: [String: AgentJSONValue] = [:]
                    object[pair.key] = try valueForPair(pair.value, lines: lines, index: &index, parentIndent: indent)
                    while index < lines.count, lines[index].indent > indent {
                        let childIndent = lines[index].indent
                        let child = try parseBlock(lines, index: &index, indent: childIndent)
                        guard case let .object(childObject) = child else { break }
                        object.merge(childObject) { current, _ in current }
                    }
                    result.append(.object(object))
                } else {
                    result.append(try scalar(item))
                }
            }
            return .array(result)
        }

        var object: [String: AgentJSONValue] = [:]
        while index < lines.count, lines[index].indent == indent, !lines[index].text.hasPrefix("-") {
            guard let pair = splitKeyValue(lines[index].text) else { throw AgentBuildError.parseError("invalid frontmatter mapping: \(lines[index].text)") }
            index += 1
            object[pair.key] = try valueForPair(pair.value, lines: lines, index: &index, parentIndent: indent)
        }
        return .object(object)
    }

    private static func valueForPair(_ value: String, lines: [Line], index: inout Int, parentIndent: Int) throws -> AgentJSONValue {
        if value == "|" || value == ">" {
            var collected: [String] = []
            while index < lines.count, lines[index].indent > parentIndent {
                collected.append(lines[index].text)
                index += 1
            }
            return .string(value == "|" ? collected.joined(separator: "\n") : collected.joined(separator: " "))
        }
        if value.isEmpty {
            guard index < lines.count, lines[index].indent > parentIndent else { return .null }
            return try parseBlock(lines, index: &index, indent: lines[index].indent)
        }
        return try scalar(value)
    }

    private static func scalar(_ raw: String) throws -> AgentJSONValue {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "" || value == "~" || value.lowercased() == "null" { return .null }
        if value.lowercased() == "true" { return .bool(true) }
        if value.lowercased() == "false" { return .bool(false) }
        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inner = String(value.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .array([]) }
            return .array(try splitTopLevel(inner, separator: ",").map(scalar))
        }
        if value.hasPrefix("{") && value.hasSuffix("}") {
            let inner = String(value.dropFirst().dropLast())
            var object: [String: AgentJSONValue] = [:]
            for pair in splitTopLevel(inner, separator: ",") {
                guard let entry = splitKeyValue(pair) else { throw AgentBuildError.parseError("invalid inline mapping: \(value)") }
                object[unquote(entry.key)] = try scalar(entry.value)
            }
            return .object(object)
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { return .string(unquote(value)) }
        let numericPattern = #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#
        if value.range(of: numericPattern, options: .regularExpression) != nil,
           let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) {
            return .number(number)
        }
        return .string(value)
    }

    private static func splitKeyValue(_ value: String) -> (key: String, value: String)? {
        var quote: Character?
        var depth = 0
        for (offset, character) in value.enumerated() {
            if character == "'" || character == "\"" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if quote == nil {
                if character == "[" || character == "{" || character == "(" { depth += 1 }
                if character == "]" || character == "}" || character == ")" { depth = max(0, depth - 1) }
                if character == ":" && depth == 0 {
                    let key = String(value.prefix(offset)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let remainder = String(value.dropFirst(offset + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return nil }
                    return (unquote(key), remainder)
                }
            }
        }
        return nil
    }

    private static func splitTopLevel(_ value: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for character in value {
            if character == "'" || character == "\"" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if quote == nil {
                if character == "[" || character == "{" || character == "(" { depth += 1 }
                if character == "]" || character == "}" || character == ")" { depth = max(0, depth - 1) }
            }
            if character == separator && quote == nil && depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else { current.append(character) }
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result.filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.first == "'", value.last == "'" { return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        if value.first == "\"", value.last == "\"" {
            let json = Data(value.utf8)
            if let decoded = try? JSONDecoder().decode(String.self, from: json) { return decoded }
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func stripComment(_ raw: String) -> String {
        var quote: Character?
        for (offset, character) in raw.enumerated() {
            if character == "'" || character == "\"" {
                if quote == character { quote = nil } else if quote == nil { quote = character }
            } else if character == "#" && quote == nil && (offset == 0 || raw[raw.index(raw.startIndex, offsetBy: offset - 1)] == " ") {
                return String(raw.prefix(offset))
            }
        }
        return raw
    }
}
