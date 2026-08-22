import Foundation
import OpenGrokFastWorktree
import OpenGrokMemory
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

@Suite("Live maintenance CLI Rust parity")
struct LiveMaintenanceCLIParityTests {
    @Test("du and disk-usage are strict real aliases rather than interactive prompts")
    func diskUsageAliasesAndGrammar() throws {
        for alias in ["du", "disk-usage"] {
            #expect(try CLICommandParser.parseOrThrow([alias]) == .diskUsage(json: false))
            #expect(try CLICommandParser.parseOrThrow([alias, "--json"]) == .diskUsage(json: true))
            #expect(CLICommandParser.parse([alias, "--unexpected"])
                == .invalid(.unknownOption("--unexpected")))
            #expect(CLICommandParser.parse([alias, "other"])
                == .invalid(.unknownOption("other")))
            #expect(OpenGrokHelp.topic(alias)?.contains("open-grok du") == true)
        }
        #expect(OpenGrokCompletions.commands.contains("du"))
        #expect(OpenGrokCompletions.commands.contains("disk-usage"))
    }

    @Test("missing-home disk usage preserves exact schema and never creates user state")
    func missingHomeNeverCreated() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("absent-state", isDirectory: true)
        let environment = ["HOME": root.path, "OPENGROK_HOME": missing.path, "PWD": root.path]

        let (syncStreams, syncOut, syncErr) = CLIStreams.buffered()
        #expect(CLIRunner.main(["du", "--json"], environment: environment, streams: syncStreams) == 0)
        let report = try jsonObject(syncOut.contents)
        #expect(report["schema_version"] as? Int == 1)
        #expect(report["grok_home"] as? String == missing.path)
        #expect(report["total_bytes"] as? Int == 0)
        #expect(report["volume_capacity_bytes"] is NSNull)
        #expect(report["volume_available_bytes"] is NSNull)
        #expect((report["top_level_dirs"] as? [Any])?.isEmpty == true)
        #expect(report["root_files_bytes"] as? Int == 0)
        #expect(report["skipped_entries"] as? Int == 0)
        #expect(report["unreadable_dirs"] as? Int == 0)
        #expect(report["unstatable_entries"] as? Int == 0)
        #expect(report["other_filesystem_dirs"] as? Int == 0)
        #expect(report["unfollowed_dir_symlinks"] as? Int == 0)
        #expect(report["worktrees_outside_managed_roots"] as? Int == 0)
        #expect(report["registry"] as? String == "absent")
        #expect(report["registry_path"] as? String == "")
        #expect((report["worktrees"] as? [Any])?.isEmpty == true)
        #expect(syncErr.contents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let (asyncStreams, asyncOut, asyncErr) = CLIStreams.buffered()
        let exit = await CLIRunner.run(
            ["disk-usage"],
            environment: environment,
            streams: asyncStreams
        )
        #expect(exit == CLIRunner.ExitCode.success.rawValue)
        #expect(asyncOut.contents == "Nothing on disk yet at $OPENGROK_HOME.\n")
        #expect(asyncErr.contents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("disk usage sizes managed rows without following escaped links or registry paths")
    func managedWorktreesAndSymlinkContainment() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("state", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let tracked = home.appendingPathComponent("worktrees/repo/tracked", isDirectory: true)
        let orphan = home.appendingPathComponent("worktree_pool/repo/orphan", isDirectory: true)
        for path in [home, outside, tracked, orphan] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try Data(repeating: 0x61, count: 131_072)
            .write(to: outside.appendingPathComponent("private-secret.txt"))
        try Data("tracked".utf8).write(to: tracked.appendingPathComponent("tracked.txt"))
        try Data("orphan".utf8).write(to: orphan.appendingPathComponent("orphan.txt"))
        try Data("root".utf8).write(to: home.appendingPathComponent("root.txt"))
        #if !os(Windows)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("escaped"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: tracked.appendingPathComponent("nested-escape"),
            withDestinationURL: outside
        )
        #endif

        let registry = WorktreeRegistry(openGrokHome: home)
        try registry.register(WorktreeRecord(
            id: "tracked-id",
            path: tracked,
            sourceRepository: root,
            repositoryName: "repo",
            kind: .launch,
            ref: "main",
            label: "tracked label"
        ))
        try registry.register(WorktreeRecord(
            id: "outside-id",
            path: outside,
            sourceRepository: root,
            repositoryName: "outside",
            kind: .manual
        ))

        let (streams, output, errors) = CLIStreams.buffered()
        let environment = ["HOME": root.path, "OPENGROK_HOME": home.path, "PWD": root.path]
        #expect(CLIRunner.main(["du", "--json"], environment: environment, streams: streams) == 0)
        let report = try jsonObject(output.contents)
        let directories = try #require(report["top_level_dirs"] as? [[String: Any]])
        #expect(Set(directories.compactMap { $0["name"] as? String })
            == Set(["worktrees", "worktree_pool"]))
        #expect((report["root_files_bytes"] as? Int ?? 0) > 0)
        #expect((report["total_bytes"] as? Int ?? Int.max) < 131_072)
        #expect(report["registry"] as? String == "read")
        #expect(report["registry_path"] as? String == registry.databaseURL.path)
        #expect(report["worktrees_outside_managed_roots"] as? Int == 1)

        let rows = try #require(report["worktrees"] as? [[String: Any]])
        try #require(rows.count == 2)
        let trackedRow = try #require(rows.first { $0["id"] as? String == "tracked-id" })
        #expect(trackedRow["kind"] as? String == "session")
        #expect(trackedRow["tracked"] as? Bool == true)
        #expect(trackedRow["status"] as? String == "alive")
        #expect(trackedRow["repo_name"] as? String == "repo")
        #expect(trackedRow["git_ref"] as? String == "main")
        #expect(trackedRow["label"] as? String == "tracked label")
        #expect(trackedRow["path"] as? String == tracked.resolvingSymlinksInPath().path)

        let orphanRow = try #require(rows.first { $0["kind"] as? String == "pool" })
        #expect(orphanRow["tracked"] as? Bool == false)
        #expect(orphanRow["id"] is NSNull)
        #expect(orphanRow["status"] is NSNull)
        #expect(orphanRow["created_at"] is NSNull)
        #expect(orphanRow["last_accessed_at"] is NSNull)
        #expect(orphanRow["label"] is NSNull)
        #expect(orphanRow["repo_name"] is NSNull)
        #expect(orphanRow["git_ref"] is NSNull)
        #expect(!output.contents.contains("private-secret.txt"))
        #expect(!output.contents.contains(outside.path))
        #expect(errors.contents.isEmpty)
        #if !os(Windows)
        #expect(report["unfollowed_dir_symlinks"] as? Int == 1)
        #endif
    }

    @Test("inspect exposes real user authority and fails closed on untrusted project execution")
    func inspectionRespectsConfigurationAndFolderTrust() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("state", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let projectConfig = workspace.appendingPathComponent(".opengrok", isDirectory: true)
        let userSkill = home.appendingPathComponent("skills/helper", isDirectory: true)
        for path in [home, workspace, projectConfig, userSkill] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try """
        [[permission.rules]]
        action = "deny"
        tool = "any"

        [[hooks.PreToolUse]]
        matcher = "Bash"
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "echo safe-user-hook"

        [mcp_servers.safe]
        command = "safe-server"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try """
        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "echo untrusted-project-hook"

        [mcp_servers.untrusted]
        command = "project-server"
        """.write(to: projectConfig.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try """
        ---
        name: helper
        description: A real user skill
        ---
        Use the helper.
        """.write(to: userSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "workspace instructions".write(
            to: workspace.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
            "GROK_FOLDER_TRUST": "1",
        ]
        let (streams, output, errors) = CLIStreams.buffered()
        #expect(CLIRunner.main(["inspect", "--json"], environment: environment, streams: streams) == 0)
        let report = try jsonObject(output.contents)
        #expect(report["cwd"] as? String == workspace.path)
        #expect(report["projectRoot"] as? String == workspace.path)
        #expect(report["projectTrusted"] as? Bool == false)
        #expect(report["releaseSource"] as? String == "github")
        #expect((report["grokVersion"] as? String)?.isEmpty == false)

        let permissions = try #require(report["permissions"] as? [String: Any])
        #expect(permissions["loaded"] as? Int == 1)
        #expect(permissions["managedSettingsExists"] is Bool)
        #expect(permissions["managedSettingsActive"] is Bool)

        let hooks = try #require(report["hooks"] as? [[String: Any]])
        #expect(hooks.contains { $0["target"] as? String == "echo safe-user-hook" })
        #expect(!hooks.contains { $0["target"] as? String == "echo untrusted-project-hook" })
        let servers = try #require(report["mcpServers"] as? [[String: Any]])
        #expect(servers.map { $0["name"] as? String } == ["safe"])
        #expect(servers.first?["transport"] as? String == "stdio")
        #expect(servers.first?["target"] as? String == "safe-server")

        let skills = try #require(report["skills"] as? [[String: Any]])
        #expect(skills.contains { $0["name"] as? String == "helper" })
        let instructions = try #require(report["projectInstructions"] as? [[String: Any]])
        #expect(instructions.contains { $0["path"] as? String == workspace.appendingPathComponent("AGENTS.md").path })
        let config = try #require(report["configSources"] as? [String: Any])
        let layers = try #require(config["layers"] as? [[String: Any]])
        #expect(layers.contains { $0["role"] as? String == "user" })
        #expect(layers.contains { $0["role"] as? String == "project" })
        let compatibility = try #require(report["externalCompat"] as? [String: Any])
        #expect(compatibility["remoteSettingsLoaded"] as? Bool == false)
        #expect((compatibility["cells"] as? [[String: Any]])?.count == 13)
        #expect(errors.contents.isEmpty)

        var trust = PersistentFolderTrustStore(environment: environment)
        try trust.record(workspace, trusted: true)
        let (trustedStreams, trustedOutput, _) = CLIStreams.buffered()
        #expect(CLIRunner.main(
            ["inspect", "--json"], environment: environment, streams: trustedStreams
        ) == 0)
        let trusted = try jsonObject(trustedOutput.contents)
        #expect(trusted["projectTrusted"] as? Bool == true)
        let trustedServers = try #require(trusted["mcpServers"] as? [[String: Any]])
        #expect(Set(trustedServers.compactMap { $0["name"] as? String }) == ["safe", "untrusted"])
    }

    @Test("inspect human and async real launch surfaces contain no fake unavailable response")
    func inspectionHumanAsyncRoute() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": root.appendingPathComponent("state").path,
            "PWD": root.path,
        ]
        let (streams, output, errors) = CLIStreams.buffered()
        let exit = await CLIRunner.run(["inspect"], environment: environment, streams: streams)
        #expect(exit == CLIRunner.ExitCode.success.rawValue)
        #expect(output.contents.contains("Environment"))
        #expect(output.contents.contains("Permissions"))
        #expect(output.contents.contains("MCP Servers"))
        #expect(output.contents.contains("Configuration Sources"))
        #expect(!output.contents.contains("not wired up"))
        #expect(errors.contents.isEmpty)
    }

    @Test("memory clear reaches both runners, confirms explicitly, and preserves the other scope")
    func memoryClearRunnerSecurityAndScopes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let home = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let environment = ["HOME": root.path, "OPENGROK_HOME": home.path, "PWD": workspace.path]
        let storage = MemoryStorage(cwd: workspace, environment: environment)
        try FileManager.default.createDirectory(at: storage.workspaceDir, withIntermediateDirectories: true)
        try "workspace".write(to: storage.workspaceMemoryFile, atomically: true, encoding: .utf8)
        try "global".write(to: storage.globalMemoryFile, atomically: true, encoding: .utf8)

        let (refusal, refusalOut, refusalErr) = CLIStreams.buffered()
        #expect(CLIRunner.main(["memory", "clear"], environment: environment, streams: refusal) == 0)
        #expect(refusalOut.contents.contains("Are you sure? [y/N]"))
        #expect(refusalOut.contents.contains("Cancelled."))
        #expect(refusalErr.contents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: storage.workspaceMemoryFile.path))
        #expect(FileManager.default.fileExists(atPath: storage.globalMemoryFile.path))

        let (global, globalOut, globalErr) = CLIStreams.buffered()
        let exit = await CLIRunner.run(
            ["memory", "clear", "--global", "-y"],
            environment: environment,
            streams: global
        )
        #expect(exit == CLIRunner.ExitCode.success.rawValue)
        #expect(globalOut.contents.contains("Cleared: global MEMORY.md"))
        #expect(globalOut.contents.contains("Memory cleared."))
        #expect(globalErr.contents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storage.globalMemoryFile.path))
        #expect(FileManager.default.fileExists(atPath: storage.workspaceMemoryFile.path))

        let (local, localOut, localErr) = CLIStreams.buffered()
        #expect(CLIRunner.main(
            ["--cwd", workspace.path, "memory", "clear", "--workspace", "--yes"],
            environment: environment,
            streams: local
        ) == 0)
        #expect(localOut.contents.contains("Cleared: workspace memory"))
        #expect(localErr.contents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storage.workspaceDir.path))
    }

    @Test("memory clear refuses conflicting scopes and never creates empty state")
    func memoryClearConflictsAndEmptyScope() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("missing-state", isDirectory: true)
        let environment = ["HOME": root.path, "OPENGROK_HOME": home.path, "PWD": root.path]

        for flags in [["--workspace", "--global"], ["--workspace", "--all"], ["--global", "--all"]] {
            let (streams, output, errors) = CLIStreams.buffered()
            let exit = CLIRunner.main(["memory", "clear"] + flags, environment: environment, streams: streams)
            #expect(exit == CLIRunner.ExitCode.usage.rawValue)
            #expect(output.contents.isEmpty)
            #expect(errors.contents.contains("cannot be used together"))
            #expect(!FileManager.default.fileExists(atPath: home.path))
        }

        let (streams, output, errors) = CLIStreams.buffered()
        #expect(CLIRunner.main(["memory", "clear"], environment: environment, streams: streams) == 0)
        #expect(output.contents == "Nothing to clear — no memory files found.\n")
        #expect(errors.contents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func jsonObject(_ value: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
        )
    }
}
