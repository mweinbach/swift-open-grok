// WriteTool.swift
//
// OpenCode full-file write — honest structured payload for the B2 create/edit painter.
//
// Rust refs (pin 650c1db7):
// - implementations/opencode/write/mod.rs: SearchReplaceOutput::EditsApplied with single detail
// - types/output.rs:297 SearchReplaceEditsApplied / SearchReplaceEditDetail / line_diff
// - diff.rs build_diff_hunks (the hunk shape is details → diff lines)

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

public enum WriteTool {
    public static func run(
        args: JSONValue,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let path = string(obj, "file_path") ?? string(obj, "filePath") ?? string(obj, "path")
            let content = string(obj, "content")
            guard let path, let content else {
                throw SessionFSError.invalidInput("file_path and content are required")
            }
            let absolute = SessionFS.resolve(cwd: resources.cwd, path: path)
            try SessionFS.enforceRoots(absolute, roots: resources.allowedRoots)
            if SessionFS.isDirectory(absolute) {
                throw SessionFSError.isDirectory(absolute)
            }
            let existingText: String? = SessionFS.fileExists(absolute)
                ? try SessionFS.readText(at: absolute)
                : nil
            let previous = existingText
            let existed = existingText != nil
            try await SessionFS.writeText(
                absolute: absolute,
                content: content,
                resources: resources,
                previousContent: previous
            )

            // Structured payload (same envelope Rust's write tool emits: SearchReplaceOutput::EditsApplied).
            // Keep the legacy `type: edits_applied` / `path` / `content` / `created` keys intact for wire compat.
            let oldString = previous ?? ""
            let newString = content
            let (added, removed) = SearchReplaceTool.lineDiff(old: oldString, new: newString)
            // Rust write emits one detail at line 1 with empty context/line_prefix (write/mod.rs:112).
            let detail: JSONValue = .object([
                "old_string": .string(oldString),
                "old_line": .number(.int64(1)),
                "new_string": .string(newString),
                "new_line": .number(.int64(1)),
                "context_before": .string(""),
                "context_after": .string(""),
                "line_prefix": .string(""),
            ])
            // Write is single-file by definition, so the collapsed summary is trusted.
            // The painter's `Creating ` vs `Edit ` prefix is decided from `created`.
            let created = previous == nil
            let value: JSONValue = .object([
                "type": .string("edits_applied"),
                "path": .string(absolute),
                "absolute_path": .string(absolute),
                "content": .string("Wrote \(content.utf8.count) bytes to \(absolute)"),
                "created": .bool(created),
                "is_new_file": .bool(created),
                "old_string": .string(oldString),
                "new_string": .string(newString),
                "edits": .object(["details": .array([detail])]),
                "lines_added": .number(.int64(Int64(added))),
                "lines_removed": .number(.int64(Int64(removed))),
                "trusted": .bool(true),
                "write_existed": .bool(existed),
            ])
            let promptText = existed
                ? "Wrote file successfully to \(absolute)."
                : "The file \(absolute) has been created."
            return .success(
                TypedToolOutput(
                    toolId: FileToolIDs.write,
                    value: value,
                    modelOutput: [.text(text: promptText)]
                )
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.write, detail: "\(error)"))
        }
    }
}
