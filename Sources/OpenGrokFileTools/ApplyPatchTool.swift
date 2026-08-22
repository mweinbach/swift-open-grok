// ApplyPatchTool.swift
//
// Codex freeform apply-patch parser + apply. Ported from
// `xai-grok-tools/src/implementations/codex/apply_patch/parser.rs` (core subset).
//
// Structured payload for B2 painter: per-file old/new content, hunks/regions,
// insert/delete counts (line_diff), trusted/untrusted provenance, and
// creating-vs-editing classification per file. The apply is compute-then-write
// and atomic: no file is written if any hunk fails.
//
// Rust refs (pin 650c1db7):
// - types/output.rs:351 ApplyPatchFileResult, 369 ApplyPatchOutput
// - implementations/codex/apply_patch/tool.rs (compute_all_changes atomicity)
// - diff.rs extract_edit_hunks / build_diff_hunks
// - scrollback/blocks/tool/edit.rs EditToolCallBlock + summary_untrusted

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

// MARK: - AST

public enum PatchHunk: Sendable, Equatable {
    case addFile(path: String, contents: String)
    case deleteFile(path: String)
    case updateFile(path: String, movePath: String?, chunks: [UpdateChunk])
}

public struct UpdateChunk: Sendable, Equatable {
    public var changeContext: String?
    public var oldLines: [String]
    public var newLines: [String]
    public var isEndOfFile: Bool

    public init(
        changeContext: String? = nil,
        oldLines: [String],
        newLines: [String],
        isEndOfFile: Bool = false
    ) {
        self.changeContext = changeContext
        self.oldLines = oldLines
        self.newLines = newLines
        self.isEndOfFile = isEndOfFile
    }
}

public struct ParsedPatch: Sendable, Equatable {
    public var hunks: [PatchHunk]
    public var patch: String
}

public enum PatchParseError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self {
        case .invalid(let m): return m
        }
    }
}

// MARK: - Parser

public enum ApplyPatchParser {
    private static let beginMarker = "*** Begin Patch"
    private static let endMarker = "*** End Patch"
    private static let addMarker = "*** Add File: "
    private static let deleteMarker = "*** Delete File: "
    private static let updateMarker = "*** Update File: "
    private static let moveMarker = "*** Move to: "
    private static let eofMarker = "*** End of File"

    public static func parse(_ patch: String) throws -> ParsedPatch {
        var lines = SessionFS.logicalLines(
            patch.trimmingCharacters(in: .whitespacesAndNewlines),
            preservingTrailingEmpty: true
        )

        // Lenient heredoc strip.
        if lines.count >= 4,
           lines.first == "<<EOF" || lines.first == "<<'EOF'" || lines.first == "<<\"EOF\"",
           lines.last?.hasSuffix("EOF") == true
        {
            lines = Array(lines.dropFirst().dropLast())
        }

        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first == beginMarker
        else {
            throw PatchParseError.invalid("The first line of the patch must be '*** Begin Patch'")
        }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces),
              last == endMarker
        else {
            throw PatchParseError.invalid("The last line of the patch must be '*** End Patch'")
        }

