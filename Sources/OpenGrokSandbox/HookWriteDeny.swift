// HookWriteDeny.swift
//
// Owner-global hooks remain readable but immutable after sandbox activation.
// Mirrors xai-grok-sandbox/src/hook_write_deny.rs and
// xai-grok-config/src/global_hook_sources.rs at upstream 00e176c8.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum HookWriteDenySourceKind: Sendable, Equatable {
    case hookDirectory
    case registryFile
    case configuredSource
    case installedPluginDirectory
}

public struct HookWriteDenySource: Sendable, Equatable {
    public let path: URL
    public let kind: HookWriteDenySourceKind

    public init(path: URL, kind: HookWriteDenySourceKind) {
        self.path = path.standardizedFileURL
        self.kind = kind
    }

    public var isDirectory: Bool {
        switch kind {
        case .hookDirectory, .installedPluginDirectory:
            return true
        case .registryFile:
            return false
        case .configuredSource:
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path.path, isDirectory: &directory)
                && directory.boolValue
        }
    }
}

public enum HookWriteDenyError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidHome(URL)
    case symlink(URL)
    case missingConfigured(URL)
    case invalidSource(URL)
    case wrongOwner(URL)
    case hardLink(URL, UInt64)
    case identityChanged(URL)
    case directorySnapshotChanged(URL)
    case notReadOnly(URL)
    case inaccessibleUnderProfile(URL)
    case io(URL, String)

    public var description: String {
        switch self {
        case .invalidHome(let path):
            return "OPENGROK_HOME is not a real, non-symlink directory: \(path.path)"
        case .symlink(let path):
            return "hook source contains a retargetable symlink: \(path.path)"
        case .missingConfigured(let path):
            return "configured absolute hooks-paths target does not exist: \(path.path)"
        case .invalidSource(let path):
            return "hook source has an unsafe path or file type: \(path.path)"
        case .wrongOwner(let path):
            return "owner-global hook source is not owned by the current user: \(path.path)"
        case .hardLink(let path, let count):
            return "hook file has writable hard-link aliases (st_nlink=\(count)): \(path.path)"
        case .identityChanged(let path):
            return "hook source identity changed before sandbox activation: \(path.path)"
        case .directorySnapshotChanged(let path):
            return "hook directory JSON snapshot changed before sandbox activation: \(path.path)"
        case .notReadOnly(let path):
            return "hook write-deny path is not effectively read-only: \(path.path)"
        case .inaccessibleUnderProfile(let path):
            return "hook source is outside the sandbox profile's readable roots: \(path.path)"
        case .io(let path, let detail):
            return "cannot safely inspect hook source \(path.path): \(detail)"
        }
    }
}

public struct HookPathIdentity: Sendable, Equatable {
    public let path: URL
    public let device: UInt64
    public let inode: UInt64
    public let isDirectory: Bool
    public let linkCount: UInt64
}

public struct HookDirectoryJSONSnapshot: Sendable, Equatable {
    public let directory: URL
    public let files: [HookPathIdentity]
    public let recursive: Bool
}

public struct HookWriteDenyPlan: Sendable, Equatable {
    /// Only ancestors already covered by a writable profile root may receive
    /// writable self-binds. Binding `/tmp` or `/Users` merely because a nested
    /// hook lives there would make hostile sibling directories writable.
    public let writableAncestors: [HookPathIdentity]
    public let leaves: [HookPathIdentity]
    public let directorySnapshots: [HookDirectoryJSONSnapshot]
}

public func profileEnforcesHookWriteDeny(_ profile: ProfileName) -> Bool {
    switch profile {
    case .off, .devbox:
        return false
    case .workspace, .readOnly, .strict, .custom:
        return true
    }
}

public func requiresHookWriteDeny(
    profile: ProfileName,
    workspace: URL,
    config: SandboxConfig? = nil
) -> Bool {
    guard profileEnforcesHookWriteDeny(profile) else { return false }
    guard case .custom(let name) = profile else { return true }
    let effectiveConfig = config ?? loadSandboxConfig(workspace: workspace)
    return effectiveConfig.profiles[name]?.extends != "devbox"
}

