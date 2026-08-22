// OpenGrokCrashHandler.swift
//
// Crash-report capture and redaction port of `xai-crash-handler`.
//
// - Binary crash blob format "GCRX" (signal-handler safe layout)
// - Startup `checkPreviousCrash` + owner-only report write under OPENGROK_HOME
// - Terminal restore sequences for signal-handler / panic paths
// - Install registers SIGBUS/SIGSEGV/SIGABRT via a C sigaction + alternate-stack shim
//   that only performs async-signal-safe ops and never touches session journals
//   (SIGABRT matters because release builds use `panic = "abort"`; Windows abort
//   does not route through SetUnhandledExceptionFilter, so SIGABRT is Unix-only:
//   handler.rs:1-8, lib.rs:1-8, handler.rs:306-308 at pin 650c1db7).
// - Report redaction delegates to `xai-grok-secrets` canonical 10-pattern
//   sanitizer (sanitizer.rs at pin 650c1db7) via `OpenGrokSecrets.SecretSanitizer`
//
// Platform seams:
//   - Unix: C shim (sigaction SA_SIGINFO|SA_ONSTACK|SA_RESETHAND + alt stack)
//   - Windows: SetUnhandledExceptionFilter when available

import Foundation
import OpenGrokCrashHandlerC
import OpenGrokSecrets

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Errors

/// Crash-handler errors.
public enum CrashHandlerError: Error, Equatable, Sendable {
    case installFailed(String)
    case unsupported(String)
    case writeFailed(String)
}

// MARK: - Public report types

/// A redacted, session-safe crash report (high-level API).
public struct CrashReport: Sendable, Equatable {
    public var summary: String
    public var redactedBacktrace: [String]
    public var openGrokHomeRelativePath: String
    public var signalName: String?
    public var appVersion: String?
    public var timestamp: UInt64?

    public init(
        summary: String,
        redactedBacktrace: [String],
        openGrokHomeRelativePath: String,
        signalName: String? = nil,
        appVersion: String? = nil,
        timestamp: UInt64? = nil
    ) {
        self.summary = summary
        self.redactedBacktrace = redactedBacktrace
        self.openGrokHomeRelativePath = openGrokHomeRelativePath
        self.signalName = signalName
        self.appVersion = appVersion
        self.timestamp = timestamp
    }
}

/// Configuration for the crash handler.
public struct CrashHandlerConfig: Sendable {
    public var appVersion: String
    public var crashDir: URL

    public init(appVersion: String, crashDir: URL) {
        self.appVersion = appVersion
        self.crashDir = crashDir
    }
}

/// Resolved backtrace frame (best-effort symbolication).
public struct ResolvedFrame: Sendable, Equatable {
    public var ip: UInt64
    public var symbolName: String?
    public var filename: String?
    public var lineNumber: UInt32?

    public init(ip: UInt64, symbolName: String? = nil, filename: String? = nil, lineNumber: UInt32? = nil) {
        self.ip = ip
        self.symbolName = symbolName
        self.filename = filename
        self.lineNumber = lineNumber
    }
}

/// Parsed previous-session crash (mirrors Rust `CrashReport`).
public struct PreviousCrashReport: Sendable, Equatable {
    public var signalName: String
    public var siCode: Int32
    public var faultingAddress: UInt64
    public var timestamp: UInt64
    public var appVersion: String
    public var backtrace: [ResolvedFrame]
    public var reportPath: URL
}

// MARK: - GCRX binary format

/// Binary crash blob format ("GCRX").
public enum CrashBlobFormat {
    public static let magic: [UInt8] = [0x47, 0x43, 0x52, 0x58] // GCRX
    public static let version: UInt8 = 1
    public static let maxFrames = 64
    public static let versionStringLength = 32
    /// magic(4)+version(1)+signal(1)+si_code(4)+si_addr(8)+pid(4)+timestamp(8)+n_frames(2)+app_version(32)
    public static let headerSize = 4 + 1 + 1 + 4 + 8 + 4 + 8 + 2 + versionStringLength
    public static let maxFileSize = headerSize + maxFrames * 8
}

