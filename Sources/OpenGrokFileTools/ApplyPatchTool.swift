// ApplyPatchTool.swift
//
// Codex freeform apply-patch parser + apply. Ported from
// `xai-grok-tools/src/implementations/codex/apply_patch/parser.rs` (core subset).

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
        var lines = patch.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

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
                // Empty patch is a no-op success (parity with Rust empty_patch_returns_empty_patch_output).
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
            var touched: [String] = []

            for hunk in parsed.hunks {
                switch hunk {
                case .addFile(let path, let contents):
                    let abs = SessionFS.resolve(cwd: resources.cwd, path: path)
                    try SessionFS.enforceRoots(abs, roots: resources.allowedRoots)
                    let prev = SessionFS.fileExists(abs) ? try? SessionFS.readText(at: abs) : nil
                    try await SessionFS.writeText(
                        absolute: abs, content: contents, resources: resources, previousContent: prev
                    )
                    touched.append("A \(abs)")
                case .deleteFile(let path):
                    let abs = SessionFS.resolve(cwd: resources.cwd, path: path)
                    try SessionFS.enforceRoots(abs, roots: resources.allowedRoots)
                    let prev = try? SessionFS.readText(at: abs)
                    let lock = await resources.locks.acquirePath(abs)
                    defer { Task { await lock.release() } }
                    try FileManager.default.removeItem(atPath: abs)
                    if let tracker = resources.hunkTracker, let prev {
                        await tracker.recordAgentWrite(
                            path: abs,
                            content: "",
                            promptIndex: resources.promptIndex,
                            previousContent: prev,
                            agentId: resources.agentId,
                            writeSucceeded: true
                        )
                    }
                    touched.append("D \(abs)")
                case .updateFile(let path, let movePath, let chunks):
                    let abs = SessionFS.resolve(cwd: resources.cwd, path: path)
                    try SessionFS.enforceRoots(abs, roots: resources.allowedRoots)
                    var text = try SessionFS.readText(at: abs)
                    let previous = text
                    for chunk in chunks {
                        text = try applyChunk(chunk, to: text)
                    }
                    let dest: String
                    if let movePath {
                        dest = SessionFS.resolve(cwd: resources.cwd, path: movePath)
                        try SessionFS.enforceRoots(dest, roots: resources.allowedRoots)
                        try await SessionFS.writeText(
                            absolute: dest, content: text, resources: resources, previousContent: nil
                        )
                        let lock = await resources.locks.acquirePath(abs)
                        defer { Task { await lock.release() } }
                        try? FileManager.default.removeItem(atPath: abs)
                        touched.append("M \(abs) -> \(dest)")
                    } else {
                        dest = abs
                        try await SessionFS.writeText(
                            absolute: abs, content: text, resources: resources, previousContent: previous
                        )
                        touched.append("M \(abs)")
                    }
                    _ = dest
                }
            }

            let summary = "Success. Updated the following files:\n" + touched.map { "\($0)\n" }.joined()
            let value: JSONValue = .object([
                "type": .string("apply_patch"),
                "content": .string(summary),
                "files": .array(touched.map { .string($0) }),
            ])
            return .success(
                TypedToolOutput(toolId: FileToolIDs.applyPatch, value: value, modelOutput: [.text(text: summary)])
            )
        } catch let e as PatchParseError {
            return .failure(.invalidArguments(e.description))
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.applyPatch, detail: "\(error)"))
        }
    }

    private static func applyChunk(_ chunk: UpdateChunk, to text: String) throws -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }

        // Locate old_lines sequence, optionally after changeContext.
        var searchFrom = 0
        if let ctx = chunk.changeContext {
            if let idx = lines.firstIndex(of: ctx) {
                searchFrom = idx + 1
            }
        }
        let old = chunk.oldLines
        guard !old.isEmpty || !chunk.newLines.isEmpty else { return text }

        if old.isEmpty {
            // Pure insertion at context or EOF.
            if chunk.isEndOfFile {
                lines.append(contentsOf: chunk.newLines)
            } else if let ctx = chunk.changeContext, let idx = lines.firstIndex(of: ctx) {
                lines.insert(contentsOf: chunk.newLines, at: idx + 1)
            } else {
                lines.append(contentsOf: chunk.newLines)
            }
        } else {
            var found: Int?
            if searchFrom < lines.count {
                let window = lines[searchFrom...]
                for i in window.indices {
                    let end = i + old.count
                    if end <= lines.count, Array(lines[i..<end]) == old {
                        found = i
                        break
                    }
                }
            }
            guard let at = found else {
                throw SessionFSError.staleContext(
                    "Failed to find expected lines in patch update (stale context). Re-read the file."
                )
            }
            lines.replaceSubrange(at..<(at + old.count), with: chunk.newLines)
        }
        return lines.joined(separator: "\n") + (text.hasSuffix("\n") ? "\n" : "")
    }
}
