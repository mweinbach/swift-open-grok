// ToolIDs.swift
//
// Safe ToolId constructors for known file-tool names.

import OpenGrokToolProtocol

enum FileToolIDs {
    static let readFile = must("read_file")
    static let listDir = must("list_dir")
    static let grep = must("grep")
    static let glob = must("glob")
    static let searchReplace = must("search_replace")
    static let applyPatch = must("apply_patch")
    static let write = must("write")
    static let hashlineEdit = must("hashline_edit")
    static let viewImage = must("view_image")

    private static func must(_ name: String) -> ToolId {
        do {
            return try ToolId(name)
        } catch {
            preconditionFailure("invalid built-in tool id: \(name)")
        }
    }
}