/// Parsed crash data from a `last-crash.bin` file.
public struct CrashBlob: Sendable, Equatable {
    public var signal: UInt8
    public var siCode: Int32
    public var siAddr: UInt64
    public var pid: UInt32
    public var timestamp: UInt64
    public var frames: [UInt64]
    public var appVersion: String

    public init(
        signal: UInt8,
        siCode: Int32,
        siAddr: UInt64,
        pid: UInt32,
        timestamp: UInt64,
        frames: [UInt64],
        appVersion: String
    ) {
        self.signal = signal
        self.siCode = siCode
        self.siAddr = siAddr
        self.pid = pid
        self.timestamp = timestamp
        self.frames = frames
        self.appVersion = appVersion
    }

    /// Parse a crash blob from bytes. Returns `nil` if the data is invalid.
    public static func parse(_ data: Data) -> CrashBlob? {
        let headerSize = CrashBlobFormat.headerSize
        guard data.count >= headerSize else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == CrashBlobFormat.magic else { return nil }
        guard bytes[4] == CrashBlobFormat.version else { return nil }

        let signal = bytes[5]
        let siCode = Int32(littleEndian: readI32(bytes, 6))
        let siAddr = UInt64(littleEndian: readU64(bytes, 10))
        let pid = UInt32(littleEndian: readU32(bytes, 18))
        let timestamp = UInt64(littleEndian: readU64(bytes, 22))
        let nFrames = Int(UInt16(littleEndian: readU16(bytes, 30)))

        let versionBytes = Array(bytes[32..<(32 + CrashBlobFormat.versionStringLength)])
        let appVersion = String(bytes: versionBytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""

        guard nFrames <= CrashBlobFormat.maxFrames else { return nil }
        let framesStart = headerSize
        let framesEnd = framesStart + nFrames * 8
        guard bytes.count >= framesEnd else { return nil }

        var frames: [UInt64] = []
        frames.reserveCapacity(nFrames)
        for i in 0..<nFrames {
            let offset = framesStart + i * 8
            frames.append(UInt64(littleEndian: readU64(bytes, offset)))
        }

        return CrashBlob(
            signal: signal,
            siCode: siCode,
            siAddr: siAddr,
            pid: pid,
            timestamp: timestamp,
            frames: frames,
            appVersion: appVersion
        )
    }

    /// Serialize to GCRX bytes (normal-context writer; signal handler uses a
    /// static buffer variant in the C shim).
    public func serialize() -> Data {
        var buf = [UInt8](repeating: 0, count: CrashBlobFormat.headerSize + frames.count * 8)
        buf[0..<4] = CrashBlobFormat.magic[0..<4]
        buf[4] = CrashBlobFormat.version
        buf[5] = signal
        writeI32(&buf, 6, siCode)
        writeU64(&buf, 10, siAddr)
        writeU32(&buf, 18, pid)
        writeU64(&buf, 22, timestamp)
        writeU16(&buf, 30, UInt16(frames.count))
        let versionData = Array(appVersion.utf8.prefix(CrashBlobFormat.versionStringLength))
        for (i, b) in versionData.enumerated() {
            buf[32 + i] = b
        }
        for (i, frame) in frames.enumerated() {
            writeU64(&buf, CrashBlobFormat.headerSize + i * 8, frame)
        }
        return Data(buf)
    }
}

// MARK: - Little-endian helpers

private func readU16(_ b: [UInt8], _ o: Int) -> UInt16 {
    UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
}
private func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}
private func readI32(_ b: [UInt8], _ o: Int) -> Int32 {
    Int32(bitPattern: readU32(b, o))
}
private func readU64(_ b: [UInt8], _ o: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 {
        v |= UInt64(b[o + i]) << (8 * i)
    }
    return v
}
private func writeU16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
    let le = v.littleEndian
    b[o] = UInt8(le & 0xff)
    b[o + 1] = UInt8((le >> 8) & 0xff)
}
private func writeU32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    let le = v.littleEndian
    for i in 0..<4 { b[o + i] = UInt8((le >> (8 * i)) & 0xff) }
}
private func writeI32(_ b: inout [UInt8], _ o: Int, _ v: Int32) {
    writeU32(&b, o, UInt32(bitPattern: v))
}
private func writeU64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
    let le = v.littleEndian
    for i in 0..<8 { b[o + i] = UInt8((le >> (8 * i)) & 0xff) }
}

