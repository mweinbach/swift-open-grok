import Foundation
import OpenGrokFileUtils

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum GlobalHookSourceKind: Sendable, Equatable {
    case hookDirectory
    case registryFile
    case configuredSource
}

public struct GlobalHookSource: Sendable, Equatable {
    public let path: URL
    public let kind: GlobalHookSourceKind
    public let isDirectory: Bool

    public init(path: URL, kind: GlobalHookSourceKind, isDirectory: Bool) {
        self.path = path
        self.kind = kind
        self.isDirectory = isDirectory
    }

    public var isDiscoverySource: Bool {
        kind != .registryFile
    }

    fileprivate var hookSource: HookSource? {
        guard isDiscoverySource else { return nil }
        return isDirectory ? .directory(path) : .settingsFile(path)
    }
}

public struct ResolvedGlobalHookSources: Sendable {
    public let sources: [GlobalHookSource]
    public let errors: [HookError]

    public init(sources: [GlobalHookSource], errors: [HookError] = []) {
        self.sources = sources
        self.errors = errors
    }

    public var discoverySources: [HookSource] {
        sources.compactMap(\.hookSource)
    }
}

public enum GlobalHookSourceDiscovery {
    public static let maximumRegistryBytes = 256 * 1024
    public static let maximumHookBytes = 1024 * 1024
    public static let maximumConfiguredSources = 256
    public static let maximumHookFilesPerSource = 1024

    public static func validateOwnerDirectory(at path: URL) throws {
        try GlobalHookSourceSecurity.validateOwnerDirectory(path)
    }

    public static func readOwnerDocument(
        at path: URL,
        maximumBytes: Int = maximumHookBytes
    ) throws -> String {
        try GlobalHookSourceSecurity.readDocument(at: path, maximumBytes: maximumBytes)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ResolvedGlobalHookSources {
        let home = openGrokHome(environment: environment).standardizedFileURL
        let hooksDirectory = home.appendingPathComponent("hooks", isDirectory: true)
        let registry = home.appendingPathComponent("hooks-paths")
        let fixedSources = [
            GlobalHookSource(path: hooksDirectory, kind: .hookDirectory, isDirectory: true),
            GlobalHookSource(path: registry, kind: .registryFile, isDirectory: false),
        ]

        do {
            try GlobalHookSourceSecurity.validateOwnerDirectory(home)
        } catch let error as GlobalHookSourceSecurityError {
            if case .missing = error {
                return ResolvedGlobalHookSources(sources: fixedSources)
            }
            return ResolvedGlobalHookSources(
                sources: [],
                errors: [.readFile(path: home, detail: error.description)]
            )
        } catch {
            return ResolvedGlobalHookSources(
                sources: [],
                errors: [.readFile(path: home, detail: String(describing: error))]
            )
        }

        var sources = fixedSources
        var errors: [HookError] = []
        let registryContents: String
        do {
            registryContents = try GlobalHookSourceSecurity.readDocument(
                at: registry,
                maximumBytes: maximumRegistryBytes
            )
        } catch let error as GlobalHookSourceSecurityError {
            if case .missing = error {
                return ResolvedGlobalHookSources(sources: sources)
            }
            errors.append(.readFile(path: registry, detail: error.description))
            return ResolvedGlobalHookSources(sources: sources, errors: errors)
        } catch {
            errors.append(.readFile(path: registry, detail: String(describing: error)))
            return ResolvedGlobalHookSources(sources: sources, errors: errors)
        }

        var seen = Set(sources.map { $0.path.standardizedFileURL.path })
        var configuredCount = 0
        for rawLine in registryContents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, (line as NSString).isAbsolutePath else { continue }
            if line.contains("\0") || line.split(separator: "/").contains("..") {
                errors.append(.readFile(path: registry, detail: "hook source path contains an unsafe component"))
                continue
            }

            let path = URL(fileURLWithPath: line).standardizedFileURL
            guard seen.insert(path.path).inserted else { continue }
            let sourceComponents = path.pathComponents
            let homeComponents = home.pathComponents
            if sourceComponents.count <= homeComponents.count,
               Array(homeComponents.prefix(sourceComponents.count)) == sourceComponents {
                errors.append(.readFile(
                    path: path,
                    detail: "configured hook source cannot contain OPENGROK_HOME"
                ))
                continue
            }
            guard configuredCount < maximumConfiguredSources else {
                errors.append(.readFile(
                    path: registry,
                    detail: "hooks-paths exceeds the \(maximumConfiguredSources)-source limit"
                ))
                break
            }
            configuredCount += 1

            do {
                let isDirectory = try GlobalHookSourceSecurity.isOwnerDirectoryOrFile(path)
                sources.append(GlobalHookSource(
                    path: path,
                    kind: .configuredSource,
                    isDirectory: isDirectory
                ))
            } catch {
                errors.append(.readFile(path: path, detail: String(describing: error)))
            }
        }

        return ResolvedGlobalHookSources(sources: sources, errors: errors)
    }
}

