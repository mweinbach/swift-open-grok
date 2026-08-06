import Foundation
import OpenGrokConfig
import Testing

@testable import OpenGrokCLI

@Suite("live sandbox composition")
struct LiveSandboxCompositionTests {
    @Test("the parsed CLI sandbox profile reaches live bootstrap")
    func cliProfileReachesBootstrap() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenGrokLiveSandbox-\(UUID().uuidString)", isDirectory: true)
        let home = workspace.appendingPathComponent("home", isDirectory: true)
        let openGrokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        try FileManager.default.createDirectory(at: openGrokHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let environment = [
            "HOME": home.path,
            "OPENGROK_HOME": openGrokHome.path,
            "GROK_SANDBOX": "strict",
        ]
        let cli = CLIPermissionOptions(sandboxProfile: "off")
        let security = LiveSecurityContext.resolve(
            workspaceRoot: workspace,
            environment: environment,
            isInteractive: false,
            cli: cli
        )

        let decision = try security.applySandbox(
            workspaceRoot: workspace,
            cliProfile: cli.sandboxProfile,
            persistedProfile: nil,
            environment: environment
        )

        #expect(decision.profileName == "off")
        #expect(!decision.enforced)
    }
}
