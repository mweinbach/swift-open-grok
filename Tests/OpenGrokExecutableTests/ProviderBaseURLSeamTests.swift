import Foundation
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokCLI

/// Upstream citations pinned by this suite:
///
///   * `crates/codegen/xai-grok-shell/src/agent/config.rs:233` — the
///     `[endpoints]` table's `xai_api_base_url` field.
///   * `crates/codegen/xai-grok-shell/src/agent/config.rs:622` —
///     `impl Default for EndpointsConfig` reads `GROK_XAI_API_BASE_URL`,
///     else `XAI_API_BASE_URL_DEFAULT`.
///   * `crates/codegen/xai-grok-shell/src/agent/config.rs:365` —
///     `from_config_value` serializes that default and then deep-merges the
///     effective config's `[endpoints]` table over it.
///
/// The merge order is the whole precedence story: config file > environment >
/// compiled default. Upstream's own `e2e_enterprise_endpoints_only_no_model_override`
/// (`agent/config.rs:10203`) pins the config-file leg.
@Suite("Provider base URL seam")
struct ProviderBaseURLSeamTests {
    private func workspace() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaseURLSeam-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeConfig(_ body: String, at directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(
            to: directory.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test("the compiled default applies when neither config nor env names an endpoint")
    func defaultWhenUnset() {
        let resolved = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .xai,
            model: nil,
            environment: [:]
        )
        #expect(resolved == XAI_API_BASE_URL_DEFAULT)
    }

    @Test("GROK_XAI_API_BASE_URL beats the compiled default")
    func environmentBeatsDefault() {
        let resolved = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .xai,
            model: nil,
            environment: ["GROK_XAI_API_BASE_URL": "https://env.example/v1"]
        )
        #expect(resolved == "https://env.example/v1")
    }

    /// The deep merge in `from_config_value` runs *over* the env-derived
    /// default, so a config file wins even when the env var is also set.
    @Test("[endpoints] xai_api_base_url beats GROK_XAI_API_BASE_URL")
    func configBeatsEnvironment() {
        let resolved = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .xai,
            model: nil,
            environment: ["GROK_XAI_API_BASE_URL": "https://env.example/v1"],
            configuredXaiBaseURL: "https://config.example/v1"
        )
        #expect(resolved == "https://config.example/v1")
    }

    @Test("the project config chain supplies [endpoints] xai_api_base_url")
    func projectConfigLayerIsRead() {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        writeConfig(
            "[endpoints]\nxai_api_base_url = \"https://project.example/v1\"\n",
            at: project.appendingPathComponent(".opengrok", isDirectory: true)
        )

        let resolved = OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
            workingDirectory: project,
            openGrokHome: root.appendingPathComponent("home", isDirectory: true),
            environment: ["HOME": root.path]
        )
        #expect(resolved == "https://project.example/v1")
    }

    @Test("$OPENGROK_HOME/config.toml supplies [endpoints] xai_api_base_url")
    func userConfigLayerIsRead() {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        writeConfig("[endpoints]\nxai_api_base_url = \"https://user.example/v1\"\n", at: home)

        let resolved = OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
            workingDirectory: root.appendingPathComponent("project", isDirectory: true),
            openGrokHome: home,
            environment: ["HOME": root.path]
        )
        #expect(resolved == "https://user.example/v1")
    }

    /// A blank value is "unset", matching upstream's `blank_as_unset` treatment
    /// of endpoint strings (`agent/config.rs:384`), so it must not shadow the
    /// environment override underneath it.
    @Test("a blank config value falls through to the environment")
    func blankConfigValueFallsThrough() {
        let root = workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        writeConfig("[endpoints]\nxai_api_base_url = \"   \"\n", at: home)

        #expect(
            OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
                workingDirectory: root.appendingPathComponent("project", isDirectory: true),
                openGrokHome: home,
                environment: ["HOME": root.path]
            ) == nil
        )
    }

    /// `[endpoints] xai_api_base_url` is an xAI-only knob upstream; the other
    /// providers keep their own env overrides and must not inherit it.
    @Test("non-xAI providers keep their own environment override")
    func otherProvidersUnaffected() {
        let resolved = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .codex,
            model: nil,
            environment: ["GROK_CODEX_INFERENCE_BASE_URL": "https://codex.example/v1"],
            configuredXaiBaseURL: "https://config.example/v1"
        )
        #expect(resolved == "https://codex.example/v1")
    }
}

/// PORT_STATUS wave 5 flagged `[features] code_mode` as a config surface with
/// no upstream counterpart. Upstream defines the setting only under `[ui]`
/// (`crates/codegen/xai-grok-pager/src/settings/defs.rs:129` `CODE_MODE_CHOICES`,
/// documented at `docs/user-guide/05-configuration.md:100`); a repo-wide grep
/// for `features` + `code_mode` over the Rust tree returns nothing.
@Suite("Code mode config surface")
struct CodeModeConfigSurfaceTests {
    private func resolve(_ config: String) -> ToolModePreference {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeModeSurface-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? config.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        return LiveCodeModeSettings.resolveToolMode(
            environment: ["HOME": root.path],
            workingDirectory: root.appendingPathComponent("project", isDirectory: true),
            openGrokHome: home
        )
    }

    @Test("[ui] code_mode still selects the mode")
    func uiSectionIsHonored() {
        #expect(resolve("[ui]\ncode_mode = \"code_mode_only\"\n") == .codeModeOnly)
    }

    @Test("[ui] code_mode still accepts the legacy boolean")
    func uiSectionAcceptsLegacyBoolean() {
        #expect(resolve("[ui]\ncode_mode = true\n") == .codeMode)
        #expect(resolve("[ui]\ncode_mode = false\n") == .direct)
    }

    @Test("[features] code_mode is not a config surface")
    func featuresSectionIsDead() {
        #expect(resolve("[features]\ncode_mode = \"code_mode_only\"\n") == .direct)
        #expect(resolve("[features]\ncode_mode = true\n") == .direct)
    }
}
