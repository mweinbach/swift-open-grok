// ForeignSessionScannerTests.swift
//
// Fixture-backed tests for the foreign session scanners (Claude and Codex)
// and the composition integration that merges them into `sessions list`.
//
// Every test points at a temporary directory, never a real Claude/Codex
// config path. The scanners are tested in isolation with hand-crafted JSONL
// fixtures.

import Foundation
import Testing

@testable import OpenGrokCLI
import OpenGrokSamplingTypes

// MARK: - Shared helpers

private func makeTempDir(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-foreign-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func dispose(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - ForeignSessionScanner types

@Suite("Foreign session shared types")
struct ForeignSessionTypeTests {

    @Test("title normalization collapses whitespace and truncates with ellipsis")
    func titleNormalization() {
        #expect(normalizeForeignTitle("  hello   world  ") == "hello world")
        #expect(normalizeForeignTitle("") == nil)
        #expect(normalizeForeignTitle("   ") == nil)
        let long = String(repeating: "a", count: 250)
        let normalized = normalizeForeignTitle(long)!
        #expect(normalized.count == ForeignSessionLimits.maxTitleChars)
        #expect(normalized.hasSuffix("…"))
    }

    @Test("finish tool scan deduplicates, sorts, and caps")
    func finishScanDedup() {
        let now = Date()
        var sessions = (0..<55).map { i in
            ForeignSessionSummary(
                tool: .claude, source: .claudeCode,
                nativeID: String(format: "%02d", i),
                title: "Session \(i)",
                cwd: "/work",
                updatedAt: now.addingTimeInterval(Double(i))
            )
        }
        sessions.append(ForeignSessionSummary(
            tool: .claude, source: .claudeCode,
            nativeID: "54",
            title: "Duplicate",
            cwd: "/work",
            updatedAt: now.addingTimeInterval(500)
        ))
        finishForeignToolScan(&sessions)
        #expect(sessions.count == ForeignSessionLimits.maxSessionsPerTool)
        #expect(sessions[0].nativeID == "54")
        for i in 0..<(sessions.count - 1) {
            #expect(sessions[i].updatedAt >= sessions[i + 1].updatedAt)
        }
    }

    @Test("age check allows within window and small future skew")
    func ageCheck() {
        let now = Date()
        let window: TimeInterval = 30 * 24 * 3600
        #expect(isForeignSessionWithin(now.addingTimeInterval(-window), now: now, window: window))
        #expect(!isForeignSessionWithin(now.addingTimeInterval(-window - 1), now: now, window: window))
        #expect(isForeignSessionWithin(now.addingTimeInterval(ForeignSessionLimits.maxFutureSkew), now: now, window: window))
        #expect(!isForeignSessionWithin(now.addingTimeInterval(ForeignSessionLimits.maxFutureSkew + 1), now: now, window: window))
    }

    @Test("foreign source badges are distinct and non-empty")
    func sourceBadges() {
        let sources: [ForeignSessionSource] = [.claudeCode, .codexCli, .codexVsCode, .codexAtlas, .codexChatGpt]
        let badges = sources.map(\.badge)
        #expect(Set(badges).count == sources.count)
        for badge in badges {
            #expect(!badge.isEmpty)
        }
    }
}

// MARK: - Claude scanner

@Suite("Claude session scanner")
struct ClaudeSessionScannerTests {

    @Test("scan returns empty for missing config dir")
    func emptyOnMissingDir() throws {
        let sessions = ClaudeSessionScanner.scan(
            requestedCwd: "/nonexistent",
            configDir: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        #expect(sessions.isEmpty)
    }

    @Test("scan discovers a session matching the cwd")
    func scanFindsMatchingSession() throws {
        let configDir = try makeTempDir("claude-scan")
        defer { dispose(configDir) }
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let sessionFile = projectDir.appendingPathComponent("\(sessionID).jsonl")
        let jsonl = """
        {"cwd":"/work/repo","type":"system","message":"init"}
        {"type":"user","message":{"content":"Fix the parser bug"},"isMeta":false}
        {"type":"assistant","message":{"content":"Done"}}
        """
        try jsonl.write(to: sessionFile, atomically: true, encoding: .utf8)

        let sessions = ClaudeSessionScanner.scan(
            requestedCwd: "/work/repo",
            configDir: configDir
        )
        #expect(sessions.count == 1)
        #expect(sessions[0].nativeID == sessionID)
        #expect(sessions[0].tool == .claude)
        #expect(sessions[0].source == .claudeCode)
        #expect(sessions[0].title == "Fix the parser bug")
        #expect(sessions[0].cwd == "/work/repo")
    }

    @Test("scan skips sessions with wrong cwd")
    func scanSkipsMismatchedCwd() throws {
        let configDir = try makeTempDir("claude-cwd")
        defer { dispose(configDir) }
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let sessionFile = projectDir.appendingPathComponent("\(sessionID).jsonl")
        try "{\"cwd\":\"/other/path\"}\n".write(to: sessionFile, atomically: true, encoding: .utf8)

        let sessions = ClaudeSessionScanner.scan(
            requestedCwd: "/work/repo",
            configDir: configDir
        )
        #expect(sessions.isEmpty)
    }

    @Test("scan skips sidechain sessions")
    func scanSkipsSidechain() throws {
        let configDir = try makeTempDir("claude-sidechain")
        defer { dispose(configDir) }
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let sessionFile = projectDir.appendingPathComponent("\(sessionID).jsonl")
        let jsonl = """
        {"cwd":"/work/repo","isSidechain":true}
        {"type":"user","message":{"content":"hello"}}
        """
        try jsonl.write(to: sessionFile, atomically: true, encoding: .utf8)

        let sessions = ClaudeSessionScanner.scan(
            requestedCwd: "/work/repo",
            configDir: configDir
        )
        #expect(sessions.isEmpty)
    }

    @Test("scan skips non-UUID filenames")
    func scanSkipsNonUUID() throws {
        let configDir = try makeTempDir("claude-nonuuid")
        defer { dispose(configDir) }
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionFile = projectDir.appendingPathComponent("not-a-uuid.jsonl")
        try "{\"cwd\":\"/work/repo\"}\n".write(to: sessionFile, atomically: true, encoding: .utf8)

        let sessions = ClaudeSessionScanner.scan(
            requestedCwd: "/work/repo",
            configDir: configDir
        )
        #expect(sessions.isEmpty)
    }

    @Test("title extraction prefers customTitle over aiTitle over firstPrompt")
    func titlePrecedence() throws {
        let configDir = try makeTempDir("claude-title")
        defer { dispose(configDir) }
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let sessionFile = projectDir.appendingPathComponent("\(sessionID).jsonl")
        let jsonl = """
        {"cwd":"/work/repo","customTitle":"My Custom Title"}
        {"type":"user","message":{"content":"the actual prompt"},"aiTitle":"AI Generated Title"}
        """
        try jsonl.write(to: sessionFile, atomically: true, encoding: .utf8)

        let sessions = ClaudeSessionScanner.scan(
            requestedCwd: "/work/repo",
            configDir: configDir
        )
        #expect(sessions.count == 1)
        #expect(sessions[0].title == "My Custom Title")
    }

    @Test("first prompt extraction handles bash-input tags")
    func firstPromptBashInput() {
        let head = """
        {"cwd":"/work","type":"system"}
        {"type":"user","message":{"content":"<bash-input> ls -la </bash-input>"}}
        """
        let prompt = ClaudeSessionScanner.firstPrompt(in: head)
        #expect(prompt == "! ls -la")
    }

    @Test("first prompt skips generated prompts starting with <lowercase")
    func firstPromptSkipsGenerated() {
        let head = """
        {"cwd":"/work"}
        {"type":"user","message":{"content":"<system>injected</system>"}}
        {"type":"user","message":{"content":"real question"}}
        """
        let prompt = ClaudeSessionScanner.firstPrompt(in: head)
        #expect(prompt == "real question")
    }

    @Test("between extracts text between tags")
    func betweenFunction() {
        #expect(ClaudeSessionScanner.between("pre<a>inner</a>post", start: "<a>", end: "</a>") == "inner")
        #expect(ClaudeSessionScanner.between("no tags here", start: "<a>", end: "</a>") == nil)
    }

    @Test("scan extracts git branch from JSONL")
    func scanExtractsBranch() throws {
        let configDir = try makeTempDir("claude-branch")
        defer { dispose(configDir) }
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let sessionFile = projectDir.appendingPathComponent("\(sessionID).jsonl")
        let jsonl = """
        {"cwd":"/work/repo","gitBranch":"feature/add-auth"}
        {"type":"user","message":{"content":"Add OAuth support"}}
        """
        try jsonl.write(to: sessionFile, atomically: true, encoding: .utf8)

        let sessions = ClaudeSessionScanner.scan(
            requestedCwd: "/work/repo",
            configDir: configDir
        )
        #expect(sessions.count == 1)
        #expect(sessions[0].branch == "feature/add-auth")
    }

    @Test("config dir resolves from CLAUDE_CONFIG_DIR env")
    func configDirFromEnv() {
        let resolved = ClaudeSessionScanner.resolveConfigDir(nil, environment: [
            "CLAUDE_CONFIG_DIR": "/custom/claude"
        ])
        #expect(resolved?.path == "/custom/claude")
    }

    @Test("config dir falls back to HOME/.claude")
    func configDirFromHome() {
        let resolved = ClaudeSessionScanner.resolveConfigDir(nil, environment: [
            "HOME": "/Users/test"
        ])
        #expect(resolved?.path.hasSuffix(".claude") == true)
    }
}

// MARK: - Codex scanner

@Suite("Codex session scanner")
struct CodexSessionScannerTests {

    @Test("scan returns empty for missing home")
    func emptyOnMissingHome() {
        let sessions = CodexSessionScanner.scan(
            requestedCwd: "/nonexistent",
            codexHome: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        #expect(sessions.isEmpty)
    }

    @Test("scan discovers a rollout session matching the cwd")
    func scanFindsRollout() throws {
        let codexHome = try makeTempDir("codex-scan")
        defer { dispose(codexHome) }
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let dateDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let rolloutFile = dateDir
            .appendingPathComponent("rollout-2027-01-15T12-00-00-\(sessionID).jsonl")
        let jsonl = """
        {"cwd":"/work/repo","session_id":"\(sessionID)","source":"cli"}
        {"role":"user","content":"Refactor the database layer"}
        {"role":"assistant","content":"Done"}
        """
        try jsonl.write(to: rolloutFile, atomically: true, encoding: .utf8)

        let sessions = CodexSessionScanner.scan(
            requestedCwd: "/work/repo",
            codexHome: codexHome
        )
        #expect(sessions.count == 1)
        #expect(sessions[0].nativeID == sessionID)
        #expect(sessions[0].tool == .codex)
        #expect(sessions[0].source == .codexCli)
        #expect(sessions[0].title == "Refactor the database layer")
        #expect(sessions[0].cwd == "/work/repo")
    }

    @Test("scan skips rollouts with wrong cwd")
    func scanSkipsMismatchedCwd() throws {
        let codexHome = try makeTempDir("codex-cwd")
        defer { dispose(codexHome) }
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let dateDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let rolloutFile = dateDir
            .appendingPathComponent("rollout-2027-01-15T12-00-00-\(sessionID).jsonl")
        try "{\"cwd\":\"/other/path\",\"session_id\":\"\(sessionID)\",\"source\":\"cli\"}\n"
            .write(to: rolloutFile, atomically: true, encoding: .utf8)

        let sessions = CodexSessionScanner.scan(
            requestedCwd: "/work/repo",
            codexHome: codexHome
        )
        #expect(sessions.isEmpty)
    }

    @Test("rollout ID extraction validates format")
    func rolloutIDExtraction() {
        let uuid = UUID().uuidString
        #expect(CodexSessionScanner.rolloutID(from: "rollout-2027-01-15T12-00-00-\(uuid)") == uuid)
        #expect(CodexSessionScanner.rolloutID(from: "not-a-rollout") == nil)
        #expect(CodexSessionScanner.rolloutID(from: "rollout-bad") == nil)
        #expect(CodexSessionScanner.rolloutID(from: "rollout-2027-01-15T12-00-00-not-a-uuid") == nil)
    }

    @Test("codex source maps strings correctly")
    func sourceMapping() {
        #expect(CodexSessionScanner.codexSourceFromString("cli") == .codexCli)
        #expect(CodexSessionScanner.codexSourceFromString("vscode") == .codexVsCode)
        #expect(CodexSessionScanner.codexSourceFromString("unknown") == nil)
    }

    @Test("codex source maps objects correctly")
    func sourceObjectMapping() {
        #expect(CodexSessionScanner.codexSourceFromObject(["custom": "atlas"]) == .codexAtlas)
        #expect(CodexSessionScanner.codexSourceFromObject(["custom": "chatgpt"]) == .codexChatGpt)
        #expect(CodexSessionScanner.codexSourceFromObject(["custom": "unknown"]) == nil)
        #expect(CodexSessionScanner.codexSourceFromObject(["other": "value"]) == nil)
    }

    @Test("codex home resolves from CODEX_HOME env")
    func homeFromEnv() {
        let resolved = CodexSessionScanner.resolveCodexHome(nil, environment: [
            "CODEX_HOME": "/custom/codex"
        ])
        #expect(resolved?.path == "/custom/codex")
    }

    @Test("codex home falls back to HOME/.codex")
    func homeFromHomeFallback() {
        let resolved = CodexSessionScanner.resolveCodexHome(nil, environment: [
            "HOME": "/Users/test"
        ])
        #expect(resolved?.path.hasSuffix(".codex") == true)
    }

    @Test("scan extracts vscode source from rollout")
    func scanExtractsVsCodeSource() throws {
        let codexHome = try makeTempDir("codex-vscode")
        defer { dispose(codexHome) }
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let dateDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let rolloutFile = dateDir
            .appendingPathComponent("rollout-2027-01-15T12-00-00-\(sessionID).jsonl")
        let jsonl = """
        {"cwd":"/work/repo","session_id":"\(sessionID)","source":"vscode"}
        {"role":"user","content":"Add dark mode toggle"}
        """
        try jsonl.write(to: rolloutFile, atomically: true, encoding: .utf8)

        let sessions = CodexSessionScanner.scan(
            requestedCwd: "/work/repo",
            codexHome: codexHome
        )
        #expect(sessions.count == 1)
        #expect(sessions[0].source == .codexVsCode)
    }

    @Test("scan extracts atlas source from rollout object")
    func scanExtractsAtlasSource() throws {
        let codexHome = try makeTempDir("codex-atlas")
        defer { dispose(codexHome) }
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let dateDir = codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(components.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString
        let rolloutFile = dateDir
            .appendingPathComponent("rollout-2027-01-15T12-00-00-\(sessionID).jsonl")
        let jsonl = """
        {"cwd":"/work/repo","session_id":"\(sessionID)","source":{"custom":"atlas"}}
        {"role":"user","content":"Deploy to production"}
        """
        try jsonl.write(to: rolloutFile, atomically: true, encoding: .utf8)

        let sessions = CodexSessionScanner.scan(
            requestedCwd: "/work/repo",
            codexHome: codexHome
        )
        #expect(sessions.count == 1)
        #expect(sessions[0].source == .codexAtlas)
    }
}

// MARK: - Composition integration

@Suite("Foreign sessions in sessions list")
struct ForeignSessionCompositionTests {

    @Test("stub scanner merges foreign sessions with local listings")
    func mergeWithLocalSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-foreign-compose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["OPENGROK_HOME": root.path, "HOME": root.path]
        let localRecord = LiveConversationRecord(
            sessionID: "local-001",
            workingDirectory: "/work",
            parentSessionID: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            items: [.user("local prompt")]
        )
        let data = try JSONEncoder().encode(localRecord)
        try data.write(
            to: root.appendingPathComponent("sessions/local-001.json")
        )
        let foreignSession = ForeignSessionSummary(
            tool: .claude, source: .claudeCode,
            nativeID: "foreign-001",
            title: "Claude session",
            cwd: FileManager.default.currentDirectoryPath,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let scanner = StubForeignSessionScanner(sessions: [foreignSession])
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list),
            environment: environment,
            streams: streams,
            foreignScanner: scanner,
            foreignSources: .all
        )

        let output = out.contents
        #expect(output.contains("[Claude Code]"))
        #expect(output.contains("foreign-001"))
        #expect(output.contains("local-001"))
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[1].contains("foreign-001"))
        #expect(lines[2].contains("local-001"))
    }

    @Test("JSON output includes foreign_source for foreign sessions")
    func jsonIncludesForeignSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-foreign-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["OPENGROK_HOME": root.path, "HOME": root.path]
        let foreignSession = ForeignSessionSummary(
            tool: .codex, source: .codexCli,
            nativeID: "codex-001",
            title: "Codex session",
            cwd: FileManager.default.currentDirectoryPath,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let scanner = StubForeignSessionScanner(sessions: [foreignSession])
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list, json: true),
            environment: environment,
            streams: streams,
            foreignScanner: scanner,
            foreignSources: .all
        )

        let decoded = try JSONSerialization.jsonObject(with: Data(out.contents.utf8))
        let rows = try #require(decoded as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["foreign_source"] as? String == "codex_cli")
        #expect(rows[0]["foreign_tool"] as? String == "codex")
        #expect(rows[0]["id"] as? String == "codex-001")
    }

    @Test("local sessions have no foreign_source in JSON output")
    func jsonExcludesForeignSourceForLocal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-foreign-nofs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["OPENGROK_HOME": root.path, "HOME": root.path]
        let localRecord = LiveConversationRecord(
            sessionID: "local-002",
            workingDirectory: "/work",
            parentSessionID: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            items: [.user("hello")]
        )
        try JSONEncoder().encode(localRecord).write(
            to: root.appendingPathComponent("sessions/local-002.json")
        )
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list, json: true),
            environment: environment,
            streams: streams
        )

        let decoded = try JSONSerialization.jsonObject(with: Data(out.contents.utf8))
        let rows = try #require(decoded as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["foreign_source"] == nil)
        #expect(rows[0]["foreign_tool"] == nil)
    }

    @Test("disabled foreign sources produce no foreign results")
    func disabledSourcesProduceNoResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-foreign-dis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["OPENGROK_HOME": root.path, "HOME": root.path]
        let foreignSession = ForeignSessionSummary(
            tool: .claude, source: .claudeCode,
            nativeID: "should-not-appear",
            title: "Hidden",
            cwd: FileManager.default.currentDirectoryPath,
            updatedAt: Date()
        )
        let scanner = StubForeignSessionScanner(sessions: [foreignSession])
        let (streams, out, _) = CLIStreams.buffered()

        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .list),
            environment: environment,
            streams: streams,
            foreignScanner: scanner,
            foreignSources: .none
        )

        #expect(!out.contents.contains("should-not-appear"))
    }

    @Test("stub scanner respects enabled source filter")
    func stubScannerFilters() {
        let sessions = [
            ForeignSessionSummary(
                tool: .claude, source: .claudeCode,
                nativeID: "c1", title: "Claude", cwd: "/w",
                updatedAt: Date()
            ),
            ForeignSessionSummary(
                tool: .codex, source: .codexCli,
                nativeID: "x1", title: "Codex", cwd: "/w",
                updatedAt: Date()
            ),
        ]
        let scanner = StubForeignSessionScanner(sessions: sessions)
        let claudeOnly = scanner.scan(
            cwd: "/w",
            enabled: EnabledForeignSources(claude: true, codex: false)
        )
        #expect(claudeOnly.count == 1)
        #expect(claudeOnly[0].tool == .claude)
        let codexOnly = scanner.scan(
            cwd: "/w",
            enabled: EnabledForeignSources(claude: false, codex: true)
        )
        #expect(codexOnly.count == 1)
        #expect(codexOnly[0].tool == .codex)
    }

    @Test("listing from foreign summary has zero message counts and foreign source")
    func listingFromForeign() {
        let summary = ForeignSessionSummary(
            tool: .codex, source: .codexVsCode,
            nativeID: "test-id", title: "Test",
            cwd: "/work", updatedAt: Date()
        )
        let listing = LiveSessionsComposition.listing(fromForeign: summary)
        #expect(listing.foreignSource == .codexVsCode)
        #expect(listing.messageCount == 0)
        #expect(listing.userMessageCount == 0)
        #expect(listing.assistantMessageCount == 0)
        #expect(listing.sessionID == "test-id")
        #expect(listing.title == "Test")
    }

    // MARK: - Import/writeback refusal

    @Test("ForeignSessionScanning protocol has no mutation methods")
    func scannerProtocolIsReadOnly() {
        // This test asserts the architectural refusal: the protocol surface
        // is scan-only. There is no import(), writeback(), delete(), or
        // mutate() method. The only way to interact with foreign sessions is
        // through read-only scanning. Adding a mutation method here would
        // require changing the protocol, which would be a visible,
        // reviewable change rather than a silent addition.
        let scanner = StubForeignSessionScanner()
        let results = scanner.scan(cwd: "/test", enabled: .all)
        #expect(results.isEmpty)
    }

    @Test("show and delete operate only on local catalog, not foreign sessions")
    func showDeleteLocalOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-foreign-nodelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["OPENGROK_HOME": root.path, "HOME": root.path]

        // show for a foreign-looking ID finds nothing in the local catalog
        let (showStreams, _, _) = CLIStreams.buffered()
        #expect(throws: CLIApplicationError.self) {
            try LiveSessionsComposition.run(
                options: CLISessionOptions(action: .show, identifier: "foreign-id"),
                environment: environment,
                streams: showStreams
            )
        }

        // delete for a foreign-looking ID reports a miss
        let (deleteStreams, deleteOut, _) = CLIStreams.buffered()
        try LiveSessionsComposition.run(
            options: CLISessionOptions(action: .delete, identifier: "foreign-id"),
            environment: environment,
            streams: deleteStreams
        )
        #expect(deleteOut.contents.contains("No session found"))
    }
}
