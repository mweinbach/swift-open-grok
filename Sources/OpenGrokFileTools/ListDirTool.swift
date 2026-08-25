// ListDirTool.swift
//
// Directory listing with char budget and truncation notice.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWorkspace

public enum ListDirTool {
    public static let defaultMaxOutputChars = 10_000
    static let maximumGlobalItems = 100_000
    static let maximumSeedItems = 100_000
    static let maximumTraversalDepth = 256

    private static let maximumIgnoreFileBytes = 1_048_576
    private static let maximumExtensionBuckets = 3
    private static let rootTruncationNotice = "    ...\n\nNote: this directory is too large "
        + "to list fully. Try list_dir on a narrower path, or use grep / bash."

    struct RenderedDirectory {
        let body: String
        let entryCount: Int
        let truncated: Bool
    }

    private struct DirectoryEntry {
        let name: String
        let path: String
        let isDirectory: Bool
    }

    private struct DirectoryContents {
        let entries: [DirectoryEntry]
        let ignoreRules: [GitIgnoreRule]
    }

    private struct DirectoryFrame {
        let path: String
        let components: [String]
        let inheritedRules: [GitIgnoreRule]
    }

    private final class DirectoryNode {
        let depth: Int
        var files: [String] = []
        var directories: [String] = []
        var children: [String: DirectoryNode] = [:]
        var extensionCounts: [String: Int] = [:]
        var totalFiles = 0
        var isExpanded = false

        init(depth: Int) {
            self.depth = depth
        }

        func add(_ components: ArraySlice<String>, isDirectory: Bool) {
            guard let first = components.first else { return }
            if components.count == 1 {
                if isDirectory {
                    let key = first + "/"
                    if children[key] == nil {
                        children[key] = DirectoryNode(depth: depth + 1)
                        directories.append(key)
                    }
                } else {
                    files.append(first)
                    addExtension(of: first)
                }
                return
            }

            let key = first + "/"
            let child: DirectoryNode
            if let existing = children[key] {
                child = existing
            } else {
                child = DirectoryNode(depth: depth + 1)
                children[key] = child
                directories.append(key)
            }
            child.add(components.dropFirst(), isDirectory: isDirectory)
            if !isDirectory, let filename = components.last {
                addExtension(of: filename)
            }
        }

        private func addExtension(of filename: String) {
            let pathExtension = (filename as NSString).pathExtension.lowercased()
            let key = pathExtension.isEmpty ? "no-ext" : pathExtension
            extensionCounts[key, default: 0] += 1
            totalFiles += 1
        }

        func sortRecursively() {
            files.sort(by: ListDirTool.caseInsensitiveOrder)
            directories.sort(by: ListDirTool.caseInsensitiveOrder)
            for child in children.values {
                child.sortRecursively()
            }
        }

        func allNames() -> [String] {
            (files + directories).sorted(by: ListDirTool.caseInsensitiveOrder)
        }

        func entryLine(_ name: String) -> String {
            String(repeating: "  ", count: depth + 1) + "- " + name
        }

        func summary() -> String {
            guard !extensionCounts.isEmpty else { return "" }
            let buckets = extensionCounts.sorted { left, right in
                if left.value != right.value { return left.value > right.value }
                return left.key < right.key
            }
            var includedFiles = 0
            let descriptions = buckets.prefix(ListDirTool.maximumExtensionBuckets).map { bucket in
                includedFiles += bucket.value
                if bucket.key == "no-ext" {
                    return "\(bucket.value) *no-ext"
                }
                return "\(bucket.value) *.\(bucket.key)"
            }
            let suffix = includedFiles < totalFiles ? ", ..." : ""
            let noun = totalFiles == 1 ? "file" : "files"
            return "[\(totalFiles) \(noun) in subtree: \(descriptions.joined(separator: ", "))\(suffix)]"
        }

        func summaryCost() -> Int {
            let summary = summary()
            guard !summary.isEmpty else { return 0 }
            return (depth + 1) * 2 + summary.utf8.count + 1
        }

        func renderExpanded() -> String {
            var result = ""
            for name in allNames() {
                result += entryLine(name) + "\n"
                if let child = children[name] {
                    result += child.renderSubtree()
                }
            }
            return result
        }

        private func renderSubtree() -> String {
            if isExpanded {
                return renderExpanded()
            }
            let summary = summary()
            guard !summary.isEmpty else { return "" }
            return String(repeating: "  ", count: depth + 1) + summary + "\n"
        }
    }

