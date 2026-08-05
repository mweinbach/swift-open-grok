import Foundation
import Testing
@testable import OpenGrokAgentDefinitions

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-skills-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@discardableResult
private func writeSkill(
    root: URL,
    configDirectory: String,
    name: String,
    frontmatter: String,
    body: String = "Do the thing."
) throws -> URL {
    let directory = root
        .appendingPathComponent(configDirectory, isDirectory: true)
        .appendingPathComponent("skills", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("SKILL.md")
    try "---\n\(frontmatter)\n---\n\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
    return file
}

@Suite("skill name normalization")
struct SkillNameTests {
    @Test("normalizes to a lowercase hyphenated slug")
    func normalizes() {
        #expect(SkillName.normalize("Deploy To Prod") == "deploy-to-prod")
        #expect(SkillName.normalize("--Weird__Name--") == "weird-name")
        #expect(SkillName.normalize("a/b/c") == "a-b-c")
    }

    @Test("rejects names that cannot address a command")
    func rejectsInvalid() {
        #expect(SkillName.isValid("deploy"))
        #expect(SkillName.isValid("deploy-to-prod"))
        #expect(SkillName.isValid("") == false)
        #expect(SkillName.isValid("-leading") == false)
        #expect(SkillName.isValid("trailing-") == false)
        #expect(SkillName.isValid("double--dash") == false)
        #expect(SkillName.isValid("Upper") == false)
        #expect(SkillName.isValid(String(repeating: "a", count: 65)) == false)
    }
}

@Suite("SKILL.md frontmatter")
struct SkillFrontmatterTests {
    @Test("parses the documented fields")
    func parsesFields() throws {
        let parsed = try SkillFrontmatterParser.parse(
            """
            ---
            name: commit
            description: Write a commit message
            when-to-use: after staging changes
            argument-hint: <subject>
            allowed-tools: Read, Bash(git diff:*)
            model: fast
            ---

            Body text.
            """,
            fallbackName: "commit"
        )
        #expect(parsed.name == "commit")
        #expect(parsed.description == "Write a commit message")
        #expect(parsed.whenToUse == "after staging changes")
        #expect(parsed.argumentHint == "<subject>")
        #expect(parsed.model == "fast")
        // The split must keep `Bash(git diff:*)` whole; splitting inside the
        // parentheses would silently narrow the tool grant.
        #expect(parsed.allowedTools == ["Read", "Bash(git diff:*)"])
        #expect(parsed.body == "Body text.")
    }

    @Test("user-invocable defaults true and disable-model-invocation defaults false")
    func gateDefaults() throws {
        let parsed = try SkillFrontmatterParser.parse(
            "---\nname: x\ndescription: y\n---\n\nbody",
            fallbackName: "x"
        )
        #expect(parsed.userInvocable)
        #expect(parsed.disableModelInvocation == false)
    }

    @Test("only literal true counts as true")
    func strictBooleans() throws {
        let off = try SkillFrontmatterParser.parse(
            "---\nname: x\ndescription: y\nuser-invocable: false\n---\n\nbody",
            fallbackName: "x"
        )
        #expect(off.userInvocable == false)

        let yes = try SkillFrontmatterParser.parse(
            "---\nname: x\ndescription: y\nuser-invocable: yes\n---\n\nbody",
            fallbackName: "x"
        )
        // "yes" is not "true", so it does not enable — matching Rust.
        #expect(yes.userInvocable == false)
    }

    @Test("falls back to the directory name when frontmatter has none")
    func directoryFallback() throws {
        let parsed = try SkillFrontmatterParser.parse(
            "---\ndescription: y\n---\n\nbody",
            fallbackName: "my-skill"
        )
        #expect(parsed.name == "my-skill")
    }

    @Test("missing name with no fallback is the one hard error")
    func missingNameThrows() {
        #expect(throws: SkillParseError.self) {
            try SkillFrontmatterParser.parse("---\ndescription: y\n---\n", fallbackName: nil)
        }
    }

    @Test("content without frontmatter is reported, not silently accepted")
    func noFrontmatter() {
        #expect(throws: SkillParseError.self) {
            try SkillFrontmatterParser.parse("just a body", fallbackName: "x")
        }
    }

    @Test("a paths list of only ** is treated as ungated")
    func unconditionalPathsDropped() throws {
        let parsed = try SkillFrontmatterParser.parse(
            "---\nname: x\ndescription: y\npaths: \"**\"\n---\n\nbody",
            fallbackName: "x"
        )
        #expect(parsed.paths == nil)
    }
}