#if canImport(Darwin) || os(Linux)
/// Create the two fixed owner-global hook slots before irreversible sandboxing.
/// The registry uses `O_EXCL | O_NOFOLLOW` and is never truncated.
public func ensureGlobalHookSlots(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    let home = try checkedHookURL(sandboxGrokHome(environment: environment), isHome: true)
    if let existing = try hookMetadataIfPresent(at: home) {
        guard hookFileType(existing) == mode_t(S_IFDIR) else {
            throw HookWriteDenyError.invalidHome(home)
        }
        try requireHookOwner(existing, at: home)
    } else {
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        } catch {
            throw HookWriteDenyError.io(home, String(describing: error))
        }
    }
    try rejectHookSymlinkComponents(home, isHome: true)

    let directory = home.appendingPathComponent("hooks", isDirectory: true)
    if directory.path.withCString({ mkdir($0, mode_t(0o700)) }) != 0, errno != EEXIST {
        throw hookIOError(directory)
    }
    let directoryIdentity = try captureHookPathIdentity(directory)
    guard directoryIdentity.isDirectory else {
        throw HookWriteDenyError.invalidSource(directory)
    }
    try rejectHookSymlinkComponents(directory)
    if let metadata = try hookMetadataIfPresent(at: directory) {
        try requireHookOwner(metadata, at: directory)
    }

    let registry = home.appendingPathComponent("hooks-paths")
    let descriptor = registry.path.withCString {
        open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    if descriptor >= 0 {
        close(descriptor)
    } else if errno != EEXIST {
        throw hookIOError(registry)
    }
    let registryIdentity = try captureHookPathIdentity(registry)
    guard !registryIdentity.isDirectory else {
        throw HookWriteDenyError.invalidSource(registry)
    }
    try rejectHookSymlinkComponents(registry)
    if let metadata = try hookMetadataIfPresent(at: registry) {
        try requireHookOwner(metadata, at: registry)
    }
}

/// Resolve fixed owner-global slots plus absolute entries from `hooks-paths`.
/// Missing fixed slots remain representable for pure profile inspection; actual
/// activation calls `ensureGlobalHookSlots` first.
public func resolveHookWriteDenySources(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> [HookWriteDenySource] {
    let home = try checkedHookURL(sandboxGrokHome(environment: environment), isHome: true)
    if let metadata = try hookMetadataIfPresent(at: home) {
        guard hookFileType(metadata) == mode_t(S_IFDIR) else {
            throw HookWriteDenyError.invalidHome(home)
        }
        try requireHookOwner(metadata, at: home)
    }
    let directory = home.appendingPathComponent("hooks", isDirectory: true)
    let registry = home.appendingPathComponent("hooks-paths")
    try rejectHookSymlinkComponents(directory)
    try rejectHookSymlinkComponents(registry)

    var sources = [
        HookWriteDenySource(path: directory, kind: .hookDirectory),
        HookWriteDenySource(path: registry, kind: .registryFile),
    ]
    let installedPlugins = home.appendingPathComponent("installed-plugins", isDirectory: true)
    if let metadata = try hookMetadataIfPresent(at: installedPlugins) {
        try rejectHookSymlinkComponents(installedPlugins)
        guard hookFileType(metadata) == mode_t(S_IFDIR) else {
            throw HookWriteDenyError.invalidSource(installedPlugins)
        }
        try requireHookOwner(metadata, at: installedPlugins)
        // Registry records, manifests, custom hook paths, and plugin scripts
        // are all executable authority. Protecting only known `hooks.json`
        // leaves inline manifests and newly created files mutable. The cost is
        // deliberate: plugin install/update/remove must run outside an active
        // session sandbox or require a restart; unrelated home state remains
        // writable. A missing plugin root is neither created nor rejected.
        sources.append(HookWriteDenySource(path: installedPlugins, kind: .installedPluginDirectory))
    }
    if let metadata = try hookMetadataIfPresent(at: directory) {
        guard hookFileType(metadata) == mode_t(S_IFDIR) else {
            throw HookWriteDenyError.invalidSource(directory)
        }
        try requireHookOwner(metadata, at: directory)
    }

    if try hookMetadataIfPresent(at: registry) != nil {
        let contents = try readVerifiedHookRegistry(registry)
        var configuredCount = 0
        for raw in contents.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("/") else { continue }
            guard !line.contains("\0"),
                  !line.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            else {
                throw HookWriteDenyError.invalidSource(URL(fileURLWithPath: line))
            }
            let path = try checkedHookURL(URL(fileURLWithPath: line))
            guard let metadata = try hookMetadataIfPresent(at: path) else {
                throw HookWriteDenyError.missingConfigured(path)
            }
            let kind = hookFileType(metadata)
            guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG),
                  !pathIsUnderRoot(candidate: home.path, root: path.path)
            else {
                throw HookWriteDenyError.invalidSource(path)
            }
            try requireHookOwner(metadata, at: path)
            let source = HookWriteDenySource(path: path, kind: .configuredSource)
            if !sources.contains(where: { $0.path.path == source.path.path }) {
                guard configuredCount < 256 else {
                    throw HookWriteDenyError.io(registry, "hooks-paths exceeds the 256-source limit")
                }
                configuredCount += 1
                sources.append(source)
            }
        }
    }

    for source in sources {
        guard try hookMetadataIfPresent(at: source.path) != nil else { continue }
        let identity = try captureHookPathIdentity(source.path)
        if source.kind == .registryFile, identity.isDirectory {
            throw HookWriteDenyError.invalidSource(source.path)
        }
        if identity.isDirectory {
            if source.kind == .installedPluginDirectory {
                _ = try installedPluginFileIdentities(in: source.path)
            } else {
                _ = try directHookJSONIdentities(in: source.path)
            }
        }
    }
    return sources
}

