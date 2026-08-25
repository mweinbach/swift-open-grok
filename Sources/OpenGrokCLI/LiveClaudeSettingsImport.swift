import Foundation
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokFileUtils
import OpenGrokMCP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokShared
import OpenGrokTerminalCore
import OpenGrokWorkspace

private typealias ClaudeImportJSON = OpenGrokShared.JSONValue

enum LiveClaudeImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsafePath(String)
    case unreadableConfiguration(String)
    case malformedConfiguration(String)
    case sourceChanged
    case untrustedProject
    case managedPolicy(String)
    case transactionFailed

    var description: String {
        switch self {
        case .unsafePath(let path):
            "unsafe Claude import path: \(path)"
        case .unreadableConfiguration(let path):
            "cannot read existing configuration: \(path)"
        case .malformedConfiguration(let path):
            "existing configuration is malformed: \(path)"
        case .sourceChanged:
            "Claude settings changed since the preview; scan again before importing"
        case .untrustedProject:
            "project Claude settings require an explicitly trusted workspace"
        case .managedPolicy(let reason):
            "Claude setting blocked by managed policy: \(reason)"
        case .transactionFailed:
            "Claude settings import failed and its previous files were restored"
        }
    }
}

enum LiveClaudeImportPathKind: String, Sendable, Equatable {
    case skill = "extra_skill_dirs"
    case rule = "extra_rule_dirs"
}

enum LiveClaudeImportPayload: Sendable, Equatable {
    case permission(action: OpenGrokWorkspace.RuleAction, rule: String)
    case environment(key: String, value: String)
    case mcpServer(name: String, config: McpServerConfig)
    case hook(event: String, matcher: String?, command: String, timeout: UInt64?)
    case path(kind: LiveClaudeImportPathKind, value: String)

    var category: PagerClaudeImportCategory {
        switch self {
        case .permission: .permission
        case .environment: .environment
        case .mcpServer: .mcpServer
        case .hook: .hook
        case .path: .path
        }
    }

    var previewLabel: String {
        switch self {
        case .permission(let action, let rule):
            "\(action.rawValue) \(rule)"
        case .environment(let key, let value):
            "\(key) = <redacted, \(value.count) chars>"
        case .mcpServer(let name, _):
            name
        case .hook(let event, let matcher, let command, _):
            "\(event) [\(matcher ?? "*")] \(LiveClaudeSettingsImport.redactPreview(command))"
        case .path(let kind, let value):
            "\(kind == .skill ? "skill" : "rule") \(value)"
        }
    }
}

struct LiveClaudeImportEntry: Sendable, Equatable {
    let id: String
    let scope: PagerClaudeImportScope
    let payload: LiveClaudeImportPayload
    let blockedReason: String?

    var preview: PagerClaudeImportItem {
        PagerClaudeImportItem(
            id: id,
            scope: scope,
            category: payload.category,
            label: payload.previewLabel,
            isEnabled: blockedReason == nil,
            blockedReason: blockedReason
        )
    }
}

struct LiveClaudeImportPlan: Sendable, Equatable {
    var entries: [LiveClaudeImportEntry]
    var overlay: PagerClaudeImportOverlay
    let workingDirectory: URL
    let projectRoot: URL
    let userHome: URL
    let openGrokHome: URL
    let globalSourcePaths: [URL]
    let projectSourcePaths: [URL]
    let globalHash: String
    let projectHash: String
    let managedSettingsPath: URL?
    let warnings: [String]

    var selectedEntries: [LiveClaudeImportEntry] {
        entries.filter { entry in
            entry.blockedReason == nil && overlay.selectedIDs.contains(entry.id)
        }
    }
}

struct LiveClaudeImportResult: Sendable, Equatable {
    var globalCount: Int
    var projectCount: Int
    var modifiedFiles: [URL]

    var totalCount: Int { globalCount + projectCount }

    var summary: String {
        totalCount == 0
            ? "No items selected."
            : "Imported \(totalCount) Claude setting\(totalCount == 1 ? "" : "s")."
    }
}

