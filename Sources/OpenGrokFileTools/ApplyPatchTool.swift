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
import OpenGrokFileUtils
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
                guard l.hasPrefix("+") else { break }
                contents.append(String(l.dropFirst()))
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
                    throw PatchParseError.invalid(
                        "Unexpected line in update hunk at line \(lineNumber + i): \(l). "
                            + "Every line must begin with ' ', '+', or '-'."
                    )
                }
                i += 1
            }
            flush()
            guard !chunks.isEmpty,
                  chunks.allSatisfy({ !$0.oldLines.isEmpty || !$0.newLines.isEmpty })
            else {
                throw PatchParseError.invalid(
                    "Update file hunk for path '\(path)' is empty at line \(lineNumber)"
                )
            }
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
    enum MutationCheckpoint: Sendable {
        case acquiredLock
        case beforeSourceDeletion
    }

    struct MutationInterlock: Sendable {
        let handler: @Sendable (MutationCheckpoint, String) async throws -> Void
    }

    private struct MutationFailure: Error, Sendable, CustomStringConvertible {
        let description: String
    }

    public static func run(
        args: JSONValue,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let supplied = ["patch", "input", "apply_patch"].compactMap { name in
                obj[name].map { (name, $0) }
            }
            guard let first = supplied.first else {
                return .failure(.invalidArguments(
                    "apply_patch requires a string 'input', 'patch', or 'apply_patch' argument"
                ))
            }
            guard supplied.allSatisfy({ $0.1 == first.1 }) else {
                return .failure(.invalidArguments("conflicting apply_patch argument aliases"))
            }
            guard case .string(let patchText) = first.1 else {
                return .failure(.invalidArguments(
                    "apply_patch requires a string 'input', 'patch', or 'apply_patch' argument"
                ))
            }

            let parsed = try ApplyPatchParser.parse(patchText)
            if parsed.hunks.isEmpty {
                let summary = "No files were modified."
                return .success(
                    TypedToolOutput(
                        toolId: FileToolIDs.applyPatch,
                        value: .object([
                            "type": .string("apply_patch"),
                            "EmptyPatch": .string(summary),
                            "content": .string(summary),
                            "files": .array([]),
                            "file_results": .array([]),
                            "lines_added": .number(.int64(0)),
                            "lines_removed": .number(.int64(0)),
                            "trusted": .bool(false),
                            "patch": .string(patchText),
                        ]),
                        modelOutput: [.text(text: summary)]
                    )
                )
            }

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
            return .failure(.invalidArguments("Invalid patch: \(e.description)"))
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
            let lock = await resources.locks.acquirePath(result.path)
            defer { Task { await lock.release() } }
            try await checkpoint(.acquiredLock, path: result.path, resources: resources)
            try SessionFS.enforceRoots(result.path, roots: resources.allowedRoots)
            guard let previous = result.oldContent else {
                throw MutationFailure(description: "Cannot delete a file without its original contents: \(result.path)")
            }
            let source = try PinnedDeletionTarget(
                path: result.path,
                expectedContent: previous,
                roots: resources.allowedRoots
            )
            try await checkpoint(.beforeSourceDeletion, path: result.path, resources: resources)
            try source.remove(roots: resources.allowedRoots)
            if let tracker = resources.hunkTracker {
                await tracker.recordAgentWrite(
                    path: result.path,
                    content: "",
                    promptIndex: resources.promptIndex,
                    previousContent: previous,
                    agentId: resources.agentId,
                    writeSucceeded: true
                )
            }
        case .modified:
            try await SessionFS.writeText(
                absolute: result.path, content: result.newContent, resources: resources, previousContent: result.oldContent
            )
        case .moved:
            guard let destination = result.moveTo else {
                throw MutationFailure(description: "Patch move is missing its destination: \(result.path)")
            }
            guard destination != result.path else {
                throw MutationFailure(description: "Patch move source and destination must differ: \(result.path)")
            }

            // SessionFS.writeText acquires its own path lock, so calling it
            // beneath an exclusive lock would deadlock. Write directly through
            // the same no-follow atomic primitive and attribute both mutations
            // only after their complete, rollback-protected transaction.
            let lock = await resources.locks.acquireExclusive()
            defer { Task { await lock.release() } }
            try await checkpoint(.acquiredLock, path: result.path, resources: resources)
            try SessionFS.enforceRoots(result.path, roots: resources.allowedRoots)
            try SessionFS.enforceRoots(destination, roots: resources.allowedRoots)
            guard let previousSource = result.oldContent else {
                throw MutationFailure(description: "Cannot move a file without its original contents: \(result.path)")
            }
            let source = try PinnedDeletionTarget(
                path: result.path,
                expectedContent: previousSource,
                roots: resources.allowedRoots
            )

            let previousDestination: String?
            if SessionFS.fileExists(destination) {
                if try PathSecurity.isSymlink(URL(fileURLWithPath: destination)) {
                    throw SessionFSError.symlinkEscape(destination)
                }
                previousDestination = try SessionFS.readText(at: destination)
            } else {
                previousDestination = nil
            }

            try AtomicFile.write(
                URL(fileURLWithPath: destination),
                contents: result.newContent,
                options: AtomicWriteOptions(syncFile: true, noFollowFinal: true)
            )

            do {
                try await checkpoint(.beforeSourceDeletion, path: result.path, resources: resources)
                try source.remove(roots: resources.allowedRoots)
            } catch {
                do {
                    try restoreMoveDestination(
                        path: destination,
                        previousContent: previousDestination,
                        writtenContent: result.newContent,
                        roots: resources.allowedRoots
                    )
                } catch let rollbackError {
                    throw MutationFailure(description:
                        "Failed to delete move source \(result.path): \(error); "
                            + "destination rollback failed for \(destination): \(rollbackError)"
                    )
                }
                throw MutationFailure(description:
                    "Failed to delete move source \(result.path): \(error)"
                )
            }

            if let tracker = resources.hunkTracker {
                await tracker.recordAgentWrite(
                    path: destination,
                    content: result.newContent,
                    promptIndex: resources.promptIndex,
                    previousContent: previousDestination,
                    agentId: resources.agentId,
                    writeSucceeded: true
                )
                await tracker.recordAgentWrite(
                    path: result.path,
                    content: "",
                    promptIndex: resources.promptIndex,
                    previousContent: previousSource,
                    agentId: resources.agentId,
                    writeSucceeded: true
                )
            }
        }
    }

    private static func checkpoint(
        _ checkpoint: MutationCheckpoint,
        path: String,
        resources: ToolResources
    ) async throws {
        guard let interlock = resources.extras.get(MutationInterlock.self) else { return }
        try await interlock.handler(checkpoint, path)
    }

    private static func restoreMoveDestination(
        path: String,
        previousContent: String?,
        writtenContent: String,
        roots: [String]
    ) throws {
        try SessionFS.enforceRoots(path, roots: roots)
        if let previousContent {
            try AtomicFile.write(
                URL(fileURLWithPath: path),
                contents: previousContent,
                options: AtomicWriteOptions(syncFile: true, noFollowFinal: true)
            )
        } else {
            let destination = try PinnedDeletionTarget(
                path: path,
                expectedContent: writtenContent,
                roots: roots
            )
            try destination.remove(roots: roots)
        }
    }

    private final class PinnedDeletionTarget: @unchecked Sendable {
        private let path: String
        private let expectedContent: String
        private let rootPath: String
        private let parentPath: String
        private let leafName: String

        #if os(Windows)
        private var directoryHandles: [HANDLE] = []
        private var directoryPaths: [String] = []
        #else
        private var directoryDescriptors: [Int32] = []
        private var fileDescriptor: Int32 = -1
        private static var directoryFlags: Int32 {
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        }
        #endif

        init(path: String, expectedContent: String, roots: [String]) throws {
            let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
            let anchor = try Self.anchor(for: absolute, roots: roots)
            guard let leaf = anchor.components.last else {
                throw MutationFailure(description: "Cannot delete an authorized workspace root: \(absolute)")
            }

            self.path = absolute
            self.expectedContent = expectedContent
            self.rootPath = anchor.root
            self.parentPath = URL(fileURLWithPath: absolute).deletingLastPathComponent().path
            self.leafName = leaf

            #if os(Windows)
            var directory = URL(fileURLWithPath: anchor.root)
            try openWindowsDirectory(directory.path)
            for component in anchor.components.dropLast() {
                directory.appendPathComponent(component, isDirectory: true)
                try openWindowsDirectory(directory.path)
            }
            let sourceData = try PathSecurity.readNoFollow(URL(fileURLWithPath: absolute))
            guard String(data: sourceData, encoding: .utf8) == expectedContent else {
                throw MutationFailure(description: "Patch source changed after it was read: \(absolute)")
            }
            #else
            let rootDescriptor = anchor.root.withCString { open($0, Self.directoryFlags) }
            guard rootDescriptor >= 0 else {
                throw Self.posixFailure(path: anchor.root, operation: "open authorized root")
            }
            directoryDescriptors.append(rootDescriptor)

            var directory = URL(fileURLWithPath: anchor.root)
            for component in anchor.components.dropLast() {
                directory.appendPathComponent(component, isDirectory: true)
                guard let parent = directoryDescriptors.last else {
                    throw MutationFailure(description: "Patch deletion lost its authorized parent descriptor")
                }
                let descriptor = component.withCString { openat(parent, $0, Self.directoryFlags) }
                guard descriptor >= 0 else {
                    throw Self.posixFailure(path: directory.path, operation: "open no-follow parent")
                }
                directoryDescriptors.append(descriptor)
            }

            guard let parent = directoryDescriptors.last else {
                throw MutationFailure(description: "Patch deletion lost its authorized parent descriptor")
            }
            fileDescriptor = leaf.withCString {
                openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            guard fileDescriptor >= 0 else {
                throw Self.posixFailure(path: absolute, operation: "open no-follow patch source")
            }

            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
            let sourceData = try handle.readToEnd() ?? Data()
            guard String(data: sourceData, encoding: .utf8) == expectedContent else {
                throw MutationFailure(description: "Patch source changed after it was read: \(absolute)")
            }
            #endif

            try revalidate(roots: roots)
        }

        deinit {
            #if os(Windows)
            for handle in directoryHandles.reversed() {
                CloseHandle(handle)
            }
            #else
            if fileDescriptor >= 0 {
                close(fileDescriptor)
            }
            for descriptor in directoryDescriptors.reversed() {
                close(descriptor)
            }
            #endif
        }

        func remove(roots: [String]) throws {
            try revalidate(roots: roots)

            #if os(Windows)
            let native = try WindowsSecurePath.extendedLengthPath(path)
            let removed = native.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
            guard removed else {
                throw MutationFailure(description:
                    "Failed to delete file \(path): Windows error \(GetLastError())"
                )
            }
            #else
            guard let parent = directoryDescriptors.last else {
                throw MutationFailure(description: "Patch deletion lost its authorized parent descriptor")
            }
            let removed = leafName.withCString { unlinkat(parent, $0, 0) }
            guard removed == 0 else {
                throw Self.posixFailure(path: path, operation: "delete file")
            }
            #endif
        }

        private func revalidate(roots: [String]) throws {
            try SessionFS.enforceRoots(path, roots: roots)

            #if os(Windows)
            for directory in directoryPaths {
                guard let metadata = try WindowsSecurePath.metadata(at: URL(fileURLWithPath: directory)),
                      metadata.isDirectory,
                      !metadata.isReparsePoint
                else {
                    throw SessionFSError.symlinkEscape(directory)
                }
            }
            guard let metadata = try WindowsSecurePath.metadata(at: URL(fileURLWithPath: path)),
                  !metadata.isDirectory,
                  !metadata.isReparsePoint
            else {
                throw MutationFailure(description: "Patch source disappeared or became unsafe: \(path)")
            }
            #else
            guard let root = directoryDescriptors.first,
                  let parent = directoryDescriptors.last
            else {
                throw MutationFailure(description: "Patch deletion lost its authorized root descriptor")
            }
            try verifyDirectory(root, stillRepresents: rootPath)
            try verifyDirectory(parent, stillRepresents: parentPath)

            var descriptorInformation = stat()
            var pathInformation = stat()
            guard fstat(fileDescriptor, &descriptorInformation) == 0 else {
                throw Self.posixFailure(path: path, operation: "inspect pinned source")
            }
            let inspected = leafName.withCString {
                fstatat(parent, $0, &pathInformation, AT_SYMLINK_NOFOLLOW)
            }
            guard inspected == 0 else {
                throw Self.posixFailure(path: path, operation: "revalidate patch source")
            }
            guard pathInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  descriptorInformation.st_dev == pathInformation.st_dev,
                  descriptorInformation.st_ino == pathInformation.st_ino
            else {
                throw MutationFailure(description: "Patch source changed after its descriptor was pinned: \(path)")
            }
            #endif
        }

        private static func anchor(
            for path: String,
            roots: [String]
        ) throws -> (root: String, components: [String]) {
            guard !path.contains("\0") else {
                throw SessionFSError.outsideWorkspace(path)
            }

            let candidates: [String]
            if roots.isEmpty {
                candidates = [URL(fileURLWithPath: path).deletingLastPathComponent().path]
            } else {
                candidates = roots.flatMap { root in
                    let standardized = URL(fileURLWithPath: root).standardizedFileURL
                    let resolved = standardized.resolvingSymlinksInPath().path
                    return standardized.path == resolved
                        ? [standardized.path]
                        : [standardized.path, resolved]
                }.sorted { $0.count > $1.count }
            }

            for root in candidates {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                #if os(Windows)
                guard path.lowercased().hasPrefix(prefix.lowercased()) else { continue }
                #else
                guard path.hasPrefix(prefix) else { continue }
                #endif
                let components = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
                guard !components.isEmpty,
                      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
                else {
                    continue
                }
                return (root, components)
            }

            throw SessionFSError.outsideWorkspace(path)
        }

        #if os(Windows)
        private func openWindowsDirectory(_ path: String) throws {
            let native = try WindowsSecurePath.extendedLengthPath(path)
            let raw = native.withCString(encodedAs: UTF16.self) { pointer in
                CreateFileW(
                    pointer,
                    DWORD(FILE_READ_ATTRIBUTES),
                    DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                    nil,
                    DWORD(OPEN_EXISTING),
                    DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
                    nil
                )
            }
            guard let handle = raw, handle != INVALID_HANDLE_VALUE else {
                throw MutationFailure(description:
                    "Failed to open no-follow patch parent \(path): Windows error \(GetLastError())"
                )
            }

            var information = BY_HANDLE_FILE_INFORMATION()
            guard GetFileInformationByHandle(handle, &information),
                  information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
                  information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
            else {
                CloseHandle(handle)
                throw SessionFSError.symlinkEscape(path)
            }
            directoryHandles.append(handle)
            directoryPaths.append(path)
        }
        #else
        private func verifyDirectory(_ descriptor: Int32, stillRepresents path: String) throws {
            let observed = path.withCString { open($0, Self.directoryFlags) }
            guard observed >= 0 else {
                throw Self.posixFailure(path: path, operation: "revalidate no-follow parent")
            }
            defer { close(observed) }

            var originalInformation = stat()
            var observedInformation = stat()
            guard fstat(descriptor, &originalInformation) == 0,
                  fstat(observed, &observedInformation) == 0,
                  originalInformation.st_dev == observedInformation.st_dev,
                  originalInformation.st_ino == observedInformation.st_ino
            else {
                throw MutationFailure(description: "Patch parent changed after its descriptor was pinned: \(path)")
            }
        }

        private static func posixFailure(path: String, operation: String) -> MutationFailure {
            let code = errno
            return MutationFailure(description:
                "Failed to \(operation) \(path): \(String(cString: strerror(code)))"
            )
        }
        #endif
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
