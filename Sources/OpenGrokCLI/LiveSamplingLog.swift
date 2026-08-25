import Foundation
import OpenGrokSampler
import OpenGrokSamplingTypes

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import COpenGrokSockets
import OpenGrokConfig
import OpenGrokFileUtils
import WinSDK
#endif

/// Explicitly enabled, owner-private operational diagnostics for one session.
///
/// Product telemetry and sampling diagnostics are separate upstream surfaces:
/// disabling ordinary telemetry does not disable this local, opt-in file.
/// Zero-data-retention and an administrator's explicit privacy denial do.
public final class LiveSamplingLog: @unchecked Sendable {
    public static let maximumBytes = 5 * 1_024 * 1_024

    private let lock = NSLock()
    private let byteLimit: Int

    #if canImport(Darwin) || canImport(Glibc)
    private let homeDescriptor: Int32
    private let directoryDescriptor: Int32
    private let fileDescriptor: Int32
    #elseif os(Windows)
    private let windowsHandles: WindowsHandles
    #endif

    /// Resolve only the supplied session environment; process-global values
    /// must never enable another session's private diagnostics.
    public static func makeIfEnabled(
        openGrokHome: URL,
        cliEnabled: Bool,
        environment: [String: String],
        zeroDataRetention: Bool = false,
        managedPrivacyBlocked: Bool = false
    ) throws -> LiveSamplingLog? {
        guard cliEnabled || ["1", "true", "on"].contains(environment["GROK_LOG_SAMPLING"] ?? "") else {
            return nil
        }
        guard !zeroDataRetention else {
            throw CLIApplicationError.failed(
                "sampling logging is prohibited by zero-data-retention policy"
            )
        }
        guard !managedPrivacyBlocked else {
            throw CLIApplicationError.failed(
                "sampling logging is prohibited by managed privacy policy"
            )
        }

        return try make(openGrokHome: openGrokHome, byteLimit: maximumBytes)
    }

    static func make(openGrokHome: URL, byteLimit: Int) throws -> LiveSamplingLog {
        let logger = try LiveSamplingLog(
            openGrokHome: openGrokHome,
            byteLimit: min(max(byteLimit, 1_024), maximumBytes)
        )
        try logger.enforceLimit(pendingBytes: 0)
        return logger
    }

    private init(openGrokHome: URL, byteLimit: Int) throws {
        self.byteLimit = byteLimit

        #if canImport(Darwin) || canImport(Glibc)
        let descriptors = try Self.openSecureDescriptors(openGrokHome: openGrokHome)
        self.homeDescriptor = descriptors.home
        self.directoryDescriptor = descriptors.directory
        self.fileDescriptor = descriptors.file
        #elseif os(Windows)
        self.windowsHandles = try Self.openWindowsHandles(openGrokHome: openGrokHome)
        #else
        throw CLIApplicationError.failed(
            "secure owner-private sampling logging is unavailable on this platform"
        )
        #endif
    }

    deinit {
        #if canImport(Darwin) || canImport(Glibc)
        close(fileDescriptor)
        close(directoryDescriptor)
        close(homeDescriptor)
        #elseif os(Windows)
        let fileClosed = og_file_handle_close(windowsHandles.rawFile)
        let directoryClosed = CloseHandle(windowsHandles.directory)
        let homeClosed = CloseHandle(windowsHandles.home)
        assert(fileClosed == 0 && directoryClosed && homeClosed)
        #endif
    }

    func begin(config: SamplerConfig, request: ConversationRequest, requestID: RequestId) throws
        -> LiveSamplingLogRequest
    {
        let authType: String
        if config.bearerResolver == nil && (config.apiKey?.isEmpty ?? true) {
            authType = "none"
        } else {
            authType = config.authScheme == .xApiKey ? "x-api-key" : "bearer"
        }

        // Reading a live resolver here changes which snapshot the real HTTP
        // request receives. A static credential's tail is safe only when it
        // is strictly shorter than the original; short keys are never logged.
        let authSuffix: String?
        if config.authScheme == .bearer,
           config.bearerResolver == nil,
           let credential = config.apiKey,
           credential.count > BEARER_SUFFIX_LEN {
            authSuffix = scrubbedBearerSuffix(credential)
        } else {
            authSuffix = nil
        }

        let scope = LiveSamplingLogRequest(
            logger: self,
            provider: config.provider.asString,
            backend: Self.backendName(config.apiBackend),
            model: Self.safeModel(config.model),
            requestSuffix: String(requestID.asString.suffix(8)),
            authType: authType,
            authSuffix: authSuffix,
            reasoningEffort: (request.reasoningEffort ?? config.reasoningEffort)?.asString,
            maxOutputTokens: request.maxOutputTokens ?? config.maxCompletionTokens
        )
        try scope.record(.requestStarted)
        return scope
    }