enum GlobalHookSourceSecurityError: Error, Sendable, CustomStringConvertible {
    case missing(URL)
    case invalidPath(URL)
    case symbolicLink(URL)
    case invalidType(URL)
    case wrongOwner(URL)
    case hardLinked(URL, UInt64)
    case oversized(URL, Int)
    case invalidEncoding(URL)
    case io(URL, String)

    var description: String {
        switch self {
        case .missing(let path):
            return "hook source does not exist: \(path.path)"
        case .invalidPath(let path):
            return "hook source must be an absolute local path without traversal: \(path.path)"
        case .symbolicLink(let path):
            return "hook source contains a symbolic-link component: \(path.path)"
        case .invalidType(let path):
            return "hook source is not a real directory or regular file: \(path.path)"
        case .wrongOwner(let path):
            return "hook source is not owned by the current user: \(path.path)"
        case .hardLinked(let path, let count):
            return "hook JSON or registry has hard-link aliases (st_nlink=\(count)): \(path.path)"
        case .oversized(let path, let limit):
            return "hook source exceeds the \(limit)-byte limit: \(path.path)"
        case .invalidEncoding(let path):
            return "hook source is not valid UTF-8: \(path.path)"
        case .io(let path, let detail):
            return "cannot read hook source \(path.path): \(detail)"
        }
    }
}

struct SecureHookDocument: Sendable {
    let path: URL
    let contents: String
}

enum GlobalHookSourceSecurity {
    static func validateOwnerDirectory(_ path: URL) throws {
        guard try isOwnerDirectoryOrFile(path) else {
            throw GlobalHookSourceSecurityError.invalidType(path)
        }
    }

    static func documents(from source: HookSource) -> (
        documents: [SecureHookDocument],
        errors: [HookError]
    ) {
        switch source {
        case .settingsFile(let path):
            do {
                let document = try readDocument(
                    at: path,
                    maximumBytes: GlobalHookSourceDiscovery.maximumHookBytes
                )
                return ([SecureHookDocument(path: path, contents: document)], [])
            } catch let error as GlobalHookSourceSecurityError {
                if case .missing = error { return ([], []) }
                return ([], [.readFile(path: path, detail: error.description)])
            } catch {
                return ([], [.readFile(path: path, detail: String(describing: error))])
            }
        case .directory(let path):
            return documents(in: path)
        }
    }

    #if os(Windows)
    static func isOwnerDirectoryOrFile(_ path: URL) throws -> Bool {
        try validateWindowsPath(path)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch {
            throw mapFoundationError(error, path: path)
        }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeDirectory || type == .typeRegular else {
            throw GlobalHookSourceSecurityError.invalidType(path)
        }
        if let owner = attributes[.ownerAccountID] as? NSNumber,
           let currentOwner = try? FileManager.default.attributesOfItem(
                atPath: NSHomeDirectory()
           )[.ownerAccountID] as? NSNumber,
           owner != currentOwner {
            throw GlobalHookSourceSecurityError.wrongOwner(path)
        }
        return type == .typeDirectory
    }