public func captureHookPathIdentity(_ path: URL) throws -> HookPathIdentity {
    let checked = try checkedHookURL(path)
    guard let metadata = try hookMetadataIfPresent(at: checked) else {
        throw HookWriteDenyError.io(checked, "path does not exist")
    }
    let kind = hookFileType(metadata)
    guard kind != mode_t(S_IFLNK) else { throw HookWriteDenyError.symlink(checked) }
    guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG) else {
        throw HookWriteDenyError.invalidSource(checked)
    }
    let links = UInt64(metadata.st_nlink)
    if kind == mode_t(S_IFREG), links != 1 {
        throw HookWriteDenyError.hardLink(checked, links)
    }
    return HookPathIdentity(
        path: checked,
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        isDirectory: kind == mode_t(S_IFDIR),
        linkCount: links
    )
}

public func revalidateHookPathIdentity(_ identity: HookPathIdentity) throws {
    let current = try captureHookPathIdentity(identity.path)
    // Directory link counts can change when entries are inserted. Directory
    // contents have their own snapshot; only inode identity must remain fixed.
    let matches = identity.isDirectory
        ? current.path == identity.path
            && current.device == identity.device
            && current.inode == identity.inode
            && current.isDirectory
        : current == identity
    guard matches else {
        throw HookWriteDenyError.identityChanged(identity.path)
    }
}