    fileprivate func record(_ entry: LiveSamplingLogEntry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = try encoder.encode(entry)
        encoded.append(0x0A)

        guard encoded.count <= byteLimit else {
            throw CLIApplicationError.failed("sampling log entry exceeds its secure size limit")
        }

        try lock.withLock {
            #if canImport(Darwin) || canImport(Glibc)
            guard flock(fileDescriptor, LOCK_EX) == 0 else {
                throw Self.failure("sampling log cannot acquire its private file lock")
            }
            defer { flock(fileDescriptor, LOCK_UN) }

            try validateDescriptors()
            try compactIfNeeded(pendingBytes: encoded.count)
            try Self.writeAll(encoded, descriptor: fileDescriptor)
            #elseif os(Windows)
            try withWindowsFileLock {
                try compactWindowsFileIfNeeded(pendingBytes: encoded.count)
                try Self.writeWindowsFile(encoded, handle: windowsHandles.rawFile)
                guard og_file_handle_flush(windowsHandles.rawFile) == 0 else {
                    throw Self.failure("sampling log cannot flush its private Windows file")
                }
            }
            #else
            throw Self.failure("secure sampling logging is unavailable on this platform")
            #endif
        }
    }

    private func enforceLimit(pendingBytes: Int) throws {
        try lock.withLock {
            #if canImport(Darwin) || canImport(Glibc)
            guard flock(fileDescriptor, LOCK_EX) == 0 else {
                throw Self.failure("sampling log cannot acquire its private file lock")
            }
            defer { flock(fileDescriptor, LOCK_UN) }
            try validateDescriptors()
            try compactIfNeeded(pendingBytes: pendingBytes)
            #elseif os(Windows)
            try withWindowsFileLock {
                try compactWindowsFileIfNeeded(pendingBytes: pendingBytes)
                guard og_file_handle_flush(windowsHandles.rawFile) == 0 else {
                    throw Self.failure("sampling log cannot flush its bounded Windows file")
                }
            }
            #endif
        }
    }

    private static func backendName(_ backend: ApiBackend) -> String {
        switch backend {
        case .chatCompletions: return "chat_completions"
        case .responses: return "responses"
        case .messages: return "messages"
        }
    }

