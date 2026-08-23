import Foundation

/// Git identity captured from repository references, never from commit objects.
///
/// An OID is only the value advertised by HEAD. Callers performing checkout or
/// restore must independently verify the object exists before reporting success.
public struct WorkspaceSessionGitMetadata: Sendable, Equatable, Codable {
    public let gitRootDirectory: String?
    public let gitRemotes: [String]
    public let headCommit: String?
    public let headBranch: String?

    public init(
        gitRootDirectory: String? = nil,
        gitRemotes: [String] = [],
        headCommit: String? = nil,
        headBranch: String? = nil
    ) {
        self.gitRootDirectory = gitRootDirectory
        self.gitRemotes = gitRemotes
        self.headCommit = headCommit
        self.headBranch = headBranch
    }

    public static func resolve(at workingDirectory: URL) -> WorkspaceSessionGitMetadata {
        SessionGitReferenceResolver.resolve(at: workingDirectory)
    }

    public static func currentCommit(at workingDirectory: URL) -> String? {
        resolve(at: workingDirectory).headCommit
    }

    private enum CodingKeys: String, CodingKey {
        case gitRootDirectory = "git_root_dir"
        case gitRemotes = "git_remotes"
        case headCommit = "head_commit"
        case headBranch = "head_branch"
    }
}

private enum SessionGitReferenceResolver {
    private static let maximumReferenceBytes = 16 * 1024
    private static let maximumConfigurationBytes = 1024 * 1024
    private static let maximumPackedReferenceBytes = 16 * 1024 * 1024
    private static let maximumSymbolicReferenceDepth = 16

    private struct Repository {
        let worktreeRoot: URL
        let gitDirectory: URL
        let commonDirectory: URL
    }

    private enum EntryKind: Equatable {
        case missing
        case regular
        case directory
        case invalid
    }

    private enum TextFile {
        case missing
        case contents(String)
        case invalid
    }

    private enum ReferenceValue {
        case missing
        case objectID(String)
        case symbolic(String)
        case invalid
    }

    static func resolve(at workingDirectory: URL) -> WorkspaceSessionGitMetadata {
        guard let repository = discover(from: workingDirectory) else {
            return WorkspaceSessionGitMetadata()
        }

        let remotes = remoteURLs(in: repository.commonDirectory)
        guard case let .contents(headText) = readTextFile(
            repository.gitDirectory.appendingPathComponent("HEAD"),
            maximumBytes: maximumReferenceBytes
        ), let head = singleRecord(headText) else {
            return WorkspaceSessionGitMetadata(
                gitRootDirectory: repository.worktreeRoot.path,
                gitRemotes: remotes
            )
        }

        if head.hasPrefix("ref: ") {
            let reference = String(head.dropFirst(5))
            guard isSafeReferenceName(reference),
                  let objectID = resolveReference(reference, in: repository) else {
                return WorkspaceSessionGitMetadata(
                    gitRootDirectory: repository.worktreeRoot.path,
                    gitRemotes: remotes
                )
            }

            let branch: String?
            if reference.hasPrefix("refs/heads/") {
                branch = String(reference.dropFirst("refs/heads/".count))
            } else {
                branch = reference.split(separator: "/").last.map(String.init)
            }
            return WorkspaceSessionGitMetadata(
                gitRootDirectory: repository.worktreeRoot.path,
                gitRemotes: remotes,
                headCommit: objectID,
                headBranch: branch
            )
        }

        guard let objectID = validatedObjectID(head) else {
            return WorkspaceSessionGitMetadata(
                gitRootDirectory: repository.worktreeRoot.path,
                gitRemotes: remotes
            )
        }
        return WorkspaceSessionGitMetadata(
            gitRootDirectory: repository.worktreeRoot.path,
            gitRemotes: remotes,
            headCommit: objectID
        )
    }