// MARK: - Symbol / report formatting

/// Human-readable signal name — mirrors `xai-crash-handler/src/symbolicate.rs:signal_name` at pin 650c1db7.
public func signalName(_ sig: UInt8) -> String {
    switch Int32(sig) {
    case 4: return "SIGILL (Illegal instruction)"
    case 6: return "SIGABRT (Abort)"
    case 7, 10: return "SIGBUS (Bus error)"
    case 11: return "SIGSEGV (Segmentation fault)"
    default: return "Unknown signal"
    }
}

public func siCodeName(signal: UInt8, code: Int32) -> String {
    // SIGABRT is raised by abort() (panic=abort) — no fault si_code (symbolicate.rs:94-99).
    if signal == 6 {
        return "abort() - raised by the process (e.g. Rust panic with panic=abort)"
    }
    let isBus = signal == 7 || signal == 10
    if isBus {
        switch code {
        case 1: return "BUS_ADRALN - invalid address alignment"
        case 2: return "BUS_ADRERR - non-existent physical address"
        case 3: return "BUS_OBJERR - object-specific hardware error"
        default: return "unknown"
        }
    } else {
        switch code {
        case 1: return "SEGV_MAPERR - address not mapped"
        case 2: return "SEGV_ACCERR - invalid permissions"
        default: return "unknown"
        }
    }
}

/// Best-effort resolve (addresses only; full symbolication needs debug info).
public func resolveFrames(_ blob: CrashBlob) -> [ResolvedFrame] {
    blob.frames.map { ResolvedFrame(ip: $0) }
}

/// Format a crash report as human-readable text. Redacts home-directory paths
/// and common secret-looking tokens.
public func formatReport(blob: CrashBlob, frames: [ResolvedFrame]) -> String {
    var out = "=== Open Grok Crash Report ===\n\n"
    out += "Signal:  \(signalName(blob.signal))\n"
    out += "si_code: \(blob.siCode) (\(siCodeName(signal: blob.signal, code: blob.siCode)))\n"
    out += String(format: "Address: 0x%016llx\n", blob.siAddr)
    out += "PID:     \(blob.pid)\n"
    out += "Version: \(redactSecrets(blob.appVersion))\n"
    out += "Time:    \(blob.timestamp) (unix)\n"
    out += "\nBacktrace (\(frames.count) frames):\n"
    for (i, frame) in frames.enumerated() {
        let name = frame.symbolName.map(redactSecrets) ?? "<unknown>"
        out += String(format: "  %3d: 0x%016llx - %@\n", i, frame.ip, name)
        if let file = frame.filename, let line = frame.lineNumber {
            out += "           at \(redactPath(file)):\(line)\n"
        }
    }
    out += "\n=== End Report ===\n"
    return out
}

/// Redact common secret patterns from crash text.
///
/// Delegates to the canonical `xai-grok-secrets` 10-pattern sanitizer
/// (`sanitizer.rs` at pin 650c1db7) via `SecretSanitizer.redactSecrets`.
/// Kept as a free function so call sites (`formatReport`, `PlatformCrashHandler.record`,
/// tests) remain source-compatible — the caller-visible marker stays
/// `SecretRedaction.secret` == `[REDACTED_SECRET]`.
public func redactSecrets(_ text: String) -> String {
    SecretSanitizer.redactSecrets(text)
}