@Suite("skill discovery and precedence")
struct SkillDiscoveryScopeTests {
    @Test("local overrides repo for the same skill name")
    func localWinsOverRepo() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        let nested = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try writeSkill(
            root: root, configDirectory: ".opengrok", name: "deploy",
            frontmatter: "name: deploy\ndescription: repo version"
        )
        try writeSkill(
            root: nested, configDirectory: ".opengrok", name: "deploy",
            frontmatter: "name: deploy\ndescription: local version"
        )

        let discovery = SkillDiscovery(environment: ["HOME": "/nonexistent"])
        let skills = discovery.discover(cwd: nested, gitRoot: root, home: nil, grokHome: nil)
        let deploy = skills.filter { $0.name == "deploy" }
        #expect(deploy.count == 1)
        #expect(deploy.first?.scope == .local)
        #expect(deploy.first?.description == "local version")
    }

    @Test("a user-invocable-false skill is still discovered")
    func gateDoesNotHideFromDiscovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(
            root: root, configDirectory: ".opengrok", name: "internal-only",
            frontmatter: "name: internal-only\ndescription: d\nuser-invocable: false"
        )
        let discovery = SkillDiscovery(environment: ["HOME": "/nonexistent"])
        let skills = discovery.discover(cwd: root, gitRoot: nil, home: nil, grokHome: nil)
        let found = skills.first { $0.name == "internal-only" }
        #expect(found != nil)
        // The gate belongs to slash registration, not discovery.
        #expect(found?.userInvocable == false)
    }

    @Test("vendor default skills do not shadow the user's")
    func vendorDefaultsDropped() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(
            root: root, configDirectory: ".claude", name: "pdf",
            frontmatter: "name: pdf\ndescription: vendor default"
        )
        let discovery = SkillDiscovery(environment: ["HOME": "/nonexistent"])
        let skills = discovery.discover(cwd: root, gitRoot: nil, home: nil, grokHome: nil)
        #expect(skills.contains { $0.name == "pdf" } == false)
    }

    @Test("scope ordering is Local > Repo > User > Server > Bundled > Plugin")
    func scopeOrdering() {
        #expect(SkillScope.local < SkillScope.repo)
        #expect(SkillScope.repo < SkillScope.user)
        #expect(SkillScope.user < SkillScope.server)
        #expect(SkillScope.server < SkillScope.bundled)
        #expect(SkillScope.bundled < SkillScope.plugin)
    }

    @Test("scope round-trips through its wire name")
    func scopeWireNames() throws {
        for scope in [SkillScope.local, .repo, .user, .server, .bundled, .plugin] {
            #expect(SkillScope(wireName: scope.wireName) == scope)
        }
        #expect(SkillScope(wireName: "nonsense") == nil)
    }

    @Test("the RPC wire shape uses snake_case field names")
    func wireShape() throws {
        let skill = SkillInfo(
            name: "commit", description: "d", path: "/tmp/SKILL.md", scope: .local
        )
        let data = try JSONEncoder().encode(skill)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"user_invocable\""))
        #expect(json.contains("\"disable_model_invocation\""))
        #expect(json.contains("\"has_user_specified_description\""))
        #expect(json.contains("\"scope\":\"local\""))
    }
}
