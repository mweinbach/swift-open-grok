// ForeignSessionSourceGatingTests.swift
//
// Parity tests for foreign-session source gating on `open-grok sessions list`.
//
// Rust pin `650c1db7` (`xai-grok-pager/src/app/foreign_sessions.rs` +
// `resolve_compat_sessions_from_raw`): a vendor is scanned only when its
// `[compat.<vendor>] sessions` cell is on *and* the matching
// `resume-claude` / `resume-codex` skill file exists under OPENGROK_HOME.
// Compat cells are read from `loadAuthorityComposition(...).effective()`
// (managed → user → project → requirements), then env overrides. Missing or
// disabled skill / compat ⇒ zero scanner calls / vendor I/O.

import Foundation
import Testing

@testable import OpenGrokCLI
import OpenGrokSamplingTypes

// MARK: - Fixtures

private func makeGateRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "opengrok-foreign-gate-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("sessions", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

private func disposeGateRoot(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private func plantResumeSkill(
    home: URL,
    skill: ForeignSessionResumeSkill,
    bundled: Bool = false
) throws {
    let base = bundled
        ? home.appendingPathComponent("bundled/skills/\(skill.rawValue)", isDirectory: true)
        : home.appendingPathComponent("skills/\(skill.rawValue)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try """
    ---
    name: \(skill.rawValue)
    description: test fixture
    ---
    fixture body
    """.write(
        to: base.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}

private func plantClaudeSession(configDir: URL, cwd: String, nativeID: String) throws {
    let projectDir = configDir
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent("gate-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let jsonl = """
    {"cwd":\(jsonString(cwd)),"type":"system"}
    {"type":"user","message":{"content":"Claude gated session"},"isMeta":false}
    """
    try jsonl.write(
        to: projectDir.appendingPathComponent("\(nativeID).jsonl"),
        atomically: true,
        encoding: .utf8
    )
}

private func plantCodexSession(codexHome: URL, cwd: String, nativeID: String) throws {
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents([.year, .month, .day], from: Date())
    let dateDir = codexHome
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(String(components.year!), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
    try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
    let jsonl = """
    {"cwd":\(jsonString(cwd)),"session_id":\(jsonString(nativeID)),"source":"cli"}
    {"role":"user","content":"Codex gated session"}
    """
    try jsonl.write(
        to: dateDir.appendingPathComponent("rollout-2027-01-15T12-00-00-\(nativeID).jsonl"),
        atomically: true,
        encoding: .utf8
    )
}

private func jsonString(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func gateEnvironment(
    root: URL,
    extras: [String: String] = [:]
) -> [String: String] {
    var environment: [String: String] = [
        "HOME": root.path,
        "OPENGROK_HOME": root.path,
        "CLAUDE_CONFIG_DIR": root.appendingPathComponent(".claude").path,
        "CODEX_HOME": root.appendingPathComponent(".codex").path,
    ]
    for (key, value) in extras {
        environment[key] = value
    }
    return environment
}

/// Counts `scan` invocations so gated-off sources prove zero vendor I/O.
private final class CountingForeignSessionScanner: ForeignSessionScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastEnabled: EnabledForeignSources?
    private var _lastCwd: String?
    var sessions: [ForeignSessionSummary]

    init(sessions: [ForeignSessionSummary] = []) {
        self.sessions = sessions
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    var lastEnabled: EnabledForeignSources? {
        lock.lock()
        defer { lock.unlock() }
        return _lastEnabled
    }

    var lastCwd: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastCwd
    }

    func scan(cwd: String, enabled: EnabledForeignSources) -> [ForeignSessionSummary] {
        lock.lock()
        _callCount += 1
        _lastEnabled = enabled
        _lastCwd = cwd
        lock.unlock()
        return sessions.filter { session in
            switch session.tool {
            case .claude: return enabled.claude
            case .codex: return enabled.codex
            }
        }
    }
}

// MARK: - Pure gate

@Suite("Foreign session source gate")
struct ForeignSessionSourceGateTests {

    @Test("compat off never probes resume skill paths")
    func compatOffSkipsSkillProbe() {
        var probed: [String] = []
        let enabled = gatedForeignSessionSources(
            compat: .none,
            openGrokHome: URL(fileURLWithPath: "/grok"),
            skillExists: { url in
                probed.append(url.path)
                return true
            }
        )
        #expect(enabled == .none)
        #expect(probed.isEmpty)
    }

    @Test("missing skill keeps source disabled even when compat is on")
    func missingSkillDisablesSource() {
        let enabled = gatedForeignSessionSources(
            compat: ForeignSessionCompatSessions(claude: true, codex: true, cursor: true),
            openGrokHome: URL(fileURLWithPath: "/grok"),
            skillExists: { _ in false }
        )
        #expect(enabled == .none)
    }

    @Test("bundled and user skill locations enable matching sources independently")
    func skillLocationsEnableIndependently() {
        let home = URL(fileURLWithPath: "/grok")
        let enabled = gatedForeignSessionSources(
            compat: .all,
            openGrokHome: home,
            skillExists: { url in
                let path = url.path
                return path.contains("bundled/skills/resume-claude")
                    || path.contains("/skills/resume-codex/")
            }
        )
        #expect(enabled.claude)
        #expect(enabled.codex)
    }

    @Test("resume skill path helpers match Rust locations")
    func skillPathsMatchRust() {
        let home = URL(fileURLWithPath: "/grok")
        let paths = foreignSessionResumeSkillPaths(skill: .claude, openGrokHome: home)
        #expect(paths.count == 2)
        #expect(paths[0].path.hasSuffix("/bundled/skills/resume-claude/SKILL.md"))
        #expect(paths[1].path.hasSuffix("/skills/resume-claude/SKILL.md"))
    }
}

// MARK: - Compat cell resolution (authority composition)

private func writeCompatSessions(
    at url: URL,
    claude: String? = nil,
    codex: String? = nil
) throws {
    var body = ""
    if let claude {
        body += "[compat.claude]\nsessions = \(claude)\n"
    }
    if let codex {
        body += "[compat.codex]\nsessions = \(codex)\n"
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try body.write(to: url, atomically: true, encoding: .utf8)
}

private func projectCwd(under root: URL) throws -> URL {
    let project = root.appendingPathComponent("proj", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return project
}

@Suite("Foreign session compat sessions resolution")
struct ForeignSessionCompatSessionsTests {

    @Test("absent effective config defaults sessions cells on")
    func absentConfigDefaultsOn() throws {
        let root = try makeGateRoot("compat-default")
        defer { disposeGateRoot(root) }
        let compat = LiveSessionsComposition.resolveForeignSessionCompatSessions(
            environment: gateEnvironment(root: root),
            cwd: root
        )
        #expect(compat.claude)
        #expect(compat.codex)
        #expect(compat.cursor)
    }

    @Test("user config.toml sessions=false disables one vendor independently")
    func userTomlDisablesIndependently() throws {
        let root = try makeGateRoot("compat-user")
        defer { disposeGateRoot(root) }
        try writeCompatSessions(
            at: root.appendingPathComponent("config.toml"),
            claude: "false"
        )
        let compat = LiveSessionsComposition.resolveForeignSessionCompatSessions(
            environment: gateEnvironment(root: root),
            cwd: root
        )
        #expect(!compat.claude)
        #expect(compat.codex)
        #expect(compat.cursor)
    }

    @Test("managed_config.toml sessions=false wins over absent user cell")
    func managedDisablesIndependently() throws {
        let root = try makeGateRoot("compat-managed")
        defer { disposeGateRoot(root) }
        try writeCompatSessions(
            at: root.appendingPathComponent("managed_config.toml"),
            claude: "false"
        )
        let compat = LiveSessionsComposition.resolveForeignSessionCompatSessions(
            environment: gateEnvironment(root: root),
            cwd: root
        )
        #expect(!compat.claude)
        #expect(compat.codex)
    }

    @Test("project .opengrok/config.toml sessions=false wins over user true")
    func projectDisablesOverUser() throws {
        let root = try makeGateRoot("compat-project")
        defer { disposeGateRoot(root) }
        try writeCompatSessions(
            at: root.appendingPathComponent("config.toml"),
            claude: "true",
            codex: "true"
        )
        let project = try projectCwd(under: root)
        try writeCompatSessions(
            at: project
                .appendingPathComponent(".opengrok", isDirectory: true)
                .appendingPathComponent("config.toml"),
            claude: "false"
        )
        let compat = LiveSessionsComposition.resolveForeignSessionCompatSessions(
            environment: gateEnvironment(root: root),
            cwd: project
        )
        #expect(!compat.claude)
        #expect(compat.codex)
    }

    @Test("env overrides managed and project sessions disables")
    func envOverridesManagedAndProject() throws {
        let root = try makeGateRoot("compat-env-auth")
        defer { disposeGateRoot(root) }
        try writeCompatSessions(
            at: root.appendingPathComponent("managed_config.toml"),
            codex: "false"
        )
        let project = try projectCwd(under: root)
        try writeCompatSessions(
            at: project
                .appendingPathComponent(".opengrok", isDirectory: true)
                .appendingPathComponent("config.toml"),
            claude: "false"
        )
        let compat = LiveSessionsComposition.resolveForeignSessionCompatSessions(
            environment: gateEnvironment(
                root: root,
                extras: [
                    "GROK_CLAUDE_SESSIONS_ENABLED": "true",
                    "GROK_CODEX_SESSIONS_ENABLED": "true",
                ]
            ),
            cwd: project
        )
        #expect(compat.claude)
        #expect(compat.codex)
    }

    @Test("malformed sessions cell fails closed for that vendor")
    func malformedCellFailsClosed() throws {
        let root = try makeGateRoot("compat-malformed")
        defer { disposeGateRoot(root) }
        try writeCompatSessions(
            at: root.appendingPathComponent("config.toml"),
            claude: "\"nope\"",
            codex: "true"
        )
        let compat = LiveSessionsComposition.resolveForeignSessionCompatSessions(
            environment: gateEnvironment(root: root),
            cwd: root
        )
        #expect(!compat.claude)
        #expect(compat.codex)
    }
}

// MARK: - Composition route

@Suite("Foreign session gating on sessions list")
struct ForeignSessionListGatingTests {

    @Test("missing resume skill yields zero scanner calls and keeps local listing")
    func missingSkillZeroScannerCalls() throws {
        let root = try makeGateRoot("list-no-skill")
        defer { disposeGateRoot(root) }
        let environment = gateEnvironment(root: root)
        let local = LiveConversationRecord(
            sessionID: "local-gate-1",
            workingDirectory: "/work",
            parentSessionID: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            items: [.user("keep me")]
        )
        try JSONEncoder().encode(local).write(
            to: root.appendingPathComponent("sessions/local-gate-1.json")
        )
        let foreign = ForeignSessionSummary(
            tool: .claude,
            source: .claudeCode,
            nativeID: "should-not-scan",
            title: "Hidden",
            cwd: FileManager.default.currentDirectoryPath,
            updatedAt: Date()
        )
        let scanner = CountingForeignSessionScanner(sessions: [foreign])
        let sources = LiveSessionsComposition.resolveProductionForeignSources(
            environment: environment,
            cwd: root,
            openGrokHome: root
        )
        #expect(sources == .none)

        let (streams, out, _) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list, json: true),
            environment: environment,
            streams: streams,
            cwd: root,
            foreignScanner: scanner,
            foreignSources: sources
        )

        #expect(scanner.callCount == 0)
        let decoded = try JSONSerialization.jsonObject(with: Data(out.contents.utf8))
        let rows = try #require(decoded as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as? String == "local-gate-1")
        #expect(rows[0]["foreign_source"] == nil)
        #expect(!out.contents.contains("should-not-scan"))
    }

    @Test("user compat sessions=false yields zero scanner calls even with skill present")
    func userCompatOffZeroScannerCalls() throws {
        let root = try makeGateRoot("list-compat-off")
        defer { disposeGateRoot(root) }
        try plantResumeSkill(home: root, skill: .claude)
        try plantResumeSkill(home: root, skill: .codex)
        try writeCompatSessions(
            at: root.appendingPathComponent("config.toml"),
            claude: "false",
            codex: "false"
        )
        let environment = gateEnvironment(root: root)
        let scanner = CountingForeignSessionScanner(sessions: [
            ForeignSessionSummary(
                tool: .claude,
                source: .claudeCode,
                nativeID: "c-hidden",
                title: "Hidden Claude",
                cwd: "/",
                updatedAt: Date()
            ),
        ])
        let sources = LiveSessionsComposition.resolveProductionForeignSources(
            environment: environment,
            cwd: root,
            openGrokHome: root
        )
        #expect(sources == .none)

        let (streams, out, _) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list),
            environment: environment,
            streams: streams,
            cwd: root,
            foreignScanner: scanner,
            foreignSources: sources
        )
        #expect(scanner.callCount == 0)
        #expect(!out.contents.contains("c-hidden"))
    }

    @Test("managed_config sessions=false yields zero scanner calls with skills present")
    func managedCompatOffZeroScannerCalls() throws {
        let root = try makeGateRoot("list-managed-off")
        defer { disposeGateRoot(root) }
        try plantResumeSkill(home: root, skill: .claude)
        try plantResumeSkill(home: root, skill: .codex)
        try writeCompatSessions(
            at: root.appendingPathComponent("managed_config.toml"),
            claude: "false",
            codex: "false"
        )
        let environment = gateEnvironment(root: root)
        let scanner = CountingForeignSessionScanner(sessions: [
            ForeignSessionSummary(
                tool: .codex,
                source: .codexCli,
                nativeID: "managed-hidden",
                title: "Hidden Codex",
                cwd: "/",
                updatedAt: Date()
            ),
        ])
        let sources = LiveSessionsComposition.resolveProductionForeignSources(
            environment: environment,
            cwd: root,
            openGrokHome: root
        )
        #expect(sources == .none)

        let (streams, out, _) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list),
            environment: environment,
            streams: streams,
            cwd: root,
            foreignScanner: scanner,
            foreignSources: sources
        )
        #expect(scanner.callCount == 0)
        #expect(!out.contents.contains("managed-hidden"))
    }

    @Test("project compat sessions=false yields zero scanner calls with skills present")
    func projectCompatOffZeroScannerCalls() throws {
        let root = try makeGateRoot("list-project-off")
        defer { disposeGateRoot(root) }
        try plantResumeSkill(home: root, skill: .claude)
        try plantResumeSkill(home: root, skill: .codex)
        try writeCompatSessions(
            at: root.appendingPathComponent("config.toml"),
            claude: "true",
            codex: "true"
        )
        let project = try projectCwd(under: root)
        try writeCompatSessions(
            at: project
                .appendingPathComponent(".opengrok", isDirectory: true)
                .appendingPathComponent("config.toml"),
            claude: "false",
            codex: "false"
        )
        let environment = gateEnvironment(root: root)
        let scanner = CountingForeignSessionScanner(sessions: [
            ForeignSessionSummary(
                tool: .claude,
                source: .claudeCode,
                nativeID: "project-hidden",
                title: "Hidden Claude",
                cwd: "/",
                updatedAt: Date()
            ),
        ])
        let sources = LiveSessionsComposition.resolveProductionForeignSources(
            environment: environment,
            cwd: project,
            openGrokHome: root
        )
        #expect(sources == .none)

        let (streams, out, _) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list),
            environment: environment,
            streams: streams,
            cwd: project,
            foreignScanner: scanner,
            foreignSources: sources
        )
        #expect(scanner.callCount == 0)
        #expect(!out.contents.contains("project-hidden"))
    }

    @Test("env override re-enables scan after managed/project disables")
    func envOverrideReenablesAfterAuthorityDisable() throws {
        let root = try makeGateRoot("list-env-override")
        defer { disposeGateRoot(root) }
        try plantResumeSkill(home: root, skill: .claude)
        try writeCompatSessions(
            at: root.appendingPathComponent("managed_config.toml"),
            claude: "false"
        )
        let project = try projectCwd(under: root)
        try writeCompatSessions(
            at: project
                .appendingPathComponent(".opengrok", isDirectory: true)
                .appendingPathComponent("config.toml"),
            claude: "false"
        )
        let foreign = ForeignSessionSummary(
            tool: .claude,
            source: .claudeCode,
            nativeID: "env-visible",
            title: "Env visible",
            cwd: project.path,
            updatedAt: Date()
        )
        let scanner = CountingForeignSessionScanner(sessions: [foreign])
        let environment = gateEnvironment(
            root: root,
            extras: ["GROK_CLAUDE_SESSIONS_ENABLED": "true"]
        )
        let sources = LiveSessionsComposition.resolveProductionForeignSources(
            environment: environment,
            cwd: project,
            openGrokHome: root
        )
        #expect(sources.claude)

        let (streams, out, _) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list, json: true),
            environment: environment,
            streams: streams,
            cwd: project,
            foreignScanner: scanner,
            foreignSources: sources
        )
        #expect(scanner.callCount == 1)
        #expect(scanner.lastCwd == project.path)
        #expect(out.contents.contains("env-visible"))
    }

    @Test("enabled compat plus resume skill includes only that source")
    func enabledSkillIncludesMatchingSource() throws {
        let root = try makeGateRoot("list-skill-on")
        defer { disposeGateRoot(root) }
        try plantResumeSkill(home: root, skill: .claude, bundled: true)
        let environment = gateEnvironment(root: root)
        let claude = ForeignSessionSummary(
            tool: .claude,
            source: .claudeCode,
            nativeID: "claude-visible",
            title: "Claude visible",
            cwd: root.path,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        let codex = ForeignSessionSummary(
            tool: .codex,
            source: .codexCli,
            nativeID: "codex-hidden",
            title: "Codex hidden",
            cwd: root.path,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        let scanner = CountingForeignSessionScanner(sessions: [claude, codex])
        let sources = LiveSessionsComposition.resolveProductionForeignSources(
            environment: environment,
            cwd: root,
            openGrokHome: root
        )
        #expect(sources.claude)
        #expect(!sources.codex)

        let (streams, out, _) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list, json: true),
            environment: environment,
            streams: streams,
            cwd: root,
            foreignScanner: scanner,
            foreignSources: sources
        )
        #expect(scanner.callCount == 1)
        #expect(scanner.lastCwd == root.path)
        #expect(scanner.lastEnabled?.claude == true)
        #expect(scanner.lastEnabled?.codex == false)

        let decoded = try JSONSerialization.jsonObject(with: Data(out.contents.utf8))
        let rows = try #require(decoded as? [[String: Any]])
        let ids = rows.compactMap { $0["id"] as? String }
        #expect(ids.contains("claude-visible"))
        #expect(!ids.contains("codex-hidden"))
    }

    @Test("run passes required cwd to scanner even when process cwd differs")
    func runPassesRequiredCwdToScanner() throws {
        let root = try makeGateRoot("list-run-cwd")
        defer { disposeGateRoot(root) }
        let project = try projectCwd(under: root)
        let processCwd = FileManager.default.currentDirectoryPath
        #expect(project.path != processCwd)

        let scanner = CountingForeignSessionScanner(sessions: [
            ForeignSessionSummary(
                tool: .claude,
                source: .claudeCode,
                nativeID: "cwd-probe",
                title: "Cwd probe",
                cwd: project.path,
                updatedAt: Date()
            ),
        ])
        let (streams, out, _) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list, json: true),
            environment: gateEnvironment(root: root),
            streams: streams,
            cwd: project,
            foreignScanner: scanner,
            foreignSources: EnabledForeignSources(claude: true, codex: false)
        )
        #expect(scanner.callCount == 1)
        #expect(scanner.lastCwd == project.path)
        #expect(scanner.lastCwd != processCwd)
        #expect(out.contents.contains("cwd-probe"))
    }

    @Test("production sessions list route gates LiveForeignSessionScanner I/O")
    func productionSessionRouteGatesVendorIO() async throws {
        let root = try makeGateRoot("session-route")
        defer { disposeGateRoot(root) }
        let cwd = FileManager.default.currentDirectoryPath
        let claudeID = UUID().uuidString
        let codexID = UUID().uuidString
        try plantClaudeSession(
            configDir: root.appendingPathComponent(".claude"),
            cwd: cwd,
            nativeID: claudeID
        )
        try plantCodexSession(
            codexHome: root.appendingPathComponent(".codex"),
            cwd: cwd,
            nativeID: codexID
        )
        let local = LiveConversationRecord(
            sessionID: "local-route-1",
            workingDirectory: cwd,
            parentSessionID: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_050),
            items: [.user("local stays")]
        )
        try JSONEncoder().encode(local).write(
            to: root.appendingPathComponent("sessions/local-route-1.json")
        )

        // No resume skills → foreign vendors must not appear.
        let (streamsOff, outOff, _) = CLIStreams.buffered()
        let environment = gateEnvironment(root: root)
        _ = try await LiveSessionsComposition.session(
            for: .sessions(CLISessionOptions(action: .list, json: true)),
            context: CLIApplicationContext(
                environment: environment,
                streams: streamsOff,
                control: .never
            )
        )
        let offRows = try #require(
            JSONSerialization.jsonObject(with: Data(outOff.contents.utf8)) as? [[String: Any]]
        )
        let offIDs = Set(offRows.compactMap { $0["id"] as? String })
        #expect(offIDs == ["local-route-1"])
        #expect(!offIDs.contains(claudeID))
        #expect(!offIDs.contains(codexID))

        // Plant both skills → Claude and Codex appear beside the local row.
        try plantResumeSkill(home: root, skill: .claude)
        try plantResumeSkill(home: root, skill: .codex)
        let (streamsOn, outOn, _) = CLIStreams.buffered()
        _ = try await LiveSessionsComposition.session(
            for: .sessions(CLISessionOptions(action: .list, json: true)),
            context: CLIApplicationContext(
                environment: environment,
                streams: streamsOn,
                control: .never
            )
        )
        let onRows = try #require(
            JSONSerialization.jsonObject(with: Data(outOn.contents.utf8)) as? [[String: Any]]
        )
        let onIDs = Set(onRows.compactMap { $0["id"] as? String })
        #expect(onIDs.contains("local-route-1"))
        #expect(onIDs.contains(claudeID))
        #expect(onIDs.contains(codexID))
        let foreignTools = Set(onRows.compactMap { $0["foreign_tool"] as? String })
        #expect(foreignTools.contains("claude"))
        #expect(foreignTools.contains("codex"))
    }

    @Test("GROK_CLAUDE_SESSIONS_ENABLED=false blocks Claude despite skill")
    func envDisablesClaudeDespiteSkill() async throws {
        let root = try makeGateRoot("session-env-off")
        defer { disposeGateRoot(root) }
        let cwd = FileManager.default.currentDirectoryPath
        let claudeID = UUID().uuidString
        try plantClaudeSession(
            configDir: root.appendingPathComponent(".claude"),
            cwd: cwd,
            nativeID: claudeID
        )
        try plantResumeSkill(home: root, skill: .claude)
        let environment = gateEnvironment(
            root: root,
            extras: ["GROK_CLAUDE_SESSIONS_ENABLED": "false"]
        )
        let (streams, out, _) = CLIStreams.buffered()
        _ = try await LiveSessionsComposition.session(
            for: .sessions(CLISessionOptions(action: .list, json: true)),
            context: CLIApplicationContext(
                environment: environment,
                streams: streams,
                control: .never
            )
        )
        #expect(!out.contents.contains(claudeID))
    }

    @Test("sessions list --cwd uses project compat and scanner cwd, not process cwd")
    func sessionsListCwdHonorsProjectNotProcessCwd() async throws {
        let root = try makeGateRoot("list-cwd-flag")
        defer { disposeGateRoot(root) }
        try plantResumeSkill(home: root, skill: .claude)

        // User config would enable Claude; project config disables it.
        try writeCompatSessions(
            at: root.appendingPathComponent("config.toml"),
            claude: "true"
        )
        let project = try projectCwd(under: root)
        try writeCompatSessions(
            at: project
                .appendingPathComponent(".opengrok", isDirectory: true)
                .appendingPathComponent("config.toml"),
            claude: "false"
        )

        let processCwd = FileManager.default.currentDirectoryPath
        #expect(project.path != processCwd)

        let projectClaudeID = UUID().uuidString
        let processClaudeID = UUID().uuidString
        try plantClaudeSession(
            configDir: root.appendingPathComponent(".claude"),
            cwd: project.path,
            nativeID: projectClaudeID
        )
        try plantClaudeSession(
            configDir: root.appendingPathComponent(".claude"),
            cwd: processCwd,
            nativeID: processClaudeID
        )

        let environment = gateEnvironment(root: root)
        let command = try CLICommandParser.parseOrThrow([
            "--cwd", project.path,
            "sessions", "list", "--json",
        ])
        guard case .sessions(let options) = command else {
            Issue.record("expected sessions route, got \(command.routeName)")
            return
        }
        #expect(options.common.cwd == project.path)

        // Phase 1: project compat disable must win even though process cwd's
        // user config would leave Claude on.
        let (streamsOff, outOff, _) = CLIStreams.buffered()
        _ = try await LiveSessionsComposition.session(
            for: command,
            context: CLIApplicationContext(
                environment: environment,
                streams: streamsOff,
                control: .never
            )
        )
        #expect(!outOff.contents.contains(projectClaudeID))
        #expect(!outOff.contents.contains(processClaudeID))

        // Phase 2: re-enable project Claude; scanner must match --cwd (project),
        // not the process cwd, so only the project-scoped foreign session appears.
        try writeCompatSessions(
            at: project
                .appendingPathComponent(".opengrok", isDirectory: true)
                .appendingPathComponent("config.toml"),
            claude: "true"
        )
        let (streamsOn, outOn, _) = CLIStreams.buffered()
        _ = try await LiveSessionsComposition.session(
            for: try CLICommandParser.parseOrThrow([
                "--cwd", project.path,
                "sessions", "list", "--json",
            ]),
            context: CLIApplicationContext(
                environment: environment,
                streams: streamsOn,
                control: .never
            )
        )
        let onRows = try #require(
            JSONSerialization.jsonObject(with: Data(outOn.contents.utf8)) as? [[String: Any]]
        )
        let onIDs = Set(onRows.compactMap { $0["id"] as? String })
        #expect(onIDs.contains(projectClaudeID))
        #expect(!onIDs.contains(processClaudeID))
    }
}