/// Redact absolute home-directory paths.
public func redactPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
        return "$HOME" + path.dropFirst(home.count)
    }
    if let og = ProcessInfo.processInfo.environment["OPENGROK_HOME"], path.hasPrefix(og) {
        return "$OPENGROK_HOME" + path.dropFirst(og.count)
    }
    return path
}

// MARK: - Owner-only write

/// Write contents with owner-only permissions when the platform allows it.
public func writeOwnerOnly(path: URL, contents: Data) throws {
    #if os(macOS) || os(Linux)
    let fd = open(
        path.path,
        O_WRONLY | O_CREAT | O_TRUNC,
        0o600
    )
    guard fd >= 0 else {
        throw CrashHandlerError.writeFailed("open failed: \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }
    _ = fchmod(fd, 0o600)
    let written = contents.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return 0 }
        return write(fd, base, raw.count)
    }
    guard written == contents.count else {
        throw CrashHandlerError.writeFailed("short write")
    }
    #else
    try contents.write(to: path, options: .atomic)
    #endif
}

// MARK: - Path isolation under OPENGROK_HOME

/// Lexical + descriptor-relative containment for crash report paths.
///
/// Guarantees:
/// - Reject absolute paths, NUL bytes, empty components, and `..`
/// - Resolve `openGrokHome` via `realpath` (system intermediate symlinks OK)
/// - Create/open each relative component with `O_NOFOLLOW` so a malicious
///   `crash` → outside symlink cannot redirect the report
public enum CrashPathIsolation {
    /// Split a relative path into non-empty components; throw on hostile form.
    public static func relativeComponents(_ relative: String) throws -> [String] {
        if relative.isEmpty {
            throw CrashHandlerError.writeFailed("empty relative path")
        }
        if relative.contains("\0") {
            throw CrashHandlerError.writeFailed("NUL in relative path")
        }
        if relative.hasPrefix("/") || relative.hasPrefix("\\") {
            throw CrashHandlerError.writeFailed("absolute path rejected: \(relative)")
        }
        // Reject drive-letter absolute forms.
        if relative.count >= 2, relative[relative.index(relative.startIndex, offsetBy: 1)] == ":" {
            throw CrashHandlerError.writeFailed("absolute path rejected: \(relative)")
        }
        let parts = relative.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !parts.isEmpty else {
            throw CrashHandlerError.writeFailed("empty relative path")
        }
        for part in parts {
            if part == ".." || part == "." {
                throw CrashHandlerError.writeFailed("path traversal component: \(relative)")
            }
            if part.isEmpty {
                throw CrashHandlerError.writeFailed("empty path component: \(relative)")
            }
        }
        return parts
    }

    /// Canonicalize an existing directory via `realpath`.
    public static func canonicalizeDirectory(_ url: URL) throws -> String {
        #if os(macOS) || os(Linux)
        let resolved = url.path.withCString { cstr -> String? in
            guard let buf = realpath(cstr, nil) else { return nil }
            defer { free(buf) }
            return String(cString: buf)
        }
        guard let resolved else {
            throw CrashHandlerError.writeFailed(
                "realpath(\(url.path)) failed: \(String(cString: strerror(errno)))"
            )
        }
        return resolved
        #else
        return url.standardizedFileURL.path
        #endif
    }