    private static func safeModel(_ model: String) -> String {
        let bytes = Array(model.utf8)
        guard !bytes.isEmpty, bytes.count <= 96,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...90).contains(byte)
                      || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 47 || byte == 95
              })
        else { return "redacted" }
        return model
    }

    private static func failure(_ message: String) -> CLIApplicationError {
        .failed(message)
    }

    #if os(Windows)
    private struct WindowsHandles {
        let home: HANDLE
        let directory: HANDLE
        let file: HANDLE
        let rawFile: OGSocketHandle
        let homeURL: URL
        let directoryURL: URL
        let fileURL: URL
        let lockURL: URL
    }

    private static func openWindowsHandles(openGrokHome: URL) throws -> WindowsHandles {
        guard openGrokHome.isFileURL else {
            throw failure("sampling log requires an absolute owner-controlled state directory")
        }
        let homeURL = openGrokHome.standardizedFileURL
        let homeNative = try WindowsSecurePath.extendedLengthPath(homeURL.path)
        try OpenGrokConfig.createDirAllOwnerOnly(homeURL, stateRoot: homeURL)
        guard homeNative.withCString({ og_path_is_private_to_current_user($0, 1) }) == 1 else {
            throw failure("sampling log owner state directory lacks an owner-private DACL")
        }
        let home = try openWindowsPath(homeURL, directory: true)

        do {
            let directoryURL = homeURL.appendingPathComponent("logs", isDirectory: true)
            try OpenGrokConfig.createDirAllOwnerOnly(directoryURL, stateRoot: homeURL)
            let directory = try openWindowsPath(directoryURL, directory: true)

            do {
                let fileURL = directoryURL.appendingPathComponent("sampling.jsonl")
                try validateExistingWindowsFile(fileURL)
                let native = try WindowsSecurePath.extendedLengthPath(fileURL.path)
                var rawFile: OGSocketHandle = -1
                guard native.withCString({ og_file_open_owner_only_lock($0, 1, &rawFile) }) == 0,
                      let file = HANDLE(bitPattern: Int(rawFile)),
                      file != INVALID_HANDLE_VALUE
                else {
                    if rawFile != -1 { og_file_handle_close(rawFile) }
                    throw failure("sampling log file cannot be opened with an owner-private DACL")
                }

                do {
                    try windowsInformation(file, directory: false)
                    return WindowsHandles(
                        home: home,
                        directory: directory,
                        file: file,
                        rawFile: rawFile,
                        homeURL: homeURL,
                        directoryURL: directoryURL,
                        fileURL: fileURL,
                        lockURL: directoryURL.appendingPathComponent("sampling.jsonl.lock")
                    )
                } catch {
                    og_file_handle_close(rawFile)
                    throw error
                }
            } catch {
                CloseHandle(directory)
                throw error
            }
        } catch {
            CloseHandle(home)
            throw error
        }
    }

    private static func openWindowsPath(_ url: URL, directory: Bool) throws -> HANDLE {
        let native = try WindowsSecurePath.extendedLengthPath(url.path)
        var flags = DWORD(FILE_FLAG_OPEN_REPARSE_POINT)
        if directory { flags |= DWORD(FILE_FLAG_BACKUP_SEMANTICS) }
        let raw = native.withCString(encodedAs: UTF16.self) { path in
            CreateFileW(
                path,
                DWORD(FILE_READ_ATTRIBUTES) | DWORD(READ_CONTROL),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_EXISTING),
                flags,
                nil
            )
        }
        guard let handle = raw, handle != INVALID_HANDLE_VALUE else {
            throw failure("sampling log cannot open its owner-private Windows path without following reparse points")
        }
        do {
            try windowsInformation(handle, directory: directory)
            return handle
        } catch {
            CloseHandle(handle)
            throw error
        }
    }

    @discardableResult
    private static func windowsInformation(
        _ handle: HANDLE,
        directory: Bool
    ) throws -> BY_HANDLE_FILE_INFORMATION {
        var information = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &information) else {
            throw failure("sampling log cannot inspect its pinned Windows file identity")
        }
        let attributes = information.dwFileAttributes
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0,
              (attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0) == directory,
              information.nFileIndexHigh != 0 || information.nFileIndexLow != 0,
              directory || information.nNumberOfLinks == 1
        else {
            throw failure("sampling log contains a reparse point, hard link, or unverifiable file identity")
        }
        let raw = OGSocketHandle(Int(bitPattern: handle))
        guard og_file_handle_is_private_to_current_user(raw, directory ? 1 : 0) == 1 else {
            throw failure("sampling log object is not private to the current Windows user")
        }
        return information
    }

    private static func validateExistingWindowsFile(_ url: URL) throws {
        guard try WindowsSecurePath.metadata(at: url) != nil else { return }
        let handle = try openWindowsPath(url, directory: false)
        defer { CloseHandle(handle) }
    }

    private func withWindowsFileLock(_ operation: () throws -> Void) throws {
        try Self.validateExistingWindowsFile(windowsHandles.lockURL)
        let held = try AdvisoryFileLock.acquire(
            at: windowsHandles.lockURL,
            options: AdvisoryLockOptions(nonBlocking: false, create: true, mode: 0o600)
        )
        defer { held.release() }
        try Self.validateExistingWindowsFile(windowsHandles.lockURL)
        try validateWindowsHandles()
        try operation()
    }

    private func validateWindowsHandles() throws {
        for (path, pinned, directory) in [
            (windowsHandles.homeURL, windowsHandles.home, true),
            (windowsHandles.directoryURL, windowsHandles.directory, true),
            (windowsHandles.fileURL, windowsHandles.file, false),
        ] {
            let attached = try Self.openWindowsPath(path, directory: directory)
            defer { CloseHandle(attached) }
            let original = try Self.windowsInformation(pinned, directory: directory)
            let current = try Self.windowsInformation(attached, directory: directory)
            guard original.dwVolumeSerialNumber == current.dwVolumeSerialNumber,
                  original.nFileIndexHigh == current.nFileIndexHigh,
                  original.nFileIndexLow == current.nFileIndexLow
            else {
                throw Self.failure("sampling log owner state, directory, or file changed after secure initialization")
            }
        }
    }

    private func compactWindowsFileIfNeeded(pendingBytes: Int) throws {
        let information = try Self.windowsInformation(windowsHandles.file, directory: false)
        let currentSize = (UInt64(information.nFileSizeHigh) << 32)
            | UInt64(information.nFileSizeLow)
        let maximum = UInt64(byteLimit - pendingBytes)
        guard currentSize > maximum else {
            try Self.seekWindowsFile(windowsHandles.file, offset: currentSize)
            return
        }

        let desiredTail = min(currentSize, UInt64(max(0, byteLimit / 2 - pendingBytes)))
        var retained = Data(count: Int(desiredTail))
        if desiredTail > 0 {
            try Self.seekWindowsFile(windowsHandles.file, offset: currentSize - desiredTail)
            var bytesRead: DWORD = 0
            let read = retained.withUnsafeMutableBytes { buffer in
                ReadFile(
                    windowsHandles.file,
                    buffer.baseAddress,
                    DWORD(buffer.count),
                    &bytesRead,
                    nil
                )
            }
            guard read else {
                throw Self.failure("sampling log cannot read its bounded private Windows tail")
            }
            retained.count = Int(bytesRead)
            if currentSize > desiredTail {
                if let newline = retained.firstIndex(of: 0x0A) {
                    retained.removeSubrange(...newline)
                } else {
                    retained.removeAll(keepingCapacity: false)
                }
            }
        }

        try Self.seekWindowsFile(windowsHandles.file, offset: 0)
        guard SetEndOfFile(windowsHandles.file) else {
            throw Self.failure("sampling log cannot enforce its private Windows size limit")
        }
        if !retained.isEmpty {
            try Self.writeWindowsFile(retained, handle: windowsHandles.rawFile)
        }
    }

    private static func seekWindowsFile(_ handle: HANDLE, offset: UInt64) throws {
        guard offset <= UInt64(Int64.max) else {
            throw failure("sampling log Windows file offset exceeds its supported range")
        }
        var high = LONG(truncatingIfNeeded: offset >> 32)
        let low = LONG(bitPattern: UInt32(truncatingIfNeeded: offset))
        SetLastError(DWORD(ERROR_SUCCESS))
        let position = SetFilePointer(handle, low, &high, DWORD(FILE_BEGIN))
        guard position != DWORD.max || GetLastError() == DWORD(ERROR_SUCCESS) else {
            throw failure("sampling log cannot seek its pinned private Windows file")
        }
    }

    private static func writeWindowsFile(_ data: Data, handle: OGSocketHandle) throws {
        let written = data.withUnsafeBytes { bytes in
            og_file_handle_write_all(handle, bytes.baseAddress, bytes.count)
        }
        guard written == Int64(data.count) else {
            throw failure("sampling log could not append to its private Windows file")
        }
    }
    #endif

    #if canImport(Darwin) || canImport(Glibc)
    private struct Descriptors {
        let home: Int32
        let directory: Int32
        let file: Int32
    }

    private static func openSecureDescriptors(openGrokHome: URL) throws -> Descriptors {
        guard openGrokHome.isFileURL, openGrokHome.path.hasPrefix("/") else {
            throw failure("sampling log requires an absolute owner-controlled state directory")
        }
        let components = openGrokHome.path.split(separator: "/")
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." })
        else {
            throw failure("sampling log owner state directory contains an unsafe path")
        }

        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var home = open("/", directoryFlags)
        guard home >= 0 else {
            throw failure("sampling log owner state directory cannot be opened securely")
        }

        do {
            for (offset, component) in components.enumerated() {
                var next = component.withCString { openat(home, $0, directoryFlags) }
                if next < 0, errno == ENOENT {
                    let created = component.withCString { mkdirat(home, $0, mode_t(0o700)) }
                    guard created == 0 || errno == EEXIST else {
                        throw failure("sampling log owner state directory cannot be created securely")
                    }
                    next = component.withCString { openat(home, $0, directoryFlags) }
                }
                guard next >= 0 else {
                    throw failure("sampling log owner state directory contains a symbolic link or unsafe component")
                }

                var information = stat()
                guard fstat(next, &information) == 0,
                      information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
                else {
                    close(next)
                    throw failure("sampling log owner state directory contains an invalid component")
                }
                if offset == components.count - 1, information.st_uid != geteuid() {
                    close(next)
                    throw failure("sampling log owner state directory belongs to another owner")
                }
                close(home)
                home = next
            }

            var directory = openat(home, "logs", directoryFlags)
            if directory < 0, errno == ENOENT {
                let created = mkdirat(home, "logs", mode_t(0o700))
                guard created == 0 || errno == EEXIST else {
                    throw failure("sampling log directory cannot be created securely")
                }
                directory = openat(home, "logs", directoryFlags)
            }
            guard directory >= 0 else {
                throw failure("sampling log directory must not be a symbolic link")
            }

            do {
                try validateDirectory(directory)
                let file = openat(
                    directory,
                    "sampling.jsonl",
                    O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
                guard file >= 0 else {
                    throw failure("sampling log file cannot be opened without following symbolic links")
                }
                do {
                    try validateFile(file)
                    return Descriptors(home: home, directory: directory, file: file)
                } catch {
                    close(file)
                    throw error
                }
            } catch {
                close(directory)
                throw error
            }
        } catch {
            close(home)
            throw error
        }
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              information.st_uid == geteuid(),
              information.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw failure("sampling log directory must be owner-controlled with mode 0700")
        }
    }

    private static func validateFile(_ descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            throw failure("sampling log file must be an unlinked owner-private regular file with mode 0600")
        }
    }

    private func validateDescriptors() throws {
        try Self.validateDirectory(directoryDescriptor)
        try Self.validateFile(fileDescriptor)

        var attachedDirectory = stat()
        var openDirectory = stat()
        guard fstatat(homeDescriptor, "logs", &attachedDirectory, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(directoryDescriptor, &openDirectory) == 0,
              attachedDirectory.st_dev == openDirectory.st_dev,
              attachedDirectory.st_ino == openDirectory.st_ino
        else {
            throw Self.failure("sampling log directory changed after secure initialization")
        }

        var attachedFile = stat()
        var openFile = stat()
        guard fstatat(directoryDescriptor, "sampling.jsonl", &attachedFile, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(fileDescriptor, &openFile) == 0,
              attachedFile.st_dev == openFile.st_dev,
              attachedFile.st_ino == openFile.st_ino,
              attachedFile.st_nlink == 1
        else {
            throw Self.failure("sampling log file changed or gained a hard link")
        }
    }

    private func compactIfNeeded(pendingBytes: Int) throws {
        var information = stat()
        guard fstat(fileDescriptor, &information) == 0, information.st_size >= 0 else {
            throw Self.failure("sampling log file size cannot be inspected securely")
        }
        guard information.st_size > off_t(byteLimit - pendingBytes) else { return }

        let currentSize = Int(clamping: information.st_size)
        let desiredTail = min(currentSize, max(0, byteLimit / 2 - pendingBytes))
        var retained = Data(count: desiredTail)
        if desiredTail > 0 {
            let bytesRead = retained.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return pread(fileDescriptor, base, buffer.count, off_t(currentSize - desiredTail))
            }
            guard bytesRead >= 0 else {
                throw Self.failure("sampling log cannot read its bounded private tail")
            }
            retained.count = bytesRead
            if currentSize > desiredTail {
                if let newline = retained.firstIndex(of: 0x0A) {
                    retained.removeSubrange(...newline)
                } else {
                    retained.removeAll(keepingCapacity: false)
                }
            }
        }

        guard ftruncate(fileDescriptor, 0) == 0 else {
            throw Self.failure("sampling log cannot enforce its private size limit")
        }
        if !retained.isEmpty {
            try Self.writeAll(retained, descriptor: fileDescriptor)
        }
    }

    private static func writeAll(_ bytes: Data, descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw failure("sampling log could not append to its private file")
                }
                offset += count
            }
        }
    }
    #endif
}