    public static func run(
        args: JSONValue,
        resources: ToolResources,
        maxChars: Int = defaultMaxOutputChars
    ) async -> Result<TypedToolOutput, ToolError> {
        do {
            guard case .object(let obj) = args else {
                throw SessionFSError.invalidInput("expected object")
            }
            let target =
                string(obj, "target_directory")
                ?? string(obj, "path")
                ?? "."
            let absolute = SessionFS.resolve(cwd: resources.cwd, path: target)
            try SessionFS.enforceRoots(absolute, roots: resources.allowedRoots)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir),
                  isDir.boolValue
            else {
                throw SessionFSError.notDirectory(absolute)
            }

            let rendered = try renderDirectory(
                at: absolute,
                allowedRoots: resources.allowedRoots,
                maxChars: maxChars
            )
            let body = rendered.body.trimmingCharacters(in: .newlines)
            let content = "- \(absolute)/\n\(body)"
            let value: JSONValue = .object([
                "type": .string("list_dir"),
                "path": .string(absolute),
                "content": .string(content),
                "truncated": .bool(rendered.truncated),
                "entry_count": .number(.int64(Int64(rendered.entryCount))),
            ])
            return .success(
                TypedToolOutput(toolId: FileToolIDs.listDir, value: value, modelOutput: [.text(text: content)])
            )
        } catch let e as SessionFSError {
            return .failure(.invalidArguments(e.description))
        } catch {
            return .failure(.execution(toolId: FileToolIDs.listDir, detail: "\(error)"))
        }
    }

    static func renderDirectory(
        at root: String,
        allowedRoots: [String],
        maxChars: Int,
        maximumItems: Int = maximumGlobalItems,
        maximumSeeds: Int = maximumSeedItems,
        maximumDepth: Int = maximumTraversalDepth
    ) throws -> RenderedDirectory {
        guard maxChars >= 0, maximumItems >= 0, maximumSeeds >= 0, maximumDepth > 0 else {
            throw SessionFSError.invalidInput("Directory listing limits must not be negative")
        }
        try SessionFS.enforceRoots(root, roots: allowedRoots)
        guard try URL(fileURLWithPath: root).resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink != true else {
            throw SessionFSError.invalidInput("Symbolic link directories cannot be traversed")
        }

        let tree = DirectoryNode(depth: 0)
        let seedContents = try visibleEntries(
            in: root,
            relativeDirectory: "",
            inheritedRules: [],
            allowedRoots: allowedRoots,
            maximumCount: maximumSeeds + 1
        )
        var walkTruncated = seedContents.entries.count > maximumSeeds
        let seeded = Array(seedContents.entries.prefix(maximumSeeds))
        for entry in seeded {
            tree.add([entry.name][...], isDirectory: entry.isDirectory)
        }

        var stack = seeded.filter(\.isDirectory).reversed().map { entry in
            DirectoryFrame(
                path: entry.path,
                components: [entry.name],
                inheritedRules: seedContents.ignoreRules
            )
        }
        var itemCount = 0
        var depthTruncated = false

        directoryWalk: while let frame = stack.popLast() {
            let contents = try visibleEntries(
                in: frame.path,
                relativeDirectory: frame.components.joined(separator: "/"),
                inheritedRules: frame.inheritedRules,
                allowedRoots: allowedRoots,
                maximumCount: maximumItems - itemCount + 1
            )
            if frame.components.count >= maximumDepth {
                if !contents.entries.isEmpty {
                    depthTruncated = true
                }
                continue
            }

            var subdirectories: [DirectoryFrame] = []
            for entry in contents.entries {
                if itemCount == maximumItems {
                    walkTruncated = true
                    break directoryWalk
                }
                itemCount += 1
                let components = frame.components + [entry.name]
                tree.add(components[...], isDirectory: entry.isDirectory)
                if entry.isDirectory {
                    subdirectories.append(DirectoryFrame(
                        path: entry.path,
                        components: components,
                        inheritedRules: contents.ignoreRules
                    ))
                }
            }
            stack.append(contentsOf: subdirectories.reversed())
        }

        tree.sortRecursively()
        return expand(
            tree,
            maxChars: maxChars,
            walkTruncated: walkTruncated,
            depthTruncated: depthTruncated
        )
    }

    private static func expand(
        _ root: DirectoryNode,
        maxChars: Int,
        walkTruncated: Bool,
        depthTruncated: Bool
    ) -> RenderedDirectory {
        let cutoff = walkTruncated
            ? "\nNote: there are more than \(maximumGlobalItems) items in the directory, "
                + "so not all files may be shown.\n"
            : ""
        guard !root.files.isEmpty || !root.directories.isEmpty else {
            return RenderedDirectory(
                body: cutoff,
                entryCount: 0,
                truncated: walkTruncated || depthTruncated
            )
        }

        root.isExpanded = true
        let rootBody = root.renderExpanded()
        if rootBody.utf8.count > maxChars {
            let body = renderTruncatedRoot(root, maxChars: maxChars) + cutoff
            return RenderedDirectory(
                body: body,
                entryCount: renderedEntryCount(in: body),
                truncated: true
            )
        }

        var remaining = maxChars - rootBody.utf8.count
        var queue = root.directories.compactMap { root.children[$0] }
        var queueIndex = 0
        var collapsed = false
        while queueIndex < queue.count {
            let node = queue[queueIndex]
            queueIndex += 1

            let expanded = node.renderExpanded()
            let summaryCost = node.summaryCost()
            if expanded.utf8.count > remaining + summaryCost {
                collapsed = true
                continue
            }
            node.isExpanded = true
            remaining += summaryCost
            remaining -= expanded.utf8.count
            queue.append(contentsOf: node.directories.compactMap { node.children[$0] })
        }

        let body = root.renderExpanded() + cutoff
        return RenderedDirectory(
            body: body,
            entryCount: renderedEntryCount(in: body),
            truncated: walkTruncated || depthTruncated || collapsed
        )
    }

    private static func renderTruncatedRoot(_ root: DirectoryNode, maxChars: Int) -> String {
        var result = ""
        var remaining = maxChars
        for name in root.allNames() {
            var chunk = root.entryLine(name) + "\n"
            if let child = root.children[name] {
                let summary = child.summary()
                if !summary.isEmpty {
                    chunk += String(repeating: "  ", count: root.depth + 2) + summary + "\n"
                }
            }
            guard chunk.utf8.count <= remaining else { break }
            result += chunk
            remaining -= chunk.utf8.count
        }
        return result + rootTruncationNotice
    }

    private static func renderedEntryCount(in body: String) -> Int {
        body.split(whereSeparator: \.isNewline).reduce(into: 0) { count, line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                count += 1
            }
        }
    }

    private static func visibleEntries(
        in directory: String,
        relativeDirectory: String,
        inheritedRules: [GitIgnoreRule],
        allowedRoots: [String],
        maximumCount: Int
    ) throws -> DirectoryContents {
        try SessionFS.enforceRoots(directory, roots: allowedRoots)
        let rules = directoryIgnoreRules(
            in: directory,
            relativeDirectory: relativeDirectory,
            inheritedRules: inheritedRules,
            allowedRoots: allowedRoots
        )
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            throw SessionFSError.io("Unable to list directory: \(directory)")
        }

        var entries: [DirectoryEntry] = []
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            guard let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            ), values.isSymbolicLink != true else {
                continue
            }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { continue }
            do {
                try SessionFS.enforceRoots(url.path, roots: allowedRoots)
            } catch {
                continue
            }
            let relativePath = relativeDirectory.isEmpty
                ? name
                : relativeDirectory + "/" + name
            guard !GitIgnoreRule.isIgnored(path: relativePath, isDir: isDirectory, rules: rules) else {
                continue
            }
            entries.append(DirectoryEntry(
                name: name,
                path: url.path,
                isDirectory: isDirectory
            ))
            if entries.count == maximumCount { break }
        }
        entries.sort { caseInsensitiveOrder($0.name, $1.name) }
        return DirectoryContents(entries: entries, ignoreRules: rules)
    }

    private static func directoryIgnoreRules(
        in directory: String,
        relativeDirectory: String,
        inheritedRules: [GitIgnoreRule],
        allowedRoots: [String]
    ) -> [GitIgnoreRule] {
        var rules = inheritedRules
        let scope = relativeDirectory.isEmpty ? "" : relativeDirectory + "/"
        for filename in [".gitignore", ".ignore", ".rgignore"] {
            let path = (directory as NSString).appendingPathComponent(filename)
            do {
                try SessionFS.enforceRoots(path, roots: allowedRoots)
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber,
                      size.intValue <= maximumIgnoreFileBytes else {
                    continue
                }
                let contents = try SessionFS.readText(at: path)
                let normalized = SessionFS.logicalLines(contents, preservingTrailingEmpty: true)
                    .joined(separator: "\n")
                rules.append(contentsOf: GitIgnoreRule.parse(content: normalized, scope: scope))
            } catch {
                continue
            }
        }
        return rules
    }

    private static func caseInsensitiveOrder(_ left: String, _ right: String) -> Bool {
        let foldedLeft = left.lowercased()
        let foldedRight = right.lowercased()
        if foldedLeft == foldedRight {
            return left < right
        }
        return foldedLeft < foldedRight
    }
}
