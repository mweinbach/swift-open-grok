import Foundation
import OpenGrokSessionPersistence
import OpenGrokWorkspace
import Testing
@testable import OpenGrokCLI

private final class WorkflowSourceLaunchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var factoryCalls = 0
    private var samplingCalls = 0

    func madeSampler() {
        lock.withLock { factoryCalls += 1 }
    }

    func sampled() {
        lock.withLock { samplingCalls += 1 }
    }

    var factories: Int {
        lock.withLock { factoryCalls }
    }

    var requests: Int {
        lock.withLock { samplingCalls }
    }
}

private struct WorkflowSourceAuthorityFixture {
    let root: URL
    let home: URL
    let workspace: URL
    let environment: [String: String]

    var projectWorkflowDirectory: URL {
        workspace.appendingPathComponent(".opengrok/workflows", isDirectory: true)
    }

    var ownerWorkflowDirectory: URL {
        home.appendingPathComponent("workflows", isDirectory: true)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-workflow-authority-\(UUID().uuidString)")
        home = root.appendingPathComponent("owner-home")
        workspace = root.appendingPathComponent("workspace")
        for directory in [home, workspace] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
            "GROK_SANDBOX": "off",
            "XDG_STATE_HOME": home.appendingPathComponent("xdg-state").path,
            "XAI_API_KEY": "workflow-authority-test-credential",
            "GROK_FOLDER_TRUST": "1",
            "GROK_WORKFLOWS": "1",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]
    }

    func dispose() {
        try? FileManager.default.removeItem(at: root)
    }

    func script(named name: String) -> String {
        """
        let meta = #{ name: "\(name)", description: "trusted source", when_to_use: "tests" };
        complete(#{ accepted: true });
        """
    }

    @discardableResult
    func writeScript(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(name).rhai")
        try script(named: name).write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    func trustWorkspace() throws {
        var store = PersistentFolderTrustStore(environment: environment)
        try store.record(workspace, trusted: true)
        #expect(PersistentFolderTrustStore(environment: environment).isTrusted(workspace))
    }

    func run(
        workflow path: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        probe: WorkflowSourceLaunchProbe = WorkflowSourceLaunchProbe()
    ) async -> (code: Int32, output: String, error: String, probe: WorkflowSourceLaunchProbe) {
        let dependencies = OpenGrokLiveCompositionDependencies(
            makeSampler: { _ in
                probe.madeSampler()
                return OpenGrokLiveSampler { _, emit in
                    probe.sampled()
                    await emit(.output("workflow authority response"))
                    return OpenGrokLiveSamplingResponse(output: "workflow authority response")
                }
            }
        )
        let (streams, output, error) = CLIStreams.buffered()
        let code = await CLIRunner.run(
            [
                "headless", "--prompt", "verify workflow authority",
                "--cwd", (workingDirectory ?? workspace).path,
                "--model", "grok-4.5",
                "--workflow", path,
            ] + arguments,
            environment: environment,
            streams: streams,
            application: OpenGrokApplication.live(dependencies: dependencies, control: .never)
        )
        return (code, output.contents, error.contents, probe)
    }

    func read(
        _ path: String,
        sessionID: String = "workflow-authority-session",
        projectTrusted: Bool = false,
        workingDirectory: URL? = nil
    ) throws -> String {
        try LiveWorkflowComposition.readScript(
            at: path,
            workingDirectory: workingDirectory ?? workspace,
            openGrokHome: home,
            sessionID: sessionID,
            projectTrusted: projectTrusted
        )
    }
}

@Suite("live workflow source authority and pre-provider security")
struct LiveWorkflowSourceAuthoritySecurityTests {
    @Test("a workflows-only untrusted clone is rejected before any sampler exists")
    func workflowsOnlyProjectCannotLaunchBeforeProviderConstruction() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let hostile = try fixture.writeScript(named: "hostile", in: fixture.projectWorkflowDirectory)
        let security = LiveSecurityContext.resolve(
            workspaceRoot: fixture.workspace,
            environment: fixture.environment,
            isInteractive: false
        )
        #expect(security.projectTrusted == false)