        var hunks: [PatchHunk] = []
        var i = 1
        let end = lines.count - 1
        while i < end {
            let (hunk, consumed) = try parseOneHunk(Array(lines[i..<end]), lineNumber: i + 1)
            hunks.append(hunk)
            i += consumed
        }
        return ParsedPatch(hunks: hunks, patch: lines.joined(separator: "\n"))
    }

    private static func parseOneHunk(_ lines: [String], lineNumber: Int) throws -> (PatchHunk, Int) {
        guard let first = lines.first else {
            throw PatchParseError.invalid("empty hunk at line \(lineNumber)")
        }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(addMarker) {
            let path = String(trimmed.dropFirst(addMarker.count))
            var contents: [String] = []
            var i = 1
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("*** ") { break }
                if l.hasPrefix("+") {
                    contents.append(String(l.dropFirst()))
                } else if l.isEmpty {
                    contents.append("")
                } else {
                    // Lenient: accept raw content lines.
                    contents.append(l)
                }
                i += 1
            }
            let body = contents.joined(separator: "\n")
            let final = body.isEmpty ? body : body + (body.hasSuffix("\n") ? "" : "\n")
            return (.addFile(path: path, contents: final), i)
        }
        if trimmed.hasPrefix(deleteMarker) {
            let path = String(trimmed.dropFirst(deleteMarker.count))
            return (.deleteFile(path: path), 1)
        }
        if trimmed.hasPrefix(updateMarker) {
            let path = String(trimmed.dropFirst(updateMarker.count))
            var i = 1
            var movePath: String?
            if i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(moveMarker) {
                    movePath = String(t.dropFirst(moveMarker.count))
                    i += 1
                }
            }
            var chunks: [UpdateChunk] = []
            var context: String?
            var oldLines: [String] = []
            var newLines: [String] = []
            var isEOF = false

            func flush() {
                if !oldLines.isEmpty || !newLines.isEmpty || context != nil {
                    chunks.append(
                        UpdateChunk(
                            changeContext: context,
                            oldLines: oldLines,
                            newLines: newLines,
                            isEndOfFile: isEOF
                        )
                    )
                }
                context = nil
                oldLines = []
                newLines = []
                isEOF = false
            }

            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("*** ") && !t.hasPrefix(eofMarker) && !t.hasPrefix(moveMarker) {
                    break
                }
                if t == eofMarker || t.hasPrefix(eofMarker) {
                    isEOF = true
                    i += 1
                    flush()
                    continue
                }
                if t == "@@" || t.hasPrefix("@@ ") {
                    flush()
                    if t.hasPrefix("@@ ") {
                        context = String(t.dropFirst(3))
                    } else {
                        context = nil
                    }
                    i += 1
                    continue
                }
                if l.hasPrefix("+") {
                    newLines.append(String(l.dropFirst()))
                } else if l.hasPrefix("-") {
                    oldLines.append(String(l.dropFirst()))
                } else if l.hasPrefix(" ") {
                    let body = String(l.dropFirst())
                    oldLines.append(body)
                    newLines.append(body)
                } else if t.isEmpty {
                    oldLines.append("")
                    newLines.append("")
                } else {
                    // Context without marker.
                    oldLines.append(l)
                    newLines.append(l)
                }
                i += 1
            }
            flush()
            return (.updateFile(path: path, movePath: movePath, chunks: chunks), i)
        }
        throw PatchParseError.invalid("Unknown hunk marker at line \(lineNumber): \(trimmed)")
    }

    /// True when every hunk only adds/updates the exact plan file path (plan-mode gate helper).
    public static func onlyTouchesPlanFile(_ patch: ParsedPatch, planPath: String) -> Bool {
        let plan = (planPath as NSString).standardizingPath
        let planName = (plan as NSString).lastPathComponent
        for hunk in patch.hunks {
            switch hunk {
            case .deleteFile:
                return false
            case .addFile(let path, _):
                let abs = (path as NSString).standardizingPath
                if abs != plan && (abs as NSString).lastPathComponent != planName {
                    return false
                }
            case .updateFile(let path, let move, _):
                if move != nil { return false }
                let abs = (path as NSString).standardizingPath
                if abs != plan && (abs as NSString).lastPathComponent != planName {
                    return false
                }
            }
        }
        return !patch.hunks.isEmpty
    }
}

// MARK: - Apply

