import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A descriptor-backed, current-user-owned capability for a foreign session store.
///
/// Real Claude stores normally contain 0755 directories and 0644 transcripts.
/// Rejecting group/other *write* access preserves those layouts while preventing
/// another account from replacing any component beneath the approved root.
final class ForeignSessionApprovedRoot {
    let url: URL

    #if canImport(Darwin) || canImport(Glibc)
    private let descriptor: Int32

    init?(_ candidate: URL) {
        let requested = candidate.standardizedFileURL
        let parent = requested.deletingLastPathComponent()
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let parentDescriptor = parent.path.withCString { open($0, directoryFlags) }
        guard parentDescriptor >= 0 else { return nil }
        defer { close(parentDescriptor) }

        let opened = requested.lastPathComponent.withCString {
            openat(parentDescriptor, $0, directoryFlags)
        }
        guard opened >= 0 else { return nil }
        guard Self.safeMetadata(for: opened, fileType: mode_t(S_IFDIR)) != nil else {
            close(opened)
            return nil
        }

        url = requested.resolvingSymlinksInPath().standardizedFileURL
        descriptor = opened
    }

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    func subroot(_ candidate: URL) -> ForeignSessionApprovedRoot? {
        guard let components = relativeComponents(for: candidate),
              let opened = openDirectory(components)
        else { return nil }

        let child = components.reduce(url) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
        return ForeignSessionApprovedRoot(url: child, descriptor: opened)
    }

    /// Visits only names under the already-open directory descriptor.
    /// `false` means the stream failed or the explicit traversal budget ran out.
    @discardableResult
    func visitEntries(
        maximum: Int = .max,
        _ visit: (String) -> Void
    ) -> Bool {
        guard maximum >= 0 else { return false }
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let opened = ".".withCString { openat(descriptor, $0, directoryFlags) }
        guard opened >= 0 else { return false }
        guard let stream = fdopendir(opened) else {
            close(opened)
            return false
        }
        defer { closedir(stream) }

        var visited = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 }
            var buffer = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: buffer)
            let name = withUnsafePointer(to: &buffer) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(validatingCString: $0)
                }
            }
            guard let name, name != ".", name != ".." else { continue }
            guard visited < maximum else { return false }
            visited += 1
            visit(name)
        }
    }

    func openRegularFile(_ candidate: URL) -> ForeignSessionApprovedFile? {
        guard let components = relativeComponents(for: candidate),
              let name = components.last,
              let parent = openDirectory(Array(components.dropLast()))
        else { return nil }
        defer { close(parent) }

        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let opened = name.withCString { openat(parent, $0, flags) }
        guard opened >= 0 else { return nil }
        guard let metadata = Self.safeMetadata(for: opened, fileType: mode_t(S_IFREG)),
              metadata.st_size >= 0
        else {
            close(opened)
            return nil
        }

        #if canImport(Darwin)
        let modified = metadata.st_mtimespec
        #else
        let modified = metadata.st_mtim
        #endif

        let path = components.reduce(url) { partial, component in
            partial.appendingPathComponent(component)
        }
        return ForeignSessionApprovedFile(
            descriptor: opened,
            path: path,
            modified: Date(
                timeIntervalSince1970: TimeInterval(modified.tv_sec)
                    + TimeInterval(modified.tv_nsec) / 1_000_000_000
            ),
            size: UInt64(metadata.st_size)
        )
    }

    private func relativeComponents(for candidate: URL) -> [String]? {
        let path = candidate.standardizedFileURL.path
        if path == url.path { return [] }
        guard path.hasPrefix(url.path + "/") else { return nil }

        let suffix = path.dropFirst(url.path.count + 1)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
        }) else { return nil }
        return components
    }

    private func openDirectory(_ components: [String]) -> Int32? {
        var current = dup(descriptor)
        guard current >= 0 else { return nil }

        for component in components {
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
            let opened = component.withCString { openat(current, $0, flags) }
            close(current)
            guard opened >= 0 else { return nil }
            guard Self.safeMetadata(for: opened, fileType: mode_t(S_IFDIR)) != nil else {
                close(opened)
                return nil
            }
            current = opened
        }
        return current
    }

    private static func safeMetadata(for descriptor: Int32, fileType: mode_t) -> stat? {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == fileType,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o022) == 0
        else { return nil }
        return metadata
    }
    #else
    init?(_ candidate: URL) {
        _ = candidate
        return nil
    }

    func subroot(_ candidate: URL) -> ForeignSessionApprovedRoot? {
        _ = candidate
        return nil
    }

    @discardableResult
    func visitEntries(maximum: Int = .max, _ visit: (String) -> Void) -> Bool {
        _ = (maximum, visit)
        return false
    }

    func openRegularFile(_ candidate: URL) -> ForeignSessionApprovedFile? {
        _ = candidate
        return nil
    }
    #endif
}

/// Keeps the original no-follow descriptor alive across candidate ranking and reads.
/// A path replacement after discovery therefore cannot redirect transcript contents.
final class ForeignSessionApprovedFile {
    let path: URL
    let modified: Date
    let size: UInt64

    #if canImport(Darwin) || canImport(Glibc)
    private let descriptor: Int32
    #endif

    fileprivate init(descriptor: Int32, path: URL, modified: Date, size: UInt64) {
        #if canImport(Darwin) || canImport(Glibc)
        self.descriptor = descriptor
        #else
        _ = descriptor
        #endif
        self.path = path
        self.modified = modified
        self.size = size
    }

    #if canImport(Darwin) || canImport(Glibc)
    deinit {
        close(descriptor)
    }

    func read(offset: UInt64 = 0, maximum: Int) -> Data? {
        guard maximum >= 0,
              offset <= UInt64(Int64.max),
              UInt64(maximum) <= UInt64(Int64.max) - offset
        else { return nil }
        if maximum == 0 { return Data() }

        var bytes = Data(count: maximum)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int? in
            guard let address = buffer.baseAddress else { return nil }
            var total = 0
            while total < maximum {
                let position = off_t(offset) + off_t(total)
                let result = pread(
                    descriptor,
                    address.advanced(by: total),
                    maximum - total,
                    position
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if result == 0 { break }
                total += result
            }
            return total
        }
        guard let count else { return nil }
        bytes.count = count
        return bytes
    }
    #else
    func read(offset: UInt64 = 0, maximum: Int) -> Data? {
        _ = (offset, maximum)
        return nil
    }
    #endif
}
