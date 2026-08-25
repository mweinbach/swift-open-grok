import Foundation
import OpenGrokAuth
import OpenGrokPagerRender

enum LiveDashboardStartupComposition {
    static let startupEnvironmentVariable = "GROK_OPEN_DASHBOARD_AT_STARTUP"

    static let disabledMessage = "the Agent Dashboard is disabled. Enable it by removing "
        + "`[dashboard] enabled = false` from ~/.opengrok/config.toml and "
        + "unsetting GROK_AGENT_DASHBOARD=0"

    /// Consume the soft subcommand before normal interactive startup, matching
    /// `xai-grok-pager-bin/src/main.rs:1413-1440` at reference `00e176c8`.
    static func normalize(
        command: CLICommand,
        environment: [String: String]
    ) throws -> (command: CLICommand, environment: [String: String]) {
        guard case .utility(let options) = command, options.name == "dashboard" else {
            return (command, environment)
        }

        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let dashboardStore = PagerDashboardStore(
            configPath: home.appendingPathComponent("config.toml")
        )
        guard environment["GROK_AGENT_DASHBOARD"] != "0",
              dashboardStore.loadEnabled() != false else {
            throw CLIApplicationError.failed(disabledMessage)
        }

        var launchEnvironment = environment
        launchEnvironment[startupEnvironmentVariable] = "1"
        return (
            .launch(CLIExecutionOptions(mode: .interactive, common: options.common)),
            launchEnvironment
        )
    }
}