    static func readDocument(at path: URL, maximumBytes: Int) throws -> String {
        guard !(try isOwnerDirectoryOrFile(path)) else {
            throw GlobalHookSourceSecurityError.invalidType(path)
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
           let size = attributes[.size] as? NSNumber,
           size.uint64Value > UInt64(maximumBytes) {
            throw GlobalHookSourceSecurityError.oversized(path, maximumBytes)
        }
        let data: Data
        do {
            data = try PathSecurity.readNoFollow(path, maximumBytes: maximumBytes)
        } catch {
            throw GlobalHookSourceSecurityError.io(path, String(describing: error))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GlobalHookSourceSecurityError.invalidEncoding(path)
        }
        return text
    }

    private static func documents(in directory: URL) -> (
        documents: [SecureHookDocument],
        errors: [HookError]
    ) {
        do {
            try validateOwnerDirectory(directory)
            let files = try WindowsSecurePath.contentsOfDirectory(
                at: directory,
                maximumEntries: GlobalHookSourceDiscovery.maximumHookFilesPerSource + 1,
                skipsHiddenFiles: true
            ).filter { isDirectHookJSONName($0.lastPathComponent) }
                .sorted { $0.path < $1.path }

            var documents: [SecureHookDocument] = []
            var errors: [HookError] = []
            if files.count > GlobalHookSourceDiscovery.maximumHookFilesPerSource {
                errors.append(.readFile(
                    path: directory,
                    detail: "hook directory exceeds the \(GlobalHookSourceDiscovery.maximumHookFilesPerSource)-file limit"
                ))
            }
            for file in files.prefix(GlobalHookSourceDiscovery.maximumHookFilesPerSource) {
                do {
                    let content = try readDocument(
                        at: file,
                        maximumBytes: GlobalHookSourceDiscovery.maximumHookBytes
                    )
                    documents.append(SecureHookDocument(path: file, contents: content))
                } catch {
                    errors.append(.readFile(path: file, detail: String(describing: error)))
                }
            }
            return (documents, errors)
        } catch let error as GlobalHookSourceSecurityError {
            if case .missing = error { return ([], []) }
            return ([], [.readFile(path: directory, detail: error.description)])
        } catch {
            return ([], [.readFile(path: directory, detail: String(describing: error))])
        }
    }

    private static func validateWindowsPath(_ path: URL) throws {
        guard path.isFileURL, (path.path as NSString).isAbsolutePath,
              !path.path.contains("\0")
        else {
            throw GlobalHookSourceSecurityError.invalidPath(path)
        }
        var component = path.standardizedFileURL
        while component.path != component.deletingLastPathComponent().path {
            if let metadata = try? WindowsSecurePath.metadata(at: component),
               metadata.isReparsePoint {
                throw GlobalHookSourceSecurityError.symbolicLink(component)
            }
            component = component.deletingLastPathComponent()
        }
    }

    private static func mapFoundationError(_ error: Error, path: URL) -> GlobalHookSourceSecurityError {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return .missing(path)
        }
        return .io(path, error.localizedDescription)
    }
    #else
    static func isOwnerDirectoryOrFile(_ path: URL) throws -> Bool {
        let descriptor = try openDescriptor(for: path)
        defer { close(descriptor) }
        let information = try inspect(descriptor: descriptor, path: path)
        let type = information.st_mode & mode_t(S_IFMT)
        guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else {
            throw GlobalHookSourceSecurityError.invalidType(path)
        }
        guard information.st_uid == geteuid() else {
            throw GlobalHookSourceSecurityError.wrongOwner(path)
        }
        if type == mode_t(S_IFREG), information.st_nlink != 1 {
            throw GlobalHookSourceSecurityError.hardLinked(path, UInt64(information.st_nlink))
        }
        return type == mode_t(S_IFDIR)
    }

    static func readDocument(at path: URL, maximumBytes: Int) throws -> String {
        let descriptor = try openDescriptor(for: path)
        defer { close(descriptor) }
        return try readDocument(descriptor: descriptor, path: path, maximumBytes: maximumBytes)
    }

