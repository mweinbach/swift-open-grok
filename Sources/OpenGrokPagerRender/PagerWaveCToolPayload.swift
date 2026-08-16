import Foundation

extension PagerWaveCToolPayload {
    static func parse(
        kind: PagerToolKind,
        rawInput: String,
        output: String?,
        structuredOutput: String?
    ) -> PagerWaveCToolPayload? {
        let arguments = dictionary(fromJSON: rawInput) ?? [:]
        let structured = jsonObject(from: structuredOutput)
        let object = structured as? [String: Any]

        switch kind {
        case .read:
            guard let object else { return nil }
            let type = string(object["type"])
            let path = string(object["path"])
                ?? string(arguments["file_path"])
                ?? string(arguments["filePath"])
                ?? string(arguments["target_file"])
                ?? string(arguments["path"])
                ?? ""
            if type == "image" {
                return .read(PagerReadPayload(path: path, media: .image))
            }
            if type == "pdf" {
                return .read(PagerReadPayload(
                    path: path,
                    media: .pdf(pages: integer(object["pages"]) ?? 0)
                ))
            }
            guard type == "file_content" || object["content"] != nil else { return nil }
            return .read(PagerReadPayload(
                path: path,
                content: stripReadPrefixes(string(object["content"]) ?? ""),
                totalLines: integer(object["total_lines"]),
                startLine: integer(object["start_line"]),
                endLine: integer(object["end_line"]),
                truncated: boolean(object["truncated"]) ?? false
            ))

        case .list:
            guard let object,
                  string(object["type"]) == "list_dir" || object["entry_count"] != nil
            else { return nil }
            let path = string(object["path"])
                ?? string(arguments["target_directory"])
                ?? string(arguments["path"])
                ?? ""
            let content = stripLeadingListPath(string(object["content"]) ?? output ?? "", path: path)
            return .list(PagerListPayload(
                path: path,
                content: content,
                entryCount: integer(object["entry_count"]) ?? visibleListEntryCount(content),
                truncated: boolean(object["truncated"]) ?? false
            ))

        case .search:
            let type = string(object?["type"])
            let mode = searchMode(
                string(object?["output_mode"])
                    ?? string(arguments["output_mode"]),
                isGlob: type == "glob"
            )
            let pattern = string(object?["pattern"])
                ?? string(arguments["pattern"])
                ?? string(arguments["query"])
                ?? ""
            let content = string(object?["content"]) ?? output ?? ""
            let matches = searchMatches(object?["matches"], content: content, mode: mode)
            let fileCount = integer(object?["file_count"])
                ?? Set(matches.map(\.path).filter { !$0.isEmpty }).count
            let matchCount = integer(object?["match_count"])
                ?? (mode == .count ? matches.reduce(0) { $0 + (Int($1.text) ?? 0) } : matches.count)
            return .search(PagerSearchPayload(
                pattern: pattern,
                path: string(object?["path"]) ?? string(arguments["path"]),
                glob: string(object?["glob"]) ?? string(arguments["glob"]),
                caseInsensitive: boolean(object?["case_insensitive"])
                    ?? boolean(arguments["case_insensitive"])
                    ?? boolean(arguments["-i"])
                    ?? false,
                multiline: boolean(object?["multiline"])
                    ?? boolean(arguments["multiline"])
                    ?? false,
                mode: mode,
                matchCount: matchCount,
                fileCount: fileCount,
                truncated: boolean(object?["truncated"]) ?? false,
                matches: matches
            ))

        case .fetch:
            let url = string(arguments["url"]) ?? string(object?["final_url"]) ?? rawInput
            guard object != nil || !url.isEmpty else { return nil }
            return .fetch(PagerFetchPayload(
                url: url,
                finalURL: string(object?["final_url"]),
                statusCode: integer(object?["status_code"]),
                contentType: string(object?["content_type"]),
                totalBytes: integer(object?["total_bytes"]),
                content: string(object?["content"]) ?? output,
                truncated: boolean(object?["truncated"]) ?? false
            ))

        case .webSearch, .xSearch:
            let isXSearch = kind == .xSearch
            let query = string(arguments["query"])
                ?? backendQuery(rawInput, isXSearch: isXSearch)
                ?? rawInput
            let citationObjects: [[String: Any]] = object?["citations"] as? [[String: Any]] ?? []
            let citations: [PagerWebCitation] = citationObjects.compactMap { citation in
                guard let url = string(citation["url"]), !url.isEmpty else { return nil }
                return PagerWebCitation(title: string(citation["title"]) ?? "", url: url)
            }
            return .webSearch(PagerWebSearchPayload(
                query: query,
                content: isXSearch ? nil : string(object?["content"]) ?? output,
                citations: citations,
                isXSearch: isXSearch
            ))

        case .memorySearch:
            let query = string(arguments["query"]) ?? rawInput
            let text = string(structured) ?? string(object?["content"]) ?? output ?? ""
            return .memorySearch(PagerMemorySearchPayload(
                query: query,
                results: memoryResults(text)
            ))

        case .integrationSearch:
            let query = string(arguments["query"]) ?? rawInput
            let catalogObject: [String: Any]? = {
                if let content = string(object?["content"]), let decoded = dictionary(fromJSON: content) {
                    return decoded
                }
                return object
            }()
            let groups = catalogObject?["results"] as? [[String: Any]] ?? []
            var results: [PagerIntegrationToolResult] = []
            for group in groups {
                let server = string(group["server"]) ?? ""
                for tool in group["tools"] as? [[String: Any]] ?? [] {
                    guard let name = string(tool["tool_name"]), !name.isEmpty else { continue }
                    results.append(PagerIntegrationToolResult(
                        server: server,
                        toolName: name,
                        description: string(tool["description"]) ?? ""
                    ))
                }
            }
            return .integrationSearch(PagerIntegrationSearchPayload(
                query: query,
                status: string(catalogObject?["status"]),
                results: results
            ))

        case .useTool:
            guard let qualifiedName = string(arguments["tool_name"])
                ?? string(arguments["toolName"])
            else { return nil }
            let server: String
            let action: String
            if let separator = qualifiedName.range(of: "__") {
                server = String(qualifiedName[..<separator.lowerBound])
                action = String(qualifiedName[separator.upperBound...])
            } else {
                server = qualifiedName
                action = qualifiedName
            }
            let input = normalizedToolInput(arguments["tool_input"])
            let pairs = input.keys.sorted().map {
                PagerUseToolArgument(key: $0, value: displayJSONValue(input[$0]))
            }
            return .useTool(PagerUseToolPayload(
                qualifiedName: qualifiedName,
                server: server,
                action: action,
                arguments: pairs,
                output: output ?? string(object?["content"])
            ))

        case .generic:
            let text = string(object?["message"])
                ?? string(object?["content"])
                ?? output
                ?? ""
            let pairs = questionAnswers(text)
            return pairs.isEmpty ? nil : .questions(pairs)

        case .execute, .edit, .create, .skill:
            return nil
        }
    }
}