enum LiveSamplingLogEvent: String, Codable, Sendable {
    case requestStarted = "request_started"
    case streamStarted = "stream_started"
    case firstToken = "first_token"
    case responseStarted = "response_started"
    case retry
    case completed
    case failed
    case cancelled
}

struct LiveSamplingLogEntry: Codable, Sendable {
    var timestampMS: Int64
    var event: LiveSamplingLogEvent
    var provider: String
    var backend: String
    var model: String
    var requestSuffix: String
    var authType: String?
    var authSuffix: String?
    var reasoningEffort: String?
    var maxOutputTokens: UInt32?
    var attempt: UInt32?
    var maxRetries: UInt32?
    var errorKind: String?
    var statusCode: UInt16?
    var inputTokens: UInt64?
    var outputTokens: UInt64?
    var reasoningTokens: UInt64?
    var chunkCount: UInt32?
    var durationMS: UInt64?
    var timeToFirstTokenMS: UInt64?

    enum CodingKeys: String, CodingKey {
        case timestampMS = "timestamp_ms"
        case event
        case provider
        case backend
        case model
        case requestSuffix = "request_suffix"
        case authType = "auth_type"
        case authSuffix = "auth_suffix"
        case reasoningEffort = "reasoning_effort"
        case maxOutputTokens = "max_output_tokens"
        case attempt
        case maxRetries = "max_retries"
        case errorKind = "error_kind"
        case statusCode = "status_code"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case reasoningTokens = "reasoning_tokens"
        case chunkCount = "chunk_count"
        case durationMS = "duration_ms"
        case timeToFirstTokenMS = "time_to_first_token_ms"
    }
}

