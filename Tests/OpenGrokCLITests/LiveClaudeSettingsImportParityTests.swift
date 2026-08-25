import Foundation
import OpenGrokConfig
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
import OpenGrokWorkspace
import Testing

@testable import OpenGrokCLI

private final class ClaudeImportTerminalSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var output: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: output, as: UTF8.self)
    }

    var visibleText: String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    func write(bytes: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        output.append(contentsOf: bytes)
    }

    func flush() throws {}
}

private struct ClaudeSettingsImportFixture: Sendable {
    let root: URL
    let ownerHome: URL
    let state: URL
    let workspace: URL
    let hookMarker: URL
    let processMarker: URL
    let environment: [String: String]

    init(trusted: Bool = false) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-grok-claude-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        root = temporary.standardizedFileURL.resolvingSymlinksInPath()
        ownerHome = root.appendingPathComponent("owner", isDirectory: true)
        state = root.appendingPathComponent("state", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        hookMarker = root.appendingPathComponent("hook-executed")
        processMarker = root.appendingPathComponent("mcp-connected")

        for directory in [
            ownerHome.appendingPathComponent(".claude", isDirectory: true),
            state,
            workspace.appendingPathComponent(".claude", isDirectory: true),
            workspace.appendingPathComponent(".git", isDirectory: true),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": ownerHome.path,
            "OPENGROK_HOME": state.path,
            "GROK_FOLDER_TRUST": "1",
            "GROK_SANDBOX": "off",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
        if trusted {
            try grantTrust()
        }
    }

    func grantTrust() throws {
        var trust = PersistentFolderTrustStore(environment: environment)
        try trust.record(workspace, trusted: true)
    }

    func writeOwnerSettings(_ object: [String: Any], local: Bool = false) throws {
        let name = local ? "settings.local.json" : "settings.json"
        try writeJSON(object, to: ownerHome.appendingPathComponent(".claude/\(name)"))
    }

    func writeProjectSettings(_ object: [String: Any], local: Bool = false) throws {
        let name = local ? "settings.local.json" : "settings.json"
        try writeJSON(object, to: workspace.appendingPathComponent(".claude/\(name)"))
    }

    func writeOwnerMCP(_ object: [String: Any]) throws {
        try writeJSON(object, to: ownerHome.appendingPathComponent(".claude.json"))
    }

    func writeProjectMCP(_ object: [String: Any]) throws {
        try writeJSON(object, to: workspace.appendingPathComponent(".mcp.json"))
    }

    func writeJSON(_ object: [String: Any], to path: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: path, options: .atomic)
    }

