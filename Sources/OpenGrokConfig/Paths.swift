// Paths.swift
//
// Port of `xai-grok-config/src/paths.rs`.
//
// Filesystem locations for Open Grok config files and binaries: `OPENGROK_HOME`
// resolution, system config dir, CWD-encoding for session directories, and
// slug generation. The Swift port mirrors the Rust invariants:
//   * `$OPENGROK_HOME` wins; otherwise `~/.opengrok` (never `~/.grok`).
//   * `userGrokHome` returns `nil` when no home resolves (rather than a
//     cwd-relative `.opengrok`), so user-tier scans don't mistake a project
//     tree for the user-global one.
//   * `encodeCwdDirname` percent-encodes short CWDs (including `/` → `%2F`,
//     matching Rust `urlencoding::encode`) when the encoded form is ≤255
//     bytes, and falls back to a compact `{slug}-{blake3_hex16}` form
//     (always ≤57 bytes) for long CWDs, writing a `.cwd` metadata file so
//     `decodeCwdFromDirname` can recover the original.
//   * `ensureSessionsCwdDir` writes the `.cwd` file via create-new
//     (O_CREAT|O_EXCL) semantics to avoid TOCTOU races with parallel session
//     starts, and never overwrites an existing `.cwd`.
//
// `defaultGrokHome`, `grokHome`, `userGrokHome`, and `systemConfigDir` accept
// an injectable `environment` so tests are deterministic without mutating the
// process environment.

import Foundation
import OpenGrokPaths
import OpenGrokConfigTypes

// MARK: - Public path resolvers

/// The default user Open Grok directory (`~/.opengrok`, canonicalized) used
/// when `OPENGROK_HOME` is unset. Exposed so callers can detect whether
/// `grokHome()` is the default without duplicating the computation.
///
/// Uses `FileManager` canonicalization where possible (the Rust port uses
/// `dunce::canonicalize` to strip Windows `\\?\` prefixes; Foundation does
/// not produce those prefixes on macOS/Linux, so no special handling is
/// needed).
public func defaultGrokHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    let home = OpenGrokStatePaths.userHomeDirectory(environment: environment)
    // Best-effort canonicalize via URL.resolvingSymlinksInPath() (a property,
    // not a method). On macOS/Linux Foundation returns the standardized path
    // without verbatim prefixes.
    let resolved = home.resolvingSymlinksInPath()
    return resolved.appendingPathComponent(".opengrok")
}

/// Per-user Open Grok directory: `$OPENGROK_HOME` or `~/.opengrok`. Created
/// if needed. Mirrors Rust `grok_home()` (cached for the process lifetime via
/// `grokHomeCached`).
public func grokHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    let resolved: URL
    if let v = environment[OpenGrokPathPolicy.homeEnvironmentVariable], !v.isEmpty {
        resolved = URL(fileURLWithPath: v)
    } else {
        resolved = defaultGrokHome(environment: environment)
    }
    try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
    return resolved
}

