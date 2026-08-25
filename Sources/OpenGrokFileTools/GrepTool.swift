// GrepTool.swift
//
// Content search via NSRegularExpression (rg-compatible flags subset).
// Prefer pure-Swift for hermetic tests; optionally shells out to `rg` when present.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspace

public enum GrepTool {
    public static let defaultHeadLimit = 200
    public static let defaultFileHeadLimit = 500
    public static let maximumContentHeadLimit = 2_000
    public static let maximumFileHeadLimit = 10_000

    private static let maximumSearchFileBytes = 5 * 1_024 * 1_024
    private static let maximumCharactersPerLine = 1_000

    private struct MatchRecord {
        let path: String
        let lineNumber: Int
        let text: String
    }

    private enum OutputRecord {
        case line(MatchRecord, isMatch: Bool)
        case separator
    }

    private enum OutputMode: String {
        case content
        case filesWithMatches = "files_with_matches"
        case count

        init(_ raw: String?) {
            switch raw?.lowercased().replacingOccurrences(of: "-", with: "_") {
            case "files_with_matches", "fileswithmatches", "files": self = .filesWithMatches
            case "count": self = .count
            default: self = .content
            }
        }
    }

    public static func run(
        args: JSONValue,
        resources: ToolResources,
        withHashline: Bool = false,
        context: ToolCallContext? = nil
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            guard let pattern = string(obj, "pattern"), !pattern.isEmpty else {
                throw SessionFSError.invalidInput("missing pattern")
            }
            let pathArg = string(obj, "path")
            let requestedGlob = string(obj, "glob")
            let glob = requestedGlob?.isEmpty == false ? requestedGlob : nil
            let caseInsensitive = bool(obj, "-i") ?? bool(obj, "case_insensitive") ?? false
            let multiline = bool(obj, "multiline") ?? false
            let outputMode = OutputMode(string(obj, "output_mode"))
            let headLimit = try effectiveHeadLimit(
                int(obj, "head_limit"),
                outputMode: outputMode.rawValue
            )
            let sharedContext = try nonnegativeArgument(obj, keys: ["-C", "context"]) ?? 0
            let beforeContext = try nonnegativeArgument(
                obj,
                keys: ["-B", "before_context"]
            ) ?? sharedContext
            let afterContext = try nonnegativeArgument(
                obj,
                keys: ["-A", "after_context"]
            ) ?? sharedContext
            let requestedFileType = string(obj, "type")
            let fileType = requestedFileType?.isEmpty == false ? requestedFileType : nil
            let typeExtensions = try fileType.map { try extensions(for: $0) }

            let root = SessionFS.resolve(cwd: resources.cwd, path: pathArg ?? ".")
            try SessionFS.enforceRoots(root, roots: resources.allowedRoots)

            var options: NSRegularExpression.Options = []
            if caseInsensitive { options.insert(.caseInsensitive) }
            if multiline {
                options.insert(.dotMatchesLineSeparators)
                options.insert(.anchorsMatchLines)
            }
            let regex = try NSRegularExpression(pattern: pattern, options: options)

            let files = try collectFiles(
                root: root,
                glob: glob,
                typeExtensions: typeExtensions,
                allowedRoots: resources.allowedRoots
            )
            let cancellation = context?.get(Cancellation.self)
            var matches: [MatchRecord] = []
            var outputRecords: [OutputRecord] = []
            var matchingFiles: [(path: String, count: Int)] = []
            var matchCount = 0
            var truncated = false

            fileSearch: for file in files {
                if Task.isCancelled || cancellation?.isCancelled == true {
                    return .failure(.cancelled(
                        toolId: FileToolIDs.grep,
                        detail: "grep was cancelled while searching"
                    ))
                }
                do {
                    try SessionFS.enforceRoots(file, roots: resources.allowedRoots)
                } catch {
                    continue
                }
                guard let text = try? SessionFS.readText(at: file) else { continue }
                let lines = SessionFS.logicalLines(text)
                guard let matchedIndexes = matchingLineIndexes(
                    in: text,
                    lines: lines,
                    regex: regex,
                    multiline: multiline,
                    cancellation: cancellation
                ) else {
                    return .failure(.cancelled(
                        toolId: FileToolIDs.grep,
                        detail: "grep was cancelled while searching"
                    ))
                }
                guard !matchedIndexes.isEmpty else { continue }

                switch outputMode {
                case .content:
                    let remaining = headLimit - outputRecords.count
                    let fileRecords = contentRecords(
                        path: file,
                        lines: lines,
                        matchingIndexes: matchedIndexes,
                        beforeContext: beforeContext,
                        afterContext: afterContext,
                        limit: remaining + 1
                    )
                    var visibleFileMatches = 0
                    for record in fileRecords.prefix(remaining) {
                        outputRecords.append(record)
                        if case .line(let match, isMatch: true) = record {
                            matches.append(match)
                            matchCount += 1
                            visibleFileMatches += 1
                        }
                    }
                    if visibleFileMatches > 0 {
                        matchingFiles.append((file, visibleFileMatches))
                    }
                    if fileRecords.count > remaining {
                        truncated = true
                        break fileSearch
                    }

                case .filesWithMatches, .count:
                    if matchingFiles.count == headLimit {
                        truncated = true
                        break fileSearch
                    }
                    matchingFiles.append((file, matchedIndexes.count))
                    matchCount += matchedIndexes.count
                }
            }

            let shownFiles = matchingFiles
            let matchedBody: String
            switch outputMode {
            case .content:
                matchedBody = outputRecords.map { record in
                    switch record {
                    case .separator:
                        return "--"
                    case .line(let match, let isMatch):
                        let separator = isMatch ? ":" : "-"
                        if withHashline {
                            let anchor = Hashline.anchor(for: match.text, line: match.lineNumber)
                            return "\(match.path):\(match.lineNumber)|\(anchor)\(separator)\(match.text)"
                        }
                        return "\(match.path):\(match.lineNumber)\(separator)\(match.text)"
                    }
                }.joined(separator: "\n")
            case .filesWithMatches:
                matchedBody = shownFiles.map(\.path).joined(separator: "\n")
            case .count:
                matchedBody = shownFiles.map { "\($0.path):\($0.count)" }.joined(separator: "\n")
            }
            var content = matchedBody
            if content.isEmpty {
                if truncated {
                    let unit = outputMode == .content ? "matches" : "files"
                    content = "[truncated: showing first \(headLimit) \(unit)]"
                } else {
                    content = "No matches found"
                }
            } else if truncated {
                let unit = outputMode == .content ? "matches" : "files"
                content += "\n\n[truncated: showing first \(headLimit) \(unit)]"
            }
            if content.utf8.count > defaultToolOutputBytes {
                let capped = capToolOutput(content)
                content = capped.modelText
                truncated = true
            }

            let visibleBody: String
            if content.hasPrefix(matchedBody) {
                visibleBody = matchedBody
            } else {
                visibleBody = String(zip(content, matchedBody)
                    .prefix { $0.0 == $0.1 }
                    .map { $0.0 })
            }
            guard await streamFileToolContent(
                visibleBody,
                subkind: "grep_match_chunk",
                context: context,
                flushPerLine: true
            ) else {
                return .failure(.cancelled(
                    toolId: FileToolIDs.grep,
                    detail: "grep was cancelled while streaming progress"
                ))
            }

            let structuredMatches: [JSONValue]
            switch outputMode {
            case .content:
                structuredMatches = matches.map { match in
                    .object([
                        "path": .string(match.path),
                        "line_number": .number(.int64(Int64(match.lineNumber))),
                        "text": .string(match.text),
                    ])
                }
            case .filesWithMatches:
                structuredMatches = shownFiles.map { .object(["path": .string($0.path)]) }
            case .count:
                structuredMatches = shownFiles.map {
                    .object([
                        "path": .string($0.path),
                        "count": .number(.int64(Int64($0.count))),
                    ])
                }
            }
            var valueFields: [String: JSONValue] = [
                "type": .string("grep"),
                "pattern": .string(pattern),
                "path": .string(root),
                "content": .string(content),
                "match_count": .number(.int64(Int64(matchCount))),
                "file_count": .number(.int64(Int64(matchingFiles.count))),
                "truncated": .bool(truncated),
                "case_insensitive": .bool(caseInsensitive),
                "multiline": .bool(multiline),
                "output_mode": .string(outputMode.rawValue),
                "head_limit": .number(.int64(Int64(headLimit))),
                "matches": .array(structuredMatches),
            ]
            if let glob { valueFields["glob"] = .string(glob) }
            if let fileType { valueFields["file_type"] = .string(fileType) }
            if beforeContext > 0 {
                valueFields["before_context"] = .number(.int64(Int64(beforeContext)))
            }
            if afterContext > 0 {
                valueFields["after_context"] = .number(.int64(Int64(afterContext)))
            }
            let value: JSONValue = .object(valueFields)
            return .success(
                TypedToolOutput(toolId: FileToolIDs.grep, value: value, modelOutput: [.text(text: content)])
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.invalidArguments("invalid regex: \(error)"))
        }
    }

    static func effectiveHeadLimit(_ requested: Int?, outputMode: String? = nil) throws -> Int {
        if let requested, requested < 0 {
            throw SessionFSError.invalidInput("head_limit must not be negative")
        }
        switch OutputMode(outputMode) {
        case .content:
            return min(requested ?? defaultHeadLimit, maximumContentHeadLimit)
        case .filesWithMatches, .count:
            return min(requested ?? defaultFileHeadLimit, maximumFileHeadLimit)
        }
    }

    private static func nonnegativeArgument(
        _ arguments: [String: JSONValue],
        keys: [String]
    ) throws -> Int? {
        for key in keys {
            guard let value = int(arguments, key) else { continue }
            guard value >= 0 else {
                throw SessionFSError.invalidInput("\(key) must not be negative")
            }
            return value
        }
        return nil
    }

    private static func matchingLineIndexes(
        in text: String,
        lines: [String],
        regex: NSRegularExpression,
        multiline: Bool,
        cancellation: Cancellation?
    ) -> [Int]? {
        guard !lines.isEmpty else { return [] }

        if !multiline {
            var result: [Int] = []
            for (index, line) in lines.enumerated() {
                if index.isMultiple(of: 64),
                   Task.isCancelled || cancellation?.isCancelled == true {
                    return nil
                }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    result.append(index)
                }
            }
            return result
        }

        // Normalize logical endings before locating UTF-16 match ranges: CRLF
        // occupies one Swift Character but two NSString code units.
        var normalized = lines.joined(separator: "\n")
        if SessionFS.hasTrailingNewline(text) {
            normalized.append("\n")
        }
        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += line.utf16.count + 1
        }

        let searchRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        var matched = Set<Int>()
        var wasCancelled = false
        var examined = 0
        regex.enumerateMatches(in: normalized, options: [], range: searchRange) { result, _, stop in
            if examined.isMultiple(of: 64),
               Task.isCancelled || cancellation?.isCancelled == true {
                wasCancelled = true
                stop.pointee = ObjCBool(true)
                return
            }
            examined += 1
            guard let result else { return }
            let lower = lineIndex(for: result.range.location, starts: lineStarts)
            let upperOffset = result.range.length == 0
                ? result.range.location
                : NSMaxRange(result.range) - 1
            let upper = lineIndex(for: upperOffset, starts: lineStarts)
            for index in lower...upper {
                matched.insert(index)
            }
        }
        return wasCancelled ? nil : matched.sorted()
    }

    private static func lineIndex(for offset: Int, starts: [Int]) -> Int {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, min(lower - 1, starts.count - 1))
    }

    private static func contentRecords(
        path: String,
        lines: [String],
        matchingIndexes: [Int],
        beforeContext: Int,
        afterContext: Int,
        limit: Int
    ) -> [OutputRecord] {
        guard limit > 0 else { return [] }
        var groups: [ClosedRange<Int>] = []
        for index in matchingIndexes {
            let lower = index - min(index, beforeContext)
            let upper = index + min(lines.count - index - 1, afterContext)
            if let previous = groups.last,
               lower <= previous.upperBound || lower - previous.upperBound == 1 {
                groups[groups.count - 1] = previous.lowerBound...max(previous.upperBound, upper)
            } else {
                groups.append(lower...upper)
            }
        }

        let matchingSet = Set(matchingIndexes)
        let includesContext = beforeContext > 0 || afterContext > 0
        var records: [OutputRecord] = []
        records.reserveCapacity(min(limit, lines.count))
        for (groupIndex, group) in groups.enumerated() {
            if groupIndex > 0, includesContext {
                records.append(.separator)
                if records.count == limit { return records }
            }
            for index in group {
                let record = MatchRecord(
                    path: path,
                    lineNumber: index + 1,
                    text: truncatedLine(lines[index])
                )
                records.append(.line(record, isMatch: matchingSet.contains(index)))
                if records.count == limit { return records }
            }
        }
        return records
    }

    private static func truncatedLine(_ line: String) -> String {
        guard line.utf8.count > maximumCharactersPerLine else { return line }
        let characterCount = line.count
        guard characterCount > maximumCharactersPerLine else { return line }
        return String(line.prefix(maximumCharactersPerLine))
            + " [... truncated (\(characterCount) chars total)]"
    }

    private static let fileTypeExtensions: [String: Set<String>] = [
        "c": ["c", "h"],
        "cpp": ["c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx", "inl"],
        "cs": ["cs"],
        "csharp": ["cs"],
        "css": ["css", "scss"],
        "dart": ["dart"],
        "elixir": ["ex", "exs"],
        "go": ["go"],
        "html": ["ejs", "htm", "html"],
        "java": ["java", "jsp", "jspx", "properties"],
        "javascript": ["cjs", "js", "jsx", "mjs", "vue"],
        "js": ["cjs", "js", "jsx", "mjs", "vue"],
        "json": ["json", "sarif"],
        "kotlin": ["kt", "kts"],
        "kt": ["kt", "kts"],
        "lua": ["lua"],
        "markdown": ["markdown", "md", "mdown", "mdwn", "mdx", "mkd", "mkdn"],
        "md": ["markdown", "md", "mdown", "mdwn", "mdx", "mkd", "mkdn"],
        "objc": ["h", "m"],
        "perl": ["pl", "pm", "pod", "t"],
        "php": ["php", "phtml"],
        "proto": ["proto"],
        "py": ["py", "pyi"],
        "python": ["py", "pyi"],
        "r": ["r"],
        "rb": ["rb", "rake"],
        "ruby": ["rb", "rake"],
        "rust": ["rs"],
        "scala": ["sc", "scala"],
        "sh": ["bash", "bashrc", "csh", "env", "ksh", "sh", "tcsh", "zsh"],
        "shell": ["bash", "bashrc", "csh", "env", "ksh", "sh", "tcsh", "zsh"],
        "sql": ["sql"],
        "swift": ["swift"],
        "toml": ["toml"],
        "ts": ["cts", "mts", "ts", "tsx"],
        "typescript": ["cts", "mts", "ts", "tsx"],
        "xml": ["xml", "xsd", "xsl", "xslt"],
        "yaml": ["yaml", "yml"],
    ]

    private static func extensions(for fileType: String) throws -> Set<String> {
        guard let extensions = fileTypeExtensions[fileType.lowercased()] else {
            throw SessionFSError.invalidInput("unrecognized file type: \(fileType)")
        }
        return extensions
    }

    private static func collectFiles(
        root: String,
        glob: String?,
        typeExtensions: Set<String>?,
        allowedRoots: [String]
    ) throws -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else {
            throw SessionFSError.notFound(root)
        }
        if !isDir.boolValue {
            let filename = (root as NSString).lastPathComponent
            guard matchesFileFilters(filename, glob: glob, typeExtensions: typeExtensions),
                  isSearchableFile(root)
            else {
                return []
            }
            return [root]
        }
        var results: [String] = []
        var ignoreRulesByDirectory: [String: [GitIgnoreRule]] = [:]
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let rel = enumerator?.nextObject() as? String {
            if rel.hasPrefix(".") || rel.contains("/.") {
                enumerator?.skipDescendants()
                continue
            }
            let full = (root as NSString).appendingPathComponent(rel)
            let values = try? URL(fileURLWithPath: full).resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            if values?.isSymbolicLink == true {
                enumerator?.skipDescendants()
                continue
            }
            var childDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &childDir) else {
                continue
            }
            do {
                try SessionFS.enforceRoots(full, roots: allowedRoots)
            } catch {
                if childDir.boolValue {
                    enumerator?.skipDescendants()
                }
                continue
            }
            let parent = (full as NSString).deletingLastPathComponent
            let activeIgnoreRules = ignoreRules(
                for: parent,
                searchRoot: root,
                allowedRoots: allowedRoots,
                cache: &ignoreRulesByDirectory
            )
            if GitIgnoreRule.isIgnored(path: rel, isDir: childDir.boolValue, rules: activeIgnoreRules) {
                if childDir.boolValue {
                    enumerator?.skipDescendants()
                }
                continue
            }
            if childDir.boolValue {
                continue
            }
            if !matchesFileFilters(rel, glob: glob, typeExtensions: typeExtensions)
                || !isSearchableFile(full) {
                continue
            }
            results.append(full)
            if results.count == maximumFileHeadLimit { break }
        }
        return results.sorted()
    }

    private static func matchesFileFilters(
        _ relativePath: String,
        glob: String?,
        typeExtensions: Set<String>?
    ) -> Bool {
        let filename = (relativePath as NSString).lastPathComponent
        if let glob, !globMatch(glob, relativePath), !globMatch(glob, filename) {
            return false
        }
        if let typeExtensions {
            let pathExtension = (filename as NSString).pathExtension.lowercased()
            return typeExtensions.contains(pathExtension)
        }
        return true
    }

    private static func isSearchableFile(_ path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ), values.isRegularFile == true else {
            return false
        }
        return values.fileSize.map { $0 <= maximumSearchFileBytes } ?? true
    }

    private static func ignoreRules(
        for directory: String,
        searchRoot: String,
        allowedRoots: [String],
        cache: inout [String: [GitIgnoreRule]]
    ) -> [GitIgnoreRule] {
        if let cached = cache[directory] {
            return cached
        }

        let relativeDirectory: String
        var rules: [GitIgnoreRule]
        if directory == searchRoot {
            relativeDirectory = ""
            rules = []
        } else {
            let parent = (directory as NSString).deletingLastPathComponent
            rules = ignoreRules(
                for: parent,
                searchRoot: searchRoot,
                allowedRoots: allowedRoots,
                cache: &cache
            )
            relativeDirectory = String(directory.dropFirst(searchRoot.count + 1)) + "/"
        }

        for filename in [".gitignore", ".ignore", ".rgignore"] {
            let path = (directory as NSString).appendingPathComponent(filename)
            guard SessionFS.fileExists(path) else { continue }
            do {
                try SessionFS.enforceRoots(path, roots: allowedRoots)
                let content = try SessionFS.readText(at: path)
                let normalized = SessionFS.logicalLines(content, preservingTrailingEmpty: true)
                    .joined(separator: "\n")
                rules.append(contentsOf: GitIgnoreRule.parse(content: normalized, scope: relativeDirectory))
            } catch {
                continue
            }
        }

        cache[directory] = rules
        return rules
    }

    static func globMatch(_ pattern: String, _ name: String) -> Bool {
        for expanded in expandedBracePatterns(pattern) {
            var expression = "^"
            var index = expanded.startIndex

            while index < expanded.endIndex {
                let character = expanded[index]
                if character == "*" {
                    let next = expanded.index(after: index)
                    if next < expanded.endIndex, expanded[next] == "*" {
                        let afterPair = expanded.index(after: next)
                        if afterPair < expanded.endIndex, expanded[afterPair] == "/" {
                            expression += "(?:.*/)?"
                            index = expanded.index(after: afterPair)
                        } else {
                            expression += ".*"
                            index = afterPair
                        }
                    } else {
                        expression += "[^/]*"
                        index = next
                    }
                } else if character == "?" {
                    expression += "[^/]"
                    index = expanded.index(after: index)
                } else {
                    expression += NSRegularExpression.escapedPattern(for: String(character))
                    index = expanded.index(after: index)
                }
            }

            expression += "$"
            guard let regex = try? NSRegularExpression(pattern: expression) else { continue }
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if regex.firstMatch(in: name, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func expandedBracePatterns(_ pattern: String) -> [String] {
        guard let opening = pattern.firstIndex(of: "{"),
              let closing = pattern[pattern.index(after: opening)...].firstIndex(of: "}")
        else {
            return [pattern]
        }

        let alternatives = pattern[pattern.index(after: opening)..<closing]
            .split(separator: ",", omittingEmptySubsequences: false)
        guard alternatives.count > 1 else { return [pattern] }

        let prefix = String(pattern[..<opening])
        let suffix = String(pattern[pattern.index(after: closing)...])
        return alternatives.flatMap { alternative in
            expandedBracePatterns(prefix + String(alternative) + suffix)
        }
    }
}
