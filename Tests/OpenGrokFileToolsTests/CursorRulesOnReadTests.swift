// CursorRulesOnReadTests.swift
//
// Tests for Cursor rules discovery, YAML frontmatter parsing, glob matching,
// upward directory scope walk, single-injection deduplication, and attachment rendering.

import Foundation
import Testing
@testable import OpenGrokFileTools

@Suite("CursorRulesOnRead")
struct CursorRulesOnReadTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-cursorrules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Frontmatter Parsing Tests

    @Test("Frontmatter parsing with alwaysApply boolean")
    func parseAlwaysApply() {
        let content = """
        ---
        alwaysApply: true
        ---
        Global instructions for everything.
        """
        let split = splitFrontmatter(content: content)
        #expect(split != nil)
        #expect(split?.frontmatter == "alwaysApply: true")
        #expect(split?.body == "Global instructions for everything.")

        let fm = parseFrontmatter(yaml: split!.frontmatter)
        #expect(fm != nil)
        #expect(fm?.alwaysApply == true)
        #expect(fm?.globs.isEmpty == true)

        let rule = parseCursorRule(
            scopeDir: "/repo",
            fullPath: "/repo/.cursor/rules/global.mdc",
            content: content
        )
        #expect(rule.kind == .global)
        #expect(rule.body == "Global instructions for everything.")
    }

    @Test("Frontmatter parsing with single glob string")
    func parseSingleGlob() {
        let content = """
        ---
        globs: *.rs
        alwaysApply: false
        ---
        Use Rust rules.
        """
        let split = splitFrontmatter(content: content)
        #expect(split != nil)
        let fm = parseFrontmatter(yaml: split!.frontmatter)
        #expect(fm != nil)
        #expect(fm?.alwaysApply == false)
        #expect(fm?.globs == ["*.rs"])

        let rule = parseCursorRule(
            scopeDir: "/repo",
            fullPath: "/repo/.cursor/rules/rust.mdc",
            content: content
        )
        #expect(rule.kind == .fileGlobbed(["*.rs"]))
        #expect(rule.body == "Use Rust rules.")
    }

    @Test("Frontmatter parsing with YAML list of globs")
    func parseGlobList() {
        let content = """
        ---
        globs:
          - "*.swift"
          - "Sources/**/*.swift"
        description: "Swift code rules"
        alwaysApply: false
        ---
        Swift formatting and strict concurrency guidelines.
        """
        let split = splitFrontmatter(content: content)
        #expect(split != nil)
        let fm = parseFrontmatter(yaml: split!.frontmatter)
        #expect(fm != nil)
        #expect(fm?.globs == ["*.swift", "Sources/**/*.swift"])
        #expect(fm?.description == "Swift code rules")

        let rule = parseCursorRule(
            scopeDir: "/repo",
            fullPath: "/repo/.cursor/rules/swift.mdc",
            content: content
        )
        #expect(rule.kind == .fileGlobbed(["*.swift", "Sources/**/*.swift"]))
        #expect(rule.body.contains("Swift formatting"))
    }

    @Test("Frontmatter parsing with inline bracketed globs")
    func parseInlineBracketedGlobs() {
        let content = """
        ---
        globs: [*.ts, src/**/*.ts, "tests/**/*.test.ts"]
        ---
        TypeScript rules.
        """
        let split = splitFrontmatter(content: content)
        #expect(split != nil)
        let fm = parseFrontmatter(yaml: split!.frontmatter)
        #expect(fm != nil)
        #expect(fm?.globs == ["*.ts", "src/**/*.ts", "tests/**/*.test.ts"])

        let rule = parseCursorRule(
            scopeDir: "/repo",
            fullPath: "/repo/.cursor/rules/ts.mdc",
            content: content
        )
        #expect(rule.kind == .fileGlobbed(["*.ts", "src/**/*.ts", "tests/**/*.test.ts"]))
    }

    @Test("Frontmatter parsing with description only (agentFetched)")
    func parseAgentFetched() {
        let content = """
        ---
        description: "Database migration instructions"
        alwaysApply: false
        ---
        Run migrations carefully.
        """
        let rule = parseCursorRule(
            scopeDir: "/repo",
            fullPath: "/repo/.cursor/rules/db.mdc",
            content: content
        )
        #expect(rule.kind == .agentFetched)
    }

    @Test(".cursorrules default vs .mdc default")
    func defaultKinds() {
        let plainContent = "General project guidelines."
        let cursorrules = parseCursorRule(
            scopeDir: "/repo",
            fullPath: "/repo/.cursorrules",
            content: plainContent
        )
        #expect(cursorrules.kind == .global)

        let mdcRule = parseCursorRule(
            scopeDir: "/repo",
            fullPath: "/repo/.cursor/rules/custom.mdc",
            content: plainContent
        )
        #expect(mdcRule.kind == .manual)
    }

    @Test("CRLF line endings frontmatter split and parsing")
    func crlfParsing() {
        let content = "---\r\nalwaysApply: true\r\ndescription: Windows style\r\n---\r\nLine 1\r\nLine 2"
        let split = splitFrontmatter(content: content)
        #expect(split != nil)
        #expect(split?.frontmatter == "alwaysApply: true\r\ndescription: Windows style")
        #expect(split?.body == "Line 1\r\nLine 2")

        let fm = parseFrontmatter(yaml: split!.frontmatter)
        #expect(fm?.alwaysApply == true)
        #expect(fm?.description == "Windows style")
    }

    // MARK: - Glob Matching Tests

    @Test("Glob matching various patterns")
    func globPatterns() {
        // Single * matches within segment
        #expect(globMatches(pattern: "*.swift", candidate: "Main.swift"))
        #expect(!globMatches(pattern: "*.swift", candidate: "Sources/Main.swift"))

        // ** matches across segments
        #expect(globMatches(pattern: "**/*.swift", candidate: "Main.swift"))
        #expect(globMatches(pattern: "**/*.swift", candidate: "Sources/App/Main.swift"))
        #expect(globMatches(pattern: "Sources/**", candidate: "Sources/App/Main.swift"))
        #expect(!globMatches(pattern: "Sources/**", candidate: "Other/App/Main.swift"))

        // ? matches single character
        #expect(globMatches(pattern: "test?.swift", candidate: "test1.swift"))
        #expect(!globMatches(pattern: "test?.swift", candidate: "test12.swift"))
        #expect(!globMatches(pattern: "test?.swift", candidate: "test/.swift"))

        // normalizeRelativeGlob
        #expect(normalizeRelativeGlob("*.swift") == "**/*.swift")
        #expect(normalizeRelativeGlob("Sources/**/*.swift") == "Sources/**/*.swift")

        // fileGlobsMatch
        #expect(fileGlobsMatch(scopeDir: "/repo", readPath: "/repo/Sources/App/Main.swift", globs: ["*.swift"]))
        #expect(fileGlobsMatch(scopeDir: "/repo", readPath: "/repo/main.swift", globs: ["*.swift"]))
        #expect(fileGlobsMatch(scopeDir: "/repo", readPath: "/repo/src/index.ts", globs: ["**/*.ts"]))
        #expect(!fileGlobsMatch(scopeDir: "/repo", readPath: "/repo/src/index.js", globs: ["**/*.ts"]))
    }

    // MARK: - Directory Hierarchy Walk Tests

    @Test("ancestorScopeDirs computes scope directories from root to file parent")
    func ancestorScopeDirsWalk() {
        let root = "/repo"
        let file = "/repo/frontend/src/components/Button.tsx"
        let scopes = ancestorScopeDirs(workspaceRoot: root, readPath: file)
        #expect(scopes == [
            "/repo",
            "/repo/frontend",
            "/repo/frontend/src",
            "/repo/frontend/src/components",
        ])

        let rootFile = "/repo/Package.swift"
        let rootScopes = ancestorScopeDirs(workspaceRoot: root, readPath: rootFile)
        #expect(rootScopes == ["/repo"])

        let outsideFile = "/other/path/File.swift"
        let outsideScopes = ancestorScopeDirs(workspaceRoot: root, readPath: outsideFile)
        #expect(outsideScopes.isEmpty)
    }

    // MARK: - Scanning & Deduplication Tests

    @Test("File globbed rule matches read path once and dedupes subsequent reads")
    func fileGlobbedRuleDeduplication() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.path

        let rulesDir = dir.appendingPathComponent(".cursor/rules")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        let ruleFile = rulesDir.appendingPathComponent("rust.mdc")
        try """
        ---
        globs: *.rs
        alwaysApply: false
        ---
        Use Rust rules.
        """.write(to: ruleFile, atomically: true, encoding: .utf8)

        let mainRs = dir.appendingPathComponent("main.rs")
        try "fn main() {}\n".write(to: mainRs, atomically: true, encoding: .utf8)

        let tracker = CursorRulesOnReadTracker()

        let first = await tracker.rulesForRead(workspaceRoot: root, readPath: mainRs.path)
        #expect(first.count == 1)
        #expect(first.first?.body == "Use Rust rules.")

        let second = await tracker.rulesForRead(workspaceRoot: root, readPath: mainRs.path)
        #expect(second.isEmpty, "Rules should be deduplicated per session")
    }

    @Test("Seeded injected rule paths suppress duplicates (canonical and relative)")
    func seededInjectedRulePaths() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.path

        let rulesDir = dir.appendingPathComponent(".cursor/rules")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        let ruleFile = rulesDir.appendingPathComponent("rust.mdc")
        try """
        ---
        globs: *.rs
        alwaysApply: false
        ---
        Use Rust rules.
        """.write(to: ruleFile, atomically: true, encoding: .utf8)

        let mainRs = dir.appendingPathComponent("main.rs")
        try "fn main() {}\n".write(to: mainRs, atomically: true, encoding: .utf8)

        // Seed with relative path
        let tracker = CursorRulesOnReadTracker(
            injectedRulePaths: [".cursor/rules/rust.mdc"]
        )

        let result = await tracker.rulesForRead(workspaceRoot: root, readPath: mainRs.path)
        #expect(result.isEmpty, "Seeded relative rule path should suppress injection")
    }

    @Test("Root alwaysApply rule is not read-scoped, nested alwaysApply rule is read-scoped")
    func rootVsNestedAlwaysApply() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.path

        // Root global rule
        let rootRulesDir = dir.appendingPathComponent(".cursor/rules")
        try FileManager.default.createDirectory(at: rootRulesDir, withIntermediateDirectories: true)
        try """
        ---
        alwaysApply: true
        ---
        Global root rule.
        """.write(to: rootRulesDir.appendingPathComponent("global.mdc"), atomically: true, encoding: .utf8)

        // Nested frontend rule
        let frontend = dir.appendingPathComponent("frontend")
        let frontendRulesDir = frontend.appendingPathComponent(".cursor/rules")
        try FileManager.default.createDirectory(at: frontendRulesDir, withIntermediateDirectories: true)
        try """
        ---
        alwaysApply: true
        ---
        Frontend rule.
        """.write(to: frontendRulesDir.appendingPathComponent("frontend.mdc"), atomically: true, encoding: .utf8)

        let frontendSrc = frontend.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: frontendSrc, withIntermediateDirectories: true)
        let appTsx = frontendSrc.appendingPathComponent("App.tsx")
        try "export const App = () => null;\n".write(to: appTsx, atomically: true, encoding: .utf8)

        let serverTs = dir.appendingPathComponent("server.ts")
        try "export const server = true;\n".write(to: serverTs, atomically: true, encoding: .utf8)

        let tracker = CursorRulesOnReadTracker()

        // Reading server.ts at root should NOT match root alwaysApply (not read-scoped) and NOT match frontend
        let outside = await tracker.rulesForRead(workspaceRoot: root, readPath: serverTs.path)
        #expect(outside.isEmpty)

        // Reading frontend/src/App.tsx should match the nested frontend rule
        let inside = await tracker.rulesForRead(workspaceRoot: root, readPath: appTsx.path)
        #expect(inside.count == 1)
        #expect(inside.first?.body == "Frontend rule.")
    }

    @Test("Repeated directory scans deduplicate rules")
    func repeatedScansDeduplicate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.path

        let rulesDir = dir.appendingPathComponent(".cursor/rules")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try """
        ---
        globs: *.rs
        alwaysApply: false
        ---
        Use Rust rules.
        """.write(to: rulesDir.appendingPathComponent("rust.mdc"), atomically: true, encoding: .utf8)

        let scan1 = scanScopeDir(scopeDir: root)
        let scan2 = scanScopeDir(scopeDir: root)
        #expect(scan1.count == 1)
        #expect(scan2.count == 1)
        #expect(scan1.first?.fullPath == scan2.first?.fullPath)
    }

    // MARK: - Attachment & Formatting Tests

    @Test("renderCursorRuleBlocks formats XML blocks with relative path")
    func renderBlocks() {
        let rules = [
            ParsedCursorRule(
                fullPath: "/workspace/project/.cursor/rules/style.mdc",
                scopeDir: "/workspace/project",
                body: "Always use 4 spaces.",
                kind: .fileGlobbed(["*.swift"])
            )
        ]
        let rendered = renderCursorRuleBlocks(rules: rules, workspaceRoot: "/workspace/project")
        #expect(rendered == "<cursor_rule path=\".cursor/rules/style.mdc\">\nAlways use 4 spaces.\n</cursor_rule>")
    }

    @Test("renderCursorRuleReminder formats human-readable reminder")
    func renderReminder() {
        let rules = [
            ParsedCursorRule(
                fullPath: "/repo/.cursor/rules/example.mdc",
                scopeDir: "/repo",
                body: "Rule body.",
                kind: .fileGlobbed(["*.rs"])
            )
        ]
        let reminder = renderCursorRuleReminder(rules: rules)
        #expect(reminder != nil)
        #expect(reminder!.contains("The following rule files are relevant to the files you just read:"))
        #expect(reminder!.contains("- /repo/.cursor/rules/example.mdc\nRule body."))
        #expect(reminder!.contains("Consider these rules if they affect your changes."))
    }

    @Test("appendCursorRulesForRead appends when enabled and does nothing when disabled")
    func appendCursorRules() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.path

        let rulesDir = dir.appendingPathComponent(".cursor/rules")
        try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
        try """
        ---
        globs: *.swift
        alwaysApply: false
        ---
        Follow Swift conventions.
        """.write(to: rulesDir.appendingPathComponent("swift.mdc"), atomically: true, encoding: .utf8)

        let mainSwift = dir.appendingPathComponent("Main.swift")
        try "import Foundation\n".write(to: mainSwift, atomically: true, encoding: .utf8)

        let tracker = CursorRulesOnReadTracker()

        // When disabled
        var content = "1→import Foundation"
        var concise: String? = "1→import Foundation"
        await appendCursorRulesForRead(
            enabled: false,
            tracker: tracker,
            workspaceRoot: root,
            readPath: mainSwift.path,
            content: &content,
            contentConcise: &concise
        )
        #expect(content == "1→import Foundation")
        #expect(concise == "1→import Foundation")

        // When enabled
        await appendCursorRulesForRead(
            enabled: true,
            tracker: tracker,
            workspaceRoot: root,
            readPath: mainSwift.path,
            content: &content,
            contentConcise: &concise
        )
        #expect(content.contains("<cursor_rule path=\".cursor/rules/swift.mdc\">"))
        #expect(content.contains("Follow Swift conventions."))
        #expect(concise?.contains("<cursor_rule path=\".cursor/rules/swift.mdc\">") == true)
        #expect(concise?.contains("Follow Swift conventions.") == true)

        // Subsequent read (should not append again due to deduplication)
        var content2 = "1→import Foundation"
        var concise2: String? = "1→import Foundation"
        await appendCursorRulesForRead(
            enabled: true,
            tracker: tracker,
            workspaceRoot: root,
            readPath: mainSwift.path,
            content: &content2,
            contentConcise: &concise2
        )
        #expect(content2 == "1→import Foundation")
        #expect(concise2 == "1→import Foundation")
    }
}
