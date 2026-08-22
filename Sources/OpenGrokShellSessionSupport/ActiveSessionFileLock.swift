import Foundation
import OpenGrokFileUtils

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ActiveSessionFileLock: Sendable {
    let root: URL

    private var lockURL: URL {
        root.appendingPathComponent(ActiveSessionRegistry.lockFileName)
    }

    private var dataURL: URL {
        root.appendingPathComponent(ActiveSessionRegistry.dataFileName)
    }

    func read() throws -> [ActiveSessionRecord] {
        try withLock(persist: false) { $0 }
    }

    func modify<Value>(
        _ mutation: (inout [ActiveSessionRecord]) throws -> Value
    ) throws -> Value {
        try withLock(persist: true, mutation)
    }

    func tryModify<Value>(
        _ mutation: (inout [ActiveSessionRecord]) throws -> Value
    ) throws -> Value? {
        try ensureSecureRoot()
        guard let lock = try AdvisoryFileLock.tryAcquire(at: lockURL) else {
            return nil
        }
        defer { lock.release() }
        try SecureFile.ensureOwnerOnlyPermissions(at: lockURL)
        return try modifyLockedState(mutation)
    }

    private func withLock<Value>(
        persist: Bool,
        _ operation: (inout [ActiveSessionRecord]) throws -> Value
    ) throws -> Value {
        try ensureSecureRoot()
        let lock = try AdvisoryFileLock.acquire(at: lockURL)
        defer { lock.release() }
        try SecureFile.ensureOwnerOnlyPermissions(at: lockURL)

        if persist {
            return try modifyLockedState(operation)
        }
        var records = try readDataFile()
        return try operation(&records)
    }

    private func modifyLockedState<Value>(
        _ mutation: (inout [ActiveSessionRecord]) throws -> Value
    ) throws -> Value {
        var records = try readDataFile()
        let result = try mutation(&records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(records)
        try AtomicFile.write(
            dataURL,
            data: data,
            options: AtomicWriteOptions(
                mode: 0o600,
                syncFile: false,
                directorySync: .none,
                noFollowFinal: true
            )
        )
        return result
    }

    private func readDataFile() throws -> [ActiveSessionRecord] {
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            return []
        }
        let data = try PathSecurity.readNoFollow(dataURL)
        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([ActiveSessionRecord].self, from: data)
        } catch is DecodingError {
            return []
        }
    }

    private func ensureSecureRoot() throws {
        try PathSecurity.rejectHostileLexical(root.path)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        #if os(Windows)
        let attributes = root.path.withCString(encodedAs: UTF16.self) {
            GetFileAttributesW($0)
        }
        guard attributes != DWORD(INVALID_FILE_ATTRIBUTES),
              attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
        else {
            throw FileUtilsError.io(
                path: root.path,
                detail: "active-session root is not an accessible directory"
            )
        }
        let isSymlink = try PathSecurity.isSymlink(root)
        if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 || isSymlink {
            throw FileUtilsError.symlinkEncountered(path: root.path)
        }
        #elseif canImport(Darwin) || canImport(Glibc)
        var information = stat()
        guard root.path.withCString({ lstat($0, &information) }) == 0 else {
            throw FileUtilsError.io(
                path: root.path,
                detail: "inspect active-session directory: \(String(cString: strerror(errno)))"
            )
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              information.st_uid == geteuid()
        else {
            throw FileUtilsError.permissionDenied(
                path: root.path,
                detail: "active-session root must be an owned, non-symlink directory"
            )
        }
        if information.st_mode & 0o077 != 0,
           root.path.withCString({ chmod($0, mode_t(0o700)) }) != 0
        {
            throw FileUtilsError.permissionDenied(
                path: root.path,
                detail: "could not restrict active-session directory to its owner"
            )
        }
        #endif
    }
}

enum ActiveSessionProcessLiveness {
    static func isAlive(_ processID: UInt32) -> Bool {
        guard processID != 0 else { return false }

        #if os(Windows)
        if processID == UInt32(ProcessInfo.processInfo.processIdentifier) {
            return true
        }
        guard let handle = OpenProcess(
            DWORD(PROCESS_QUERY_LIMITED_INFORMATION),
            false,
            DWORD(processID)
        ), handle != INVALID_HANDLE_VALUE else {
            return GetLastError() == DWORD(ERROR_ACCESS_DENIED)
        }
        defer { CloseHandle(handle) }
        var exitCode: DWORD = 0
        guard GetExitCodeProcess(handle, &exitCode) else { return false }
        return exitCode == DWORD(STILL_ACTIVE)
        #elseif canImport(Darwin) || canImport(Glibc)
        guard let signedProcessID = Int32(exactly: processID), signedProcessID > 0 else {
            return false
        }
        if kill(pid_t(signedProcessID), 0) == 0 {
            return true
        }
        return errno == EPERM
        #else
        return true
        #endif
    }
}
