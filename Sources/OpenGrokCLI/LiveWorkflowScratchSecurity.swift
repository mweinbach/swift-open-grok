import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokWorkflow

#if os(Windows)
import COpenGrokSockets
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LiveWorkflowScratchSecurity {
    static let maximumNameBytes = 255
    static let maximumFileBytes = 10 * 1_024 * 1_024
    static let maximumFiles = 64
    static let maximumTotalBytes = 64 * 1_024 * 1_024

    static func write(name: String, content: String, root: URL) throws -> String {
        let path = try scratchPath(name: name, root: root)
        let body = Data(content.utf8)
        guard body.count <= maximumFileBytes else {
            throw failure("scratch file exceeds \(maximumFileBytes) byte limit")
        }

        let directory = try openDirectory(at: root, create: true)
        try rejectUnsafeFile(named: name, in: directory, allowMissing: true)
        let usage = try scratchUsage(in: directory, replacing: name)
        guard usage.files + 1 <= maximumFiles else {
            throw failure("scratch file quota exceeded (maximum \(maximumFiles))")
        }
        guard usage.bytes <= maximumTotalBytes - body.count else {
            throw failure("scratch byte quota exceeded (maximum \(maximumTotalBytes))")
        }

        #if os(Windows)
        try verifyDirectory(directory)
        try rejectUnsafeFile(named: name, in: directory, allowMissing: true)
        do {
            try SecureFile.write(at: path, contents: body)
        } catch {
            throw failure("scratch atomic persist: \(error)")
        }
        try verifyDirectory(directory)
        #else
        try atomicWrite(body, named: name, in: directory)
        #endif

        return "scratch/\(name)"
    }

    static func read(name: String, root: URL) throws -> String {
        let path = try scratchPath(name: name, root: root)
        let directory = try openDirectory(at: root, create: false)
        try rejectUnsafeFile(named: name, in: directory, allowMissing: false)

        let bytes: Data
        #if os(Windows)
        do {
            bytes = try PathSecurity.readNoFollow(
                path,
                maximumBytes: maximumFileBytes,
                requireOwnerOnly: true
            )
        } catch {
            if let fileError = error as? FileUtilsError,
               case .io(_, let detail) = fileError,
               detail == "file exceeds secure-read byte bound"
            {
                throw failure("scratch file exceeds \(maximumFileBytes) byte read limit")
            }
            throw failure("scratch read: \(error)")
        }
        try verifyDirectory(directory)
        #else
        bytes = try readBounded(named: name, in: directory)
        #endif

        guard let text = String(data: bytes, encoding: .utf8) else {
            throw failure("scratch file is not UTF-8")
        }
        return text
    }

    private static func scratchPath(name: String, root: URL) throws -> URL {
        guard name.utf8.count <= maximumNameBytes else {
            throw failure("scratch file name exceeds \(maximumNameBytes) bytes")
        }
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.utf8.contains(0),
              root.isFileURL
        else {
            throw failure("scratch file name must be a single relative path component, got: \(name)")
        }

        let path = root.standardizedFileURL.appendingPathComponent(name)
        #if os(Windows)
        do {
            _ = try WindowsSecurePath.extendedLengthPath(path.path)
        } catch {
            throw failure("scratch file name must be a single relative path component, got: \(name)")
        }
        #endif
        return path
    }

    private static func failure(_ message: String) -> RhaiHostError {
        .failed(message)
    }

    private final class ScratchDirectory {
        let url: URL

        #if !os(Windows)
        let descriptor: Int32

        init(url: URL, descriptor: Int32) {
            self.url = url
            self.descriptor = descriptor
        }

        deinit {
            close(descriptor)
        }
        #else
        init(url: URL) {
            self.url = url
        }
        #endif
    }

    #if os(Windows)
    private static func openDirectory(at root: URL, create: Bool) throws -> ScratchDirectory {
        let directory = root.standardizedFileURL
        let parent = directory.deletingLastPathComponent()

        if let information = try WindowsSecurePath.metadata(at: parent) {
            guard information.isDirectory, !information.isReparsePoint else {
                throw failure("scratch directory parent must be a real directory: \(parent.path)")
            }
        } else if !create {
            throw failure("scratch read metadata: scratch directory does not exist")
        }

        if let information = try WindowsSecurePath.metadata(at: directory) {
            guard !information.isReparsePoint else {
                throw failure("scratch directory must not be a symlink: \(directory.path)")
            }
            guard information.isDirectory else {
                throw failure("scratch directory is not a real directory: \(directory.path)")
            }
        } else if create {
            let stateRoot = parent.lastPathComponent == "workflow-scratch" ? parent : directory
            do {
                try createDirAllOwnerOnly(directory, stateRoot: stateRoot)
            } catch {
                throw failure("scratch dir: \(error)")
            }
        } else {
            throw failure("scratch read metadata: scratch directory does not exist")
        }

        let result = ScratchDirectory(url: directory)
        try verifyDirectory(result)
        return result
    }

    private static func verifyDirectory(_ directory: ScratchDirectory) throws {
        guard let information = try WindowsSecurePath.metadata(at: directory.url),
              information.isDirectory,
              !information.isReparsePoint
        else {
            throw failure("scratch directory must be a real, non-symlink directory")
        }
        let native = try WindowsSecurePath.extendedLengthPath(directory.url.path)
        guard native.withCString({ og_path_is_private_to_current_user($0, 1) }) == 1 else {
            throw failure("scratch directory is not private to the current user")
        }
    }

    private static func rejectUnsafeFile(
        named name: String,
        in directory: ScratchDirectory,
        allowMissing: Bool
    ) throws {
        let path = directory.url.appendingPathComponent(name)
        guard let information = try WindowsSecurePath.metadata(at: path) else {
            if allowMissing { return }
            throw failure("scratch read metadata: scratch file does not exist")
        }
        guard !information.isReparsePoint else {
            throw failure("scratch file must not be a symlink: \(path.path)")
        }
        guard !information.isDirectory else {
            throw failure("scratch path is not a regular file")
        }
        guard try SecureFile.isOwnerOnly(at: path) else {
            throw failure("scratch file is not private to the current user")
        }
    }

    private static func scratchUsage(
        in directory: ScratchDirectory,
        replacing target: String
    ) throws -> (files: Int, bytes: Int) {
        let paths: [URL]
        do {
            paths = try WindowsSecurePath.contentsOfDirectory(
                at: directory.url,
                maximumEntries: maximumFiles + 1,
                skipsHiddenFiles: false
            )
        } catch {
            throw failure("scratch dir listing: \(error)")
        }

        var files = 0
        var bytes = 0
        for path in paths {
            guard let information = try WindowsSecurePath.metadata(at: path) else {
                throw failure("scratch metadata: entry disappeared")
            }
            guard !information.isReparsePoint else {
                throw failure("scratch directory contains a symlink: \(path.path)")
            }
            guard !information.isDirectory else { continue }
            guard try SecureFile.isOwnerOnly(at: path) else {
                throw failure("scratch file is not private to the current user")
            }
            guard path.lastPathComponent != target else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.uint64Value <= UInt64(Int.max)
            else {
                throw failure("scratch metadata: invalid file size")
            }
            files += 1
            guard Int(size.uint64Value) <= maximumTotalBytes - bytes else {
                throw failure("scratch byte quota exceeded (maximum \(maximumTotalBytes))")
            }
            bytes += Int(size.uint64Value)
        }
        try verifyDirectory(directory)
        return (files, bytes)
    }
    #else
    private static var directoryFlags: Int32 {
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    }

    private static func openDirectory(at root: URL, create: Bool) throws -> ScratchDirectory {
        let directory = root.standardizedFileURL
        let parent = directory.deletingLastPathComponent()
        let ancestor = parent.deletingLastPathComponent()
        let ancestorFD = ancestor.path.withCString { open($0, directoryFlags) }
        guard ancestorFD >= 0 else {
            throw failure("scratch directory parent: \(String(cString: strerror(errno)))")
        }
        defer { close(ancestorFD) }

        if create {
            try createDirectoryIfMissing(
                named: parent.lastPathComponent,
                under: ancestorFD,
                path: parent
            )
        }
        let parentFD = parent.lastPathComponent.withCString {
            openat(ancestorFD, $0, directoryFlags)
        }
        guard parentFD >= 0 else {
            throw failure("scratch directory parent must not be a symlink: \(parent.path)")
        }
        defer { close(parentFD) }

        if create, parent.lastPathComponent == "workflow-scratch" {
            try makeOwnerPrivate(parentFD, path: parent)
        }
        if create {
            try createDirectoryIfMissing(
                named: directory.lastPathComponent,
                under: parentFD,
                path: directory
            )
        }
        let descriptor = directory.lastPathComponent.withCString {
            openat(parentFD, $0, directoryFlags)
        }
        guard descriptor >= 0 else {
            throw failure("scratch directory must not be a symlink: \(directory.path)")
        }

        do {
            if create {
                try makeOwnerPrivate(descriptor, path: directory)
            } else {
                try requireOwnerPrivateDirectory(descriptor, path: directory)
            }
            return ScratchDirectory(url: directory, descriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func createDirectoryIfMissing(
        named component: String,
        under descriptor: Int32,
        path: URL
    ) throws {
        let result = component.withCString { mkdirat(descriptor, $0, mode_t(0o700)) }
        guard result == 0 || errno == EEXIST else {
            throw failure("scratch dir: \(path.path): \(String(cString: strerror(errno)))")
        }
    }

    private static func makeOwnerPrivate(_ descriptor: Int32, path: URL) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              information.st_uid == geteuid()
        else {
            throw failure("scratch directory is not owned by the current user: \(path.path)")
        }
        if information.st_mode & mode_t(0o777) != mode_t(0o700),
           fchmod(descriptor, mode_t(0o700)) != 0
        {
            throw failure("scratch directory permissions: \(String(cString: strerror(errno)))")
        }
    }

    private static func requireOwnerPrivateDirectory(_ descriptor: Int32, path: URL) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw failure("scratch directory is not private to the current user: \(path.path)")
        }
    }

    private static func verifyDirectory(_ directory: ScratchDirectory) throws {
        let observed = directory.url.path.withCString { open($0, directoryFlags) }
        guard observed >= 0 else {
            throw failure("scratch directory changed during its operation")
        }
        defer { close(observed) }
        var originalInformation = stat()
        var observedInformation = stat()
        guard fstat(directory.descriptor, &originalInformation) == 0,
              fstat(observed, &observedInformation) == 0,
              originalInformation.st_dev == observedInformation.st_dev,
              originalInformation.st_ino == observedInformation.st_ino
        else {
            throw failure("scratch directory changed during its operation")
        }
    }

    private static func metadata(
        for name: String,
        in directory: ScratchDirectory,
        allowMissing: Bool
    ) throws -> stat? {
        var information = stat()
        let result = name.withCString {
            fstatat(directory.descriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT, allowMissing { return nil }
            throw failure("scratch metadata: \(String(cString: strerror(errno)))")
        }
        return information
    }

    private static func rejectUnsafeFile(
        named name: String,
        in directory: ScratchDirectory,
        allowMissing: Bool
    ) throws {
        guard let information = try metadata(for: name, in: directory, allowMissing: allowMissing) else {
            return
        }
        if information.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            throw failure("scratch file must not be a symlink: \(directory.url.appendingPathComponent(name).path)")
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw failure("scratch path is not a regular file")
        }
        guard information.st_uid == geteuid(),
              information.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            throw failure("scratch file is not private to the current user")
        }
    }

    private static func scratchUsage(
        in directory: ScratchDirectory,
        replacing target: String
    ) throws -> (files: Int, bytes: Int) {
        try verifyDirectory(directory)
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        } catch {
            throw failure("scratch dir listing: \(error)")
        }
        try verifyDirectory(directory)

        var files = 0
        var bytes = 0
        for entry in entries {
            guard let information = try metadata(for: entry, in: directory, allowMissing: false) else {
                throw failure("scratch metadata: entry disappeared")
            }
            let kind = information.st_mode & mode_t(S_IFMT)
            guard kind != mode_t(S_IFLNK) else {
                throw failure("scratch directory contains a symlink: \(directory.url.appendingPathComponent(entry).path)")
            }
            guard kind == mode_t(S_IFREG) else { continue }
            guard information.st_uid == geteuid(),
                  information.st_mode & mode_t(0o777) == mode_t(0o600)
            else {
                throw failure("scratch file is not private to the current user")
            }
            guard entry != target else { continue }
            guard information.st_size >= 0,
                  UInt64(information.st_size) <= UInt64(Int.max)
            else {
                throw failure("scratch metadata: invalid file size")
            }
            files += 1
            let size = Int(information.st_size)
            guard size <= maximumTotalBytes - bytes else {
                throw failure("scratch byte quota exceeded (maximum \(maximumTotalBytes))")
            }
            bytes += size
        }
        return (files, bytes)
    }

    private static func atomicWrite(
        _ data: Data,
        named name: String,
        in directory: ScratchDirectory
    ) throws {
        try verifyDirectory(directory)
        let temporary = ".workflow-scratch-\(UUID().uuidString)"
        let descriptor = temporary.withCString {
            openat(
                directory.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw failure("scratch temp file: \(String(cString: strerror(errno)))")
        }
        var descriptorOpen = true
        var temporaryExists = true
        defer {
            if descriptorOpen { close(descriptor) }
            if temporaryExists {
                _ = temporary.withCString { unlinkat(directory.descriptor, $0, 0) }
            }
        }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #else
                let count = Glibc.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #endif
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("scratch write: \(String(cString: strerror(errno)))")
                }
                guard count > 0 else { throw failure("scratch write: zero-byte write") }
                offset += count
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw failure("scratch write: \(String(cString: strerror(errno)))")
        }
        close(descriptor)
        descriptorOpen = false

        try verifyDirectory(directory)
        try rejectUnsafeFile(named: name, in: directory, allowMissing: true)
        let replaced = temporary.withCString { source in
            name.withCString { destination in
                renameat(directory.descriptor, source, directory.descriptor, destination)
            }
        }
        guard replaced == 0 else {
            throw failure("scratch atomic persist: \(String(cString: strerror(errno)))")
        }
        temporaryExists = false
        guard fsync(directory.descriptor) == 0 else {
            throw failure("scratch atomic persist: \(String(cString: strerror(errno)))")
        }
        try verifyDirectory(directory)
    }

    private static func readBounded(
        named name: String,
        in directory: ScratchDirectory
    ) throws -> Data {
        try verifyDirectory(directory)
        let descriptor = name.withCString {
            openat(directory.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw failure("scratch read: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw failure("scratch read metadata: \(String(cString: strerror(errno)))")
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw failure("scratch path is not a regular file")
        }
        guard information.st_uid == geteuid(),
              information.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            throw failure("scratch file is not private to the current user")
        }
        guard information.st_size >= 0,
              UInt64(information.st_size) <= UInt64(maximumFileBytes)
        else {
            throw failure("scratch file exceeds \(maximumFileBytes) byte read limit")
        }

        var bytes = Data()
        bytes.reserveCapacity(min(Int(information.st_size), 64 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { storage in
                #if canImport(Darwin)
                Darwin.read(descriptor, storage.baseAddress, storage.count)
                #else
                Glibc.read(descriptor, storage.baseAddress, storage.count)
                #endif
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("scratch read: \(String(cString: strerror(errno)))")
            }
            if count == 0 { break }
            guard count <= maximumFileBytes - bytes.count else {
                throw failure("scratch file exceeds \(maximumFileBytes) byte read limit")
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        try verifyDirectory(directory)
        return bytes
    }
    #endif
}