/// The user-global Open Grok home, but only when one genuinely resolves:
/// `some` when `OPENGROK_HOME` is set or a home directory is found, `nil`
/// otherwise. Unlike `grokHome`, this never falls back to a cwd-relative
/// `.opengrok`, so callers that scan user-global grok resources (hooks,
/// marketplace sources, ...) don't mistake a project's `.opengrok` tree for
/// the user-global one when no home resolves.
public func userGrokHome(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL? {
    let hasOverride = environment[OpenGrokPathPolicy.homeEnvironmentVariable]?.isEmpty == false
    let hasHome = !OpenGrokStatePaths
        .userHomeDirectory(environment: environment)
        .path.isEmpty
    guard hasOverride || hasHome else { return nil }
    return grokHome(environment: environment)
}

/// Canonical Open Grok application path: `$OPENGROK_HOME/bin/open-grok`
/// (Unix) or `open-grok.exe` (Windows).
public func grokApplication(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    #if os(Windows)
    let name = "open-grok.exe"
    #else
    let name = "open-grok"
    #endif
    return grokHome(environment: environment)
        .appendingPathComponent("bin")
        .appendingPathComponent(name)
}

/// System-wide config directory: `/etc/opengrok/` on Unix, `nil` on Windows.
public func systemConfigDir() -> URL? {
    #if os(Windows)
    return nil
    #else
    return URL(fileURLWithPath: "/etc/opengrok", isDirectory: true)
    #endif
}

// MARK: - Claude managed-settings compat

#if os(macOS) || os(Linux)
/// The platform path for the managed-settings.json used for settings compat.
private let claudeManagedSettingsPathString: String = {
    #if os(macOS)
    return "/Library/Application Support/ClaudeCode/managed-settings.json"
    #else
    return "/etc/claude-code/managed-settings.json"
    #endif
}()
#endif

/// System path for the managed-settings.json used for settings compat, if it
/// exists. `nil` on unsupported platforms.
public func claudeManagedSettingsPath() -> URL? {
    #if os(macOS) || os(Linux)
    let path = URL(fileURLWithPath: claudeManagedSettingsPathString)
    return FileManager.default.fileExists(atPath: path.path) ? path : nil
    #else
    return nil
    #endif
}

/// The platform path where managed-settings.json would live for settings
/// compat, whether or not it exists. `nil` on unsupported platforms.
public func claudeManagedSettingsProbePath() -> URL? {
    #if os(macOS) || os(Linux)
    return URL(fileURLWithPath: claudeManagedSettingsPathString)
    #else
    return nil
    #endif
}

// MARK: - CWD encoding

/// Max bytes for a single directory name component (macOS APFS, Linux ext4,
/// NTFS all enforce 255 bytes).
private let maxDirnameBytes = 255

/// Encode a CWD string into a filesystem-safe directory name component.
///
/// Short CWDs (URL-encoded form <= 255 bytes) use `urlencoding::encode`
/// parity (percent-encode every non-unreserved byte, **including** `/` as
/// `%2F`) for backward compatibility and human readability on disk.
///
/// Long CWDs (> 255 bytes encoded) use a compact `{slug}-{blake3_hex16}`
/// form that is always <= 57 bytes. Callers must write a `.cwd` metadata
/// file via `ensureSessionsCwdDir` so the original CWD can be recovered by
/// `decodeCwdFromDirname`.
public func encodeCwdDirname(_ cwd: String) -> String {
    let urlEncoded = urlEncodePath(cwd)
    if urlEncoded.utf8.count <= maxDirnameBytes {
        return urlEncoded
    }
    // Compact hash form — first 16 hex chars of BLAKE3 (Rust `blake3::hash`).
    let hashHex = Blake3.hexPrefix(cwd, length: 16)
    let leaf = URL(fileURLWithPath: cwd).lastPathComponent
    var slug = slugify(leaf, maxLen: 40)
    if slug.isEmpty { slug = "workspace" }
    return "\(slug)-\(hashHex)"
}

/// Recover the original CWD from a sessions CWD directory.
///
/// Tries URL-decoding the directory name first (works for short/legacy dirs).
/// Falls back to reading a `.cwd` metadata file inside the directory (written
/// by `ensureSessionsCwdDir` for hash-based dirs).
public func decodeCwdFromDirname(_ dir: URL) -> String? {
    guard let name = dir.lastPathComponent.isEmpty ? nil : dir.lastPathComponent else { return nil }
    if let decoded = urlDecodePath(name) {
        // URL-decoded absolute CWDs always start with `/` (Unix) or a drive
        // letter (Windows). The slug-hash form never does, so this
        // distinguishes the two encodings unambiguously.
        if decoded.hasPrefix("/") {
            return decoded
        }
        #if os(Windows)
        if decoded.count >= 2, decoded[decoded.index(after: decoded.startIndex)] == ":" {
            return decoded
        }
        #endif
    }
    let cwdFile = dir.appendingPathComponent(".cwd")
    guard let s = try? String(contentsOf: cwdFile, encoding: .utf8) else { return nil }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Build the CWD-level session directory path:
/// `grokHome()/sessions/{encodeCwdDirname(cwd)}`.
///
/// Does **not** create the directory on disk — use `ensureSessionsCwdDir`
/// when the directory must exist.
public func sessionsCwdDir(
    _ cwd: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    grokHome(environment: environment)
        .appendingPathComponent("sessions")
        .appendingPathComponent(encodeCwdDirname(cwd))
}

/// Create the CWD-level session directory and write a `.cwd` metadata file
/// when hash-based encoding is used (long paths).
///
/// For short paths the `.cwd` file is not written because the directory name
/// itself is reversible via URL-decoding. The `.cwd` file is written with
/// create-new (O_CREAT|O_EXCL) semantics so parallel session starts never
/// overwrite an existing file.
public func ensureSessionsCwdDir(
    _ cwd: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> URL {
    let encodedName = encodeCwdDirname(cwd)
    let dir = grokHome(environment: environment)
        .appendingPathComponent("sessions")
        .appendingPathComponent(encodedName)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Hash-based encoding is in use when the dirname differs from the plain
    // URL-encoded form. Write a `.cwd` file so decode can recover the original
    // path. withoutOverwriting ≈ O_CREAT|O_EXCL.
    if encodedName != urlEncodePath(cwd) {
        let cwdFile = dir.appendingPathComponent(".cwd")
        let data = Data(cwd.utf8)
        // O_CREAT|O_EXCL: create only if absent. Do not combine with `.atomic`
        // — Foundation rejects that pairing.
        if FileManager.default.fileExists(atPath: cwdFile.path) {
            return dir
        }
        do {
            try data.write(to: cwdFile, options: [.withoutOverwriting])
        } catch let error as NSError {
            // NSFileWriteFileExistsError = 516; treat as AlreadyExists.
            if error.code != NSFileWriteFileExistsError {
                throw error
            }
        }
    }
    return dir
}

// MARK: - Slug

/// Generate a URL-safe slug from a string.
///
/// Lowercases, replaces non-alphanumeric chars with `-`, collapses
/// consecutive dashes, and truncates to `maxLen` characters.
public func slugify(_ input: String, maxLen: Int) -> String {
    var result = ""
    var prevDash = false
    for c in input.lowercased() {
        if c.isASCII && (c.isLetter || c.isNumber) {
            result.append(c)
            prevDash = false
        } else if !prevDash {
            result.append("-")
            prevDash = true
        }
    }
    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return String(trimmed.prefix(maxLen))
}

// MARK: - URL encoding (urlencoding::encode parity)

/// Percent-encode a CWD path the way Rust `urlencoding::encode` does:
/// every byte outside the unreserved set `A-Z a-z 0-9 - _ . ~` is encoded,
/// **including** `/` as `%2F`. This produces a single filesystem-safe
/// directory name component for short paths.
func urlEncodePath(_ s: String) -> String {
    var out = ""
    for byte in s.utf8 {
        let c = Character(Unicode.Scalar(byte))
        if (byte >= 0x30 && byte <= 0x39) // 0-9
            || (byte >= 0x41 && byte <= 0x5A) // A-Z
            || (byte >= 0x61 && byte <= 0x7A) // a-z
            || byte == 0x2D // -
            || byte == 0x5F // _
            || byte == 0x2E // .
            || byte == 0x7E // ~
        {
            out.append(c)
        } else {
            out += String(format: "%%%02X", byte)
        }
    }
    return out
}

/// URL-decode a percent-encoded string (the inverse of `urlEncodePath`).
/// Returns `nil` on malformed input (bad hex digits or a dangling `%`).
func urlDecodePath(_ s: String) -> String? {
    var bytes: [UInt8] = []
    var idx = s.startIndex
    while idx < s.endIndex {
        let c = s[idx]
        if c == "%" {
            let next = s.index(after: idx)
            guard next < s.endIndex else { return nil }
            let next2 = s.index(after: next)
            guard next2 < s.endIndex else { return nil }
            let hex = String(s[next...next2])
            guard let v = UInt8(hex, radix: 16) else { return nil }
            bytes.append(v)
            idx = s.index(after: next2)
        } else {
            guard let ascii = c.asciiValue else { return nil }
            bytes.append(ascii)
            idx = s.index(after: idx)
        }
    }
    return String(bytes: bytes, encoding: .utf8)
}
