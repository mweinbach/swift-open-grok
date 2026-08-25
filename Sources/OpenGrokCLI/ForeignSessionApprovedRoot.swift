import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import COpenGrokSockets
import OpenGrokFileUtils
import WinSDK
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
    #elseif os(Windows)
    private let handle: HANDLE

    init?(_ candidate: URL) {
        guard candidate.isFileURL,
              (try? PathSecurity.rejectHostileLexical(candidate.path)) != nil
        else { return nil }
        let requested = candidate.standardizedFileURL
        guard let opened = Self.openWindowsPath(requested, directory: true) else {
            return nil
        }
        url = requested
        handle = opened
    }

    private init(url: URL, handle: HANDLE) {
        self.url = url
        self.handle = handle
    }

    deinit {
        CloseHandle(handle)
    }

    func subroot(_ candidate: URL) -> ForeignSessionApprovedRoot? {
        guard let components = relativeWindowsComponents(for: candidate),
              let opened = openWindowsDirectory(components)
        else { return nil }
        let child = components.reduce(url) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        return ForeignSessionApprovedRoot(url: child, handle: opened)
    }

    @discardableResult
    func visitEntries(maximum: Int = .max, _ visit: (String) -> Void) -> Bool {
        guard maximum >= 0,
              Self.windowsInformation(handle, directory: true, path: url) != nil,
              let entries = try? WindowsSecurePath.contentsOfDirectory(
                  at: url,
                  maximumEntries: maximum,
                  skipsHiddenFiles: false
              )
        else { return false }
        for entry in entries {
            let name = entry.lastPathComponent
            guard !name.isEmpty,
                  name != ".",
                  name != "..",
                  !name.contains("\\"),
                  !name.contains("/"),
                  !name.contains("\0")
            else { return false }
            visit(name)
        }
        return Self.windowsInformation(handle, directory: true, path: url) != nil
    }

    func openRegularFile(_ candidate: URL) -> ForeignSessionApprovedFile? {
        guard let components = relativeWindowsComponents(for: candidate),
              let name = components.last,
              let parent = openWindowsDirectory(Array(components.dropLast()))
        else { return nil }
        defer { CloseHandle(parent) }

        let parentPath = components.dropLast().reduce(url) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        guard Self.windowsInformation(parent, directory: true, path: parentPath) != nil else {
            return nil
        }
        let path = parentPath.appendingPathComponent(name)
        guard let opened = Self.openWindowsPath(path, directory: false) else { return nil }
        guard let metadata = Self.windowsInformation(opened, directory: false, path: path) else {
            CloseHandle(opened)
            return nil
        }

        let ticks = (UInt64(metadata.ftLastWriteTime.dwHighDateTime) << 32)
            | UInt64(metadata.ftLastWriteTime.dwLowDateTime)
        let unixEpochTicks: UInt64 = 116_444_736_000_000_000
        guard ticks >= unixEpochTicks else {
            CloseHandle(opened)
            return nil
        }
        return ForeignSessionApprovedFile(
            windowsHandle: opened,
            path: path,
            modified: Date(
                timeIntervalSince1970: TimeInterval(ticks - unixEpochTicks) / 10_000_000
            ),
            size: (UInt64(metadata.nFileSizeHigh) << 32) | UInt64(metadata.nFileSizeLow),
            volume: UInt64(metadata.dwVolumeSerialNumber),
            index: (UInt64(metadata.nFileIndexHigh) << 32) | UInt64(metadata.nFileIndexLow)
        )
    }

    private func relativeWindowsComponents(for candidate: URL) -> [String]? {
        guard candidate.isFileURL,
              (try? PathSecurity.rejectHostileLexical(candidate.path)) != nil
        else { return nil }
        let path = candidate.standardizedFileURL.path.replacingOccurrences(of: "\\", with: "/")
        let base = url.path.replacingOccurrences(of: "\\", with: "/")
        if path.caseInsensitiveCompare(base) == .orderedSame { return [] }
        guard path.lowercased().hasPrefix(base.lowercased() + "/") else { return nil }
        let suffix = path.dropFirst(base.count + 1)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
        }) else { return nil }
        return components
    }

    private func openWindowsDirectory(_ components: [String]) -> HANDLE? {
        guard Self.windowsInformation(handle, directory: true, path: url) != nil else {
            return nil
        }
        var path = url
        var pinned: [HANDLE] = []
        defer {
            for directory in pinned.dropLast() {
                CloseHandle(directory)
            }
        }
        if components.isEmpty {
            return Self.openWindowsPath(url, directory: true)
        }
        for component in components {
            path = path.appendingPathComponent(component, isDirectory: true)
            guard let next = Self.openWindowsPath(path, directory: true) else {
                for directory in pinned { CloseHandle(directory) }
                pinned.removeAll()
                return nil
            }
            pinned.append(next)
        }
        return pinned.last
    }

    fileprivate static func openWindowsPath(_ path: URL, directory: Bool) -> HANDLE? {
        guard let native = try? WindowsSecurePath.extendedLengthPath(path.path) else {
            return nil
        }
        var flags = DWORD(FILE_FLAG_OPEN_REPARSE_POINT)
        if directory { flags |= DWORD(FILE_FLAG_BACKUP_SEMANTICS) }
        let access = DWORD(READ_CONTROL) | DWORD(FILE_READ_ATTRIBUTES)
            | (directory ? 0 : DWORD(GENERIC_READ))
        let opened = native.withCString(encodedAs: UTF16.self) { pointer in
            CreateFileW(
                pointer,
                access,
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_EXISTING),
                flags,
                nil
            )
        }
        guard let handle = opened, handle != INVALID_HANDLE_VALUE else { return nil }
        guard windowsInformation(handle, directory: directory, path: path) != nil else {
            CloseHandle(handle)
            return nil
        }
        return handle
    }

    fileprivate static func windowsInformation(
        _ handle: HANDLE,
        directory: Bool,
        path: URL
    ) -> BY_HANDLE_FILE_INFORMATION? {
        var information = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &information),
              information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
              (information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0) == directory,
              information.nFileIndexHigh != 0 || information.nFileIndexLow != 0,
              directory || information.nNumberOfLinks == 1,
              og_file_handle_is_private_to_current_user(
                  OGSocketHandle(Int(bitPattern: handle)),
                  directory ? 1 : 0
              ) == 1,
              finalWindowsPathMatches(handle, expected: path)
        else { return nil }
        return information
    }

    private static func finalWindowsPathMatches(_ handle: HANDLE, expected: URL) -> Bool {
        let required = GetFinalPathNameByHandleW(handle, nil, 0, 0)
        guard required > 0, required <= 32_768,
              let native = try? WindowsSecurePath.extendedLengthPath(expected.path)
        else { return false }
        var buffer = [UInt16](repeating: 0, count: Int(required) + 1)
        let written = buffer.withUnsafeMutableBufferPointer {
            GetFinalPathNameByHandleW(handle, $0.baseAddress, DWORD($0.count), 0)
        }
        guard written > 0, written < DWORD(buffer.count) else { return false }
        let resolved = String(decoding: buffer.prefix(Int(written)), as: UTF16.self)
        return resolved.caseInsensitiveCompare(native) == .orderedSame
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
    #elseif os(Windows)
    private let handle: HANDLE
    private let readLock = NSLock()
    let windowsVolume: UInt64
    let windowsIndex: UInt64
    #endif

    #if !os(Windows)
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
    #endif

    #if os(Windows)
    fileprivate init(
        windowsHandle: HANDLE,
        path: URL,
        modified: Date,
        size: UInt64,
        volume: UInt64,
        index: UInt64
    ) {
        self.handle = windowsHandle
        self.path = path
        self.modified = modified
        self.size = size
        self.windowsVolume = volume
        self.windowsIndex = index
    }
    #endif

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
    #elseif os(Windows)
    deinit {
        CloseHandle(handle)
    }

    func read(offset: UInt64 = 0, maximum: Int) -> Data? {
        guard maximum >= 0,
              offset <= UInt64(Int64.max),
              UInt64(maximum) <= UInt64(Int64.max) - offset
        else { return nil }
        if maximum == 0 { return Data() }

        return readLock.withLock {
            guard let information = ForeignSessionApprovedRoot.windowsInformation(
                handle,
                directory: false,
                path: path
            ), information.dwVolumeSerialNumber == DWORD(windowsVolume),
            ((UInt64(information.nFileIndexHigh) << 32) | UInt64(information.nFileIndexLow))
                == windowsIndex
            else { return nil }

            var high = LONG(truncatingIfNeeded: offset >> 32)
            let low = LONG(bitPattern: UInt32(truncatingIfNeeded: offset))
            SetLastError(DWORD(ERROR_SUCCESS))
            let position = SetFilePointer(handle, low, &high, DWORD(FILE_BEGIN))
            guard position != DWORD.max || GetLastError() == DWORD(ERROR_SUCCESS) else {
                return nil
            }

            var bytes = Data(count: maximum)
            let total = bytes.withUnsafeMutableBytes { buffer -> Int? in
                guard let address = buffer.baseAddress else { return nil }
                var consumed = 0
                while consumed < maximum {
                    var count: DWORD = 0
                    let capacity = DWORD(min(maximum - consumed, 64 * 1_024))
                    guard ReadFile(
                        handle,
                        address.advanced(by: consumed),
                        capacity,
                        &count,
                        nil
                    ) else { return nil }
                    if count == 0 { break }
                    consumed += Int(count)
                }
                return consumed
            }
            guard let total else { return nil }
            bytes.count = total
            return bytes
        }
    }
    #else
    func read(offset: UInt64 = 0, maximum: Int) -> Data? {
        _ = (offset, maximum)
        return nil
    }
    #endif
}