    private static func discover(from workingDirectory: URL) -> Repository? {
        var current = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if entryKind(at: current) == .regular {
            current.deleteLastPathComponent()
        }

        while true {
            let marker = current.appendingPathComponent(".git")
            switch entryKind(at: marker) {
            case .directory:
                return repository(worktreeRoot: current, gitDirectory: marker)
            case .regular:
                guard case let .contents(pointerText) = readTextFile(
                    marker,
                    maximumBytes: maximumReferenceBytes
                ), let pointer = singleRecord(pointerText),
                    pointer.hasPrefix("gitdir:") else {
                    return nil
                }
                let value = pointer.dropFirst("gitdir:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, !value.contains("\0") else { return nil }
                let gitDirectory: URL
                if (value as NSString).isAbsolutePath {
                    gitDirectory = URL(fileURLWithPath: value, isDirectory: true)
                } else {
                    gitDirectory = current.appendingPathComponent(value, isDirectory: true)
                }
                return repository(worktreeRoot: current, gitDirectory: gitDirectory)
            case .invalid:
                // A broken nested repository must not be mistaken for its parent.
                return nil
            case .missing:
                break
            }

            let bareHead = current.appendingPathComponent("HEAD")
            let bareObjects = current.appendingPathComponent("objects")
            if entryKind(at: bareHead) != .missing,
               entryKind(at: bareObjects) == .directory {
                // Session metadata requires a worktree even though status can
                // legitimately inspect bare repositories.
                return nil
            }

            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            current = parent
        }
    }

    private static func repository(worktreeRoot: URL, gitDirectory: URL) -> Repository? {
        let canonicalGitDirectory = gitDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard entryKind(at: canonicalGitDirectory) == .directory else { return nil }

        let commonPointer = canonicalGitDirectory.appendingPathComponent("commondir")
        let commonDirectory: URL
        switch readTextFile(commonPointer, maximumBytes: maximumReferenceBytes) {
        case .missing:
            commonDirectory = canonicalGitDirectory
        case let .contents(text):
            guard let pointer = singleRecord(text), !pointer.isEmpty,
                  !pointer.contains("\0") else { return nil }
            if (pointer as NSString).isAbsolutePath {
                commonDirectory = URL(fileURLWithPath: pointer, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath()
            } else {
                commonDirectory = canonicalGitDirectory
                    .appendingPathComponent(pointer, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath()
            }
        case .invalid:
            return nil
        }

        guard entryKind(at: commonDirectory) == .directory,
              entryKind(at: canonicalGitDirectory.appendingPathComponent("HEAD")) == .regular
        else { return nil }

        return Repository(
            worktreeRoot: worktreeRoot,
            gitDirectory: canonicalGitDirectory,
            commonDirectory: commonDirectory
        )
    }

    private static func resolveReference(_ name: String, in repository: Repository) -> String? {
        var reference = name
        var visited = Set<String>()

        for _ in 0..<maximumSymbolicReferenceDepth {
            guard isSafeReferenceName(reference), visited.insert(reference).inserted else {
                return nil
            }

            let directories = repository.gitDirectory.path == repository.commonDirectory.path
                ? [repository.gitDirectory]
                : [repository.gitDirectory, repository.commonDirectory]
            var value: ReferenceValue = .missing
            for directory in directories {
                value = readLooseReference(reference, in: directory)
                if case .missing = value {
                    continue
                }
                break
            }

            if case .missing = value {
                value = readPackedReference(reference, in: repository.commonDirectory)
            }

            switch value {
            case let .objectID(objectID):
                return objectID
            case let .symbolic(next):
                reference = next
            case .missing, .invalid:
                return nil
            }
        }
        return nil
    }

    private static func readLooseReference(_ name: String, in directory: URL) -> ReferenceValue {
        guard let candidate = containedReference(named: name, in: directory) else {
            return .invalid
        }
        switch readTextFile(candidate, maximumBytes: maximumReferenceBytes) {
        case .missing:
            return .missing
        case .invalid:
            return .invalid
        case let .contents(text):
            guard let line = singleRecord(text) else { return .invalid }
            if line.hasPrefix("ref: ") {
                let reference = String(line.dropFirst(5))
                return isSafeReferenceName(reference) ? .symbolic(reference) : .invalid
            }
            guard let objectID = validatedObjectID(line) else { return .invalid }
            return .objectID(objectID)
        }
    }

    private static func readPackedReference(_ name: String, in directory: URL) -> ReferenceValue {
        switch readTextFile(
            directory.appendingPathComponent("packed-refs"),
            maximumBytes: maximumPackedReferenceBytes
        ) {
        case .missing:
            return .missing
        case .invalid:
            return .invalid
        case let .contents(text):
            for line in text.split(whereSeparator: { $0.isNewline }) {
                guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count == 2 else { continue }
                guard fields[1] == name else { continue }
                guard let objectID = validatedObjectID(String(fields[0])) else {
                    return .invalid
                }
                return .objectID(objectID)
            }
            return .missing
        }
    }

    private static func containedReference(named name: String, in directory: URL) -> URL? {
        guard isSafeReferenceName(name) else { return nil }
        let candidate = directory.appendingPathComponent(name).standardizedFileURL
        let canonicalParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard isContained(canonicalParent, within: directory) else { return nil }
        return candidate
    }

    private static func isContained(_ candidate: URL, within root: URL) -> Bool {
        #if os(Windows)
        let candidatePath = candidate.standardizedFileURL.path.lowercased()
        let rootPath = root.standardizedFileURL.path.lowercased()
        #else
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        #endif
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isSafeReferenceName(_ value: String) -> Bool {
        guard value.hasPrefix("refs/"), !value.hasSuffix("/"), !value.contains("//"),
              !value.contains("\\"), !value.contains(".."), !value.contains("@{"),
              !value.contains("\0"), value.utf8.allSatisfy({ byte in
                  byte > 0x20 && byte != 0x7f
                      && ![0x7e, 0x5e, 0x3a, 0x3f, 0x2a, 0x5b].contains(byte)
              }),
              value.split(separator: "/").allSatisfy({ component in
                  component != "." && !component.hasPrefix(".")
                      && !component.hasSuffix(".") && !component.hasSuffix(".lock")
              }) else {
            return false
        }
        return true
    }

    private static func validatedObjectID(_ value: String) -> String? {
        guard value.utf8.count == 40 || value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x61...0x66).contains(byte)
                      || (0x41...0x46).contains(byte)
              }) else {
            return nil
        }
        return value.lowercased()
    }

    private static func singleRecord(_ value: String) -> String? {
        guard !value.contains("\0") else { return nil }
        let records = value.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isNewline }
        )
        guard records.count == 1 || records.count == 2 && records[1].isEmpty,
              let first = records.first, !first.isEmpty else {
            return nil
        }
        return String(first)
    }

    private static func remoteURLs(in directory: URL) -> [String] {
        guard case let .contents(configuration) = readTextFile(
            directory.appendingPathComponent("config"),
            maximumBytes: maximumConfigurationBytes
        ) else { return [] }

        var currentRemote: String?
        var urls: [String: String] = [:]
        for rawLine in configuration.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else {
                continue
            }
            if line.hasPrefix("[") {
                currentRemote = remoteName(in: line)
                continue
            }
            guard let remote = currentRemote,
                  let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard key.caseInsensitiveCompare("url") == .orderedSame,
                  urls[remote] == nil else { continue }
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            urls[remote] = strippedCredentials(from: value)
        }

        return Array(Set(urls.values)).sorted()
    }

    private static func remoteName(in line: String) -> String? {
        guard line.hasSuffix("]") else { return nil }
        let section = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard section.lowercased().hasPrefix("remote "),
              let quote = section.firstIndex(of: "\""), section.hasSuffix("\"") else {
            return nil
        }
        let name = section[section.index(after: quote)..<section.index(before: section.endIndex)]
        return name.isEmpty ? nil : String(name)
    }

    private static func strippedCredentials(from value: String) -> String {
        guard var components = URLComponents(string: value),
              components.scheme != nil, components.host != nil else {
            return value
        }
        components.user = nil
        components.password = nil
        return components.string ?? value
    }

    private static func readTextFile(_ url: URL, maximumBytes: Int) -> TextFile {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return isMissing(error) ? .missing : .invalid
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0, size.int64Value <= Int64(maximumBytes) else {
            return .invalid
        }
        guard let data = try? Data(contentsOf: url), data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8) else {
            return .invalid
        }
        return .contents(text)
    }

    private static func entryKind(at url: URL) -> EntryKind {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular:
                return .regular
            case .typeDirectory:
                return .directory
            default:
                return .invalid
            }
        } catch {
            return isMissing(error) ? .missing : .invalid
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSCocoaErrorDomain && (
            failure.code == NSFileReadNoSuchFileError
                || failure.code == NSFileNoSuchFileError
        )
    }
}