    func scan(managedSettingsPath: URL? = nil) throws -> LiveClaudeImportPlan {
        try LiveClaudeSettingsImport.scan(
            workingDirectory: workspace,
            environment: environment,
            openGrokHome: state,
            managedSettingsPath: managedSettingsPath
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Live Claude settings import parity")
struct LiveClaudeSettingsImportParityTests {
    @Test("trusted owner and workspace sources produce bounded categorized secret-free previews")
    func discoversCategorizedSourcesWithoutExposingSecrets() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }

        try fixture.writeOwnerSettings([
            "permissions": [
                "allow": ["Bash(git status)", "UnknownTool(nope)"],
                "deny": ["Read(.env)"],
            ],
            "env": ["OWNER_TOKEN": "owner-super-secret", "BAD-NAME": "reject-me"],
            "hooks": ["PreToolUse": [[
                "matcher": "Bash",
                "hooks": [[
                    "type": "command",
                    "command": "printf token=hook-super-secret",
                    "timeout": 7,
                ]],
            ]]],
        ])
        try fixture.writeProjectSettings([
            "permissions": ["ask": ["Edit(project.swift)"]],
            "env": ["PROJECT_TOKEN": "project-super-secret"],
        ])
        try fixture.writeOwnerMCP([
            "mcpServers": [
                "owner-server": [
                    "command": "/usr/bin/touch",
                    "args": [fixture.processMarker.path],
                    "env": ["HIDDEN_SERVER_KEY": "server-super-secret"],
                ],
                "invalid-server": ["url": ""],
            ],
            "projects": [
                fixture.workspace.path: [
                    "mcpServers": ["scoped-owner-server": ["url": "https://mcp.example.test"]],
                ],
                fixture.root.appendingPathComponent("other").path: [
                    "mcpServers": ["foreign-server": ["url": "https://foreign.example.test"]],
                ],
            ],
        ])
        try fixture.writeProjectMCP([
            "mcpServers": ["project-server": ["command": "/usr/bin/true"]],
        ])
        try FileManager.default.createDirectory(
            at: fixture.ownerHome.appendingPathComponent(".claude/rules"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(".claude/skills"),
            withIntermediateDirectories: true
        )

        let plan = try fixture.scan()
        let previews = plan.entries.map(\.preview)
        #expect(Set(previews.map(\.category)) == Set(PagerClaudeImportCategory.allCases))
        #expect(Set(previews.map(\.scope)) == Set(PagerClaudeImportScope.allCases))
        #expect(previews.contains { $0.scope == .global && $0.label == "owner-server" })
        #expect(previews.contains { $0.scope == .project && $0.label == "scoped-owner-server" })
        #expect(previews.contains { $0.scope == .project && $0.label == "project-server" })
        #expect(!previews.contains { $0.label.contains("foreign-server") })
        #expect(!previews.contains { $0.label.contains("invalid-server") })
        #expect(!previews.contains { $0.label.contains("BAD-NAME") })
        #expect(!previews.contains { $0.label.contains("UnknownTool") })

        let displayed = previews.map { "\($0.label) \($0.detail ?? "")" }.joined(separator: "\n")
        #expect(displayed.contains("OWNER_TOKEN = <redacted"))
        #expect(displayed.contains("token=<redacted>"))
        #expect(!displayed.contains("owner-super-secret"))
        #expect(!displayed.contains("project-super-secret"))
        #expect(!displayed.contains("hook-super-secret"))
        #expect(!displayed.contains("server-super-secret"))
        #expect(!FileManager.default.fileExists(atPath: fixture.hookMarker.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.processMarker.path))
        #expect(plan.overlay.selectedCount == plan.entries.count)
    }

    @Test("untrusted project files and owner-file project stanzas stay absent until durable trust")
    func projectImportsRequirePersistedFolderTrust() throws {
        let fixture = try ClaudeSettingsImportFixture()
        defer { fixture.dispose() }

        try fixture.writeOwnerSettings(["env": ["OWNER_ONLY": "owner"]])
        try fixture.writeProjectSettings(["env": ["PROJECT_ONLY": "project"]])
        try fixture.writeProjectMCP([
            "mcpServers": ["project-server": ["command": "/usr/bin/true"]],
        ])
        try fixture.writeOwnerMCP([
            "projects": [fixture.workspace.path: [
                "mcpServers": ["owner-project-server": ["command": "/usr/bin/true"]],
            ]],
        ])

        let untrusted = try fixture.scan()
        #expect(!untrusted.entries.isEmpty)
        #expect(untrusted.entries.allSatisfy { $0.scope == .global })
        #expect(untrusted.projectSourcePaths.isEmpty)

        try fixture.grantTrust()
        let trusted = try fixture.scan()
        #expect(trusted.entries.contains { $0.scope == .project })
        #expect(trusted.entries.contains { $0.preview.label == "project-server" })
        #expect(trusted.entries.contains { $0.preview.label == "owner-project-server" })
    }

    @Test("managed MCP denials and administrator permission denials remain visible but unselectable")
    func protectedManagedPolicyBlocksImportedItems() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }

        try fixture.writeOwnerSettings([
            "permissions": ["allow": ["Bash(git status)", "Read(safe.txt)"]],
        ])
        try fixture.writeOwnerMCP([
            "mcpServers": [
                "denied-server": ["command": "/usr/bin/true"],
                "allowed-server": ["command": "/usr/bin/true"],
            ],
        ])
        let policy = fixture.root.appendingPathComponent("managed-settings.json")
        try fixture.writeJSON([
            "permissions": ["deny": ["Bash(git status)"]],
            "deniedMcpServers": [["serverName": "denied-server"]],
        ], to: policy)

        var plan = try fixture.scan(managedSettingsPath: policy)
        let deniedServer = try #require(plan.entries.first {
            $0.preview.label == "denied-server"
        })
        let deniedPermission = try #require(plan.entries.first {
            $0.preview.label == "allow Bash(git status)"
        })
        #expect(deniedServer.blockedReason?.contains("deniedMcpServers") == true)
        #expect(deniedPermission.blockedReason?.contains("administrator") == true)
        #expect(!plan.overlay.selectedIDs.contains(deniedServer.id))
        #expect(!plan.overlay.selectedIDs.contains(deniedPermission.id))
        plan.overlay.selectAll()
        #expect(!plan.overlay.selectedIDs.contains(deniedServer.id))
        #expect(!plan.overlay.selectedIDs.contains(deniedPermission.id))

        let result = try LiveClaudeSettingsImport.apply(plan, environment: fixture.environment)
        #expect(result.globalCount == 2)
        let document = try parseTOML(String(
            contentsOf: fixture.state.appendingPathComponent("config.toml"),
            encoding: .utf8
        ))
        #expect(document[path: ["mcp_servers", "allowed-server"]] != nil)
        #expect(document[path: ["mcp_servers", "denied-server"]] == nil)
        #expect(document[path: ["permission", "allow"]]?.arrayValue == [
            .string("Read(safe.txt)"),
        ])
    }

    @Test("nofollow bounded scanning rejects oversized files, linked sources, and linked path roots")
    func rejectsSymlinkEscapeAndOversizedSources() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }

        let outside = fixture.root.appendingPathComponent("outside.json")
        try fixture.writeJSON(["env": ["ESCAPED_SECRET": "outside-super-secret"]], to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.ownerHome.appendingPathComponent(".claude/settings.json"),
            withDestinationURL: outside
        )
        try Data(repeating: 0x61, count: LiveClaudeSettingsImport.maximumSourceBytes + 1)
            .write(to: fixture.ownerHome.appendingPathComponent(".claude/settings.local.json"))
        try FileManager.default.createSymbolicLink(
            at: fixture.ownerHome.appendingPathComponent(".claude.json"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent(".mcp.json"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.ownerHome.appendingPathComponent(".claude/skills"),
            withDestinationURL: fixture.workspace
        )

        let plan = try fixture.scan()
        #expect(plan.entries.isEmpty)
        #expect(plan.warnings.count >= 4)
        let preview = plan.entries.map { $0.preview.label }.joined(separator: "\n")
        #expect(!preview.contains("outside-super-secret"))
        #expect(!plan.warnings.joined(separator: "\n").contains("outside-super-secret"))
    }

    @Test("explicit apply is additive, owner-private, durable, and never executes hooks or MCP")
    func explicitApplyWritesCanonicalFilesWithoutRunningImportedCode() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }

        let ownerConfig = fixture.state.appendingPathComponent("config.toml")
        try """
        [env]
        EXISTING_KEY = "existing-value"

        [permission]
        allow = ["Read(existing.txt)"]

        [mcp_servers.existing-server]
        command = "/bin/existing"
        """.write(to: ownerConfig, atomically: true, encoding: .utf8)
        try fixture.writeOwnerSettings([
            "permissions": ["allow": ["Read(existing.txt)", "Bash(git status)"]],
            "env": ["EXISTING_KEY": "must-not-overwrite", "OWNER_KEY": "owner-secret"],
            "hooks": ["PreToolUse": [[
                "matcher": "Bash",
                "hooks": [[
                    "type": "command",
                    "command": "/usr/bin/touch '\(fixture.hookMarker.path)'",
                    "timeout": 9,
                ]],
            ]]],
        ])
        try fixture.writeProjectSettings([
            "env": ["PROJECT_KEY": "project-secret"],
            "hooks": ["PostToolUse": [["hooks": [[
                "type": "command",
                "command": "/usr/bin/touch '\(fixture.hookMarker.path)'",
            ]]]]],
        ])
        try fixture.writeOwnerMCP([
            "mcpServers": [
                "existing-server": ["command": "/bin/replacement"],
                "new-server": [
                    "command": "/usr/bin/touch",
                    "args": [fixture.processMarker.path],
                ],
            ],
        ])

        let plan = try fixture.scan()
        let result = try LiveClaudeSettingsImport.apply(plan, environment: fixture.environment)
        #expect(result.globalCount > 0)
        #expect(result.projectCount > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.hookMarker.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.processMarker.path))

        let owner = try parseTOML(String(contentsOf: ownerConfig, encoding: .utf8))
        #expect(owner[path: ["env", "EXISTING_KEY"]] == .string("existing-value"))
        #expect(owner[path: ["env", "OWNER_KEY"]] == .string("owner-secret"))
        #expect(owner[path: ["permission", "allow"]]?.arrayValue == [
            .string("Read(existing.txt)"),
            .string("Bash(git status)"),
        ])
        #expect(owner[path: ["mcp_servers", "existing-server", "command"]] == .string(
            "/bin/existing"
        ))
        #expect(owner[path: ["mcp_servers", "new-server", "command"]] == .string(
            "/usr/bin/touch"
        ))
        #expect(owner[path: ["claude_compat", "imported"]] == .boolean(true))
        #expect(LiveClaudeSettingsImport.isImported(environment: fixture.environment))

        let projectConfig = fixture.workspace.appendingPathComponent(".opengrok/config.toml")
        let project = try parseTOML(String(contentsOf: projectConfig, encoding: .utf8))
        #expect(project[path: ["env", "PROJECT_KEY"]] == .string("project-secret"))

        let ownerHooks = fixture.state.appendingPathComponent("hooks/imported-from-claude.json")
        let projectHooks = fixture.workspace.appendingPathComponent(
            ".opengrok/hooks/imported-from-claude.json"
        )
        let importedHook = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: ownerHooks)
        ) as? [String: Any])
        #expect(importedHook["hooks"] != nil)
        #expect(FileManager.default.fileExists(atPath: projectHooks.path))

        let statePath = fixture.state.appendingPathComponent("claude_import_state.json")
        let importState = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: statePath)
        ) as? [String: Any])
        #expect(importState["version"] as? Int == 1)
        let globalState = try #require(importState["global"] as? [String: Any])
        #expect(globalState["last_hash"] as? String == plan.globalHash)
        let projects = try #require(importState["projects"] as? [String: Any])
        let workspaceState = try #require(projects[fixture.workspace.path] as? [String: Any])
        #expect(workspaceState["last_hash"] as? String == plan.projectHash)

        #if !os(Windows)
        for path in [ownerConfig, projectConfig, ownerHooks, projectHooks, statePath] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue
            #expect(mode & 0o777 == 0o600)
        }
        #endif
    }

    @Test("deselected legacy permissions stop loading while protected administrator denies survive")
    func migrationMarkerCutsOffLegacyPermissionsWithoutRemovingManagedPolicy() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }

        try fixture.writeOwnerSettings([
            "permissions": ["allow": ["Bash(owner-deselected)"]],
            "env": ["IMPORTED_VALUE": "safe"],
        ])
        try fixture.writeProjectSettings([
            "permissions": ["allow": ["Read(project-deselected)"]],
        ])
        let managed = fixture.root.appendingPathComponent("managed-settings.json")
        try fixture.writeJSON([
            "permissions": ["deny": ["Edit(protected.txt)"]],
        ], to: managed)

        let before = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false,
            managedSettingsPath: managed
        )
        #expect(before.permissions.config.rules.contains {
            $0.action == .allow && $0.pattern == "owner-deselected" && $0.source == .settings
        })
        #expect(before.permissions.config.rules.contains {
            $0.action == .deny && $0.pattern == "protected.txt" && $0.source == .managedSettings
        })

        var plan = try fixture.scan(managedSettingsPath: managed)
        for entry in plan.entries where entry.payload.category == .permission {
            let deselectedPermission = plan.overlay.toggle(rowID: "item:\(entry.id)")
            #expect(deselectedPermission)
        }
        let result = try LiveClaudeSettingsImport.apply(plan, environment: fixture.environment)
        #expect(result.totalCount == 1)
        #expect(LiveClaudeSettingsImport.isImported(environment: fixture.environment))

        let after = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false,
            managedSettingsPath: managed
        )
        #expect(!after.permissions.config.rules.contains {
            $0.source == .settings
        })
        #expect(!after.permissions.config.rules.contains {
            $0.pattern == "owner-deselected" || $0.pattern == "project-deselected"
        })
        #expect(after.permissions.config.rules.contains {
            $0.action == .deny && $0.pattern == "protected.txt" && $0.source == .managedSettings
        })
    }

    @Test("select-none still durably records the explicit compatibility cutoff")
    func selectNonePublishesMarkerWithoutImportingAnything() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }
        try fixture.writeOwnerSettings(["env": ["DESELECTED": "secret"]])
        try fixture.writeProjectSettings(["env": ["PROJECT_DESELECTED": "secret"]])

        var plan = try fixture.scan()
        plan.overlay.selectNone()
        let result = try LiveClaudeSettingsImport.apply(plan, environment: fixture.environment)
        #expect(result.totalCount == 0)
        #expect(result.summary == "No items selected.")
        #expect(LiveClaudeSettingsImport.isImported(environment: fixture.environment))
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace
            .appendingPathComponent(".opengrok/config.toml").path))
        let config = try parseTOML(String(
            contentsOf: fixture.state.appendingPathComponent("config.toml"),
            encoding: .utf8
        ))
        #expect(config["env"] == nil)
        #expect(config[path: ["claude_compat", "imported"]] == .boolean(true))
        #expect(FileManager.default.fileExists(atPath: fixture.state
            .appendingPathComponent("claude_import_state.json").path))
    }

    @Test("source edits after preview fail closed without publishing state or the marker")
    func stalePreviewCannotBeApplied() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }
        try fixture.writeOwnerSettings(["env": ["ORIGINAL": "value"]])
        let plan = try fixture.scan()
        try fixture.writeOwnerSettings(["env": ["REPLACED": "value"]])

        #expect(throws: LiveClaudeImportError.sourceChanged) {
            try LiveClaudeSettingsImport.apply(plan, environment: fixture.environment)
        }
        #expect(!LiveClaudeSettingsImport.isImported(environment: fixture.environment))
        #expect(!FileManager.default.fileExists(atPath: fixture.state
            .appendingPathComponent("config.toml").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.state
            .appendingPathComponent("claude_import_state.json").path))
    }

    @Test("malformed existing configuration is preserved without a destructive rewrite")
    func malformedExistingConfigFailsClosed() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }
        try fixture.writeOwnerSettings(["env": ["NEW_KEY": "value"]])
        let plan = try fixture.scan()
        let config = fixture.state.appendingPathComponent("config.toml")
        let original = Data("[env\nAPI_KEY = \"sensitive\"\n".utf8)
        try original.write(to: config)

        #expect(throws: LiveClaudeImportError.malformedConfiguration(config.path)) {
            try LiveClaudeSettingsImport.apply(plan, environment: fixture.environment)
        }
        #expect(try Data(contentsOf: config) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.state
            .appendingPathComponent("claude_import_state.json").path))
    }

    @Test("a failed later atomic write restores every earlier project write")
    func failedCommitRollsBackEarlierFilesAndNeverPublishesMarker() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }
        try fixture.writeOwnerSettings(["env": ["OWNER_KEY": "new"]])
        try fixture.writeProjectSettings(["env": ["PROJECT_KEY": "new"]])

        let ownerConfig = fixture.state.appendingPathComponent("config.toml")
        let projectDirectory = fixture.workspace.appendingPathComponent(".opengrok")
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let projectConfig = projectDirectory.appendingPathComponent("config.toml")
        let originalOwner = Data("[env]\nOWNER_OLD = \"keep\"\n".utf8)
        let originalProject = Data("[env]\nPROJECT_OLD = \"keep\"\n".utf8)
        try originalOwner.write(to: ownerConfig)
        try originalProject.write(to: projectConfig)
        let plan = try fixture.scan()

        #expect(throws: LiveClaudeImportError.transactionFailed) {
            try LiveClaudeSettingsImport.apply(
                plan,
                environment: fixture.environment,
                beforeWrite: { completed, _ in
                    if completed == 1 {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            )
        }
        #expect(try Data(contentsOf: ownerConfig) == originalOwner)
        #expect(try Data(contentsOf: projectConfig) == originalProject)
        #expect(!FileManager.default.fileExists(atPath: fixture.state
            .appendingPathComponent("claude_import_state.json").path))
        #expect(!LiveClaudeSettingsImport.isImported(environment: fixture.environment))
    }

    @Test("linked destination parents cannot redirect project configuration outside the workspace")
    func linkedOutputDirectoryFailsClosed() throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }
        try fixture.writeProjectSettings(["env": ["PROJECT_KEY": "secret"]])
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent(".opengrok"),
            withDestinationURL: outside
        )
        let plan = try fixture.scan()
        let rejected = fixture.workspace.appendingPathComponent(".opengrok/config.toml")

        #expect(throws: LiveClaudeImportError.unsafePath(rejected.path)) {
            try LiveClaudeSettingsImport.apply(plan, environment: fixture.environment)
        }
        #expect(!FileManager.default.fileExists(atPath: outside
            .appendingPathComponent("config.toml").path))
        #expect(!LiveClaudeSettingsImport.isImported(environment: fixture.environment))
    }

    @Test("the real backed slash command presents, toggles, and commits through live pager input")
    func actualSlashRendererSelectionAndEnterPersistOnlyConfirmedItems() async throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }
        try fixture.writeOwnerSettings([
            "env": ["DESELECTED_TOKEN": "never-display-this-secret", "SELECTED_KEY": "saved"],
        ])
        let sink = ClaudeImportTerminalSink()
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 120, height: 36) },
                write: { _ in }
            ),
            sink: sink,
            workingDirectory: fixture.workspace.path,
            sessionID: "claude-import-live-seam",
            openGrokHome: fixture.state,
            environment: fixture.environment
        )
        try await renderer.begin()

        let outcome = try await renderer.performBackedSlashCommand(.importClaudeSettings)
        #expect(outcome == .completed)
        #expect(await renderer.testingFocusedOverlayID() == PagerClaudeImportOverlay.overlayID)
        let initial = try #require(await renderer.claudeImportPlan)
        #expect(initial.overlay.selectedCount == 2)
        try await renderer.testingForcePaint()
        #expect(sink.visibleText.contains("Import Claude settings"))
        #expect(!sink.text.contains("never-display-this-secret"))

        let clear = try await renderer.handleInput(.key(KeyEvent(key: "n")))
        #expect(clear == .consumed)
        #expect(await renderer.claudeImportPlan?.overlay.selectedCount == 0)
        let selectAll = try await renderer.handleInput(.key(KeyEvent(key: "a")))
        #expect(selectAll == .consumed)
        #expect(await renderer.claudeImportPlan?.overlay.selectedCount == 2)

        let deselected = try #require(initial.entries.first {
            $0.preview.label.hasPrefix("DESELECTED_TOKEN =")
        })
        let selected = try await renderer.select(
            overlayID: PagerClaudeImportOverlay.overlayID,
            rowID: "item:\(deselected.id)"
        )
        #expect(selected == nil)
        #expect(await renderer.claudeImportPlan?.overlay.selectedCount == 1)
        #expect(await renderer.testingFocusedOverlayID() == PagerClaudeImportOverlay.overlayID)
        #expect(!FileManager.default.fileExists(atPath: fixture.state
            .appendingPathComponent("config.toml").path))

        let confirmed = try await renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(confirmed == .consumed)
        #expect(await renderer.testingFocusedOverlayID() == nil)
        #expect(await renderer.claudeImportPlan == nil)
        let persisted = try parseTOML(String(
            contentsOf: fixture.state.appendingPathComponent("config.toml"),
            encoding: .utf8
        ))
        #expect(persisted[path: ["env", "SELECTED_KEY"]] == .string("saved"))
        #expect(persisted[path: ["env", "DESELECTED_TOKEN"]] == nil)
        #expect(persisted[path: ["claude_compat", "imported"]] == .boolean(true))
        #expect(!sink.text.contains("never-display-this-secret"))
        #expect(!FileManager.default.fileExists(atPath: fixture.hookMarker.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.processMarker.path))
        try await renderer.restoreTerminal()
    }

    @Test("Esc dismisses the actual import modal without mutating files or publishing a marker")
    func actualRendererCancellationNeverCommits() async throws {
        let fixture = try ClaudeSettingsImportFixture(trusted: true)
        defer { fixture.dispose() }
        try fixture.writeOwnerSettings(["env": ["CANCELLED_TOKEN": "secret"]])
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: OpenGrokLiveTerminal(
                isTTY: { false },
                size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
                write: { _ in }
            ),
            sink: ClaudeImportTerminalSink(),
            workingDirectory: fixture.workspace.path,
            sessionID: "claude-import-cancel",
            openGrokHome: fixture.state,
            environment: fixture.environment
        )
        try await renderer.begin()
        let presented = try await renderer.performBackedSlashCommand(.importClaudeSettings)
        #expect(presented == .completed)
        #expect(await renderer.testingFocusedOverlayID() == PagerClaudeImportOverlay.overlayID)

        let cancelled = try await renderer.handleInput(.key(KeyEvent(key: .escape)))
        #expect(cancelled == .consumed)
        #expect(await renderer.testingFocusedOverlayID() == nil)
        #expect(await renderer.claudeImportPlan == nil)
        #expect(!LiveClaudeSettingsImport.isImported(environment: fixture.environment))
        #expect(!FileManager.default.fileExists(atPath: fixture.state
            .appendingPathComponent("config.toml").path))
        try await renderer.restoreTerminal()
    }
}