    private static func documents(in directory: URL) -> (
        documents: [SecureHookDocument],
        errors: [HookError]
    ) {
        let descriptor: Int32
        do {
            descriptor = try openDescriptor(for: directory, directory: true)
            let information = try inspect(descriptor: descriptor, path: directory)
            guard information.st_uid == geteuid() else {
                close(descriptor)
                throw GlobalHookSourceSecurityError.wrongOwner(directory)
            }
        } catch let error as GlobalHookSourceSecurityError {
            if case .missing = error { return ([], []) }
            return ([], [.readFile(path: directory, detail: error.description)])
        } catch {
            return ([], [.readFile(path: directory, detail: String(describing: error))])
        }
        defer { close(descriptor) }

        let listingDescriptor = dup(descriptor)
        guard listingDescriptor >= 0 else {
            return ([], [.readFile(path: directory, detail: String(cString: strerror(errno)))])
        }
        guard let stream = fdopendir(listingDescriptor) else {
            let reason = String(cString: strerror(errno))
            close(listingDescriptor)
            return ([], [.readFile(path: directory, detail: reason)])
        }
        defer { closedir(stream) }

        var names: [String] = []
        var errors: [HookError] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    errors.append(.readFile(path: directory, detail: String(cString: strerror(errno))))
                }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) {
                    String(cString: $0)
                }
            }
            guard isDirectHookJSONName(name) else { continue }
            if names.count == GlobalHookSourceDiscovery.maximumHookFilesPerSource {
                errors.append(.readFile(
                    path: directory,
                    detail: "hook directory exceeds the \(GlobalHookSourceDiscovery.maximumHookFilesPerSource)-file limit"
                ))
                break
            }
            names.append(name)
        }

        var documents: [SecureHookDocument] = []
        for name in names.sorted() {
            let path = directory.appendingPathComponent(name)
            do {
                let childDescriptor = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard childDescriptor >= 0 else {
                    throw mapPOSIXError(errno, path: path)
                }
                defer { close(childDescriptor) }
                let content = try readDocument(
                    descriptor: childDescriptor,
                    path: path,
                    maximumBytes: GlobalHookSourceDiscovery.maximumHookBytes
                )
                documents.append(SecureHookDocument(path: path, contents: content))
            } catch {
                errors.append(.readFile(path: path, detail: String(describing: error)))
            }
        }
        return (documents, errors)
    }

    private static func openDescriptor(for path: URL, directory: Bool = false) throws -> Int32 {
        guard path.isFileURL, path.path.hasPrefix("/"), !path.path.contains("\0"),
              !path.path.split(separator: "/").contains("..")
        else {
            throw GlobalHookSourceSecurityError.invalidPath(path)
        }

        var components = path.standardizedFileURL.pathComponents.filter { $0 != "/" }
        #if os(macOS) || os(iOS)
        if let first = components.first, ["tmp", "var", "etc"].contains(first) {
            components.insert("private", at: 0)
        }
        #endif
        guard let final = components.popLast() else {
            throw GlobalHookSourceSecurityError.invalidType(path)
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var parent = "/".withCString { open($0, directoryFlags) }
        guard parent >= 0 else {
            throw mapPOSIXError(errno, path: path)
        }
        defer { close(parent) }

        var componentPath = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components {
            componentPath.appendPathComponent(component, isDirectory: true)
            let next = component.withCString { openat(parent, $0, directoryFlags) }
            guard next >= 0 else {
                throw mapPOSIXError(errno, path: componentPath)
            }
            close(parent)
            parent = next
        }

        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            | (directory ? O_DIRECTORY : O_NONBLOCK)
        let descriptor = final.withCString { openat(parent, $0, flags) }
        guard descriptor >= 0 else {
            throw mapPOSIXError(errno, path: path)
        }
        return descriptor
    }

    private static func inspect(descriptor: Int32, path: URL) throws -> stat {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw mapPOSIXError(errno, path: path)
        }
        return information
    }

    private static func readDocument(
        descriptor: Int32,
        path: URL,
        maximumBytes: Int
    ) throws -> String {
        let information = try inspect(descriptor: descriptor, path: path)
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw GlobalHookSourceSecurityError.invalidType(path)
        }
        guard information.st_uid == geteuid() else {
            throw GlobalHookSourceSecurityError.wrongOwner(path)
        }
        guard information.st_nlink == 1 else {
            throw GlobalHookSourceSecurityError.hardLinked(path, UInt64(information.st_nlink))
        }
        guard information.st_size >= 0, UInt64(information.st_size) <= UInt64(maximumBytes) else {
            throw GlobalHookSourceSecurityError.oversized(path, maximumBytes)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1024))
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard let bytes = try handle.read(upToCount: min(64 * 1024, remaining)),
                      !bytes.isEmpty
                else {
                    break
                }
                data.append(bytes)
                guard data.count <= maximumBytes else {
                    throw GlobalHookSourceSecurityError.oversized(path, maximumBytes)
                }
            }
        } catch let error as GlobalHookSourceSecurityError {
            throw error
        } catch {
            throw GlobalHookSourceSecurityError.io(path, error.localizedDescription)
        }

        let finalInformation = try inspect(descriptor: descriptor, path: path)
        guard finalInformation.st_uid == information.st_uid,
              finalInformation.st_dev == information.st_dev,
              finalInformation.st_ino == information.st_ino,
              finalInformation.st_nlink == 1
        else {
            throw GlobalHookSourceSecurityError.hardLinked(path, UInt64(finalInformation.st_nlink))
        }
        guard let document = String(data: data, encoding: .utf8) else {
            throw GlobalHookSourceSecurityError.invalidEncoding(path)
        }
        return document
    }

    private static func mapPOSIXError(_ value: Int32, path: URL) -> GlobalHookSourceSecurityError {
        switch value {
        case ENOENT:
            return .missing(path)
        case ELOOP, ENOTDIR:
            return .symbolicLink(path)
        default:
            return .io(path, String(cString: strerror(value)))
        }
    }
    #endif
}