public func buildHookWriteDenyPlan(
    sources: [HookWriteDenySource],
    writableRoots: [URL],
    readableRoots: [URL] = [],
    defaultRead: Bool = true
) throws -> HookWriteDenyPlan {
    var leaves: [HookPathIdentity] = []
    var snapshots: [HookDirectoryJSONSnapshot] = []
    var seenLeaves = Set<String>()
    var ancestors: [HookPathIdentity] = []
    var seenAncestors = Set<String>()

    for source in sources {
        if !defaultRead,
           !(writableRoots + readableRoots).contains(where: {
               pathIsUnderRoot(candidate: source.path.path, root: $0.path)
           }) {
            throw HookWriteDenyError.inaccessibleUnderProfile(source.path)
        }
        let identity = try captureHookPathIdentity(source.path)
        if seenLeaves.insert(identity.path.path).inserted {
            leaves.append(identity)
        }
        if identity.isDirectory {
            let recursive = source.kind == .installedPluginDirectory
            let files: [HookPathIdentity]
            if recursive {
                files = try installedPluginFileIdentities(in: source.path)
            } else {
                files = try directHookJSONIdentities(in: source.path)
            }
            snapshots.append(HookDirectoryJSONSnapshot(
                directory: source.path,
                files: files,
                recursive: recursive
            ))
            if !recursive {
                for file in files where seenLeaves.insert(file.path.path).inserted {
                    leaves.append(file)
                }
            }
        }

        var ancestor = source.path.deletingLastPathComponent()
        while ancestor.path != "/" {
            if writableRoots.contains(where: {
                pathIsUnderRoot(candidate: ancestor.path, root: $0.path)
            }), seenAncestors.insert(ancestor.path).inserted {
                let identity = try captureHookPathIdentity(ancestor)
                guard identity.isDirectory else {
                    throw HookWriteDenyError.invalidSource(ancestor)
                }
                ancestors.append(identity)
            }
            ancestor.deleteLastPathComponent()
        }
    }

    let protected = Set(leaves.map { $0.path.path })
    ancestors = ancestors.filter { !protected.contains($0.path.path) }
    ancestors.sort {
        let left = $0.path.pathComponents.count
        let right = $1.path.pathComponents.count
        return left == right ? $0.path.path < $1.path.path : left < right
    }

    return HookWriteDenyPlan(
        writableAncestors: ancestors,
        leaves: leaves,
        directorySnapshots: snapshots
    )
}

public func revalidateHookWriteDenyPlan(_ plan: HookWriteDenyPlan) throws {
    for identity in plan.writableAncestors + plan.leaves {
        try revalidateHookPathIdentity(identity)
    }
    for snapshot in plan.directorySnapshots {
        let current: [HookPathIdentity]
        if snapshot.recursive {
            current = try installedPluginFileIdentities(in: snapshot.directory)
        } else {
            current = try directHookJSONIdentities(in: snapshot.directory)
        }
        guard current == snapshot.files else {
            throw HookWriteDenyError.directorySnapshotChanged(snapshot.directory)
        }
    }
}

private func directHookJSONIdentities(in directory: URL) throws -> [HookPathIdentity] {
    let entries: [URL]
    do {
        entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
    } catch {
        throw HookWriteDenyError.io(directory, String(describing: error))
    }

    var identities: [HookPathIdentity] = []
    for entry in entries {
        let name = entry.lastPathComponent
        guard name.hasSuffix(".json"), name.count > 5, !name.hasPrefix(".") else {
            continue
        }
        let identity = try captureHookPathIdentity(entry)
        guard !identity.isDirectory else {
            throw HookWriteDenyError.invalidSource(entry)
        }
        if let metadata = try hookMetadataIfPresent(at: entry) {
            try requireHookOwner(metadata, at: entry)
        }
        guard identities.count < 1_024 else {
            throw HookWriteDenyError.io(directory, "hook directory exceeds the 1,024-file limit")
        }
        identities.append(identity)
    }
    return identities.sorted { $0.path.path < $1.path.path }
}

private func installedPluginFileIdentities(in directory: URL) throws -> [HookPathIdentity] {
    var pending = [(directory, 0)]
    var identities: [HookPathIdentity] = []
    var entries = 0

    while let (parent, depth) = pending.popLast() {
        guard depth <= 128 else {
            throw HookWriteDenyError.io(directory, "installed plugin directory nesting exceeds 128 levels")
        }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw HookWriteDenyError.io(parent, String(describing: error))
        }
        for child in children {
            entries += 1
            guard entries <= 32_768 else {
                throw HookWriteDenyError.io(directory, "installed plugin directory exceeds 32,768 entries")
            }
            let identity = try captureHookPathIdentity(child)
            if let metadata = try hookMetadataIfPresent(at: child) {
                try requireHookOwner(metadata, at: child)
            }
            if identity.isDirectory {
                pending.append((child, depth + 1))
            } else {
                identities.append(identity)
            }
        }
    }

    return identities.sorted { $0.path.path < $1.path.path }
}

