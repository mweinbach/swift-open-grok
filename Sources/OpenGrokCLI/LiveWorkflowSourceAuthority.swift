import Foundation
import OpenGrokSessionPersistence

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LiveWorkflowSourceAuthorityError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPath(String, reason: String)
    case unavailable(String, reason: String)
    case symbolicLink(String)
    case nonRegularFile(String)
    case untrustedProject(String)
    case outsideAllowedRoots(String)
    case sourceTooLarge(String, limit: Int)
    case invalidEncoding(String)

    var description: String {
        switch self {
        case .invalidPath(let path, let reason):
            return "workflow path is not trusted: \(path) (\(reason))"
        case .unavailable(let path, let reason):
            return "failed to read \(path): \(reason)"
        case .symbolicLink(let path):
            return "workflow path is not trusted: \(path) (symbolic links are not allowed)"
        case .nonRegularFile(let path):
            return "workflow path is not trusted: \(path) (expected a non-symlink regular file)"
        case .untrustedProject(let path):
            return "workflow path is not trusted: \(path) (project workflows require folder trust)"
        case .outsideAllowedRoots(let path):
            return "workflow path is not trusted: \(path) "
                + "(outside the project, owner workflows, and this session's workflow runs)"
        case .sourceTooLarge(let path, let limit):
            return "workflow source exceeds \(limit) bytes: \(path)"
        case .invalidEncoding(let path):
            return "failed to read \(path): workflow source is not valid UTF-8"
        }
    }
}

enum LiveWorkflowSourceAuthority {
    static let maximumSourceBytes = 1_048_576

    private struct AuthorizedRoot {
        let directory: URL
        let kind: Kind

        enum Kind {
            case owner
            case session
            case project
        }
    }

    static func read(
        candidate rawPath: String,
        workingDirectory: URL,
        openGrokHome: URL,
        sessionID: String,
        projectTrusted: Bool
    ) throws -> String {
        try validateRawPath(rawPath)
        guard workingDirectory.isFileURL, openGrokHome.isFileURL else {
            throw LiveWorkflowSourceAuthorityError.invalidPath(
                rawPath,
                reason: "workflow authority roots must be local filesystem paths"
            )
        }

        let canonicalWorkingDirectory = try existingDirectory(workingDirectory)
        if let homeAttributes = try? FileManager.default.attributesOfItem(atPath: openGrokHome.path),
           homeAttributes[.type] as? FileAttributeType != .typeDirectory {
            throw LiveWorkflowSourceAuthorityError.unavailable(
                openGrokHome.path,
                reason: "workflow owner home is not a directory"
            )
        }
        let canonicalHome = openGrokHome.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalSessionDirectory: URL
        do {
            canonicalSessionDirectory = try SessionDocumentStore(grokHome: canonicalHome)
                .sessionDirectory(sessionID: sessionID, cwd: canonicalWorkingDirectory.path)
        } catch {
            throw LiveWorkflowSourceAuthorityError.invalidPath(
                sessionID,
                reason: "invalid workflow session identity: \(error)"
            )
        }

        let candidate = resolve(rawPath, relativeTo: workingDirectory)
        let candidateAttributes = try attributes(at: candidate)
        try rejectSymbolicLink(at: candidate, attributes: candidateAttributes)
        guard candidateAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw LiveWorkflowSourceAuthorityError.nonRegularFile(candidate.path)
        }
        try rejectOversized(candidateAttributes, path: candidate.path)

        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let project = AuthorizedRoot(
            directory: projectRoot(for: canonicalWorkingDirectory),
            kind: .project
        )
        var trustedRoots: [AuthorizedRoot] = []
        if let ownerRoot = optionalDirectory(
            canonicalHome.appendingPathComponent("workflows", isDirectory: true)
        ) {
            trustedRoots.append(AuthorizedRoot(directory: ownerRoot, kind: .owner))
        }

        let legacySessionDirectory = canonicalHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        for directory in [canonicalSessionDirectory, legacySessionDirectory] {
            if let runRoot = optionalDirectory(
                directory.appendingPathComponent("workflows", isDirectory: true)
            ) {
                trustedRoots.append(AuthorizedRoot(directory: runRoot, kind: .session))
            }
        }