final class LiveSamplingLogRequest: @unchecked Sendable {
    private let logger: LiveSamplingLog
    private let provider: String
    private let backend: String
    private let model: String
    private let requestSuffix: String
    private let authType: String
    private let authSuffix: String?
    private let reasoningEffort: String?
    private let maxOutputTokens: UInt32?
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var isTerminal = false

    init(
        logger: LiveSamplingLog,
        provider: String,
        backend: String,
        model: String,
        requestSuffix: String,
        authType: String,
        authSuffix: String?,
        reasoningEffort: String?,
        maxOutputTokens: UInt32?
    ) {
        self.logger = logger
        self.provider = provider
        self.backend = backend
        self.model = model
        self.requestSuffix = requestSuffix
        self.authType = authType
        self.authSuffix = authSuffix
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
    }

    func observe(_ event: SamplingEvent) throws {
        switch event {
        case .streamStarted:
            try record(.streamStarted)
        case .firstToken:
            try record(.firstToken)
        case .responseStarted(_, _, _, let inputTokens, _, _):
            try record(.responseStarted, inputTokens: inputTokens)
        case .retrying(_, let attempt, let maxRetries, let kind, _, _, _):
            try record(.retry, attempt: attempt, maxRetries: maxRetries, errorKind: kind.asString)
        case .completed(_, let response, let metrics):
            try record(
                .completed,
                attempt: metrics.attempts,
                inputTokens: response.usage.map { UInt64($0.promptTokens) },
                outputTokens: response.usage.map { UInt64($0.completionTokens) },
                reasoningTokens: response.usage.map { UInt64($0.reasoningTokens) },
                chunkCount: metrics.chunkCount,
                durationMS: metrics.timeToLastByteMs,
                timeToFirstTokenMS: metrics.timeToFirstTokenMs,
                terminal: true
            )
        case .failed(_, let error):
            try record(
                .failed,
                errorKind: error.kind.asString,
                statusCode: error.statusCode,
                terminal: true
            )
        default:
            break
        }
    }