private func checkedHookURL(_ path: URL, isHome: Bool = false) throws -> URL {
    do {
        try rejectTraversableRoot(path)
    } catch {
        if isHome { throw HookWriteDenyError.invalidHome(path) }
        throw HookWriteDenyError.invalidSource(path)
    }
    let standardized = path.standardizedFileURL
    try rejectHookSymlinkComponents(standardized, isHome: isHome)
    return standardized
}

private func rejectHookSymlinkComponents(_ path: URL, isHome: Bool = false) throws {
    var component = URL(fileURLWithPath: "/", isDirectory: true)
    for segment in path.standardizedFileURL.pathComponents where segment != "/" {
        component.appendPathComponent(segment)
        guard let metadata = try hookMetadataIfPresent(at: component) else { break }
        guard hookFileType(metadata) != mode_t(S_IFLNK) else {
            #if os(macOS)
            if ["/tmp", "/var", "/etc", "/private/tmp", "/private/var", "/private/etc"]
                .contains(component.path) {
                continue
            }
            #endif
            if isHome { throw HookWriteDenyError.invalidHome(component) }
            throw HookWriteDenyError.symlink(component)
        }
    }
}

private func hookMetadataIfPresent(at path: URL) throws -> stat? {
    var metadata = stat()
    guard path.path.withCString({ lstat($0, &metadata) }) == 0 else {
        if errno == ENOENT { return nil }
        throw hookIOError(path)
    }
    return metadata
}

private func hookFileType(_ metadata: stat) -> mode_t {
    metadata.st_mode & mode_t(S_IFMT)
}

private func requireHookOwner(_ metadata: stat, at path: URL) throws {
    guard metadata.st_uid == geteuid() else {
        throw HookWriteDenyError.wrongOwner(path)
    }
}

private func hookIOError(_ path: URL) -> HookWriteDenyError {
    HookWriteDenyError.io(path, String(cString: strerror(errno)))
}

private func readVerifiedHookRegistry(_ registry: URL) throws -> String {
    let expected = try captureHookPathIdentity(registry)
    guard !expected.isDirectory else { throw HookWriteDenyError.invalidSource(registry) }
    let descriptor = registry.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw hookIOError(registry) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else { throw hookIOError(registry) }
    try requireHookOwner(metadata, at: registry)
    guard UInt64(metadata.st_dev) == expected.device,
          UInt64(metadata.st_ino) == expected.inode,
          UInt64(metadata.st_nlink) == 1
    else {
        if metadata.st_nlink != 1 {
            throw HookWriteDenyError.hardLink(registry, UInt64(metadata.st_nlink))
        }
        throw HookWriteDenyError.identityChanged(registry)
    }

    let maximumBytes = 256 * 1_024
    guard metadata.st_size >= 0, UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
        throw HookWriteDenyError.io(registry, "hooks-paths exceeds the 256 KiB limit")
    }
    var data = Data()
    data.reserveCapacity(min(maximumBytes, 64 * 1_024))
    do {
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try file.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else {
                break
            }
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw HookWriteDenyError.io(registry, "hooks-paths exceeds the 256 KiB limit")
            }
        }
    } catch let error as HookWriteDenyError {
        throw error
    } catch {
        throw HookWriteDenyError.io(registry, String(describing: error))
    }
    try revalidateHookPathIdentity(expected)
    guard let contents = String(data: data, encoding: .utf8) else {
        throw HookWriteDenyError.io(registry, "registry is not valid UTF-8")
    }
    return contents
}
#else
public func ensureGlobalHookSlots(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    _ = environment
    throw SandboxError.unsupported("owner-global hook write protection requires a Unix sandbox backend")
}