    #if os(macOS) || os(Linux)
    /// Ensure `openGrokHome` exists, canonicalize it, then create/open a file
    /// at `relative` with no-follow semantics. Returns the owned FD.
    public static func openWriteNoFollow(
        openGrokHome: URL,
        relative: String,
        mode: mode_t = 0o600
    ) throws -> (fd: Int32, absolutePath: String) {
        let parts = try relativeComponents(relative)
        try FileManager.default.createDirectory(
            at: openGrokHome,
            withIntermediateDirectories: true
        )
        let homeCanon = try canonicalizeDirectory(openGrokHome)

        var flags: Int32 = O_RDONLY | O_DIRECTORY
        #if os(macOS)
        flags |= O_CLOEXEC
        #endif
        let homeFD = homeCanon.withCString { open($0, flags) }
        guard homeFD >= 0 else {
            throw CrashHandlerError.writeFailed(
                "open home failed: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(homeFD) }

        // Verify the opened home still maps under the canonical root (TOCTOU).
        var homePathBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        #if os(macOS)
        if fcntl(homeFD, F_GETPATH, &homePathBuf) == 0 {
            let opened = String(cString: homePathBuf)
            if opened != homeCanon && !opened.hasPrefix(homeCanon + "/") {
                throw CrashHandlerError.writeFailed("home escaped after open: \(opened)")
            }
        }
        #endif

        var dirFD = homeFD
        var closeDir = false
        defer {
            if closeDir { close(dirFD) }
        }

        // Walk intermediate directories with O_NOFOLLOW so a symlink component
        // cannot redirect the write outside OPENGROK_HOME.
        for (idx, component) in parts.enumerated() {
            let isLast = idx == parts.count - 1
            if isLast {
                var fileFlags: Int32 = O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW
                #if os(macOS)
                fileFlags |= O_CLOEXEC
                #endif
                let fd = component.withCString { openat(dirFD, $0, fileFlags, mode) }
                guard fd >= 0 else {
                    let err = errno
                    if err == ELOOP || err == EEXIST {
                        // EEXIST with O_NOFOLLOW typically means a symlink is present.
                        throw CrashHandlerError.writeFailed(
                            "symlink or hostile final component rejected: \(relative)"
                        )
                    }
                    throw CrashHandlerError.writeFailed(
                        "openat(\(component)) failed: \(String(cString: strerror(err)))"
                    )
                }
                _ = fchmod(fd, mode)
                let abs = homeCanon + "/" + parts.joined(separator: "/")
                return (fd, abs)
            } else {
                // mkdir may fail with EEXIST; then open with O_NOFOLLOW.
                _ = component.withCString { mkdirat(dirFD, $0, 0o700) }
                var dirFlags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
                #if os(macOS)
                dirFlags |= O_CLOEXEC
                #endif
                let next = component.withCString { openat(dirFD, $0, dirFlags) }
                guard next >= 0 else {
                    let err = errno
                    if err == ELOOP {
                        throw CrashHandlerError.writeFailed(
                            "symlinked directory rejected: \(component)"
                        )
                    }
                    throw CrashHandlerError.writeFailed(
                        "openat dir(\(component)) failed: \(String(cString: strerror(err)))"
                    )
                }
                if closeDir { close(dirFD) }
                dirFD = next
                closeDir = true
            }
        }
        throw CrashHandlerError.writeFailed("unreachable path isolation state")
    }
    #endif
}

// MARK: - Terminal restore sequences

/// Terminal restore sequences (async-signal-safe constants).
public enum CrashTerminalRestore {
    /// Full escape sequence to restore the terminal to a sane state.
    public static let restoreSeq: [UInt8] = Array(
        "\u{1b}[?2026l\u{1b}[?25h\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1015l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?1004l\u{1b}[<u\u{1b}[?1049l"
            .utf8
    )

    public static let mouseTrackingReset: [UInt8] = Array(
        "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1015l\u{1b}[?1006l".utf8
    )

    /// Write restore sequences to stderr using raw `write(2)`.
    public static func restoreInSignalHandler() {
        #if os(macOS) || os(Linux)
        restoreSeq.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = write(STDERR_FILENO, base, buf.count)
        }
        #endif
    }
}

// MARK: - check / archive previous crash

private let maxHistory = 5

/// Check for a crash from the previous session.
///
/// Reads `crashDir/last-crash.bin`, formats a human-readable report, archives
/// it, and removes the binary blob. Returns `nil` if no valid crash file.
public func checkPreviousCrash(crashDir: URL) -> PreviousCrashReport? {
    let crashFile = crashDir.appendingPathComponent("last-crash.bin")
    guard let data = try? Data(contentsOf: crashFile) else { return nil }
    guard let blob = CrashBlob.parse(data) else { return nil }

    let frames = resolveFrames(blob)
    let reportText = formatReport(blob: blob, frames: frames)

    let reportPath = crashDir.appendingPathComponent("last-crash-report.txt")
    try? writeOwnerOnly(path: reportPath, contents: Data(reportText.utf8))

    archiveReport(crashDir: crashDir, reportText: reportText, timestamp: blob.timestamp)

    try? FileManager.default.removeItem(at: crashFile)

    return PreviousCrashReport(
        signalName: signalName(blob.signal),
        siCode: blob.siCode,
        faultingAddress: blob.siAddr,
        timestamp: blob.timestamp,
        appVersion: blob.appVersion,
        backtrace: frames,
        reportPath: reportPath
    )
}

private func archiveReport(crashDir: URL, reportText: String, timestamp: UInt64) {
    let historyDir = crashDir.appendingPathComponent("history", isDirectory: true)
    try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    let filename = "crash-\(timestamp).txt"
    try? writeOwnerOnly(
        path: historyDir.appendingPathComponent(filename),
        contents: Data(reportText.utf8)
    )

    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: historyDir,
        includingPropertiesForKeys: nil
    ) else { return }
    let files = entries
        .filter { $0.pathExtension == "txt" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    if files.count > maxHistory {
        for old in files.prefix(files.count - maxHistory) {
            try? FileManager.default.removeItem(at: old)
        }
    }
}

// MARK: - Install / record protocol

/// Crash capture, redaction, and persistence below OPENGROK_HOME.
public protocol CrashHandler: Sendable {
    /// Install platform crash/signal hooks. Idempotent.
    func install(openGrokHome: URL) async throws
    /// Record a redacted report without corrupting active session journals.
    func record(_ report: CrashReport, openGrokHome: URL) async throws -> URL
}

/// Production crash handler.
public struct PlatformCrashHandler: CrashHandler, Sendable {
    public var appVersion: String