    func cancel() {
        do {
            try record(.cancelled, terminal: true)
        } catch {
            // Cancellation must still tear down the sampler if an attacker
            // replaced its log file; descriptor validation already prevented
            // the unsafe write, and this handler cannot throw.
        }
    }

    func failUnexpectedly() throws {
        try record(.failed, errorKind: SamplingErrorKind.http.asString, terminal: true)
    }

    func record(
        _ event: LiveSamplingLogEvent,
        attempt: UInt32? = nil,
        maxRetries: UInt32? = nil,
        errorKind: String? = nil,
        statusCode: UInt16? = nil,
        inputTokens: UInt64? = nil,
        outputTokens: UInt64? = nil,
        reasoningTokens: UInt64? = nil,
        chunkCount: UInt32? = nil,
        durationMS: UInt64? = nil,
        timeToFirstTokenMS: UInt64? = nil,
        terminal: Bool = false
    ) throws {
        try lock.withLock {
            guard !isTerminal else { return }
            let elapsed = (DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000
            let entry = LiveSamplingLogEntry(
                timestampMS: Int64(Date().timeIntervalSince1970 * 1_000),
                event: event,
                provider: provider,
                backend: backend,
                model: model,
                requestSuffix: requestSuffix,
                authType: event == .requestStarted ? authType : nil,
                authSuffix: event == .requestStarted ? authSuffix : nil,
                reasoningEffort: event == .requestStarted ? reasoningEffort : nil,
                maxOutputTokens: event == .requestStarted ? maxOutputTokens : nil,
                attempt: attempt,
                maxRetries: maxRetries,
                errorKind: errorKind,
                statusCode: statusCode,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                chunkCount: chunkCount,
                durationMS: durationMS ?? (terminal ? elapsed : nil),
                timeToFirstTokenMS: timeToFirstTokenMS
            )
            try logger.record(entry)
            if terminal { isTerminal = true }
        }
    }
}