        let result = await fixture.run(workflow: hostile.path)

        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("project workflows require folder trust"))
        #expect(result.probe.factories == 0)
        #expect(result.probe.requests == 0)
        #expect(FileManager.default.fileExists(
            atPath: fixture.home.appendingPathComponent("workflow-runs.json").path
        ) == false)
    }

    @Test("a user-owned workflow runs while the repository remains untrusted")
    func ownerWorkflowRunsInUntrustedCheckout() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        try fixture.writeScript(named: "hostile", in: fixture.projectWorkflowDirectory)
        let owner = try fixture.writeScript(named: "owner-safe", in: fixture.ownerWorkflowDirectory)

        let result = await fixture.run(workflow: owner.path)

        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("owner-safe"))
        #expect(result.probe.factories == 1)
    }

    @Test("persisted explicit folder trust allows a genuine project workflow")
    func durableTrustAllowsProjectWorkflowLaunch() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let trusted = try fixture.writeScript(named: "trusted-project", in: fixture.projectWorkflowDirectory)
        try fixture.trustWorkspace()

        let result = await fixture.run(workflow: trusted.path)

        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("trusted-project"))
        #expect(result.probe.factories == 1)
    }

    @Test("--trust authorizes the project and relative paths resolve from --cwd")
    func explicitTrustResolvesRelativePathFromSessionWorkingDirectory() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        try fixture.writeScript(named: "relative-safe", in: fixture.projectWorkflowDirectory)

        let result = await fixture.run(
            workflow: ".opengrok/workflows/relative-safe.rhai",
            arguments: ["--trust"]
        )

        #expect(result.code == CLIRunner.ExitCode.success.rawValue)
        #expect(result.output.contains("relative-safe"))
        #expect(result.probe.factories == 1)
    }

    @Test("a workflow outside every authorized root is denied before provider creation")
    func externalWorkflowCannotStartTheSampler() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let external = try fixture.writeScript(named: "external", in: fixture.root)

        let result = await fixture.run(workflow: external.path, arguments: ["--trust"])

        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("outside the project"))
        #expect(result.probe.factories == 0)
    }

    @Test("parent traversal is rejected before resolving or starting a provider")
    func parentTraversalCannotEscapeTheSessionWorkingDirectory() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        try fixture.writeScript(named: "external", in: fixture.root)

        let result = await fixture.run(workflow: "../external.rhai", arguments: ["--trust"])

        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("parent traversal"))
        #expect(result.probe.factories == 0)
    }

    @Test("directories are rejected without starting a provider")
    func nonRegularWorkflowNeverStartsTheSampler() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let fake = fixture.workspace.appendingPathComponent("directory.rhai", isDirectory: true)
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)

        let result = await fixture.run(workflow: fake.path, arguments: ["--trust"])

        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("regular file"))
        #expect(result.probe.factories == 0)
    }

    @Test("workflow sources larger than the exact upstream one-megabyte limit are rejected")
    func oversizedWorkflowCannotBeReadOrSampled() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let path = fixture.workspace.appendingPathComponent("oversized.rhai")
        try Data(repeating: 0x61, count: LiveWorkflowSourceAuthority.maximumSourceBytes + 1)
            .write(to: path)

        let result = await fixture.run(workflow: path.path, arguments: ["--trust"])

        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("1048576 bytes"))
        #expect(result.probe.factories == 0)
    }

    @Test("invalid UTF-8 fails closed before provider construction")
    func invalidEncodingCannotReachTheSampler() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let path = fixture.workspace.appendingPathComponent("invalid.rhai")
        try Data([0xFF, 0xFE, 0x80]).write(to: path)

        let result = await fixture.run(workflow: path.path, arguments: ["--trust"])

        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("valid UTF-8"))
        #expect(result.probe.factories == 0)
    }

    @Test("an exact-limit source is readable without unbounded allocation")
    func exactMaximumSourceIsAccepted() throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let path = fixture.workspace.appendingPathComponent("maximum.rhai")
        try Data(repeating: 0x61, count: LiveWorkflowSourceAuthority.maximumSourceBytes)
            .write(to: path)

        let source = try fixture.read(path.path, projectTrusted: true)

        #expect(source.utf8.count == LiveWorkflowSourceAuthority.maximumSourceBytes)
    }

    @Test("only the current canonical session's workflow run directory is authorized")
    func canonicalSessionWorkflowRunsAreScopedToTheExactSession() throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let sessionID = "authorized-session"
        let sessionDirectory = try SessionDocumentStore(grokHome: fixture.home)
            .sessionDirectory(sessionID: sessionID, cwd: fixture.workspace.path)
        let run = try fixture.writeScript(
            named: "session-run",
            in: sessionDirectory.appendingPathComponent("workflows", isDirectory: true)
        )

        #expect(try fixture.read(run.path, sessionID: sessionID).contains("session-run"))
        #expect(throws: CLIApplicationError.self) {
            try fixture.read(run.path, sessionID: "different-session")
        }
    }

    @Test("legacy session workflow runs remain confined to the exact session identifier")
    func legacySessionWorkflowRunsRemainSessionScoped() throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let sessionID = "legacy-session"
        let directory = fixture.home
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
        let run = try fixture.writeScript(named: "legacy-run", in: directory)

        #expect(try fixture.read(run.path, sessionID: sessionID).contains("legacy-run"))
        #expect(throws: CLIApplicationError.self) {
            try fixture.read(run.path, sessionID: "different-session")
        }
    }

    @Test("invalid session identifiers cannot widen workflow authority")
    func invalidSessionIdentifierFailsClosed() throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let safe = try fixture.writeScript(named: "safe", in: fixture.ownerWorkflowDirectory)

        #expect(throws: CLIApplicationError.self) {
            try fixture.read(safe.path, sessionID: "../different-session")
        }
    }

    @Test("a sibling with the same lexical prefix is never considered inside the project")
    func sharedPathPrefixCannotBypassProjectContainment() throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let sibling = fixture.root.appendingPathComponent("workspace-other", isDirectory: true)
        let outside = try fixture.writeScript(named: "outside", in: sibling)

        #expect(throws: CLIApplicationError.self) {
            try fixture.read(outside.path, projectTrusted: true)
        }
    }

    @Test("a nested --cwd inherits the canonical repository root boundary")
    func nestedSessionUsesTheCanonicalRepositoryRoot() throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let nested = fixture.workspace.appendingPathComponent("nested/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let project = try fixture.writeScript(named: "root-workflow", in: fixture.projectWorkflowDirectory)

        #expect(
            try fixture.read(project.path, projectTrusted: true, workingDirectory: nested)
                .contains("root-workflow")
        )
        #expect(throws: CLIApplicationError.self) {
            try fixture.read(project.path, projectTrusted: false, workingDirectory: nested)
        }
    }

    @Test("workflow validate uses the same untrusted-source gate as launch")
    func validationRouteCannotReadUntrustedProjectWorkflows() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let hostile = try fixture.writeScript(named: "validate-hostile", in: fixture.projectWorkflowDirectory)
        let (streams, _, error) = CLIStreams.buffered()

        let code = await CLIRunner.run(
            ["--cwd", fixture.workspace.path, "workflow", "validate", hostile.path],
            environment: fixture.environment,
            streams: streams,
            application: OpenGrokApplication.live(control: .never)
        )

        #expect(code == CLIRunner.ExitCode.failure.rawValue)
        #expect(error.contents.contains("project workflows require folder trust"))
    }

    #if !os(Windows)
    @Test("a final workflow symlink is rejected before provider construction")
    func finalSymlinkNeverStartsTheSampler() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let actual = try fixture.writeScript(named: "actual", in: fixture.workspace)
        let link = fixture.workspace.appendingPathComponent("alias.rhai")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)

        let result = await fixture.run(workflow: link.path, arguments: ["--trust"])

        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("symbolic links"))
        #expect(result.probe.factories == 0)
    }

    @Test("an intermediate symlink is rejected even when its target stays in the project")
    func intermediateInProjectSymlinkStillFailsClosed() async throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let real = fixture.workspace.appendingPathComponent("real-directory", isDirectory: true)
        try fixture.writeScript(named: "inside", in: real)
        let alias = fixture.workspace.appendingPathComponent("alias-directory", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let result = await fixture.run(
            workflow: alias.appendingPathComponent("inside.rhai").path,
            arguments: ["--trust"]
        )

        #expect(result.code == CLIRunner.ExitCode.failure.rawValue)
        #expect(result.error.contains("symbolic links"))
        #expect(result.probe.factories == 0)
    }

    @Test("an owner workflow symlink cannot smuggle an external source past trust")
    func ownerWorkflowSymlinkCannotEscapeOwnerRoot() throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let outside = try fixture.writeScript(named: "outside", in: fixture.root)
        try FileManager.default.createDirectory(
            at: fixture.ownerWorkflowDirectory,
            withIntermediateDirectories: true
        )
        let alias = fixture.ownerWorkflowDirectory.appendingPathComponent("outside.rhai")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

        #expect(throws: CLIApplicationError.self) {
            try fixture.read(alias.path)
        }
    }

    @Test("a symlinked owner workflow directory is never an authority root")
    func ownerWorkflowDirectorySymlinkIsRejected() throws {
        let fixture = try WorkflowSourceAuthorityFixture()
        defer { fixture.dispose() }
        let outside = fixture.root.appendingPathComponent("external-owner", isDirectory: true)
        try fixture.writeScript(named: "outside", in: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.ownerWorkflowDirectory,
            withDestinationURL: outside
        )

        #expect(throws: CLIApplicationError.self) {
            try fixture.read(fixture.ownerWorkflowDirectory.appendingPathComponent("outside.rhai").path)
        }
    }
    #endif
}