    public init(appVersion: String = "0.0.0") {
        self.appVersion = appVersion
    }

    public func install(openGrokHome: URL) async throws {
        let crashDir = openGrokHome.appendingPathComponent("crash", isDirectory: true)
        let ok = installCrashHandler(
            CrashHandlerConfig(appVersion: appVersion, crashDir: crashDir),
            openGrokHome: openGrokHome
        )
        if !ok {
            throw CrashHandlerError.installFailed("failed to install crash handler")
        }
    }

    public func record(_ report: CrashReport, openGrokHome: URL) async throws -> URL {
        let relative = report.openGrokHomeRelativePath
        #if os(macOS) || os(Linux)
        let (fd, absPath) = try CrashPathIsolation.openWriteNoFollow(
            openGrokHome: openGrokHome,
            relative: relative
        )
        defer { close(fd) }

        var body = "=== Open Grok Crash Report ===\n\n"
        body += "Summary: \(redactSecrets(report.summary))\n"
        if let sig = report.signalName { body += "Signal:  \(sig)\n" }
        if let ver = report.appVersion { body += "Version: \(redactSecrets(ver))\n" }
        if let ts = report.timestamp { body += "Time:    \(ts)\n" }
        body += "\nBacktrace:\n"
        for (i, frame) in report.redactedBacktrace.enumerated() {
            body += "  \(i): \(redactSecrets(redactPath(frame)))\n"
        }
        body += "\n=== End Report ===\n"

        let data = Data(body.utf8)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(fd, base, raw.count)
        }
        guard written == data.count else {
            throw CrashHandlerError.writeFailed("short write to \(absPath)")
        }
        return URL(fileURLWithPath: absPath)
        #else
        // Lexical gate only on non-POSIX.
        _ = try CrashPathIsolation.relativeComponents(relative)
        let dest = openGrokHome.appendingPathComponent(relative)
        let parent = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var body = "=== Open Grok Crash Report ===\n\n"
        body += "Summary: \(redactSecrets(report.summary))\n"
        try writeOwnerOnly(path: dest, contents: Data(body.utf8))
        return dest
        #endif
    }
}

