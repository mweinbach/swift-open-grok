import Foundation
import OpenGrokFileUtils
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokWebMediaTools
#if os(Windows)
import COpenGrokSockets
#endif

/// Export uses the same platform-capability-checked clipboard as live tools;
/// injecting its one effect keeps unsupported/headless platforms fail-closed.
public struct LiveExportServices: Sendable {
    public typealias ClipboardWriter = @Sendable (String, [String: String]) async throws -> Void

    public let copyToClipboard: ClipboardWriter

    public init(copyToClipboard: @escaping ClipboardWriter) {
        self.copyToClipboard = copyToClipboard
    }

    public static var production: Self {
        Self { text, environment in
            let provider = SystemClipboardProvider(
                environment: environment,
                commandRunner: SystemClipboardCommandRunner(environment: environment)
            )
            guard provider.capabilityStatus()[.clipboardText] == true else {
                throw OpenGrokWebMediaTools.ClipboardError.unsupported(
                    "text clipboard is unavailable on this platform"
                )
            }
            try await provider.write(.text(text))
        }
    }
}

/// Rust: `xai-grok-pager/src/export_cmd.rs:15-67`; canonical updates, never
/// compatibility chat-history mirrors, are the replay/export source of truth.
public enum LiveExportComposition {
    private static let maximumJournalBytes = 16 * 1_024 * 1_024
    private static let maximumJournalRecords = 100_000
    private static let maximumSummaryBytes = 1_024 * 1_024
    private static let maximumWorkspaceDirectories = 10_000

    public static func handles(_ command: CLICommand) -> Bool {
        guard case .utility(let options) = command else { return false }
        return options.name == "export"
    }

    public static func session(
        for command: CLICommand,
        context: CLIApplicationContext,
        services: LiveExportServices = .production
    ) async throws -> CLIApplicationSession {
        guard case .utility(let options) = command, options.name == "export" else {
            throw CLIApplicationError.unsupported(route: command.routeName)
        }
        try await run(
            options: options,
            environment: context.environment,
            streams: context.streams,
            services: services
        )
        return CLIApplicationSession(waitForExit: {}, shutdown: {})
    }

