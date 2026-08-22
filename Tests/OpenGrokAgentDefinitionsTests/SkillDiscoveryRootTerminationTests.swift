import Foundation
import Testing
@testable import OpenGrokAgentDefinitions

private struct SkillDiscoveryRootFixture {
    let root: URL
    let cwd: URL
    let siblingHome: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-discovery-root-\(UUID().uuidString)", isDirectory: true)
        cwd = root.appendingPathComponent("workspace", isDirectory: true)
        siblingHome = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingHome, withIntermediateDirectories: true)
    }

    func writeSkill(in directory: URL, name: String) throws {
        let skillDirectory = directory
            .appendingPathComponent(".opengrok/skills/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(name) description\n---\n\nbody"
            .write(
                to: skillDirectory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("skill discovery filesystem-root termination")
struct SkillDiscoveryRootTerminationTests {
    @Test("a no-Git workspace reaches the filesystem root without looping")
    func noGitRootTerminates() throws {
        let fixture = try SkillDiscoveryRootFixture()
        defer { fixture.cleanup() }

        #expect(SkillDiscovery.findGitRoot(from: fixture.cwd) == nil)
        #expect(SkillDiscovery.ancestorChain(from: fixture.cwd, stoppingAt: nil).map(\.path)
            == [fixture.cwd.path])
    }

    @Test("startup scans only the no-Git cwd and sibling HOME roots")
    func noGitStartupWithSiblingHomeTerminates() throws {
        let fixture = try SkillDiscoveryRootFixture()
        defer { fixture.cleanup() }
        try fixture.writeSkill(in: fixture.cwd, name: "local-owned")
        try fixture.writeSkill(in: fixture.siblingHome, name: "user-owned")
        try fixture.writeSkill(in: fixture.root, name: "parent-not-owned")

        let discovery = SkillDiscovery(environment: ["HOME": fixture.siblingHome.path])
        let skills = discovery.discover(cwd: fixture.cwd)

        #expect(skills.contains { $0.name == "local-owned" && $0.scope == .local })
        #expect(skills.contains { $0.name == "user-owned" && $0.scope == .user })
        #expect(!skills.contains { $0.name == "parent-not-owned" })
    }

    @Test("dynamic discovery outside a no-Git cwd stops at the filesystem root")
    func dynamicSiblingPathTerminatesAtRoot() throws {
        let fixture = try SkillDiscoveryRootFixture()
        defer { fixture.cleanup() }
        let nested = fixture.siblingHome.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try fixture.writeSkill(in: nested, name: "dynamically-owned")
        let discovery = SkillDiscovery(environment: ["HOME": fixture.siblingHome.path])
        var checked = Set<String>()

        let skills = discovery.discoverForPaths(
            [nested.appendingPathComponent("edited.swift")],
            cwd: fixture.cwd,
            gitRoot: nil,
            alreadyChecked: &checked
        )

        #expect(skills.contains { $0.name == "dynamically-owned" })
        #expect(checked.count <= nested.standardizedFileURL.pathComponents.count + 2)
        #expect(Set(checked).count == checked.count)
    }

    @Test("a nested Git root remains the nearest inclusive ancestor")
    func nestedGitRootAndAncestorChainArePreserved() throws {
        let fixture = try SkillDiscoveryRootFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.cwd.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let nested = fixture.cwd.appendingPathComponent("one/two", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let discoveredRoot = try #require(SkillDiscovery.findGitRoot(from: nested))
        #expect(discoveredRoot.standardizedFileURL.path == fixture.cwd.standardizedFileURL.path)
        let chain = SkillDiscovery.ancestorChain(from: nested, stoppingAt: discoveredRoot)
        #expect(chain.map(\.lastPathComponent) == ["two", "one", "workspace"])
    }

    #if !os(Windows)
    @Test("a symlinked Git-root spelling terminates on canonical ancestor identity")
    func symlinkedGitRootUsesCanonicalIdentity() throws {
        let fixture = try SkillDiscoveryRootFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.cwd.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let nested = fixture.cwd.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = fixture.root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.cwd)

        let chain = SkillDiscovery.ancestorChain(from: nested, stoppingAt: alias)

        #expect(chain.map(\.lastPathComponent) == ["nested", "workspace"])
    }
    #endif
}