/// Install the crash handler. Creates `crash_dir` if needed under a verified
/// OPENGROK_HOME root when provided.
///
/// Returns `true` if installed. On unsupported platforms returns `false`.
/// Call `checkPreviousCrash` BEFORE this — install truncates `last-crash.bin`.
@discardableResult
public func installCrashHandler(
    _ config: CrashHandlerConfig,
    openGrokHome: URL? = nil
) -> Bool {
    #if os(macOS) || os(Linux)
    // Prefer descriptor-relative open under OPENGROK_HOME when known.
    if let home = openGrokHome {
        // Relative path of crashDir under home → "crash/last-crash.bin"
        let homePath = home.standardizedFileURL.path
        let crashPath = config.crashDir.standardizedFileURL.path
        var relative = "crash/last-crash.bin"
        if crashPath.hasPrefix(homePath) {
            let suffix = String(crashPath.dropFirst(homePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !suffix.isEmpty {
                relative = suffix + "/last-crash.bin"
            }
        }
        do {
            let (fd, _) = try CrashPathIsolation.openWriteNoFollow(
                openGrokHome: home,
                relative: relative
            )
            // C shim adopts the fd (signal-safe write + close on crash).
            return opengrok_crash_install_fd(fd, config.appVersion) != 0
        } catch {
            return false
        }
    }

    // Fallback: create crashDir and install by path (less strict).
    do {
        try FileManager.default.createDirectory(
            at: config.crashDir,
            withIntermediateDirectories: true
        )
    } catch {
        return false
    }
    let crashFile = config.crashDir.appendingPathComponent("last-crash.bin")
    return crashFile.path.withCString { cPath in
        opengrok_crash_install(cPath, config.appVersion) != 0
    }
    #elseif os(Windows)
    return WindowsCrashHandler.install(config)
    #else
    return false
    #endif
}

/// Install a minimal SIGSEGV/SIGBUS/SIGABRT handler that only restores the terminal.
public func installTerminalRestoreOnly() {
    #if os(macOS) || os(Linux)
    opengrok_crash_install_terminal_restore_only()
    #endif
}

/// Upgrade handlers to include terminal escape code restoration.
public func enableTerminalEscapeRestore() {
    #if os(macOS) || os(Linux)
    opengrok_crash_enable_terminal_escape_restore()
    #endif
}

/// Downgrade handlers to termios-only restoration.
public func disableTerminalEscapeRestore() {
    #if os(macOS) || os(Linux)
    opengrok_crash_disable_terminal_escape_restore()
    #endif
}

/// Whether a full crash blob install is currently active.
public func isCrashHandlerInstalled() -> Bool {
    #if os(macOS) || os(Linux)
    return opengrok_crash_is_installed() != 0
    #else
    return false
    #endif
}

// MARK: - Windows exception filter seam

#if os(Windows)
enum WindowsCrashHandler {
    static func install(_ config: CrashHandlerConfig) -> Bool {
        // SetUnhandledExceptionFilter path when WinSDK is linked. Until then
        // report failure so callers know capture is unavailable.
        _ = config
        return false
    }
}
#endif

// MARK: - Bootstrap

/// Bootstrap handler that now delegates to the platform handler.
public struct BootstrapCrashHandler: CrashHandler {
    private let inner: PlatformCrashHandler
    public init(appVersion: String = "0.0.0") {
        self.inner = PlatformCrashHandler(appVersion: appVersion)
    }
    public func install(openGrokHome: URL) async throws {
        try await inner.install(openGrokHome: openGrokHome)
    }
    public func record(_ report: CrashReport, openGrokHome: URL) async throws -> URL {
        try await inner.record(report, openGrokHome: openGrokHome)
    }
}