enum LiveClaudeSettingsImport: Sendable {
    static let maximumSourceBytes = 1_048_576
    static let maximumSourceFiles = 64
    static let maximumItems = 1_024
    static let stateFileName = "claude_import_state.json"
    static let importedHooksFileName = "imported-from-claude.json"

    static func isImported(environment: [String: String]) -> Bool {
        let configuration = OpenGrokHomeResolver.resolve(environment: environment)
            .appendingPathComponent("config.toml")
        guard let data = try? PathSecurity.readNoFollow(
            configuration,
            maximumBytes: maximumSourceBytes
        ),
              let text = String(data: data, encoding: .utf8),
              let document = try? parseTOML(text)
        else { return false }
        return document[path: ["claude_compat", "imported"]]?.boolValue == true
    }

    static func scan(
        workingDirectory: URL,
        environment: [String: String],
        openGrokHome explicitHome: URL? = nil,
        managedSettingsPath: URL? = nil
    ) throws -> LiveClaudeImportPlan {
        let cwd = workingDirectory.standardizedFileURL
        let userHome = OpenGrokHomeResolver.userHomeDirectory(environment: environment)
            .standardizedFileURL
        let openGrokHome = (explicitHome ?? OpenGrokHomeResolver.resolve(environment: environment))
            .standardizedFileURL
        let projectRoot = LiveFolderTrustPrompt.workspaceRoot(
            for: cwd,
            environment: environment
        ).standardizedFileURL
        let security = LiveSecurityContext.resolve(
            workspaceRoot: cwd,
            environment: environment,
            isInteractive: false,
            managedSettingsPath: managedSettingsPath
        )
        let projectAllowed = security.projectTrusted && projectRoot != userHome

        var entries: [LiveClaudeImportEntry] = []
        var warnings: [String] = []
        var nextID = 0
        let globalSettings = globalClaudeSettingsPaths(home: userHome)
        let globalClaudeJSON = userHome.appendingPathComponent(".claude.json")
        var globalSources = globalSettings
        globalSources.append(globalClaudeJSON)

        for path in globalSettings {
            guard let object = readJSONObject(path, boundary: userHome, warnings: &warnings) else {
                continue
            }
            appendSettings(
                object,
                scope: .global,
                security: security,
                entries: &entries,
                nextID: &nextID
            )
        }

        if let object = readJSONObject(globalClaudeJSON, boundary: userHome, warnings: &warnings) {
            appendMCPServers(
                object["mcpServers"]?.objectValue,
                scope: .global,
                security: security,
                entries: &entries,
                nextID: &nextID
            )
            if projectAllowed,
               let projects = object["projects"]?.objectValue
            {
                for candidate in Set([cwd.path, projectRoot.path]).sorted() {
                    appendMCPServers(
                        projects[candidate]?["mcpServers"]?.objectValue,
                        scope: .project,
                        security: security,
                        entries: &entries,
                        nextID: &nextID
                    )
                }
            }
        }

        var projectSources: [URL] = []
        if projectAllowed {
            let settings = Array(
                projectClaudeSettingsPaths(cwd: cwd, home: userHome)
                    .prefix(maximumSourceFiles / 2)
            )
            projectSources.append(contentsOf: settings)
            for path in settings {
                guard isContained(path, in: projectRoot),
                      let object = readJSONObject(path, boundary: projectRoot, warnings: &warnings)
                else { continue }
                appendSettings(
                    object,
                    scope: .project,
                    security: security,
                    entries: &entries,
                    nextID: &nextID
                )
            }

            for path in projectMCPPaths(cwd: cwd, root: projectRoot) {
                projectSources.append(path)
                guard let object = readJSONObject(path, boundary: projectRoot, warnings: &warnings)
                else { continue }
                appendMCPServers(
                    object["mcpServers"]?.objectValue,
                    scope: .project,
                    security: security,
                    entries: &entries,
                    nextID: &nextID
                )
            }
        }

        appendPathDirectories(
            base: userHome,
            scope: .global,
            boundary: userHome,
            entries: &entries,
            nextID: &nextID
        )
        if projectAllowed {
            appendPathDirectories(
                base: projectRoot,
                scope: .project,
                boundary: projectRoot,
                entries: &entries,
                nextID: &nextID
            )
        }

        entries = Array(entries.prefix(maximumItems))
        return LiveClaudeImportPlan(
            entries: entries,
            overlay: PagerClaudeImportOverlay(items: entries.map(\.preview)),
            workingDirectory: cwd,
            projectRoot: projectRoot,
            userHome: userHome,
            openGrokHome: openGrokHome,
            globalSourcePaths: Array(globalSources.prefix(maximumSourceFiles)),
            projectSourcePaths: Array(projectSources.prefix(maximumSourceFiles)),
            globalHash: sourceHash(paths: globalSources),
            projectHash: sourceHash(paths: projectSources),
            managedSettingsPath: managedSettingsPath,
            warnings: warnings
        )
    }