private func jsonObject(from raw: String?) -> Any? {
    guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

private func dictionary(fromJSON raw: String) -> [String: Any]? {
    jsonObject(from: raw) as? [String: Any]
}

private func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    return nil
}

private func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

private func boolean(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
    return nil
}

private func stripReadPrefixes(_ content: String) -> String {
    content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        let value = String(line)
        guard let arrow = value.firstIndex(of: "→") else { return value }
        let prefix = value[..<arrow]
        guard prefix.first?.isNumber == true else { return value }
        return String(value[value.index(after: arrow)...])
    }.joined(separator: "\n")
}

private func stripLeadingListPath(_ content: String, path: String) -> String {
    var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if let first = lines.first,
       first.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        == path.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    {
        lines.removeFirst()
    }
    return lines.map { line in
        line.hasPrefix("  ") ? String(line.dropFirst(2)) : line
    }.joined(separator: "\n")
}

private func visibleListEntryCount(_ content: String) -> Int {
    content.split(separator: "\n").filter {
        let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        return !line.isEmpty && line != "..." && !line.hasPrefix("Note:")
    }.count
}

private func searchMode(_ raw: String?, isGlob: Bool) -> PagerSearchOutputMode {
    if isGlob { return .glob }
    switch raw?.lowercased().replacingOccurrences(of: "-", with: "_") {
    case "files_with_matches", "fileswithmatches", "files": return .filesWithMatches
    case "count": return .count
    default: return .content
    }
}

private func searchMatches(
    _ rawMatches: Any?,
    content: String,
    mode: PagerSearchOutputMode
) -> [PagerSearchMatch] {
    if let objects = rawMatches as? [[String: Any]] {
        return objects.compactMap { object in
            guard let path = string(object["path"]), !path.isEmpty else { return nil }
            return PagerSearchMatch(
                path: path,
                lineNumber: integer(object["line_number"]),
                text: string(object["text"])
                    ?? integer(object["count"]).map(String.init)
                    ?? ""
            )
        }
    }
    return content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "No matches found",
              trimmed != "No files found",
              !trimmed.hasPrefix("[truncated:"),
              !trimmed.hasPrefix("(Results are truncated:")
        else { return nil }
        if mode == .glob || mode == .filesWithMatches {
            return PagerSearchMatch(path: trimmed)
        }
        if mode == .count, let separator = trimmed.lastIndex(of: ":") {
            let path = String(trimmed[..<separator])
            let count = String(trimmed[trimmed.index(after: separator)...])
            return PagerSearchMatch(path: path, text: count)
        }
        guard let match = firstRegexMatch("^(.+):(\\d+)(?:\\|[^:]+)?:?(.*)$", in: line),
              match.count == 4
        else { return PagerSearchMatch(path: "", text: line) }
        return PagerSearchMatch(
            path: match[1],
            lineNumber: Int(match[2]),
            text: match[3]
        )
    }
}

