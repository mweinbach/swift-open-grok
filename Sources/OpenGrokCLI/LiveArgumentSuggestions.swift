// LiveArgumentSuggestions.swift
//
// Filesystem path completion for the `/export` argument dropdown.
//
// Port of `list_path_completions` (`xai-grok-pager/src/slash/commands/
// export.rs:83-160` at upstream 70002584): parse the typed query into a
// directory-to-list plus the prefix the user has typed, list that directory,
// offer directories with a trailing `/` so accepting one keeps the dropdown
// open for drill-down (the same trick `/model` plays with a trailing space),
// sort directories first then alphabetical, and cap the row count.
//
// Upstream hands its items to a nucleo fuzzy matcher; this port's dropdown
// providers do their own matching, so the partial final component is applied
// here as a case-insensitive prefix filter — narrower than fuzzy, never
// wider: every row offered is one the query could have meant.

import Foundation
import OpenGrokPager

enum LiveExportPathSuggestions {
    /// `read_dir` pre-sort cap against pathological directories
    /// (export.rs:148-151).
    static let preSortCap = 1000
    /// Row cap after sorting (export.rs:159).
    static let maximumRows = 100

    static func suggestions(
        query: String,
        workingDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [OpenGrokPagerCommandSuggestion] {
        let trimmed = String(query.drop(while: \.isWhitespace))
        // An empty query offers nothing (export.rs:85-87): a bare `/export `
        // exports to the clipboard, and listing the whole cwd would bury that.
        guard !trimmed.isEmpty else { return [] }

        let expanded = expandTilde(trimmed, homeDirectory: homeDirectory)

        // Directory to list and the typed prefix to re-attach to each row
        // (export.rs:91-107): a trailing `/` lists that directory; otherwise
        // list the parent and filter by the partial final component.
        let directoryToList: String
        let typedPrefix: String
        let partialComponent: String
        if trimmed.hasSuffix("/") {
            directoryToList = expanded
            typedPrefix = trimmed
            partialComponent = ""
        } else if let slash = trimmed.lastIndex(of: "/") {
            typedPrefix = String(trimmed[...slash])
            partialComponent = String(trimmed[trimmed.index(after: slash)...])
            directoryToList = String(
                expandTilde(typedPrefix, homeDirectory: homeDirectory)
            )
        } else {
            typedPrefix = ""
            partialComponent = trimmed
            directoryToList = ""
        }

        let resolved: URL
        if directoryToList.isEmpty {
            resolved = workingDirectory
        } else if directoryToList.hasPrefix("/") {
            resolved = URL(fileURLWithPath: directoryToList, isDirectory: true)
        } else {
            resolved = workingDirectory.appendingPathComponent(
                directoryToList,
                isDirectory: true
            )
        }

        guard let names = try? fileManager.contentsOfDirectory(atPath: resolved.path) else {
            return []
        }

        struct Row {
            let display: String
            let insertPath: String
            let isDirectory: Bool
        }
        var rows: [Row] = []
        let needle = partialComponent.lowercased()
        for name in names {
            // Hidden entries are skipped (export.rs:126-128).
            if name.hasPrefix(".") { continue }
            if !needle.isEmpty, !name.lowercased().hasPrefix(needle) { continue }
            // `is_dir()` follows symlinks (export.rs:130-132), so a symlinked
            // directory still gets its drill-down slash.
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(
                atPath: resolved.appendingPathComponent(name).path,
                isDirectory: &isDirectory
            )
            let suffix = isDirectory.boolValue ? "/" : ""
            rows.append(Row(
                display: "\(name)\(suffix)",
                insertPath: "\(typedPrefix)\(name)\(suffix)",
                isDirectory: isDirectory.boolValue
            ))
            if rows.count >= preSortCap { break }
        }

        // Directories first, then alphabetical (export.rs:153-158).
        rows.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.display < rhs.display
        }

        return rows.prefix(maximumRows).map { row in
            OpenGrokPagerCommandSuggestion(
                name: row.display,
                summary: row.isDirectory ? "directory" : "file",
                // The row commits the whole composer text, not the bare path:
                // accepting must leave `/export docs/notes.md` behind.
                insertText: "/export \(row.insertPath)"
            )
        }
    }

    private static func expandTilde(_ path: String, homeDirectory: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = homeDirectory.path
        return path == "~" ? home : home + path.dropFirst(1)
    }
}
