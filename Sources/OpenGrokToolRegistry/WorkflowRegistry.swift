import Foundation

public enum WorkflowSourceScope: String, Codable, Sendable, Hashable {
    case registered
    case project
    case user
}

public struct WorkflowSource: Codable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var script: String
    public var scope: WorkflowSourceScope

    public init(name: String, path: String, script: String, scope: WorkflowSourceScope) {
        self.name = name
        self.path = path
        self.script = script
        self.scope = scope
    }
}

public enum WorkflowRegistryError: Error, Sendable, Hashable, CustomStringConvertible {
    case selectorMustBeExclusive
    case duplicateName(String)
    case sourceTooLarge(String)
    case invalidSource(String)
    case unreadableSource(String)
    case filenameMismatch(filename: String, name: String)

    public var description: String {
        switch self {
        case .selectorMustBeExclusive:
            return "workflow selection requires exactly one of name, path, or script"
        case .duplicateName(let name):
            return "duplicate workflow name: \(name)"
        case .sourceTooLarge(let path):
            return "workflow source exceeds the 1 MiB limit: \(path)"
        case .invalidSource(let path):
            return "invalid workflow source: \(path)"
        case .unreadableSource(let path):
            return "unable to read workflow source: \(path)"
        case .filenameMismatch(let filename, let name):
            return "workflow filename \(filename) does not match metadata name \(name)"
        }
    }
}

public struct WorkflowRegistryIndex: Sendable {
    public static let sourceLimitBytes = 1_048_576

    public var sources: [WorkflowSource]

    public init(registered: [WorkflowSource] = []) throws {
        self.sources = []
        try add(contentsOf: registered)
    }

    public mutating func add(_ source: WorkflowSource) throws {
        guard !source.name.isEmpty else {
            throw WorkflowRegistryError.invalidSource(source.path)
        }
        guard !sources.contains(where: { $0.name == source.name }) else {
            throw WorkflowRegistryError.duplicateName(source.name)
        }
        sources.append(source)
        sources.sort { ($0.name, $0.scope.rawValue, $0.path) < ($1.name, $1.scope.rawValue, $1.path) }
    }

    public mutating func add(contentsOf newSources: [WorkflowSource]) throws {
        for source in newSources {
            try add(source)
        }
    }

    public static func discover(
        projectRoot: URL?,
        userHome: URL?,
        opengrokHome: URL?,
        registered: [WorkflowSource] = []
    ) throws -> WorkflowRegistryIndex {
        var index = try WorkflowRegistryIndex(registered: registered)
        var directories: [(URL, WorkflowSourceScope)] = []
        if let projectRoot {
            directories.append((projectRoot.appendingPathComponent(".opengrok/workflows"), .project))
        }
        if let userHome {
            directories.append((userHome.appendingPathComponent(".opengrok/workflows"), .user))
        }
        if let opengrokHome {
            directories.append((opengrokHome.appendingPathComponent("workflows"), .user))
        }

        var visited = Set<String>()
        for (directory, scope) in directories {
            let normalizedDirectory = directory.standardizedFileURL.path
            guard visited.insert(normalizedDirectory).inserted else { continue }
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw WorkflowRegistryError.unreadableSource(directory.path)
            }
            for filename in names.sorted() where filename.hasSuffix(".rhai") {
                let path = directory.appendingPathComponent(filename)
                let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= Int64(sourceLimitBytes) else {
                    throw WorkflowRegistryError.sourceTooLarge(path.path)
                }
                guard let script = try? String(contentsOf: path, encoding: .utf8) else {
                    throw WorkflowRegistryError.unreadableSource(path.path)
                }
                guard let name = extractWorkflowName(from: script) else {
                    throw WorkflowRegistryError.invalidSource(path.path)
                }
                guard URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent == name else {
                    throw WorkflowRegistryError.filenameMismatch(filename: filename, name: name)
                }
                try index.add(WorkflowSource(name: name, path: path.standardizedFileURL.path, script: script, scope: scope))
            }
        }
        return index
    }

    public func resolve(name: String? = nil, path: String? = nil, script: String? = nil) throws -> WorkflowSource {
        let selected = [name != nil, path != nil, script != nil].filter { $0 }.count
        guard selected == 1 else { throw WorkflowRegistryError.selectorMustBeExclusive }
        if let name {
            guard let source = sources.first(where: { $0.name == name }) else {
                throw WorkflowRegistryError.invalidSource(name)
            }
            return source
        }
        if let path {
            guard let source = sources.first(where: { $0.path == URL(fileURLWithPath: path).standardizedFileURL.path }) else {
                throw WorkflowRegistryError.invalidSource(path)
            }
            return source
        }
        guard let script else { throw WorkflowRegistryError.selectorMustBeExclusive }
        guard let source = sources.first(where: { $0.script == script }) else {
            throw WorkflowRegistryError.invalidSource("<inline>")
        }
        return source
    }

}

private func extractWorkflowName(from script: String) -> String? {
    guard let range = script.range(of: "name") else { return nil }
    let suffix = script[range.upperBound...]
    guard let quoteStart = suffix.firstIndex(of: "\"") else { return nil }
    let value = suffix[suffix.index(after: quoteStart)...]
    guard let quoteEnd = value.firstIndex(of: "\"") else { return nil }
    return String(value[..<quoteEnd])
}
