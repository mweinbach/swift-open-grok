// LiveModelSwitchEndpointTests.swift
//
// The `/model` switch path must resolve endpoints through the same ladder the
// cold start does. Upstream ranks the config file above the environment for
// `[endpoints] xai_api_base_url` (`from_config_value` deep-merges the
// `[endpoints]` table over the env-derived default, `agent/config.rs:365`), so
// a mid-session switch that consulted only the environment would send the same
// model to a different endpoint depending on whether the session started on it
// or switched to it.
//
// `ProviderBaseURLSeamTests` pins the resolution function itself; this suite
// pins that the model-switch path actually feeds it the config leg.

import Foundation
import OpenGrokModels
import OpenGrokSamplingTypes
import Testing
@testable import OpenGrokCLI

private func endpointWorkspace() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ModelSwitchEndpoint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeEndpointsConfig(_ baseURL: String, at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "[endpoints]\nxai_api_base_url = \"\(baseURL)\"\n".write(
        to: directory.appendingPathComponent("config.toml"),
        atomically: true,
        encoding: .utf8
    )
}

@Suite("Model switch endpoint resolution")
struct LiveModelSwitchEndpointTests {
    /// The load-bearing case: config and environment disagree, and the switch
    /// must land on the config value exactly as a cold start would.
    @Test("a /model switch honors [endpoints] xai_api_base_url over the env var")
    func switchHonorsConfigLeg() async throws {
        let root = try endpointWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeEndpointsConfig("https://config.example/v1", at: home)

        let environment = [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XAI_API_KEY": "xai-key",
            "GROK_XAI_API_BASE_URL": "https://env.example/v1",
        ]
        let resolver = LiveModelCatalogResolver(
            environment: environment,
            openGrokHome: home,
            sessionID: "session-endpoint",
            workingDirectory: project
        )

        let resolved = try await resolver.resolve(modelID: "grok-4.5")
        #expect(resolved.sampling.provider == .xai)
        #expect(resolved.sampling.baseURL == "https://config.example/v1")

        // Same inputs through the cold-start path: the two must agree.
        let coldStart = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
            provider: .xai,
            model: nil,
            environment: environment,
            configuredXaiBaseURL: OpenGrokLiveApplicationLauncher.configuredXaiAPIBaseURL(
                workingDirectory: project,
                openGrokHome: home,
                environment: environment
            )
        )
        #expect(resolved.sampling.baseURL == coldStart)
    }

    /// Without a config file the environment leg still applies, so adding the
    /// config lookup did not shadow the override underneath it.
    @Test("the env var still applies when no config names an endpoint")
    func switchFallsBackToEnvironment() async throws {
        let root = try endpointWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let resolver = LiveModelCatalogResolver(
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": home.path,
                "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                "XAI_API_KEY": "xai-key",
                "GROK_XAI_API_BASE_URL": "https://env.example/v1",
            ],
            openGrokHome: home,
            sessionID: "session-endpoint-env",
            workingDirectory: project
        )

        let resolved = try await resolver.resolve(modelID: "grok-4.5")
        #expect(resolved.sampling.baseURL == "https://env.example/v1")
    }

    /// The key is xAI-only upstream. A non-xAI provider keeps its own
    /// `*_API_BASE_URL` env var and must not inherit the xAI config value.
    @Test("a non-xAI provider does not inherit the xAI endpoint config")
    func nonXaiProviderIgnoresXaiConfig() async throws {
        let root = try endpointWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeEndpointsConfig("https://config.example/v1", at: home)

        let resolver = LiveModelCatalogResolver(
            environment: [
                "HOME": root.path,
                "OPENGROK_HOME": home.path,
                "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                "FIREWORKS_API_KEY": "fw-key",
            ],
            openGrokHome: home,
            sessionID: "session-endpoint-fireworks",
            workingDirectory: project
        )

        let resolved = try await resolver.resolve(modelID: "glm-5.2")
        #expect(resolved.sampling.provider == .fireworks)
        #expect(resolved.sampling.baseURL != "https://config.example/v1")
        #expect(resolved.sampling.baseURL == FireworksModels.apiBaseURLDefault)
    }
}
