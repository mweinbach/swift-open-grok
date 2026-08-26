import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import OpenGrokCLI

#if canImport(Darwin) || canImport(Glibc)
private struct ClaudeScopeFixture {
    let root: URL
    let config: URL
    let workspace: URL

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claude-scope-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        config = root.appendingPathComponent("config", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: config.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func project(for path: String, config override: URL? = nil) throws -> URL {
        let name = try #require(ClaudeSessionScanner.sanitizedProjectPath(path))
        let directory = (override ?? config)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func session(
        in project: URL,
        cwd: String? = nil,
        title: String = "approved session",
        id: String = UUID().uuidString
    ) throws -> URL {
        let metadata = try JSONSerialization.data(withJSONObject: [
            "cwd": cwd ?? workspace.path,
            "type": "system",
        ])
        let prompt = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "message": ["content": title],
        ])
        var transcript = metadata
        transcript.append(0x0A)
        transcript.append(prompt)
        transcript.append(0x0A)
        let target = project.appendingPathComponent("\(id).jsonl")
        try transcript.write(to: target)
        return target
    }

    func scan(cwd: String? = nil, config override: URL? = nil) -> [ForeignSessionSummary] {
        ClaudeSessionScanner.scan(
            requestedCwd: cwd ?? workspace.path,
            configDir: override ?? config
        )
    }

