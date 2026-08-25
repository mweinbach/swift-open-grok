import Foundation
import OpenGrokToolRegistry
import OpenGrokWorkspace

/// Trusted, session-scoped opt-in; absence preserves upstream's read default.
public struct GitIgnoreAccessPolicy: Sendable {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    static func enforce(path: String, resources: ToolResources, operation: String) throws {
        guard resources.extras.get(Self.self)?.enabled == true else { return }

        let standardized = (path as NSString).standardizingPath
        let canonical = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        let roots = (resources.allowedRoots.isEmpty ? [resources.cwd] : resources.allowedRoots)
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            .filter { canonical == $0 || canonical.hasPrefix($0 + "/") }
            .sorted { $0.count > $1.count }
        guard let root = roots.first else {
            throw SessionFSError.outsideWorkspace(standardized)
        }

        var candidates = [canonical]
        if standardized != canonical,
           standardized == root || standardized.hasPrefix(root + "/") {
            candidates.append(standardized)
        }
        for candidate in candidates where try isIgnored(path: candidate, root: root) {
            throw SessionFSError.invalidInput(
                "Error: \(standardized) is ignored by .gitignore and cannot be \(operation)."
            )
        }
    }

    private static func isIgnored(path: String, root: String) throws -> Bool {
        guard path != root else { return false }
        let relative = String(path.dropFirst(root.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 256 else {
            throw SessionFSError.invalidInput("Path exceeds the Git ignore policy depth limit")
        }

        var rules: [GitIgnoreRule] = []
        var directory = root
        for index in components.indices {
            let scope = index == 0 ? "" : components[..<index].joined(separator: "/") + "/"
            try appendRules(in: directory, scope: scope, to: &rules)
            let traversed = components[...index].joined(separator: "/")
            let isDirectory = index < components.count - 1
            if GitIgnoreRule.isIgnored(path: traversed, isDir: isDirectory, rules: rules) {
                return true
            }
            if isDirectory {
                directory = (directory as NSString).appendingPathComponent(String(components[index]))
            }
        }
        return false
    }

    private static func appendRules(
        in directory: String,
        scope: String,
        to rules: inout [GitIgnoreRule]
    ) throws {
        let manager = FileManager.default
        for filename in [".gitignore", ".ignore", ".rgignore"] {
            let path = (directory as NSString).appendingPathComponent(filename)
            guard manager.fileExists(atPath: path) else { continue }
            do {
                let attributes = try manager.attributesOfItem(atPath: path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber,
                      size.uint64Value <= 1_048_576 else {
                    throw SessionFSError.invalidInput("Unsafe or oversized Git ignore policy")
                }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 1_048_576,
                      let contents = String(data: data, encoding: .utf8) else {
                    throw SessionFSError.invalidInput("Invalid Git ignore policy encoding")
                }
                let normalized = contents.split(
                    omittingEmptySubsequences: false,
                    whereSeparator: \.isNewline
                ).joined(separator: "\n")
                rules.append(contentsOf: GitIgnoreRule.parse(content: normalized, scope: scope))
                guard rules.count <= 16_384 else {
                    throw SessionFSError.invalidInput("Git ignore policy exceeds its rule limit")
                }
            } catch let error as SessionFSError {
                throw error
            } catch {
                throw SessionFSError.invalidInput("Unable to inspect Git ignore policy")
            }
        }
    }
}
