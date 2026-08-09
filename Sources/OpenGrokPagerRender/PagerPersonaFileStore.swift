// PagerPersonaFileStore.swift
//
// The Personas tab's file operations (Wave 18 B9-b3), ported from
// `xai-grok-pager/src/views/agents_modal.rs` at upstream 650c1db7:
// `sanitize_config_name` (`:588-605`), `personas_dir_for_scope`
// (`:606-611`), `create_persona_template` (`:620-646` — refuses
// overwrite, omits empty fields), the shared canonical-path guard
// `config_path_is_user_or_project` (`:651-671`) behind
// `persona_path_is_deletable` (`:647-649`), and `delete_persona_file`
// (`:684-697` — the bundled refusal and the outside-dir rejection, copy
// byte-parity). Plus the persona detail modal's `save_to_file`
// (`views/persona_detail.rs:316-347`).
//
// Every function takes `openGrokHome` explicitly where upstream reads
// `xai_grok_config::grok_home()` internally — resolving the home from
// process globals here would be the process-cwd trap (AGENTS.md §2).
//
// Error carrier: `PagerAgentsConfigWriteError`, the b2 writers' type —
// the modal surfaces `message` verbatim as its inline line.

import Foundation
import OpenGrokConfig

public enum PagerPersonaFileStore {
    // MARK: - Name sanitization

    /// `sanitize_config_name` (`agents_modal.rs:590-605`): every character
    /// that is not alphanumeric, `-`, or `_` becomes `-`; a result with no
    /// alphanumeric character at all is refused with upstream's copy.
    public static func sanitizeConfigName(_ name: String) throws -> String {
        let sanitized = String(name.map { character -> Character in
            if character.isLetter || character.isNumber
                || character == "-" || character == "_" {
                return character
            }
            return "-"
        })
        guard sanitized.contains(where: { $0.isLetter || $0.isNumber }) else {
            throw PagerAgentsConfigWriteError(
                message: "Name must contain at least one alphanumeric character"
            )
        }
        return sanitized
    }

    // MARK: - Directories

    /// `personas_dir_for_scope` (`agents_modal.rs:606-611`).
    public static func personasDirectory(
        scope: PagerConfigFileScope,
        cwd: URL,
        openGrokHome: URL
    ) -> URL {
        switch scope {
        case .user:
            return openGrokHome.appendingPathComponent("personas", isDirectory: true)
        case .project:
            return cwd
                .appendingPathComponent(".opengrok", isDirectory: true)
                .appendingPathComponent("personas", isDirectory: true)
        }
    }

    // MARK: - Create

