import Foundation
import OpenGrokConfig
import OpenGrokFileUtils
import OpenGrokUpdate

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum LiveInstallerLaunchConfiguration {
    private static let maximumInstallerBytes = 64
    private static let maximumConfigurationBytes = 1_048_576

    static func apply(installer: String?, environment: [String: String]) throws {
        guard let installer else { return }
        guard isSafeInstaller(installer) else {
            throw CLIApplicationError.failed(
                "invalid --installer value: expected a nonempty ASCII installer identifier"
            )
        }

        let ownerHome: URL
        if let override = environment["OPENGROK_HOME"], !override.isEmpty {
            try PathSecurity.rejectHostileLexical(override)
            guard override.hasPrefix("/") || Self.isWindowsAbsolute(override) else {
                throw CLIApplicationError.failed("--installer requires an absolute owner state directory")
            }
            ownerHome = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            ownerHome = defaultGrokHome(environment: environment)
        }
        try ensureOwnerDirectory(ownerHome)

        let configPath = ownerHome.appendingPathComponent("config.toml")
        let lock = try AdvisoryFileLock.acquire(at: configPath.appendingPathExtension("installer.lock"))
        defer { lock.release() }

        let existing = try readExistingConfiguration(at: configPath)
        let document: TOMLValue
        if let existing {
            do {
                document = try parseTOML(existing)
            } catch {
                throw CLIApplicationError.failed(
                    "owner config.toml is malformed; refusing to replace existing configuration"
                )
            }
        } else {
            document = .table(TOMLTable())
        }

        guard var root = document.table else {
            throw CLIApplicationError.failed("owner config.toml must contain a TOML table")
        }
        let cli: TOMLTable
        if let value = root["cli"] {
            guard let table = value.table else {
                throw CLIApplicationError.failed("owner config.toml [cli] value is not a table")
            }
            cli = table
        } else {
            cli = TOMLTable()
        }
        var updatedCLI = cli
        updatedCLI.insert(.string(installer), forKey: "installer")
        root.insert(.table(updatedCLI), forKey: "cli")
        let updated = TOMLValue.table(root)
        let contents = preservedConfiguration(
            existing: existing,
            updated: updated,
            installer: installer,
            hadCLITable: document[path: ["cli"]] != nil,
            hadInstaller: document[path: ["cli", "installer"]] != nil
        )
        try AtomicFile.write(configPath, contents: contents, options: .ownerOnly)
    }

    static func effectiveInstaller(environment: [String: String]) throws -> UpdateInstaller {
        let layers: ConfigLayers
        do {
            layers = try ConfigLayers.load(environment: environment)
        } catch {
            throw CLIApplicationError.failed("could not load trusted update installer configuration")
        }

        // A protected installer cannot be replaced by a user-config write:
        // changing npm into open-grok would otherwise authorize a rollback.
        let protected: [TOMLValue?] = [
            layers.mdmRequirements,
            layers.systemRequirements,
            layers.userRequirements,
            layers.managed,
            layers.systemManaged,
        ]
        for layer in protected {
            if let value = layer?[path: ["cli", "installer"]] {
                return try validatedInstaller(value)
            }
        }
        guard let value = layers.user[path: ["cli", "installer"]] else {
            return .openGrok
        }
        return try validatedInstaller(value)
    }

    private static func validatedInstaller(_ value: TOMLValue) throws -> UpdateInstaller {
        guard case .string(let raw) = value, isSafeInstaller(raw) else {
            throw CLIApplicationError.failed("trusted update installer configuration is invalid")
        }
        return UpdateInstaller(rawValue: raw)
    }

    private static func isSafeInstaller(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumInstallerBytes else { return false }
        func isAlphanumeric(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        }
        guard let first = bytes.first, isAlphanumeric(first) else { return false }
        return bytes.allSatisfy {
            isAlphanumeric($0) || $0 == UInt8(ascii: "-")
                || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".")
        }
    }

    private static func isWindowsAbsolute(_ value: String) -> Bool {
        #if os(Windows)
        return value.utf8.count > 2 && value[value.index(after: value.startIndex)] == ":"
        #else
        _ = value
        return false
        #endif
    }

    private static func ensureOwnerDirectory(_ directory: URL) throws {
        #if os(Windows)
        try createDirAllOwnerOnly(directory, stateRoot: directory)
        #else
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        try PathSecurity.rejectHostileLexical(directory.path)
        let parts = directory.path.split(separator: "/")
        guard !parts.isEmpty else {
            throw CLIApplicationError.failed("installer owner state directory cannot be the filesystem root")
        }
        var descriptor = open("/", flags)
        guard descriptor >= 0 else {
            throw CLIApplicationError.failed("installer owner state directory cannot be opened securely")
        }
        defer { close(descriptor) }

        for (offset, component) in parts.enumerated() {
            var next = component.withCString { openat(descriptor, $0, flags) }
            if next < 0, errno == ENOENT {
                let created = component.withCString { mkdirat(descriptor, $0, 0o700) }
                guard created == 0 || errno == EEXIST else {
                    throw CLIApplicationError.failed("installer owner state directory cannot be created securely")
                }
                next = component.withCString { openat(descriptor, $0, flags) }
            }
            guard next >= 0 else {
                throw CLIApplicationError.failed("installer owner state directory contains an unsafe path component")
            }
            var information = stat()
            guard fstat(next, &information) == 0,
                  information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                close(next)
                throw CLIApplicationError.failed("installer owner state directory contains an invalid component")
            }
            if offset == parts.count - 1 {
                guard information.st_uid == geteuid() else {
                    close(next)
                    throw CLIApplicationError.failed("installer owner state directory belongs to another owner")
                }
                if information.st_mode & 0o777 != 0o700,
                   fchmod(next, 0o700) != 0 {
                    close(next)
                    throw CLIApplicationError.failed("installer owner state directory cannot be made private")
                }
            }
            close(descriptor)
            descriptor = next
        }
        #endif
    }

    private static func readExistingConfiguration(at path: URL) throws -> String? {
        #if !os(Windows)
        var information = stat()
        let inspected = path.path.withCString { lstat($0, &information) }
        if inspected != 0 {
            if errno == ENOENT { return nil }
            throw CLIApplicationError.failed("owner config.toml cannot be inspected securely")
        }
        guard information.st_uid == geteuid(),
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              information.st_mode & 0o022 == 0
        else {
            throw CLIApplicationError.failed("owner config.toml is not a safe owner-controlled file")
        }
        #endif

        let bytes: Data
        do {
            bytes = try PathSecurity.readNoFollow(path, maximumBytes: maximumConfigurationBytes)
        } catch let error as FileUtilsError {
            if case .notFound = error { return nil }
            throw error
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CLIApplicationError.failed("owner config.toml is not valid UTF-8")
        }
        return text
    }

    private static func preservedConfiguration(
        existing: String?,
        updated: TOMLValue,
        installer: String,
        hadCLITable: Bool,
        hadInstaller: Bool
    ) -> String {
        guard let existing, !existing.isEmpty else { return TOMLEncoder.encode(updated) }
        let newline = existing.contains("\r\n") ? "\r\n" : "\n"
        let encodedInstaller = TOMLEncoder.encode(.string(installer))
        let candidate: String?

        if !hadCLITable {
            let separator = existing.hasSuffix("\n") || existing.hasSuffix("\r") ? newline : newline + newline
            candidate = existing + separator + "[cli]" + newline
                + "installer = " + encodedInstaller + newline
        } else {
            candidate = replacingInstaller(
                in: existing,
                encodedInstaller: encodedInstaller,
                newline: newline,
                hadInstaller: hadInstaller
            )
        }

        // Regexes are only a format-preservation optimization. A successful
        // independent TOML reparse must reproduce the exact mutated tree.
        if let candidate, let reparsed = try? parseTOML(candidate), reparsed == updated {
            return candidate
        }
        return TOMLEncoder.encode(updated)
    }

    private static func replacingInstaller(
        in source: String,
        encodedInstaller: String,
        newline: String,
        hadInstaller: Bool
    ) -> String? {
        let header = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*\[[ \t]*cli[ \t]*\][ \t]*(?:#[^\r\n]*)?$"#
        )
        let text = source as NSString
        let entire = NSRange(location: 0, length: text.length)
        guard let section = header?.firstMatch(in: source, range: entire) else { return nil }
        let sectionStart = NSMaxRange(section.range)
        let subsequent = NSRange(location: sectionStart, length: text.length - sectionStart)
        let nextHeader = try? NSRegularExpression(pattern: #"(?m)^[ \t]*\["#)
        let sectionEnd = nextHeader?.firstMatch(in: source, range: subsequent)?.range.location ?? text.length
        let body = NSRange(location: sectionStart, length: sectionEnd - sectionStart)

        if hadInstaller {
            let pattern = try? NSRegularExpression(
                pattern: #"(?m)^[ \t]*(?:installer|"installer"|'installer')[ \t]*=[ \t]*([^\r\n]*)"#
            )
            guard let match = pattern?.firstMatch(in: source, range: body) else { return nil }
            let valueRange = match.range(at: 1)
            let current = text.substring(with: valueRange)
            let comment: String
            if let index = unquotedComment(in: current) {
                comment = " " + String(current[index...])
            } else {
                comment = ""
            }
            return text.replacingCharacters(in: valueRange, with: encodedInstaller + comment)
        }

        let before = text.substring(to: sectionEnd)
        let separator = before.hasSuffix("\n") || before.hasSuffix("\r") ? "" : newline
        return text.replacingCharacters(
            in: NSRange(location: sectionEnd, length: 0),
            with: separator + "installer = " + encodedInstaller + newline
        )
    }

    private static func unquotedComment(in value: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return index
            }
        }
        return nil
    }
}