public func resolveHookWriteDenySources(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> [HookWriteDenySource] {
    _ = environment
    throw SandboxError.unsupported("owner-global hook write protection requires a Unix sandbox backend")
}

public func captureHookPathIdentity(_ path: URL) throws -> HookPathIdentity {
    _ = path
    throw SandboxError.unsupported("owner-global hook identity validation requires a Unix sandbox backend")
}

public func revalidateHookPathIdentity(_ identity: HookPathIdentity) throws {
    _ = identity
    throw SandboxError.unsupported("owner-global hook identity validation requires a Unix sandbox backend")
}

public func buildHookWriteDenyPlan(
    sources: [HookWriteDenySource],
    writableRoots: [URL],
    readableRoots: [URL] = [],
    defaultRead: Bool = true
) throws -> HookWriteDenyPlan {
    _ = (sources, writableRoots, readableRoots, defaultRead)
    throw SandboxError.unsupported("owner-global hook write protection requires a Unix sandbox backend")
}

public func revalidateHookWriteDenyPlan(_ plan: HookWriteDenyPlan) throws {
    _ = plan
    throw SandboxError.unsupported("owner-global hook write protection requires a Unix sandbox backend")
}
#endif

#if os(Linux)
func verifyHookWriteDenyEnforced(_ sources: [HookWriteDenySource]) throws {
    let plan = try buildHookWriteDenyPlan(sources: sources, writableRoots: [])
    for identity in plan.leaves {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            | (identity.isDirectory ? O_DIRECTORY : 0)
        let descriptor = identity.path.path.withCString { open($0, flags) }
        guard descriptor >= 0 else { throw hookIOError(identity.path) }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw hookIOError(identity.path)
        }
        guard UInt64(metadata.st_dev) == identity.device,
              UInt64(metadata.st_ino) == identity.inode,
              (hookFileType(metadata) == mode_t(S_IFDIR)) == identity.isDirectory,
              identity.isDirectory || UInt64(metadata.st_nlink) == identity.linkCount
        else {
            throw HookWriteDenyError.identityChanged(identity.path)
        }

        var information = statvfs()
        guard fstatvfs(descriptor, &information) == 0 else {
            throw hookIOError(identity.path)
        }
        // Linux ST_RDONLY is the POSIX bit 0x1. An inode mode check cannot
        // substitute: the owner's original file may still have mode 0600.
        guard UInt64(information.f_flag) & 1 != 0 else {
            throw HookWriteDenyError.notReadOnly(identity.path)
        }
    }
    try verifyLinuxUserNamespaceCannotReopenMounts()
}

private final class HookNamespaceProbeStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?

    func set(_ value: Int32) {
        lock.lock()
        status = value
        lock.unlock()
    }

    func get() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}

private func verifyLinuxUserNamespaceCannotReopenMounts() throws {
    let files = FileManager.default
    guard let unshare = ["/usr/bin/unshare", "/bin/unshare"].first(where: {
        files.isExecutableFile(atPath: $0)
    }), let success = ["/usr/bin/true", "/bin/true"].first(where: {
        files.isExecutableFile(atPath: $0)
    }) else {
        throw SandboxError.unsupported(
            "hook write-deny cannot prove user-namespace lockdown; an absolute unshare probe is unavailable"
        )
    }

    let process = Process()
    let errors = Pipe()
    let completed = DispatchSemaphore(value: 0)
    let status = HookNamespaceProbeStatus()
    process.executableURL = URL(fileURLWithPath: unshare)
    process.arguments = ["--user", "--mount", "--", success]
    process.environment = ["LC_ALL": "C"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    process.terminationHandler = { child in
        status.set(child.terminationStatus)
        completed.signal()
    }

    do {
        try process.run()
        errors.fileHandleForWriting.closeFile()
    } catch {
        throw SandboxError.unsupported("hook namespace-lockdown probe could not launch: \(error)")
    }
    guard completed.wait(timeout: .now() + 5) == .success else {
        process.terminate()
        if completed.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = completed.wait(timeout: .now() + 2)
        }
        throw SandboxError.unsupported("hook namespace-lockdown probe timed out")
    }

    if status.get() == 0 {
        throw SandboxError.unsupported(
            "hook write-deny is escapable because user/mount namespaces remain available; "
                + "TSYNC namespace lockdown would conflict with existing child-network isolation"
        )
    }
    let detail = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )?.lowercased() ?? ""
    guard detail.contains("operation not permitted") || detail.contains("permission denied") else {
        throw SandboxError.unsupported(
            "hook write-deny cannot prove user namespaces are unavailable: \(detail)"
        )
    }
}
#endif