    static func apply(
        _ plan: LiveClaudeImportPlan,
        environment: [String: String],
        beforeWrite: (@Sendable (_ completedWrites: Int, _ nextPath: URL) throws -> Void)? = nil
    ) throws -> LiveClaudeImportResult {
        guard sourceHash(paths: plan.globalSourcePaths) == plan.globalHash,
              sourceHash(paths: plan.projectSourcePaths) == plan.projectHash
        else {
            throw LiveClaudeImportError.sourceChanged
        }

        let security = LiveSecurityContext.resolve(
            workspaceRoot: plan.workingDirectory,
            environment: environment,
            isInteractive: false,
            managedSettingsPath: plan.managedSettingsPath
        )
        let selected = plan.selectedEntries
        if selected.contains(where: { $0.scope == .project }), !security.projectTrusted {
            throw LiveClaudeImportError.untrustedProject
        }
        for item in selected {
            if let reason = managedBlockReason(for: item.payload, security: security) {
                throw LiveClaudeImportError.managedPolicy(reason)
            }
        }

        let global = selected.filter { $0.scope == .global }
        let project = selected.filter { $0.scope == .project }
        let globalConfig = plan.openGrokHome.appendingPathComponent("config.toml")
        let projectConfig = plan.projectRoot.appendingPathComponent(".opengrok/config.toml")
        var writes: [StagedWrite] = []
        var result = LiveClaudeImportResult(globalCount: 0, projectCount: 0, modifiedFiles: [])

        if !project.isEmpty {
            let staged = try stageConfig(
                at: projectConfig,
                items: project,
                boundary: plan.projectRoot,
                includeMarker: false
            )
            result.projectCount += staged.count
            if staged.changed {
                writes.append(staged.write)
                result.modifiedFiles.append(projectConfig)
            }
        }

        if let hooks = try stageHooks(
            items: project,
            at: plan.projectRoot.appendingPathComponent(".opengrok/hooks/\(importedHooksFileName)"),
            boundary: plan.projectRoot
        ) {
            result.projectCount += hooks.count
            writes.append(hooks.write)
            result.modifiedFiles.append(hooks.write.path)
        }

        if let hooks = try stageHooks(
            items: global,
            at: plan.openGrokHome.appendingPathComponent("hooks/\(importedHooksFileName)"),
            boundary: plan.openGrokHome
        ) {
            result.globalCount += hooks.count
            writes.append(hooks.write)
            result.modifiedFiles.append(hooks.write.path)
        }

        let state = try stageImportState(plan: plan)
        writes.append(state)
        result.modifiedFiles.append(state.path)

        // The global marker is published last: a failed project/hook/state
        // write cannot switch compatibility off beneath a partial import.
        let globalStage = try stageConfig(
            at: globalConfig,
            items: global,
            boundary: plan.openGrokHome,
            includeMarker: true
        )
        result.globalCount += globalStage.count
        writes.append(globalStage.write)
        if globalStage.changed {
            result.modifiedFiles.append(globalConfig)
        }

        try commit(writes, beforeWrite: beforeWrite)
        return result
    }

