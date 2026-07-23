// EndpointsConfig.swift
//
// Minimal endpoint configuration needed by the model catalog. Full endpoint
// resolution for telemetry/feedback lives with the shell; this type only
// covers inference + models-list URL selection for catalog construction.

import Foundation

/// Default base URL for the cli-chat-proxy.
public let CLI_CHAT_PROXY_BASE_URL_DEFAULT = "https://cli-chat-proxy.grok.com/v1"
/// Default base URL for the public xAI API.
public let XAI_API_BASE_URL_DEFAULT = "https://api.x.ai/v1"

/// Endpoint knobs that affect model catalog resolution and cache origin.
public struct EndpointsConfig: Sendable, Equatable {
    public var cliChatProxyBaseURL: String?
    public var xaiApiBaseURL: String
    public var modelsBaseURL: String?
    public var modelsListURL: String?
    public var deploymentKey: String?

    public init(
        cliChatProxyBaseURL: String? = nil,
        xaiApiBaseURL: String = XAI_API_BASE_URL_DEFAULT,
        modelsBaseURL: String? = nil,
        modelsListURL: String? = nil,
        deploymentKey: String? = nil
    ) {
        self.cliChatProxyBaseURL = cliChatProxyBaseURL
        self.xaiApiBaseURL = xaiApiBaseURL
        self.modelsBaseURL = modelsBaseURL
        self.modelsListURL = modelsListURL
        self.deploymentKey = deploymentKey
    }

    public static let `default` = EndpointsConfig()

    public func hasCustomEndpoint() -> Bool {
        modelsBaseURL != nil || modelsListURL != nil
    }

    public func proxyURL() -> String {
        blankAsUnset(cliChatProxyBaseURL) ?? CLI_CHAT_PROXY_BASE_URL_DEFAULT
    }

    public func resolveInferenceBaseURL() -> String {
        modelsBaseURL ?? proxyURL()
    }

    /// Models list URL: explicit list URL, else `{base}/models`, else proxy `/models`.
    public func resolveModelsListURL() -> String {
        if let list = blankAsUnset(modelsListURL) {
            return list
        }
        if let base = blankAsUnset(modelsBaseURL) {
            return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models"
        }
        return proxyURL().trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models"
    }
}

/// True when `url` is a trusted first-party xAI endpoint that can safely receive
/// an xAI session bearer token or XAI_API_KEY. Requires HTTPS and non-loopback host.
public func isXaiApiBearerURL(_ url: String) -> Bool {
    guard let parsed = URL(string: url),
          let scheme = parsed.scheme?.lowercased(),
          scheme == "https",
          let host = parsed.host?.lowercased() else {
        return false
    }
    // Reject loopback hosts
    if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.") {
        return false
    }
    if host == "cli-chat-proxy.grok.com" || host == "x.ai" || host.hasSuffix(".x.ai") {
        return true
    }
    return false
}

private func blankAsUnset(_ opt: String?) -> String? {
    guard let s = opt?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
        return nil
    }
    return s
}