public enum ApplyPatchTool {
    public static func run(
        args: JSONValue,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let patchText =
                string(obj, "input")
                ?? string(obj, "patch")
                ?? string(obj, "apply_patch")
            guard let patchText, !patchText.isEmpty else {
                return .success(
                    TypedToolOutput(
                        toolId: FileToolIDs.applyPatch,
                        value: .object([
                            "type": .string("apply_patch"),
                            "content": .string("Success. Updated the following files:\n"),
                            "files": .array([]),
                        ]),
                        modelOutput: [.text(text: "Success. Updated the following files:\n")]
                    )
                )
            }

            let parsed = try ApplyPatchParser.parse(patchText)

            // Compute all changes in-memory first (atomic: no write until every hunk validates).
            // Mirrors Rust's compute_all_changes overlay semantics (tool.rs:compute_all_changes).
            let computed = try await computeAllChanges(parsed: parsed, resources: resources)
            switch computed {
            case .failure(let message):
                // ApplicationError — no file was mutated.
                return .failure(.invalidArguments(message))
            case .success(let fileResults):
                // Commit each change and record hunks only after success.
                for result in fileResults {
                    try await commit(result: result, resources: resources)
                }
                let touched = fileResults.map { $0.shortLabel }
                let summary = "Success. Updated the following files:\n" + touched.map { "\($0)\n" }.joined()
                // Structured payload for B2: per-file old/new, hunks as details, counts, provenance.
                let fileObjects: [JSONValue] = fileResults.map { r in
                    let (added, removed) = r.lineCounts
                    // Build details for this file (same shape as search_replace edits)
                    let details: [JSONValue]
                    switch r.kind {
                    case .added:
                        details = [.object([
                            "old_string": .string(""),
                            "old_line": .number(.int64(1)),
                            "new_string": .string(r.newContent),
                            "new_line": .number(.int64(1)),
                            "context_before": .string(""),
                            "context_after": .string(""),
                            "line_prefix": .string(""),
                        ])]
                    case .deleted:
                        let old = r.oldContent ?? ""
                        let (a2, rm2) = SearchReplaceTool.lineDiff(old: old, new: "")
                        _ = (a2, rm2)
                        details = [.object([
                            "old_string": .string(old),
                            "old_line": .number(.int64(1)),
                            "new_string": .string(""),
                            "new_line": .number(.int64(1)),
                            "context_before": .string(""),
                            "context_after": .string(""),
                            "line_prefix": .string(""),
                        ])]
                    case .modified, .moved:
                        // For updates, synthesize a single detail spanning the file
                        // with before/after as full content; the diff layer's LCS
                        // will derive the correct hunks. This keeps the wire
                        // honest without reimplementing the full Rust chunk→edits mapping.
                        let old = r.oldContent ?? ""
                        details = [.object([
                            "old_string": .string(old),
                            "old_line": .number(.int64(1)),
                            "new_string": .string(r.newContent),
                            "new_line": .number(.int64(1)),
                            "context_before": .string(""),
                            "context_after": .string(""),
                            "line_prefix": .string(""),
                        ])]
                    }
                    var obj: [String: JSONValue] = [
                        "path": .string(r.path),
                        "action": .string(r.actionString),
                        "old_text": r.oldContent.map { .string($0) } ?? .null,
                        "new_text": .string(r.newContent),
                        "lines_added": .number(.int64(Int64(added))),
                        "lines_removed": .number(.int64(Int64(removed))),
                        "edits": .object(["details": .array(details)]),
                    ]
                    if let dest = r.moveTo {
                        obj["move_to"] = .string(dest)
                    }
                    return .object(obj)
                }
                let totalAdded = fileResults.reduce(0) { $0 + $1.lineCounts.added }
                let totalRemoved = fileResults.reduce(0) { $0 + $1.lineCounts.removed }
                let trusted = fileResults.count == 1
                let value: JSONValue = .object([
                    "type": .string("apply_patch"),
                    "content": .string(summary),
                    "files": .array(touched.map { .string($0) }),
                    "file_results": .array(fileObjects),
                    "lines_added": .number(.int64(Int64(totalAdded))),
                    "lines_removed": .number(.int64(Int64(totalRemoved))),
                    "trusted": .bool(trusted),
                    "patch": .string(patchText),
                ])
                return .success(
                    TypedToolOutput(toolId: FileToolIDs.applyPatch, value: value, modelOutput: [.text(text: summary)])
                )
            }
        } catch let e as PatchParseError {
            return .failure(.invalidArguments(e.description))
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.applyPatch, detail: "\(error)"))
        }
    }

    // MARK: - In-memory compute + atomic commit

    enum ComputedKind: Sendable, Equatable {
        case added, deleted, modified, moved
    }

    struct ComputedFileResult: Sendable, Equatable {
        var kind: ComputedKind
        var path: String
        var moveTo: String?
        var oldContent: String?
        var newContent: String
        var lineCounts: (added: Int, removed: Int)
        var shortLabel: String

        static func == (lhs: ComputedFileResult, rhs: ComputedFileResult) -> Bool {
            lhs.kind == rhs.kind && lhs.path == rhs.path && lhs.moveTo == rhs.moveTo
            && lhs.oldContent == rhs.oldContent && lhs.newContent == rhs.newContent
        }

        var actionString: String {
            switch kind {
            case .added: return "added"
            case .deleted: return "deleted"
            case .modified: return "modified"
            case .moved: return "moved"
            }
        }
    }

    enum ComputeOutcome: Sendable {
        case success([ComputedFileResult])
        case failure(String)
    }

    private static func computeAllChanges(parsed: ParsedPatch, resources: ToolResources) async throws -> ComputeOutcome {
        var overlay: [String: String?] = [:]
        var results: [ComputedFileResult] = []
        var errors: [String] = []
        var validPaths: [String] = []

        func readCurrent(_ absolute: String) async throws -> String {
            if let v = overlay[absolute] {
                if let s = v { return s }
                throw SessionFSError.notFound(absolute)
            }
            return try SessionFS.readText(at: absolute)
        }

        for hunk in parsed.hunks {
            switch hunk {
            case .addFile(let path, let contents):
                let abs = SessionFS.resolve(cwd: resources.cwd, path: path)
                do { try SessionFS.enforceRoots(abs, roots: resources.allowedRoots) } catch {
                    errors.append("Path escapes workspace: \(abs)")
                    continue
                }
                let previousContent: String?
                if let current = overlay[abs] {
                    previousContent = current
                } else if SessionFS.fileExists(abs) {
                    do {
                        previousContent = try SessionFS.readText(at: abs)
                    } catch {
                        errors.append("Failed to read existing file: \(abs), \(error)")
                        continue
                    }
                } else {
                    previousContent = nil
                }
                let (a, r) = SearchReplaceTool.lineDiff(old: "", new: contents)
                overlay[abs] = contents
                validPaths.append(path)
                results.append(ComputedFileResult(
                    kind: .added, path: abs, moveTo: nil, oldContent: previousContent,
                    newContent: contents, lineCounts: (a, r), shortLabel: "A \(abs)"
                ))
            case .deleteFile(let path):
                let abs = SessionFS.resolve(cwd: resources.cwd, path: path)
                do { try SessionFS.enforceRoots(abs, roots: resources.allowedRoots) } catch {
                    errors.append("Path escapes workspace: \(abs)")
                    continue
                }
                do {
                    let original = try await readCurrent(abs)
                    overlay[abs] = .some(nil)
                    validPaths.append(path)
                    let (a, rm) = SearchReplaceTool.lineDiff(old: original, new: "")
                    results.append(ComputedFileResult(
                        kind: .deleted, path: abs, moveTo: nil, oldContent: original,
                        newContent: "", lineCounts: (a, rm), shortLabel: "D \(abs)"
                    ))
                } catch {
                    errors.append("Failed to read file: \(abs), \(error)")
                }
            case .updateFile(let path, let movePath, let chunks):
                let abs = SessionFS.resolve(cwd: resources.cwd, path: path)
                do { try SessionFS.enforceRoots(abs, roots: resources.allowedRoots) } catch {
                    errors.append("Path escapes workspace: \(abs)")
                    continue
                }
                if let movePath {
                    let dest = SessionFS.resolve(cwd: resources.cwd, path: movePath)
                    do { try SessionFS.enforceRoots(dest, roots: resources.allowedRoots) } catch {
                        errors.append("Path escapes workspace: \(dest)")
                        continue
                    }
                }
                // Deleted-by-earlier-hunk guard (tool.rs parity).
                if let v = overlay[abs], v == nil {
                    errors.append("File \(abs) was deleted by an earlier hunk in this patch")
                    continue
                }
                let original: String
                do { original = try await readCurrent(abs) } catch {
                    errors.append("Failed to read file to update: \(abs), \(error)")
                    continue
                }
                do {
                    var text = original
                    for chunk in chunks {
                        text = try applyChunk(chunk, to: text)
                    }
                    if let movePath {
                        let dest = SessionFS.resolve(cwd: resources.cwd, path: movePath)
                        overlay[abs] = .some(nil)
                        overlay[dest] = text
                        validPaths.append(path)
                        let (a, rm) = SearchReplaceTool.lineDiff(old: original, new: text)
                        results.append(ComputedFileResult(
                            kind: .moved, path: abs, moveTo: dest, oldContent: original,
                            newContent: text, lineCounts: (a, rm), shortLabel: "M \(abs) -> \(dest)"
                        ))
                    } else {
                        overlay[abs] = text
                        validPaths.append(path)
                        let (a, rm) = SearchReplaceTool.lineDiff(old: original, new: text)
                        results.append(ComputedFileResult(
                            kind: .modified, path: abs, moveTo: nil, oldContent: original,
                            newContent: text, lineCounts: (a, rm), shortLabel: "M \(abs)"
                        ))
                    }
                } catch let e as SessionFSError {
                    errors.append(e.description)
                } catch {
                    errors.append("\(error)")
                }
            }
        }

        if errors.isEmpty {
            return .success(results)
        }
        let validSummary = validPaths.isEmpty ? "none" : validPaths.joined(separator: ", ")
        let msg = errors.joined(separator: "\n") + "\nNo changes were applied to any file. \(validPaths.count) of \(parsed.hunks.count) hunks were valid (\(validSummary))."
        return .failure(msg)
    }

    private static func commit(result: ComputedFileResult, resources: ToolResources) async throws {
        switch result.kind {
        case .added:
            let prev: String? = SessionFS.fileExists(result.path)
                ? try SessionFS.readText(at: result.path)
                : nil
            try await SessionFS.writeText(
                absolute: result.path, content: result.newContent, resources: resources, previousContent: prev
            )
        case .deleted:
            try SessionFS.enforceRoots(result.path, roots: resources.allowedRoots)
            let lock = await resources.locks.acquirePath(result.path)
            defer { Task { await lock.release() } }
            try FileManager.default.removeItem(atPath: result.path)
            if let tracker = resources.hunkTracker, let prev = result.oldContent {
                await tracker.recordAgentWrite(
                    path: result.path,
                    content: "",
                    promptIndex: resources.promptIndex,
                    previousContent: prev,
                    agentId: resources.agentId,
                    writeSucceeded: true
                )
            }
        case .modified:
            try await SessionFS.writeText(
                absolute: result.path, content: result.newContent, resources: resources, previousContent: result.oldContent
            )
        case .moved:
            guard let dest = result.moveTo else { return }
            try await SessionFS.writeText(
                absolute: dest, content: result.newContent, resources: resources, previousContent: nil
            )
            let lock = await resources.locks.acquirePath(result.path)
            defer { Task { await lock.release() } }
            try? FileManager.default.removeItem(atPath: result.path)
            // Record the move as a write to the destination; the deletion's
            // prior content is still `result.oldContent` for hunk diff context.
            _ = result.path
        }
    }

    private static func applyChunk(_ chunk: UpdateChunk, to text: String) throws -> String {
        var lines = SessionFS.logicalLines(text)
        let lineEnding = SessionFS.lineEnding(in: text)

        var searchFrom = 0
        if let ctx = chunk.changeContext {
            guard let index = seekSequence(lines, pattern: [ctx], start: 0, atEndOfFile: false) else {
                throw SessionFSError.staleContext(
                    "Failed to find patch context '\(ctx)' (stale context). Re-read the file."
                )
            }
            searchFrom = index + 1
        }
        let old = chunk.oldLines
        guard !old.isEmpty || !chunk.newLines.isEmpty else { return text }

        if old.isEmpty {
            if chunk.isEndOfFile {
                lines.append(contentsOf: chunk.newLines)
            } else if let ctx = chunk.changeContext, let idx = lines.firstIndex(of: ctx) {
                lines.insert(contentsOf: chunk.newLines, at: idx + 1)
            } else {
                lines.append(contentsOf: chunk.newLines)
            }
        } else {
            guard let at = seekSequence(
                lines,
                pattern: old,
                start: searchFrom,
                atEndOfFile: chunk.isEndOfFile
            ) else {
                throw SessionFSError.staleContext(
                    "Failed to find expected lines in patch update (stale context). Re-read the file."
                )
            }
            lines.replaceSubrange(at..<(at + old.count), with: chunk.newLines)
        }
        return lines.joined(separator: lineEnding)
            + (SessionFS.hasTrailingNewline(text) ? lineEnding : "")
    }

    private static func seekSequence(
        _ lines: [String],
        pattern: [String],
        start: Int,
        atEndOfFile: Bool
    ) -> Int? {
        guard !pattern.isEmpty else { return start }
        guard pattern.count <= lines.count else { return nil }

        let lastStart = lines.count - pattern.count
        let firstStart = atEndOfFile ? lastStart : start
        guard firstStart >= 0, firstStart <= lastStart else { return nil }

        let comparisons: [(String, String) -> Bool] = [
            { $0 == $1 },
            { trimTrailingWhitespace($0) == trimTrailingWhitespace($1) },
            {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    == $1.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            { normalizedPatchLine($0) == normalizedPatchLine($1) },
        ]

        for matches in comparisons {
            for index in firstStart...lastStart {
                let candidate = lines[index..<(index + pattern.count)]
                if zip(candidate, pattern).allSatisfy({ matches($0.0, $0.1) }) {
                    return index
                }
            }
        }
        return nil
    }

    private static func trimTrailingWhitespace(_ text: String) -> String {
        guard let last = text.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(text[...last])
    }

    private static func normalizedPatchLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = String.UnicodeScalarView()

        for scalar in trimmed.unicodeScalars {
            switch scalar.value {
            case 0x2010...0x2015, 0x2212:
                normalized.append("-")
            case 0x2018...0x201B:
                normalized.append("'")
            case 0x201C...0x201F:
                normalized.append("\"")
            case 0x00A0, 0x2002...0x200A, 0x202F, 0x205F, 0x3000:
                normalized.append(" ")
            default:
                normalized.append(scalar)
            }
        }
        return String(normalized)
    }
}