        let authorized: AuthorizedRoot
        if let trusted = trustedRoots.first(where: {
            contains(canonicalCandidate, inside: $0.directory)
        }) {
            authorized = trusted
        } else if contains(canonicalCandidate, inside: project.directory) {
            guard projectTrusted else {
                throw LiveWorkflowSourceAuthorityError.untrustedProject(candidate.path)
            }
            authorized = project
        } else {
            throw LiveWorkflowSourceAuthorityError.outsideAllowedRoots(candidate.path)
        }

        try rejectSymbolicComponents(
            between: candidate,
            and: authorized.directory
        )
        let source = try readBoundedFile(
            canonicalCandidate,
            authorizedRoot: authorized.directory
        )
        guard let script = String(data: source, encoding: .utf8) else {
            throw LiveWorkflowSourceAuthorityError.invalidEncoding(candidate.path)
        }
        return script
    }

    private static func validateRawPath(_ path: String) throws {
        guard !path.isEmpty else {
            throw LiveWorkflowSourceAuthorityError.invalidPath(path, reason: "empty workflow path")
        }
        guard !path.contains("\0") else {
            throw LiveWorkflowSourceAuthorityError.invalidPath(path, reason: "NUL byte in workflow path")
        }
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !components.contains("..") else {
            throw LiveWorkflowSourceAuthorityError.invalidPath(
                path,
                reason: "parent traversal components are not allowed"
            )
        }
    }

    private static func resolve(_ path: String, relativeTo directory: URL) -> URL {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(fileURLWithPath: path, relativeTo: directory)
            .absoluteURL.standardizedFileURL
    }

    private static func existingDirectory(_ directory: URL) throws -> URL {
        let values = try attributes(at: directory)
        guard values[.type] as? FileAttributeType == .typeDirectory else {
            throw LiveWorkflowSourceAuthorityError.unavailable(
                directory.path,
                reason: "workflow authority root is not a directory"
            )
        }
        return directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func optionalDirectory(_ directory: URL) -> URL? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: directory.path),
              values[.type] as? FileAttributeType == .typeDirectory,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) == nil
        else {
            return nil
        }
        return directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func projectRoot(for workingDirectory: URL) -> URL {
        var cursor = workingDirectory
        var visited = Set<String>()
        while visited.insert(cursor.standardizedFileURL.resolvingSymlinksInPath().path).inserted {
            let gitMarker = cursor.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitMarker.path) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path.count < cursor.path.count else { return workingDirectory }
            cursor = parent.standardizedFileURL
        }
        return workingDirectory
    }

    private static func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw LiveWorkflowSourceAuthorityError.unavailable(
                url.path,
                reason: error.localizedDescription
            )
        }
    }

    private static func rejectSymbolicLink(
        at path: URL,
        attributes: [FileAttributeKey: Any]
    ) throws {
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil
            || (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw LiveWorkflowSourceAuthorityError.symbolicLink(path.path)
        }
    }

    private static func rejectOversized(
        _ attributes: [FileAttributeKey: Any],
        path: String
    ) throws {
        guard let size = attributes[.size] as? NSNumber else {
            throw LiveWorkflowSourceAuthorityError.unavailable(path, reason: "file size is unavailable")
        }
        guard size.uint64Value <= UInt64(maximumSourceBytes) else {
            throw LiveWorkflowSourceAuthorityError.sourceTooLarge(path, limit: maximumSourceBytes)
        }
    }

    private static func rejectSymbolicComponents(
        between candidate: URL,
        and authorizedRoot: URL
    ) throws {
        var cursor = candidate.standardizedFileURL
        var visited = Set<String>()
        while visited.insert(cursor.standardizedFileURL.resolvingSymlinksInPath().path).inserted {
            let values = try attributes(at: cursor)
            try rejectSymbolicLink(at: cursor, attributes: values)
            let canonical = cursor.standardizedFileURL.resolvingSymlinksInPath()
            if pathsMatch(canonical, authorizedRoot) {
                return
            }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path.count < cursor.path.count else {
                throw LiveWorkflowSourceAuthorityError.outsideAllowedRoots(candidate.path)
            }
            cursor = parent.standardizedFileURL
        }
        throw LiveWorkflowSourceAuthorityError.outsideAllowedRoots(candidate.path)
    }

    private static func contains(_ candidate: URL, inside root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { root, candidate in
            pathsMatch(root, candidate)
        }
    }

    private static func pathsMatch(_ left: URL, _ right: URL) -> Bool {
        pathsMatch(left.path, right.path)
    }

    private static func pathsMatch(_ left: String, _ right: String) -> Bool {
        #if os(Windows)
        return left.caseInsensitiveCompare(right) == .orderedSame
        #else
        return left == right
        #endif
    }

    private static func readBoundedFile(
        _ path: URL,
        authorizedRoot: URL
    ) throws -> Data {
        #if os(Windows)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: path)
        } catch {
            throw LiveWorkflowSourceAuthorityError.unavailable(path.path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        let openedAttributes = try attributes(at: path)
        try rejectSymbolicLink(at: path, attributes: openedAttributes)
        guard openedAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw LiveWorkflowSourceAuthorityError.nonRegularFile(path.path)
        }
        try rejectOversized(openedAttributes, path: path.path)
        #else
        let descriptor = try openDescriptorNoFollow(path, authorizedRoot: authorizedRoot)
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            close(descriptor)
            throw LiveWorkflowSourceAuthorityError.unavailable(
                path.path,
                reason: String(cString: strerror(errno))
            )
        }
        guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(descriptor)
            throw LiveWorkflowSourceAuthorityError.nonRegularFile(path.path)
        }
        guard information.st_size >= 0,
              UInt64(information.st_size) <= UInt64(maximumSourceBytes)
        else {
            close(descriptor)
            throw LiveWorkflowSourceAuthorityError.sourceTooLarge(path.path, limit: maximumSourceBytes)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        #endif

        var contents = Data()
        contents.reserveCapacity(min(maximumSourceBytes, 64 * 1024))
        do {
            while contents.count <= maximumSourceBytes {
                let remaining = maximumSourceBytes + 1 - contents.count
                guard let chunk = try handle.read(upToCount: min(64 * 1024, remaining)),
                      !chunk.isEmpty
                else {
                    return contents
                }
                contents.append(chunk)
                if contents.count > maximumSourceBytes {
                    throw LiveWorkflowSourceAuthorityError.sourceTooLarge(
                        path.path,
                        limit: maximumSourceBytes
                    )
                }
            }
        } catch let error as LiveWorkflowSourceAuthorityError {
            throw error
        } catch {
            throw LiveWorkflowSourceAuthorityError.unavailable(path.path, reason: error.localizedDescription)
        }
        throw LiveWorkflowSourceAuthorityError.sourceTooLarge(path.path, limit: maximumSourceBytes)
    }

    #if !os(Windows)
    private static func openDescriptorNoFollow(
        _ candidate: URL,
        authorizedRoot: URL
    ) throws -> Int32 {
        let rootComponents = authorizedRoot.pathComponents
        let components = Array(candidate.pathComponents.dropFirst(rootComponents.count))
        guard let filename = components.last, !filename.isEmpty else {
            throw LiveWorkflowSourceAuthorityError.nonRegularFile(candidate.path)
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var directoryDescriptor = authorizedRoot.path.withCString { open($0, directoryFlags) }
        guard directoryDescriptor >= 0 else {
            throw LiveWorkflowSourceAuthorityError.unavailable(
                authorizedRoot.path,
                reason: String(cString: strerror(errno))
            )
        }
        defer { close(directoryDescriptor) }

        for component in components.dropLast() {
            let childDescriptor = component.withCString {
                openat(directoryDescriptor, $0, directoryFlags)
            }
            guard childDescriptor >= 0 else {
                throw LiveWorkflowSourceAuthorityError.symbolicLink(
                    candidate.deletingLastPathComponent().path
                )
            }
            close(directoryDescriptor)
            directoryDescriptor = childDescriptor
        }

        let descriptor = filename.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let reason = errno
            if reason == ELOOP {
                throw LiveWorkflowSourceAuthorityError.symbolicLink(candidate.path)
            }
            throw LiveWorkflowSourceAuthorityError.unavailable(
                candidate.path,
                reason: String(cString: strerror(reason))
            )
        }
        return descriptor
    }
    #endif
}