    static func redactPreview(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?i)(bearer\s+)[^\s\"';]+"#,
            #"(?i)((?:token|secret|password|passwd|api[_-]?key|authorization)\s*[:=]\s*)[^\s\"';]+"#,
            #"(?i)(https?://[^\s/?#]+[^\s?#]*\?)[^\s\"']+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1<redacted>",
                options: .regularExpression
            )
        }
        return result
    }

    private static func readJSONObject(
        _ path: URL,
        boundary: URL,
        warnings: inout [String]
    ) -> [String: ClaudeImportJSON]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard isContained(path, in: boundary),
              isCanonicalParentContained(path, in: boundary)
        else {
            warnings.append("Skipped unsafe Claude settings source: \(path.path)")
            return nil
        }
        do {
            let data = try PathSecurity.readNoFollow(path, maximumBytes: maximumSourceBytes)
            let value = try JSONDecoder().decode(ClaudeImportJSON.self, from: data)
            guard let object = value.objectValue else {
                warnings.append("Skipped malformed Claude settings source: \(path.path)")
                return nil
            }
            return object
        } catch {
            warnings.append("Skipped unreadable Claude settings source: \(path.path)")
            return nil
        }
    }

    private static func appendSettings(
        _ object: [String: ClaudeImportJSON],
        scope: PagerClaudeImportScope,
        security: LiveSecurityContext,
        entries: inout [LiveClaudeImportEntry],
        nextID: inout Int
    ) {
        if let permissions = object["permissions"]?.objectValue {
            for action in [OpenGrokWorkspace.RuleAction.allow, .deny, .ask] {
                guard let rules = permissions[action.rawValue]?.arrayValue else { continue }
                for candidate in rules {
                    guard let text = candidate.stringValue,
                          (try? parsePermissionRule(text, action: action, source: .settings)) != nil
                    else { continue }
                    append(
                        .permission(action: action, rule: text),
                        scope: scope,
                        security: security,
                        entries: &entries,
                        nextID: &nextID
                    )
                }
            }
        }

        if let environment = object["env"]?.objectValue {
            for key in environment.keys.sorted() {
                guard let value = environment[key]?.stringValue,
                      key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression)
                        != nil
                else { continue }
                append(
                    .environment(key: key, value: value),
                    scope: scope,
                    security: security,
                    entries: &entries,
                    nextID: &nextID
                )
            }
        }

        if let hooks = object["hooks"]?.objectValue {
            for event in hooks.keys.sorted() {
                guard let groups = hooks[event]?.arrayValue else { continue }
                for group in groups {
                    let matcher = group["matcher"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                    guard let handlers = group["hooks"]?.arrayValue else { continue }
                    for handler in handlers {
                        guard handler["type"]?.stringValue == "command",
                              let command = handler["command"]?.stringValue
                        else { continue }
                        let timeout = handler["timeout"]?.int64Value.flatMap(UInt64.init(exactly:))
                        append(
                            .hook(event: event, matcher: matcher, command: command, timeout: timeout),
                            scope: scope,
                            security: security,
                            entries: &entries,
                            nextID: &nextID
                        )
                    }
                }
            }
        }
    }

    private static func appendMCPServers(
        _ servers: [String: ClaudeImportJSON]?,
        scope: PagerClaudeImportScope,
        security: LiveSecurityContext,
        entries: inout [LiveClaudeImportEntry],
        nextID: inout Int
    ) {
        guard let servers else { return }
        for name in servers.keys.sorted() {
            guard !name.isEmpty, name.count <= 256,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let value = servers[name],
                  let config = try? value.decode(McpServerConfig.self),
                  MCPConfigLoader.blankTransportField(config) == nil
            else { continue }
            append(
                .mcpServer(name: name, config: config),
                scope: scope,
                security: security,
                entries: &entries,
                nextID: &nextID
            )
        }
    }

    private static func append(
        _ payload: LiveClaudeImportPayload,
        scope: PagerClaudeImportScope,
        security: LiveSecurityContext,
        entries: inout [LiveClaudeImportEntry],
        nextID: inout Int
    ) {
        guard entries.count < maximumItems else { return }
        let entry = LiveClaudeImportEntry(
            id: "\(scope.rawValue)-\(nextID)",
            scope: scope,
            payload: payload,
            blockedReason: managedBlockReason(for: payload, security: security)
        )
        nextID += 1
        entries.append(entry)
    }

    private static func managedBlockReason(
        for payload: LiveClaudeImportPayload,
        security: LiveSecurityContext
    ) -> String? {
        switch payload {
        case .mcpServer(let name, let config):
            let identity = ManagedMCPServerIdentity(name: name, transport: config.transport)
            return security.managedMCPPolicy.blockReason(for: identity)
        case .permission(let action, let text):
            guard action == .allow,
                  let candidate = try? parsePermissionRule(text, action: action)
            else { return nil }
            let blocked = security.permissions.config.rules.contains { rule in
                rule.action == .deny && rule.source.isAdminTier
                    && (rule.tool == .any || rule.tool == candidate.tool)
                    && (rule.pattern == nil || rule.pattern == candidate.pattern)
            }
            return blocked ? "an administrator deny rule takes precedence" : nil
        case .environment, .hook, .path:
            return nil
        }
    }

    private static func appendPathDirectories(
        base: URL,
        scope: PagerClaudeImportScope,
        boundary: URL,
        entries: inout [LiveClaudeImportEntry],
        nextID: inout Int
    ) {
        for (kind, name) in [(LiveClaudeImportPathKind.skill, "skills"), (.rule, "rules")] {
            let directory = base.appendingPathComponent(".claude/\(name)")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  isCanonicalParentContained(directory, in: boundary),
                  (try? PathSecurity.isSymlink(directory)) == false
            else { continue }
            guard entries.count < maximumItems else { return }
            entries.append(LiveClaudeImportEntry(
                id: "\(scope.rawValue)-\(nextID)",
                scope: scope,
                payload: .path(kind: kind, value: directory.path),
                blockedReason: nil
            ))
            nextID += 1
        }
    }

    private static func projectMCPPaths(cwd: URL, root: URL) -> [URL] {
        var result: [URL] = []
        var directory = cwd.standardizedFileURL
        for _ in 0..<maximumSourceFiles {
            guard isContained(directory, in: root) else { break }
            result.append(directory.appendingPathComponent(".mcp.json"))
            if directory.path == root.standardizedFileURL.path { break }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return result
    }

    private static func isContained(_ path: URL, in root: URL) -> Bool {
        let candidate = path.standardizedFileURL.path
        let boundary = root.standardizedFileURL.path
        return candidate == boundary || candidate.hasPrefix(boundary + "/")
    }

    private static func isCanonicalParentContained(_ path: URL, in root: URL) -> Bool {
        guard let canonicalRoot = try? PathSecurity.canonicalize(root),
              let canonicalParent = try? PathSecurity.canonicalize(path.deletingLastPathComponent())
        else { return false }
        return isContained(canonicalParent, in: canonicalRoot)
    }

    private static func sourceHash(paths: [URL]) -> String {
        var bytes = Data()
        for path in Array(Set(paths)).sorted(by: { $0.path < $1.path }) {
            guard let content = try? PathSecurity.readNoFollow(
                path,
                maximumBytes: maximumSourceBytes
            ) else { continue }
            bytes.append(contentsOf: path.path.utf8)
            bytes.append(0)
            bytes.append(content)
            bytes.append(0)
        }
        return "sha256:\(SHA256.hexDigest(bytes))"
    }

    private struct StagedWrite {
        let path: URL
        let data: Data
        let previous: Data?
    }

    private struct CountedWrite {
        let write: StagedWrite
        let count: Int
        let changed: Bool
    }

    private static func stageConfig(
        at path: URL,
        items: [LiveClaudeImportEntry],
        boundary: URL,
        includeMarker: Bool
    ) throws -> CountedWrite {
        try validateDestination(path, boundary: boundary)
        let previous = try existingData(at: path)
        var root: TOMLValue
        if let previous {
            guard let text = String(data: previous, encoding: .utf8),
                  let parsed = try? parseTOML(text), parsed.table != nil
            else {
                throw LiveClaudeImportError.malformedConfiguration(path.path)
            }
            root = parsed
        } else {
            root = .table(TOMLTable())
        }

        guard var table = root.table else {
            throw LiveClaudeImportError.malformedConfiguration(path.path)
        }
        var count = 0
        for entry in items {
            switch entry.payload {
            case .permission(let action, let rule):
                count += try appendArrayValue(
                    table: &table,
                    section: "permission",
                    key: action.rawValue,
                    value: rule,
                    path: path
                )
            case .environment(let key, let value):
                var section = try sectionTable("env", in: table, path: path)
                if section[key] == nil {
                    section.insert(.string(value), forKey: key)
                    table.insert(.table(section), forKey: "env")
                    count += 1
                }
            case .mcpServer(let name, let configuration):
                let sectionName = MCPServerTableName.resolved(in: table)
                var section = try sectionTable(sectionName, in: table, path: path)
                if section[name] == nil {
                    section.insert(try TOMLValue.encoding(configuration), forKey: name)
                    table.insert(.table(section), forKey: sectionName)
                    count += 1
                }
            case .path(let kind, let value):
                count += try appendArrayValue(
                    table: &table,
                    section: "paths",
                    key: kind.rawValue,
                    value: value,
                    path: path
                )
            case .hook:
                continue
            }
        }

        if includeMarker {
            var marker = try sectionTable("claude_compat", in: table, path: path)
            marker.insert(.boolean(true), forKey: "imported")
            table.insert(.table(marker), forKey: "claude_compat")
        }

        root = .table(table)
        let data = Data(TOMLEncoder.encode(root).utf8)
        return CountedWrite(
            write: StagedWrite(path: path, data: data, previous: previous),
            count: count,
            changed: previous != data
        )
    }

    private static func sectionTable(
        _ key: String,
        in root: TOMLTable,
        path: URL
    ) throws -> TOMLTable {
        guard let existing = root[key] else { return TOMLTable() }
        guard let table = existing.table else {
            throw LiveClaudeImportError.malformedConfiguration(path.path)
        }
        return table
    }

    private static func appendArrayValue(
        table: inout TOMLTable,
        section: String,
        key: String,
        value: String,
        path: URL
    ) throws -> Int {
        var sectionTable = try self.sectionTable(section, in: table, path: path)
        let existing: [TOMLValue]
        if let candidate = sectionTable[key] {
            guard let array = candidate.arrayValue else {
                throw LiveClaudeImportError.malformedConfiguration(path.path)
            }
            existing = array
        } else {
            existing = []
        }
        guard !existing.contains(.string(value)) else { return 0 }
        sectionTable.insert(.array(existing + [.string(value)]), forKey: key)
        table.insert(.table(sectionTable), forKey: section)
        return 1
    }

    private static func stageHooks(
        items: [LiveClaudeImportEntry],
        at path: URL,
        boundary: URL
    ) throws -> CountedWrite? {
        let hookItems = items.filter { $0.payload.category == .hook }
        guard !hookItems.isEmpty else { return nil }
        try validateDestination(path, boundary: boundary)
        let previous = try existingData(at: path)
        var object: [String: ClaudeImportJSON]
        if let previous {
            guard let decoded = try? JSONDecoder().decode(ClaudeImportJSON.self, from: previous),
                  let root = decoded.objectValue
            else {
                throw LiveClaudeImportError.malformedConfiguration(path.path)
            }
            object = root
        } else {
            object = [:]
        }
        var events: [String: ClaudeImportJSON]
        if let existing = object["hooks"] {
            guard let decoded = existing.objectValue else {
                throw LiveClaudeImportError.malformedConfiguration(path.path)
            }
            events = decoded
        } else {
            events = [:]
        }

        var count = 0
        for item in hookItems {
            guard case .hook(let event, let matcher, let command, let timeout) = item.payload
            else { continue }
            var groups: [ClaudeImportJSON]
            if let existing = events[event] {
                guard let decoded = existing.arrayValue else {
                    throw LiveClaudeImportError.malformedConfiguration(path.path)
                }
                groups = decoded
            } else {
                groups = []
            }

            var duplicate = false
            for (groupIndex, group) in groups.enumerated() {
                guard var fields = group.objectValue,
                      fields["matcher"]?.stringValue == matcher,
                      var handlers = fields["hooks"]?.arrayValue
                else { continue }
                for (handlerIndex, handler) in handlers.enumerated() {
                    guard var values = handler.objectValue,
                          values["type"]?.stringValue == "command",
                          values["command"]?.stringValue == command
                    else { continue }
                    if let timeout {
                        values["timeout"] = .number(.uint64(timeout))
                    } else {
                        values.removeValue(forKey: "timeout")
                    }
                    handlers[handlerIndex] = .object(values)
                    fields["hooks"] = .array(handlers)
                    groups[groupIndex] = .object(fields)
                    duplicate = true
                    break
                }
                if duplicate { break }
            }

            if !duplicate {
                var handler: [String: ClaudeImportJSON] = [
                    "type": .string("command"),
                    "command": .string(command),
                ]
                if let timeout { handler["timeout"] = .number(.uint64(timeout)) }
                var group: [String: ClaudeImportJSON] = ["hooks": .array([.object(handler)])]
                if let matcher { group["matcher"] = .string(matcher) }
                groups.append(.object(group))
                count += 1
            }
            events[event] = .array(groups)
        }

        object["hooks"] = .object(events)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(ClaudeImportJSON.object(object))
        guard previous != data else { return nil }
        return CountedWrite(
            write: StagedWrite(path: path, data: data, previous: previous),
            count: count,
            changed: true
        )
    }

    private struct ImportScopeState: Codable {
        var last_hash: String
        var last_checked: String
    }

    private struct ImportState: Codable {
        var version: Int = 1
        var global: ImportScopeState?
        var projects: [String: ImportScopeState] = [:]
    }

    private static func stageImportState(plan: LiveClaudeImportPlan) throws -> StagedWrite {
        let path = plan.openGrokHome.appendingPathComponent(stateFileName)
        try validateDestination(path, boundary: plan.openGrokHome)
        let previous = try existingData(at: path)
        var state: ImportState
        if let previous {
            guard let decoded = try? JSONDecoder().decode(ImportState.self, from: previous) else {
                throw LiveClaudeImportError.malformedConfiguration(path.path)
            }
            state = decoded
        } else {
            state = ImportState()
        }
        let now = ISO8601DateFormatter().string(from: Date())
        state.global = ImportScopeState(last_hash: plan.globalHash, last_checked: now)
        state.projects[plan.projectRoot.path] = ImportScopeState(
            last_hash: plan.projectHash,
            last_checked: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return StagedWrite(path: path, data: try encoder.encode(state), previous: previous)
    }

    private static func existingData(at path: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do {
            return try PathSecurity.readNoFollow(path, maximumBytes: maximumSourceBytes)
        } catch {
            throw LiveClaudeImportError.unreadableConfiguration(path.path)
        }
    }

    private static func validateDestination(_ path: URL, boundary: URL) throws {
        guard isContained(path, in: boundary) else {
            throw LiveClaudeImportError.unsafePath(path.path)
        }
        var existingParent = path.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: existingParent.path) {
            let parent = existingParent.deletingLastPathComponent()
            guard parent.path != existingParent.path else {
                throw LiveClaudeImportError.unsafePath(path.path)
            }
            existingParent = parent
        }
        if FileManager.default.fileExists(atPath: boundary.path) {
            guard let canonicalRoot = try? PathSecurity.canonicalize(boundary),
                  let canonicalParent = try? PathSecurity.canonicalize(existingParent),
                  isContained(canonicalParent, in: canonicalRoot)
            else {
                throw LiveClaudeImportError.unsafePath(path.path)
            }
        }
        if FileManager.default.fileExists(atPath: path.path),
           (try? PathSecurity.isSymlink(path)) != false {
            throw LiveClaudeImportError.unsafePath(path.path)
        }
    }

    private static func commit(
        _ writes: [StagedWrite],
        beforeWrite: (@Sendable (_ completedWrites: Int, _ nextPath: URL) throws -> Void)?
    ) throws {
        var committed: [StagedWrite] = []
        do {
            for write in writes {
                try beforeWrite?(committed.count, write.path)
                try FileManager.default.createDirectory(
                    at: write.path.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try AtomicFile.write(write.path, data: write.data, options: .ownerOnly)
                committed.append(write)
            }
        } catch {
            for write in committed.reversed() {
                if let previous = write.previous {
                    try? AtomicFile.write(write.path, data: previous, options: .ownerOnly)
                } else {
                    try? FileManager.default.removeItem(at: write.path)
                }
            }
            throw LiveClaudeImportError.transactionFailed
        }
    }
}

extension LiveInteractiveControllerRenderer {
    func presentClaudeSettingsImport() throws {
        let cwd = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let plan = try LiveClaudeSettingsImport.scan(
            workingDirectory: cwd,
            environment: environment,
            openGrokHome: openGrokHome
        )
        guard !plan.entries.isEmpty else {
            let result = try LiveClaudeSettingsImport.apply(plan, environment: environment)
            guard result.totalCount == 0 else {
                throw LiveClaudeImportError.transactionFailed
            }
            note("No Claude settings found to import.")
            try renderState()
            return
        }
        claudeImportPlan = plan
        overlays.push(plan.overlay.makeOverlay())
        try renderState()
    }

    func handleClaudeImportOverlaySelection(rowID: String) throws -> String? {
        guard var plan = claudeImportPlan else { return nil }
        guard plan.overlay.toggle(rowID: rowID) else { return nil }
        claudeImportPlan = plan
        try refreshClaudeImportOverlay(plan)
        return nil
    }

    func handleClaudeImportOverlayKey(_ key: KeyEvent) throws -> OpenGrokPagerInputRouting? {
        guard overlays.focused?.id == PagerClaudeImportOverlay.overlayID,
              key.modifiers.isEmpty,
              var plan = claudeImportPlan
        else { return nil }

        switch key.key {
        case .char(" "):
            guard case .list(let list)? = overlays.focused?.content,
                  let selected = list.selectedRow,
                  plan.overlay.toggle(rowID: selected.id)
            else { return .consumed }
            claudeImportPlan = plan
            try refreshClaudeImportOverlay(plan)
            return .consumed
        case .char("a"):
            plan.overlay.selectAll()
            claudeImportPlan = plan
            try refreshClaudeImportOverlay(plan)
            return .consumed
        case .char("n"):
            plan.overlay.selectNone()
            claudeImportPlan = plan
            try refreshClaudeImportOverlay(plan)
            return .consumed
        case .enter:
            do {
                let result = try LiveClaudeSettingsImport.apply(plan, environment: environment)
                overlays.dismiss(id: PagerClaudeImportOverlay.overlayID)
                claudeImportPlan = nil
                note(result.summary)
            } catch {
                note("Failed to import Claude settings: \(error)")
            }
            try renderState()
            return .consumed
        default:
            return nil
        }
    }

    private func refreshClaudeImportOverlay(_ plan: LiveClaudeImportPlan) throws {
        let currentID: String?
        if case .list(let list)? = overlays.focused?.content {
            currentID = list.selectedRow?.id
        } else {
            currentID = nil
        }
        let updated = overlays.updateList(id: PagerClaudeImportOverlay.overlayID) { list in
            list.rows = plan.overlay.rows
            if let currentID,
               let index = list.rows.firstIndex(where: { $0.id == currentID }) {
                list.selectedIndex = index
            }
        }
        guard updated else { throw LiveClaudeImportError.transactionFailed }
        let retitled = overlays.retitle(
            id: PagerClaudeImportOverlay.overlayID,
            title: plan.overlay.title
        )
        guard retitled else { throw LiveClaudeImportError.transactionFailed }
        try renderState()
    }
}