    func setMode(_ mode: mode_t, for path: URL) throws {
        let result = path.path.withCString { chmod($0, mode) }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func configureLinkedWorktree(_ linked: URL, name: String = "linked") throws {
        let mainGit = workspace.appendingPathComponent(".git", isDirectory: true)
        let registration = mainGit
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: registration, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: \(registration.path)\n".write(
            to: linked.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        try "\(linked.appendingPathComponent(".git").path)\n".write(
            to: registration.appendingPathComponent("gitdir"),
            atomically: true,
            encoding: .utf8
        )
        try "../..\n".write(
            to: registration.appendingPathComponent("commondir"),
            atomically: true,
            encoding: .utf8
        )
    }
}

@Suite("Claude foreign sessions remain scoped to safe current-workspace roots")
struct ClaudeForeignSessionScopeSecurityTests {
    @Test("Claude project names use ASCII-alphanumeric substitution and a 200-byte ceiling")
    func projectNamesMatchRustSanitization() {
        #expect(ClaudeSessionScanner.sanitizedProjectPath("/work/My Repo_é") == "-work-My-Repo--")
        #expect(ClaudeSessionScanner.sanitizedProjectPath(
            "/" + String(repeating: "a", count: 199)
        )?.utf8.count == ClaudeSessionScanner.maxSanitizedPathBytes)
        #expect(ClaudeSessionScanner.sanitizedProjectPath(
            "/" + String(repeating: "a", count: 200)
        ) == nil)
    }

    @Test(
        "non-Git and filesystem-root scans terminate without qualifying unrelated Claude projects",
        arguments: [false, true]
    )
    func unrelatedProjectTranscriptIsNeverRead(atFilesystemRoot: Bool) throws {
        let fixture = try ClaudeScopeFixture("foreign-project")
        defer { fixture.dispose() }
        let cwd = atFilesystemRoot ? "/" : fixture.workspace.path

        let expected = try fixture.project(for: cwd)
        try fixture.session(in: expected, cwd: cwd, title: "current workspace")
        let foreign = try fixture.project(for: "/someone/elses/project")
        try fixture.session(in: foreign, cwd: cwd, title: "foreign secret")

        let sessions = fixture.scan(cwd: cwd)
        #expect(sessions.map(\.title) == ["current workspace"])
    }

    @Test("a symlinked projects parent cannot redirect an approved Claude config")
    func symlinkedProjectsParentIsRejected() throws {
        let fixture = try ClaudeScopeFixture("projects-link")
        defer { fixture.dispose() }

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let externalProject = try fixture.project(for: fixture.workspace.path, config: outside)
        try fixture.session(in: externalProject, title: "outside secret")
        let projects = fixture.config.appendingPathComponent("projects")
        try FileManager.default.removeItem(at: projects)
        try FileManager.default.createSymbolicLink(
            at: projects,
            withDestinationURL: outside.appendingPathComponent("projects")
        )

        #expect(fixture.scan().isEmpty)
    }

    @Test("a symlinked workspace project cannot expose a different Claude directory")
    func symlinkedProjectCandidateIsRejected() throws {
        let fixture = try ClaudeScopeFixture("project-link")
        defer { fixture.dispose() }

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try fixture.session(in: outside, title: "outside secret")
        let projectName = try #require(ClaudeSessionScanner.sanitizedProjectPath(fixture.workspace.path))
        let candidate = fixture.config
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectName)
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: outside)

        #expect(fixture.scan().isEmpty)
    }

    @Test("a symlinked final JSONL transcript is never followed")
    func symlinkedTranscriptIsRejected() throws {
        let fixture = try ClaudeScopeFixture("transcript-link")
        defer { fixture.dispose() }

        let project = try fixture.project(for: fixture.workspace.path)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = try fixture.session(in: outside, title: "outside secret")
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent(secret.lastPathComponent),
            withDestinationURL: secret
        )

        #expect(fixture.scan().isEmpty)
    }

    @Test("configured root and its immediate parent must not be symbolic links")
    func symlinkedConfigRootAndParentAreRejected() throws {
        let fixture = try ClaudeScopeFixture("root-link")
        defer { fixture.dispose() }

        let project = try fixture.project(for: fixture.workspace.path)
        try fixture.session(in: project)

        let rootAlias = fixture.root.appendingPathComponent("config-alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: fixture.config)
        #expect(fixture.scan(config: rootAlias).isEmpty)

        let parentAlias = fixture.root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: fixture.root)
        #expect(fixture.scan(config: parentAlias.appendingPathComponent("config")).isEmpty)
    }

    @Test("0755 directories and 0644 transcripts remain readable, but group/other writes do not")
    func ownerReadableModesRemainCompatibleWithoutWritableByOthers() throws {
        let fixture = try ClaudeScopeFixture("permissions")
        defer { fixture.dispose() }

        let project = try fixture.project(for: fixture.workspace.path)
        let transcript = try fixture.session(in: project)
        try fixture.setMode(0o755, for: fixture.config)
        try fixture.setMode(0o755, for: fixture.config.appendingPathComponent("projects"))
        try fixture.setMode(0o755, for: project)
        try fixture.setMode(0o644, for: transcript)
        #expect(fixture.scan().count == 1)

        try fixture.setMode(0o775, for: fixture.config)
        #expect(fixture.scan().isEmpty)
        try fixture.setMode(0o755, for: fixture.config)

        let projects = fixture.config.appendingPathComponent("projects")
        try fixture.setMode(0o775, for: projects)
        #expect(fixture.scan().isEmpty)
        try fixture.setMode(0o755, for: projects)

        try fixture.setMode(0o777, for: project)
        #expect(fixture.scan().isEmpty)
        try fixture.setMode(0o755, for: project)

        try fixture.setMode(0o666, for: transcript)
        #expect(fixture.scan().isEmpty)
    }

    @Test("descriptor-backed transcript reads cannot be redirected by a replacement symlink")
    func openedTranscriptSurvivesPathSwapWithoutReadingOutside() throws {
        let fixture = try ClaudeScopeFixture("file-swap")
        defer { fixture.dispose() }

        let project = try fixture.project(for: fixture.workspace.path)
        let original = try fixture.session(in: project, title: "original private transcript")
        let root = try #require(ForeignSessionApprovedRoot(fixture.config))
        let approvedProject = try #require(root.subroot(project))
        let approvedFile = try #require(approvedProject.openRegularFile(original))

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = try fixture.session(in: outside, title: "outside redirected secret")
        let retained = project.appendingPathComponent("retained.jsonl")
        try FileManager.default.moveItem(at: original, to: retained)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: secret)

        let bytes = try #require(approvedFile.read(maximum: Int(approvedFile.size)))
        let contents = String(decoding: bytes, as: UTF8.self)
        #expect(contents.contains("original private transcript"))
        #expect(!contents.contains("outside redirected secret"))
        #expect(approvedProject.openRegularFile(original) == nil)
        #expect(fixture.scan().isEmpty)
    }

    @Test("replacing the projects parent after root approval still cannot escape its descriptor")
    func projectsParentSwapAfterApprovalIsRejected() throws {
        let fixture = try ClaudeScopeFixture("parent-swap")
        defer { fixture.dispose() }

        let original = try fixture.project(for: fixture.workspace.path)
        try fixture.session(in: original, title: "original transcript")
        let approved = try #require(ForeignSessionApprovedRoot(fixture.config))

        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        let redirected = try fixture.project(for: fixture.workspace.path, config: outside)
        try fixture.session(in: redirected, title: "outside redirected secret")

        let projects = fixture.config.appendingPathComponent("projects")
        let retained = fixture.config.appendingPathComponent("retained-projects")
        try FileManager.default.moveItem(at: projects, to: retained)
        try FileManager.default.createSymbolicLink(
            at: projects,
            withDestinationURL: outside.appendingPathComponent("projects")
        )

        #expect(approved.subroot(original) == nil)
        #expect(fixture.scan().isEmpty)
    }

    @Test(
        "linked Git worktrees include the main checkout without scanning unrelated projects",
        arguments: [false, true]
    )
    func linkedWorktreeRecognizesItsMainRepositoryProject(fromNestedDirectory: Bool) throws {
        let fixture = try ClaudeScopeFixture("linked-main")
        defer { fixture.dispose() }

        let linked = fixture.root.appendingPathComponent("linked", isDirectory: true)
        try fixture.configureLinkedWorktree(linked)
        let cwd = fromNestedDirectory
            ? linked.appendingPathComponent("nested", isDirectory: true)
            : linked
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let mainProject = try fixture.project(for: fixture.workspace.path)
        try fixture.session(
            in: mainProject,
            cwd: cwd.path,
            title: "linked worktree in primary project"
        )
        let unrelated = try fixture.project(for: "/unrelated/repository")
        try fixture.session(in: unrelated, cwd: cwd.path, title: "unrelated secret")

        let sessions = fixture.scan(cwd: cwd.path)
        #expect(sessions.map(\.title) == ["linked worktree in primary project"])
    }

    @Test("the main Git checkout can discover its registered linked worktree project")
    func mainCheckoutRecognizesRegisteredLinkedProject() throws {
        let fixture = try ClaudeScopeFixture("main-linked")
        defer { fixture.dispose() }

        let linked = fixture.root.appendingPathComponent("linked", isDirectory: true)
        try fixture.configureLinkedWorktree(linked)
        let linkedProject = try fixture.project(for: linked.path)
        try fixture.session(
            in: linkedProject,
            cwd: fixture.workspace.path,
            title: "main checkout in linked project"
        )

        let sessions = fixture.scan()
        #expect(sessions.map(\.title) == ["main checkout in linked project"])
    }

    @Test("Git worktree discovery never authorizes more than sixteen project directories")
    func gitWorktreeProjectCandidatesAreBounded() throws {
        let fixture = try ClaudeScopeFixture("worktree-cap")
        defer { fixture.dispose() }

        for index in 0..<(ClaudeSessionScanner.maxProjectDirs + 4) {
            let name = String(format: "linked-%02d", index)
            let linked = fixture.root.appendingPathComponent(name, isDirectory: true)
            try fixture.configureLinkedWorktree(linked, name: name)
        }

        let candidates = ClaudeSessionScanner.scopedProjectDirs(
            configDir: fixture.config,
            cwd: fixture.workspace.path
        )
        #expect(candidates.count == ClaudeSessionScanner.maxProjectDirs)
        #expect(Set(candidates.map(\.path)).count == candidates.count)
    }

    @Test("stored cwd aliases compare by canonical workspace identity")
    func canonicalWorkspaceComparisonAcceptsSameDirectoryAlias() throws {
        let fixture = try ClaudeScopeFixture("canonical-cwd")
        defer { fixture.dispose() }

        let alias = fixture.root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.workspace)
        let project = try fixture.project(for: fixture.workspace.path)
        try fixture.session(in: project, cwd: alias.path, title: "same canonical workspace")

        #expect(fixture.scan().map(\.title) == ["same canonical workspace"])
    }

    @Test("oversized JSON records cannot exhaust transcript parsing")
    func oversizedJSONLineIsRejected() throws {
        let fixture = try ClaudeScopeFixture("oversized-json")
        defer { fixture.dispose() }

        let project = try fixture.project(for: fixture.workspace.path)
        let oversized = String(repeating: "x", count: ClaudeSessionScanner.maxJSONLineBytes + 1)
        let metadata = try JSONSerialization.data(withJSONObject: [
            "cwd": fixture.workspace.path,
            "padding": oversized,
        ])
        let prompt = try JSONSerialization.data(withJSONObject: [
            "type": "user",
            "message": ["content": "oversized record"],
        ])
        var transcript = metadata
        transcript.append(0x0A)
        transcript.append(prompt)
        try transcript.write(to: project.appendingPathComponent("\(UUID().uuidString).jsonl"))

        #expect(fixture.scan().isEmpty)
    }
}
#endif