    public static func run(
        options: CLIUtilityOptions,
        environment: [String: String],
        streams: CLIStreams,
        services: LiveExportServices = .production
    ) async throws {
        guard let sessionID = options.values.first, !sessionID.isEmpty else {
            throw CLIApplicationError.failed(
                "export requires a session id: open-grok export <SESSION_ID> [OUTPUT] [-c|--clipboard]"
            )
        }
        guard options.values.count <= 2 else {
            throw CLIApplicationError.failed("export accepts at most one output path")
        }
        do {
            try LiveConversationStore.validateSessionID(sessionID)
        } catch {
            throw CLIApplicationError.failed("Invalid session ID '\(sessionID)'.")
        }

        let home = OpenGrokHomeResolver.resolve(environment: environment)
            .standardizedFileURL
        let envelopes = try loadReplayEnvelopes(sessionID: sessionID, openGrokHome: home)
        let markdown = renderMarkdown(from: envelopes)
        guard !markdown.isEmpty else {
            throw CLIApplicationError.failed(
                "Session '\(sessionID)' has no conversation content to export"
            )
        }

        if options.values.count == 2 {
            let destination = expandedOutputPath(options.values[1], environment: environment)
            let parent = destination.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
            } catch {
                throw CLIApplicationError.failed("Failed to create \(parent.path): \(error)")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                let values: URLResourceValues
                do {
                    values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
                } catch {
                    throw CLIApplicationError.failed(
                        "Failed to inspect export destination \(destination.path): \(error)"
                    )
                }
                if values.isSymbolicLink == true {
                    throw CLIApplicationError.failed(
                        "Failed to write \(destination.path): refusing a symbolic-link destination"
                    )
                }
            }
            do {
                try Data(markdown.utf8).write(to: destination, options: .atomic)
            } catch {
                throw CLIApplicationError.failed("Failed to write \(destination.path): \(error)")
            }
            streams.err("Conversation exported to \(destination.path)\n")
        } else if options.isSet("--clipboard") {
            do {
                try await services.copyToClipboard(markdown, environment)
            } catch {
                throw CLIApplicationError.failed(
                    "Failed to copy conversation to clipboard: \(error)"
                )
            }
            let lineCount = markdown.split(
                omittingEmptySubsequences: false,
                whereSeparator: \.isNewline
            ).count
            streams.err(
                "Conversation copied to clipboard (\(markdown.utf8.count) chars, \(lineCount) lines)\n"
            )
        } else {
            streams.out(markdown + "\n")
        }
    }

    private static func loadReplayEnvelopes(
        sessionID: String,
        openGrokHome: URL
    ) throws -> [SessionUpdateEnvelope] {
        let manager = FileManager.default
        let root = openGrokHome.appendingPathComponent("sessions", isDirectory: true)
        guard try pathExists(root) else {
            throw notFound(sessionID)
        }
        try requireRealDirectory(root, root: nil)
        #if os(Windows)
        let canonicalRoot = root.standardizedFileURL
        #else
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        #endif

        let workspaces: [URL]
        do {
            #if os(Windows)
            workspaces = try WindowsSecurePath.contentsOfDirectory(
                at: root,
                maximumEntries: maximumWorkspaceDirectories,
                skipsHiddenFiles: true
            )
            #else
            workspaces = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            #endif
        } catch {
            throw CLIApplicationError.failed("Failed to inspect session history: \(error)")
        }
        guard workspaces.count <= maximumWorkspaceDirectories else {
            throw CLIApplicationError.failed("Session history exceeds the bounded workspace scan")
        }

        var matchingJournals: [ExportReplayJournal] = []
        for workspace in workspaces {
            #if os(Windows)
            let values: WindowsSecurePath.Metadata
            do {
                guard let metadata = try WindowsSecurePath.metadata(at: workspace) else { continue }
                values = metadata
            } catch {
                throw CLIApplicationError.failed("Failed to inspect session workspace: \(error)")
            }
            guard values.isDirectory, !values.isReparsePoint else { continue }
            #else
            let values: URLResourceValues
            do {
                values = try workspace.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                throw CLIApplicationError.failed("Failed to inspect session workspace: \(error)")
            }
            guard values.isDirectory == true else { continue }
            guard values.isSymbolicLink != true else { continue }
            #endif
            let directory = workspace.appendingPathComponent(sessionID, isDirectory: true)
            guard try pathExists(directory) else { continue }
            try requireRealDirectory(workspace, root: canonicalRoot)
            try requireRealDirectory(directory, root: canonicalRoot)

            let summary = directory.appendingPathComponent(SessionDocumentStore.summaryFileName)
            guard try pathExists(summary) else { continue }
            let summaryBytes = try readPrivateRegularFile(
                summary,
                root: canonicalRoot,
                maximumBytes: maximumSummaryBytes
            )
            let value: JSONValue
            do {
                value = try JSONDecoder().decode(JSONValue.self, from: summaryBytes)
            } catch {
                throw CLIApplicationError.failed("Failed to read session summary: \(error)")
            }
            guard value["info"]?["id"]?.stringValue == sessionID,
                  let cwd = value["info"]?["cwd"]?.stringValue
            else {
                throw CLIApplicationError.failed("Session summary identity does not match '\(sessionID)'.")
            }
            let knownTransportIDs: Set<String>
            if let provenance = value["code_mode_transport_call_ids"], !provenance.isNull {
                guard let identifiers = provenance.arrayValue,
                      identifiers.count <= maximumJournalRecords
                else {
                    throw CLIApplicationError.failed(
                        "Session summary contains invalid Code Mode transport provenance."
                    )
                }
                var validated = Set<String>()
                for identifier in identifiers {
                    guard let value = identifier.stringValue,
                          !value.isEmpty,
                          value.utf8.count <= 1_024
                    else {
                        throw CLIApplicationError.failed(
                            "Session summary contains an invalid Code Mode transport identity."
                        )
                    }
                    validated.insert(value)
                }
                knownTransportIDs = validated
            } else {
                knownTransportIDs = []
            }
            let expected: URL
            do {
                expected = try SessionDocumentStore(grokHome: openGrokHome).sessionDirectory(
                    sessionID: sessionID,
                    cwd: cwd
                )
            } catch {
                throw CLIApplicationError.failed("Session summary contains an invalid workspace: \(error)")
            }
            guard pathsMatch(
                expected.standardizedFileURL.path,
                directory.standardizedFileURL.path
            ) else {
                throw CLIApplicationError.failed("Session summary workspace does not own its journal.")
            }

            let journal = directory.appendingPathComponent(SessionDocumentStore.updatesFileName)
            guard try pathExists(journal) else { continue }
            let journalBytes = try readPrivateRegularFile(
                journal,
                root: canonicalRoot,
                maximumBytes: maximumJournalBytes
            )
            matchingJournals.append(ExportReplayJournal(
                bytes: journalBytes,
                knownTransportIDs: knownTransportIDs
            ))
        }

        guard matchingJournals.count <= 1 else {
            throw CLIApplicationError.failed(
                "Session '\(sessionID)' exists in multiple workspaces; refusing ambiguous export."
            )
        }
        guard let journal = matchingJournals.first else { throw notFound(sessionID) }

        guard let contents = String(data: journal.bytes, encoding: .utf8) else {
            throw CLIApplicationError.failed("Session update journal is not valid UTF-8.")
        }

        let decoder = JSONDecoder()
        var envelopes: [SessionUpdateEnvelope] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard envelopes.count < maximumJournalRecords else {
                throw CLIApplicationError.failed("Session update journal exceeds the bounded replay count.")
            }
            let envelope: SessionUpdateEnvelope
            do {
                envelope = try decoder.decode(SessionUpdateEnvelope.self, from: Data(line.utf8))
            } catch {
                throw CLIApplicationError.failed("Session update journal contains an invalid envelope: \(error)")
            }
            if envelope.method == "session/update" || envelope.method == "_x.ai/session/update" {
                guard let owner = envelope.params["sessionId"]?.stringValue,
                      owner == sessionID
                else {
                    throw CLIApplicationError.failed(
                        "Session update journal contains an invalid or cross-session update identity."
                    )
                }
            }
            envelopes.append(envelope)
        }
        let live = filteredLiveEnvelopes(envelopes)
        let transportIDs = codeModeTransportCallIDs(
            in: live,
            knownTransportIDs: journal.knownTransportIDs
        )
        return live.filter { !isCodeModeTransportUpdate($0, hiddenIDs: transportIDs) }
    }

    private static func requireRealDirectory(_ directory: URL, root: URL?) throws {
        #if os(Windows)
        let values: WindowsSecurePath.Metadata
        let native: String
        do {
            guard let metadata = try WindowsSecurePath.metadata(at: directory) else {
                throw CLIApplicationError.failed("Session history directory does not exist.")
            }
            values = metadata
            native = try WindowsSecurePath.extendedLengthPath(directory.path)
        } catch let error as CLIApplicationError {
            throw error
        } catch {
            throw CLIApplicationError.failed("Failed to inspect session directory: \(error)")
        }
        guard values.isDirectory, !values.isReparsePoint else {
            throw CLIApplicationError.failed("Session history must use real private directories.")
        }
        guard native.withCString({ path in
            og_path_is_private_to_current_user(path, 1)
        }) == 1 else {
            throw CLIApplicationError.failed(
                "Session history directory is not private to the current Windows user."
            )
        }
        #else
        let values: URLResourceValues
        do {
            values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw CLIApplicationError.failed("Failed to inspect session directory: \(error)")
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CLIApplicationError.failed("Session history must use real private directories.")
        }
        #endif
        if let root {
            #if os(Windows)
            let resolved = directory.standardizedFileURL
            #else
            let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
            #endif
            guard isStrictDescendant(resolved, of: root) else {
                throw CLIApplicationError.failed("Session directory escapes the private history root.")
            }
        }
    }

    private static func readPrivateRegularFile(
        _ file: URL,
        root: URL,
        maximumBytes: Int
    ) throws -> Data {
        #if os(Windows)
        guard isStrictDescendant(file.standardizedFileURL, of: root) else {
            throw CLIApplicationError.failed("Session document must be a contained regular file.")
        }
        do {
            return try PathSecurity.readNoFollow(
                file,
                maximumBytes: maximumBytes,
                requireOwnerOnly: true
            )
        } catch {
            throw CLIApplicationError.failed("Failed to securely read session document: \(error)")
        }
        #else
        let values: URLResourceValues
        do {
            values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw CLIApplicationError.failed("Failed to inspect private session document: \(error)")
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              isStrictDescendant(
                file.resolvingSymlinksInPath().standardizedFileURL,
                of: root
              )
        else {
            throw CLIApplicationError.failed("Session document must be a contained regular file.")
        }
        guard (values.fileSize ?? 0) <= maximumBytes else {
            throw CLIApplicationError.failed("Session document exceeds the bounded export size.")
        }
        do {
            guard try SecureFile.isOwnerOnly(at: file) else {
                throw CLIApplicationError.failed("Session document is not owner-private.")
            }
            let bytes = try PathSecurity.readNoFollow(file)
            guard bytes.count <= maximumBytes else {
                throw CLIApplicationError.failed("Session document exceeds the bounded export size.")
            }
            guard try SecureFile.isOwnerOnly(at: file) else {
                throw CLIApplicationError.failed("Session document is not owner-private.")
            }
            return bytes
        } catch let error as CLIApplicationError {
            throw error
        } catch {
            throw CLIApplicationError.failed("Failed to securely read session document: \(error)")
        }
        #endif
    }

    private static func pathExists(_ path: URL) throws -> Bool {
        #if os(Windows)
        do {
            return try WindowsSecurePath.metadata(at: path) != nil
        } catch {
            throw CLIApplicationError.failed("Failed to inspect session history path: \(error)")
        }
        #else
        return FileManager.default.fileExists(atPath: path.path)
        #endif
    }

    /// Rust: `session/storage/mod.rs:1378-1469`; a rewind removes its marker
    /// and every dead-branch update, while host turns never own a prompt index.
    private static func filteredLiveEnvelopes(
        _ envelopes: [SessionUpdateEnvelope]
    ) -> [SessionUpdateEnvelope] {
        var survivors: [SessionUpdateEnvelope] = []
        var promptStarts: [Int] = []
        var tracker = ExportPromptRunTracker()
        for envelope in envelopes {
            let update = envelope.params["update"]
            let tag = update?["sessionUpdate"]?.stringValue
            if envelope.method == "_x.ai/session/update", tag == "rewind_marker",
               let rawTarget = update?["target_prompt_index"]?.uint64Value
            {
                let target = Int(exactly: rawTarget) ?? promptStarts.count
                let boundary = target < promptStarts.count
                    ? promptStarts[target] : survivors.count
                survivors.removeSubrange(boundary..<survivors.count)
                if target < promptStarts.count {
                    promptStarts.removeSubrange(target..<promptStarts.count)
                }
                tracker.finishRun()
                continue
            }

            let metadata = update?["_meta"]
            if envelope.method == "session/update", tag == "user_message_chunk",
               metadata?["hostTurn"]?.boolValue != true
            {
                let promptIndex = metadata?["promptIndex"]?.uint64Value
                    .flatMap(Int.init(exactly:))
                if tracker.startsCountedTurn(promptIndex: promptIndex) {
                    promptStarts.append(survivors.count)
                }
            } else {
                tracker.finishRun()
            }
            survivors.append(envelope)
        }
        return survivors
    }

    /// Rust: `session/storage/mod.rs:1625-1712`. Titles alone are not
    /// provenance: plugins legitimately expose object-input `exec`/`wait`.
    private static func codeModeTransportCallIDs(
        in envelopes: [SessionUpdateEnvelope],
        knownTransportIDs: Set<String>
    ) -> Set<String> {
        let updates = envelopes.compactMap { envelope -> ExportToolUpdate? in
            guard envelope.method == "session/update",
                  let update = envelope.params["update"],
                  let kind = update["sessionUpdate"]?.stringValue,
                  kind == "tool_call" || kind == "tool_call_update",
                  let identifier = update["toolCallId"]?.stringValue,
                  !identifier.isEmpty
            else { return nil }
            return ExportToolUpdate(
                identifier: identifier,
                isCall: kind == "tool_call",
                update: update,
                marked: envelope.params["_meta"]?["open-grok/codeModeTransport"]?.boolValue
                    == true
            )
        }
        var hiddenIDs = knownTransportIDs

        for entry in updates where entry.marked {
            if !entry.isCall
                || ["exec", "wait"].contains(entry.update["title"]?.stringValue ?? "")
            {
                hiddenIDs.insert(entry.identifier)
            }
        }

        var recognizedExecIDs = Set(updates.compactMap { entry -> String? in
            guard entry.isCall,
                  entry.update["title"]?.stringValue == "exec",
                  hiddenIDs.contains(entry.identifier)
            else { return nil }
            return entry.identifier
        })
        for entry in updates {
            guard entry.isCall,
                  entry.update["title"]?.stringValue == "exec",
                  entry.update["kind"]?.stringValue == "other",
                  case .string? = entry.update["rawInput"]
            else { continue }
            hiddenIDs.insert(entry.identifier)
            recognizedExecIDs.insert(entry.identifier)
        }

        let cellIDs = Set(updates.compactMap { entry -> String? in
            guard recognizedExecIDs.contains(entry.identifier),
                  let identifier = entry.update["rawOutput"]?["cell_id"]?.stringValue,
                  !identifier.isEmpty
            else { return nil }
            return identifier
        })
        for entry in updates {
            guard entry.isCall,
                  entry.update["title"]?.stringValue == "wait",
                  entry.update["kind"]?.stringValue == "other",
                  let cellID = entry.update["rawInput"]?["cell_id"]?.stringValue,
                  cellIDs.contains(cellID)
            else { continue }
            hiddenIDs.insert(entry.identifier)
        }
        return hiddenIDs
    }

    private static func isCodeModeTransportUpdate(
        _ envelope: SessionUpdateEnvelope,
        hiddenIDs: Set<String>
    ) -> Bool {
        guard envelope.method == "session/update",
              let update = envelope.params["update"],
              let kind = update["sessionUpdate"]?.stringValue,
              kind == "tool_call" || kind == "tool_call_update",
              let identifier = update["toolCallId"]?.stringValue
        else { return false }
        return hiddenIDs.contains(identifier)
    }

    /// Rust: `scrollback/export.rs:13-73`; the shared projector already hides
    /// synthetic/host prompts. Transport calls were removed before projection.
    static func renderMarkdown(from envelopes: [SessionUpdateEnvelope]) -> String {
        let replay = envelopes.compactMap { envelope -> SessionUpdate? in
            guard envelope.method == "session/update" else { return nil }
            return .acp(envelope.params)
        }
        let projection = SessionTranscriptProjector.project(replay)
        let toolSummaries = envelopes.compactMap { envelope -> String? in
            guard envelope.method == "session/update",
                  let update = envelope.params["update"],
                  update["sessionUpdate"]?.stringValue == "tool_call"
            else { return nil }
            return toolSummary(update)
        }

        var blocks: [ExportBlock] = []
        var toolIndex = 0
        for event in projection.events {
            switch event {
            case .userTextChunk(let original, let promptIndex):
                let text = stripContextWrappers(original)
                guard !text.isEmpty else { continue }
                if case .user(let previous, let previousPromptIndex)? = blocks.last,
                   previousPromptIndex == promptIndex
                {
                    blocks[blocks.count - 1] = .user(previous + text, promptIndex)
                } else {
                    blocks.append(.user(text, promptIndex))
                }
            case .assistantTextChunk(let text):
                guard !text.isEmpty else { continue }
                if case .assistant(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .assistant(previous + text)
                } else {
                    blocks.append(.assistant(text))
                }
            case .toolCall(let title, let paths):
                let summary: String
                if toolIndex < toolSummaries.count {
                    summary = toolSummaries[toolIndex]
                    toolIndex += 1
                } else if let path = paths.first {
                    summary = "Tool: \(title) (\(path))"
                } else {
                    summary = "Tool: \(title)"
                }
                blocks.append(.tool(summary))
            default:
                continue
            }
        }

        var output = ""
        var lastWasAssistant = false
        var inToolsSection = false
        for block in blocks {
            switch block {
            case .user(let text, _):
                if inToolsSection {
                    output.append("\n")
                    inToolsSection = false
                }
                output.append("## User\n\n\(text)\n\n")
                lastWasAssistant = false
            case .assistant(let text):
                if !lastWasAssistant {
                    if inToolsSection {
                        output.append("\n")
                        inToolsSection = false
                    }
                    output.append("## Assistant\n\n")
                }
                output.append("\(text)\n\n")
                lastWasAssistant = true
            case .tool(let summary):
                if !inToolsSection {
                    output.append("## Tools\n\n")
                    inToolsSection = true
                }
                output.append("- \(summary)\n")
                lastWasAssistant = false
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolSummary(_ update: JSONValue) -> String {
        let name = update["title"]?.stringValue ?? "unknown"
        let lowered = name.lowercased()
        let kind = update["kind"]?.stringValue?.lowercased() ?? ""
        let input: [String: JSONValue]
        if let object = update["rawInput"]?.objectValue {
            input = object
        } else if let text = update["rawInput"]?.stringValue,
                  let data = text.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            input = value.objectValue ?? [:]
        } else {
            input = [:]
        }
        let location = update["locations"]?.arrayValue?.first?["path"]?.stringValue
        let path = input["path"]?.stringValue
            ?? input["file_path"]?.stringValue
            ?? input["file"]?.stringValue
            ?? input["target_file"]?.stringValue
            ?? location

        if kind == "read" || ["read", "read_file", "view"].contains(lowered) {
            var summary = "Read: \(path ?? name)"
            if let range = input["line_range"]?.stringValue {
                summary += " (\(range))"
            }
            return summary
        }
        if kind == "edit"
            || ["edit", "write", "write_file", "search_replace", "apply_patch"].contains(lowered)
        {
            return "Edit: \(path ?? name)"
        }
        if kind == "execute" || ["bash", "exec", "execute", "shell"].contains(lowered) {
            let command = input["command"]?.stringValue ?? input["cmd"]?.stringValue ?? name
            let detail = input["description"]?.stringValue
            let description = detail.map { " (\($0))" } ?? ""
            return "Execute: \(command)\(description)"
        }
        if ["list_dir", "list_directory", "ls"].contains(lowered) {
            return "ListDir: \(path ?? name)"
        }
        if ["grep", "search", "file_search"].contains(lowered) || kind == "search" {
            return "Search: \(input["pattern"]?.stringValue ?? input["query"]?.stringValue ?? name)"
        }
        if ["web_fetch", "fetch"].contains(lowered) || kind == "fetch" {
            return "WebFetch: \(input["url"]?.stringValue ?? name)"
        }
        if ["web_search", "search_web"].contains(lowered) {
            return "WebSearch: \(input["query"]?.stringValue ?? name)"
        }
        if lowered == "memory_search" { return "MemorySearch" }
        if lowered == "integration_search" { return "IntegrationSearch (MCP tool discovery)" }
        if lowered.contains("__") { return "UseTool: \(name)" }
        return "Tool: \(name)"
    }

    private static func stripContextWrappers(_ value: String) -> String {
        var text = value
        for tag in ["fork-context", "resume-context"] {
            let opening = "<\(tag)>"
            let closing = "</\(tag)>"
            guard let start = text.range(of: opening),
                  let end = text.range(of: closing, range: start.upperBound..<text.endIndex)
            else { continue }
            let suffix = text[end.upperBound...].drop(while: \.isWhitespace)
            text = String(text[..<start.lowerBound]) + String(suffix)
        }
        return text
    }

    private static func expandedOutputPath(
        _ raw: String,
        environment: [String: String]
    ) -> URL {
        if raw == "~" {
            return OpenGrokHomeResolver.userHomeDirectory(environment: environment)
        }
        if raw.hasPrefix("~/") {
            return OpenGrokHomeResolver.userHomeDirectory(environment: environment)
                .appendingPathComponent(String(raw.dropFirst(2)))
        }
        return URL(fileURLWithPath: raw).standardizedFileURL
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy { root, candidate in
            pathsMatch(root, candidate)
        }
    }

    private static func pathsMatch(_ left: String, _ right: String) -> Bool {
        #if os(Windows)
        return left.replacingOccurrences(of: "\\", with: "/")
            .caseInsensitiveCompare(right.replacingOccurrences(of: "\\", with: "/"))
            == .orderedSame
        #else
        return left == right
        #endif
    }

    private static func notFound(_ sessionID: String) -> CLIApplicationError {
        .failed("Session '\(sessionID)' not found.")
    }

    private enum ExportBlock {
        case user(String, UInt64?)
        case assistant(String)
        case tool(String)
    }

    private struct ExportReplayJournal {
        let bytes: Data
        let knownTransportIDs: Set<String>
    }

    private struct ExportToolUpdate {
        let identifier: String
        let isCall: Bool
        let update: JSONValue
        let marked: Bool
    }

    private struct ExportPromptRunTracker {
        private var hasMarkedPrompt = false
        private var inUserRun = false
        private var currentPromptIndex: Int?

        mutating func startsCountedTurn(promptIndex: Int?) -> Bool {
            if promptIndex != nil { hasMarkedPrompt = true }
            let counts = !hasMarkedPrompt || promptIndex != nil
            let newRun = !inUserRun
                || ((hasMarkedPrompt || promptIndex != nil) && promptIndex != currentPromptIndex)
            if newRun { currentPromptIndex = promptIndex }
            inUserRun = true
            return newRun && counts
        }

        mutating func finishRun() {
            inUserRun = false
            currentPromptIndex = nil
        }
    }
}