    /// `create_persona_template` (`agents_modal.rs:620-646`): sanitize,
    /// ensure the scope's personas directory, refuse overwrite, write the
    /// template with trimmed non-empty fields only.
    @discardableResult
    public static func createPersonaTemplate(
        name: String,
        description: String,
        instructions: String,
        scope: PagerConfigFileScope,
        cwd: URL,
        openGrokHome: URL
    ) throws -> URL {
        let sanitized = try sanitizeConfigName(name)
        let directory = personasDirectory(scope: scope, cwd: cwd, openGrokHome: openGrokHome)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw PagerAgentsConfigWriteError(
                message: "Failed to create personas directory: \(error)"
            )
        }
        let path = directory.appendingPathComponent("\(sanitized).toml")
        if FileManager.default.fileExists(atPath: path.path) {
            throw PagerAgentsConfigWriteError(
                message: "Persona '\(sanitized)' already exists"
            )
        }
        let content = templateContent(description: description, instructions: instructions)
        do {
            try content.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            throw PagerAgentsConfigWriteError(
                message: "Failed to write persona file: \(error)"
            )
        }
        return path
    }

    /// The template body: `toml::to_string_pretty` over the two optional
    /// fields (`PersonaTomlTemplate`, `agents_modal.rs:612-618`, fields in
    /// struct order, trimmed, empties omitted, `:636-643`). The form's
    /// fields are single-line by construction (append/backspace entry, no
    /// paste channel), and for single-line strings upstream's serializer
    /// emits exactly `key = "value"` basic strings — reproduced here with
    /// TOML basic-string escaping. Both fields empty yields an empty file,
    /// as upstream serializes an all-None struct to "".
    static func templateContent(description: String, instructions: String) -> String {
        var lines: [String] = []
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        if !trimmedDescription.isEmpty {
            lines.append("description = \(tomlBasicString(trimmedDescription))")
        }
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespaces)
        if !trimmedInstructions.isEmpty {
            lines.append("instructions = \(tomlBasicString(trimmedInstructions))")
        }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A TOML basic string: `"`, `\`, and C0 controls escaped.
    private static func tomlBasicString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\u{08}": escaped += "\\b"
            case "\t": escaped += "\\t"
            case "\n": escaped += "\\n"
            case "\u{0C}": escaped += "\\f"
            case "\r": escaped += "\\r"
            case let control where control.value < 0x20:
                escaped += String(format: "\\u%04X", control.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    // MARK: - Delete guards

    /// `persona_path_is_deletable` → `config_path_is_user_or_project`
    /// (`agents_modal.rs:648-671`): canonicalize (a path that cannot
    /// resolve — nonexistent, upstream's `dunce::canonicalize` error arm —
    /// is NOT deletable), refuse any path with a `bundled` component, then
    /// require the canonical path under `{home}/personas` or under any
    /// `.opengrok/personas` ancestor.
    public static func personaPathIsDeletable(_ path: String, openGrokHome: URL) -> Bool {
        guard let canonical = canonicalize(path) else { return false }
        let components = canonical.split(separator: "/").map(String.init)
        if components.contains("bundled") { return false }
        let userDirectory = openGrokHome
            .appendingPathComponent("personas", isDirectory: true).path
        let inUser: Bool
        if let canonicalUser = canonicalize(userDirectory) {
            inUser = canonical == canonicalUser
                || canonical.hasPrefix(canonicalUser + "/")
        } else {
            inUser = false
        }
        // `canonical.ancestors().any(|a| a.ends_with(".opengrok/personas"))`
        // (`:666-669`): the suffix check against every ancestor is the
        // consecutive-components check against the whole path.
        var inProject = false
        if components.count >= 2 {
            for index in 0...(components.count - 2)
            where components[index] == ".opengrok" && components[index + 1] == "personas" {
                inProject = true
                break
            }
        }
        return inUser || inProject
    }

    /// `delete_persona_file` (`agents_modal.rs:685-697`): the guard first;
    /// a rejected path that canonicalizes into a `bundled` component gets
    /// the bundled copy, anything else the outside-dir rejection; then the
    /// actual remove with upstream's failure copy.
    public static func deletePersonaFile(atPath path: String, openGrokHome: URL) throws {
        if !personaPathIsDeletable(path, openGrokHome: openGrokHome) {
            if let canonical = canonicalize(path),
               canonical.split(separator: "/").map(String.init).contains("bundled") {
                throw PagerAgentsConfigWriteError(message: "Cannot delete bundled personas")
            }
            throw PagerAgentsConfigWriteError(
                message: "Persona file is not in a known personas directory"
            )
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw PagerAgentsConfigWriteError(
                message: "Failed to delete persona file: \(error)"
            )
        }
    }

    /// `dunce::canonicalize` stand-in: resolve symlinks and fail (nil) when
    /// the path does not exist — the existence requirement is load-bearing,
    /// because upstream's guard returns false for a path it cannot
    /// canonicalize.
    private static func canonicalize(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Detail save

    /// `PersonaDetailState::save_to_file` (`persona_detail.rs:316-347`):
    /// read the source fresh, parse, splice the seven scalar fields —
    /// empty removes the key — and write, each failure with upstream's
    /// copy. Upstream edits with `toml_edit` and keeps comments; this uses
    /// the port's parse-mutate-serialize writer, which preserves key order
    /// but drops comments on rewrite — the recorded config-write
    /// divergence every port writer shares (see `PagerAgentsConfigStore`).
    public static func saveDetail(_ detail: PagerPersonaDetailOverlay) throws {
        guard let path = detail.sourcePath else {
            throw PagerAgentsConfigWriteError(message: "No source file to save to")
        }
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw PagerAgentsConfigWriteError(message: "Failed to read file: \(error)")
        }
        var table: TOMLTable
        do {
            let parsed = try parseTOML(Data(content.utf8))
            guard let inner = parsed.table else {
                throw PagerAgentsConfigWriteError(message: "Failed to parse TOML: not a table")
            }
            table = inner
        } catch let error as PagerAgentsConfigWriteError {
            throw error
        } catch {
            throw PagerAgentsConfigWriteError(message: "Failed to parse TOML: \(error)")
        }
        // Field order per upstream's array (`:328-336`).
        let fields: [(key: String, value: String)] = [
            ("name", detail.name),
            ("description", detail.description),
            ("instructions", detail.instructions),
            ("instructions_file", detail.instructionsFile),
            ("model", detail.model),
            ("reasoning_effort", detail.reasoningEffort),
            ("default_isolation", detail.defaultIsolation),
        ]
        for (key, value) in fields {
            if value.isEmpty {
                _ = table.removeValue(forKey: key)
            } else {
                table.insert(.string(value), forKey: key)
            }
        }
        do {
            try writeConfigFile(.table(table), to: URL(fileURLWithPath: path))
        } catch {
            throw PagerAgentsConfigWriteError(message: "Failed to write file: \(error)")
        }
    }
}