private func backendQuery(_ raw: String, isXSearch: Bool) -> String? {
    if isXSearch {
        guard let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close else {
            return raw.split(separator: "]", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        }
        let inside = String(raw[raw.index(after: open)..<close])
        if let object = dictionary(fromJSON: inside), let query = string(object["query"]) { return query }
        return inside
    }
    if let marker = raw.range(of: "search: ") {
        return String(raw[marker.upperBound...])
    }
    return raw.split(separator: "]", maxSplits: 1).last.map(String.init)?.trimmingCharacters(in: .whitespaces)
}

private func memoryResults(_ text: String) -> [PagerMemoryResult] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var results: [PagerMemoryResult] = []
    var index = 0
    while index < lines.count {
        guard lines[index].hasPrefix("### Result ") else {
            index += 1
            continue
        }
        let header = firstRegexMatch("score: ([0-9.]+), source: ([^)]+)", in: lines[index])
        index += 1
        guard index < lines.count,
              let file = firstRegexMatch("^\\*\\*File:\\*\\* (.+) \\(lines (\\d+)-(\\d+)\\)$", in: lines[index]),
              file.count == 4
        else { continue }
        index += 1
        if index < lines.count, lines[index] == "```" { index += 1 }
        var snippet: [String] = []
        while index < lines.count, lines[index] != "```" {
            snippet.append(lines[index])
            index += 1
        }
        results.append(PagerMemoryResult(
            path: file[1],
            startLine: Int(file[2]),
            endLine: Int(file[3]),
            score: header.flatMap { $0.count > 1 ? Double($0[1]) : nil },
            source: header.flatMap { $0.count > 2 ? $0[2] : nil },
            snippet: snippet.joined(separator: "\n")
        ))
        index += 1
    }
    return results
}

private func normalizedToolInput(_ value: Any?) -> [String: Any] {
    if let object = value as? [String: Any] { return object }
    if let string = value as? String, let object = dictionary(fromJSON: string) { return object }
    return [:]
}

private func displayJSONValue(_ value: Any?) -> String {
    guard let value else { return "null" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let string = String(data: data, encoding: .utf8)
    {
        return string
    }
    return String(describing: value)
}

private func questionAnswers(_ output: String) -> [PagerToolQuestionAnswer] {
    let prefix = "User has answered your questions: "
    if output.hasPrefix(prefix) {
        var body = String(output.dropFirst(prefix.count))
        let suffix = ". You can now continue with the user's answers in mind."
        if body.hasSuffix(suffix) { body.removeLast(suffix.count) }
        var pairs: [PagerToolQuestionAnswer] = []
        var remaining = body
        while remaining.hasPrefix("\"") {
            remaining.removeFirst()
            guard let separator = remaining.range(of: "\"=\"") else { break }
            let question = String(remaining[..<separator.lowerBound])
            remaining = String(remaining[separator.upperBound...])
            let next = remaining.range(of: ", \"")
            var answer = String(remaining[..<(next?.lowerBound ?? remaining.endIndex)])
            if answer.hasSuffix("\"") { answer.removeLast() }
            if let annotation = answer.range(of: " selected preview:") {
                answer = String(answer[..<annotation.lowerBound])
            }
            if let annotation = answer.range(of: " user notes:") {
                answer = String(answer[..<annotation.lowerBound])
            }
            pairs.append(PagerToolQuestionAnswer(question: question, answer: answer))
            guard let next else { break }
            remaining = String(remaining[next.upperBound...])
            remaining.insert("\"", at: remaining.startIndex)
        }
        return pairs
    }

    guard output.contains("Questions asked"), output.contains("- \"") else { return [] }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var pairs: [PagerToolQuestionAnswer] = []
    var index = 0
    while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
            index += 1
            continue
        }
        let question = String(trimmed.dropFirst().dropLast())
        var answer = ""
        if index + 1 < lines.count {
            let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
            if next.hasPrefix("Answer: ") { answer = String(next.dropFirst(8)) }
        }
        pairs.append(PagerToolQuestionAnswer(question: question, answer: answer))
        index += 2
    }
    return pairs
}

private func firstRegexMatch(_ pattern: String, in text: String) -> [String]? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
          )
    else { return nil }
    return (0..<match.numberOfRanges).map { offset in
        let range = match.range(at: offset)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }
}
