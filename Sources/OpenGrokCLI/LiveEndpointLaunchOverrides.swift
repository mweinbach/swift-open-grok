import Foundation
import OpenGrokConfig

/// Apply trusted, launch-scoped xAI endpoints without changing process-global
/// state or allowing a caller to forge command-line precedence in its env.
enum LiveEndpointLaunchOverrides {
    static let xaiCommandLineMarker = "OPENGROK_INTERNAL_CLI_XAI_API_BASE_URL"

    private struct Override {
        let value: String
        let environmentKey: String
        let configKey: String
        let flag: String
    }

    static func applying(
        options: CLIExecutionOptions,
        to context: CLIApplicationContext
    ) throws -> CLIApplicationContext {
        var environment = context.environment
        let forgedMarker = environment.removeValue(forKey: xaiCommandLineMarker) != nil

        var overrides: [Override] = []
        if let value = options.advanced.xaiAPIBaseURL {
            overrides.append(Override(
                value: value,
                environmentKey: "GROK_XAI_API_BASE_URL",
                configKey: "xai_api_base_url",
                flag: "--xai-api-base-url"
            ))
        }
        if let value = options.advanced.cliChatProxyBaseURL {
            overrides.append(Override(
                value: value,
                environmentKey: "GROK_CLI_CHAT_PROXY_BASE_URL",
                configKey: "cli_chat_proxy_base_url",
                flag: "--cli-chat-proxy-base-url"
            ))
        }

        guard !overrides.isEmpty else {
            guard forgedMarker else { return context }
            return CLIApplicationContext(
                environment: environment,
                streams: context.streams,
                control: context.control
            )
        }

        let trustedLayers = try managedEndpointLayers(environment: environment)
        for override in overrides {
            let endpoint = try normalizedEndpoint(override.value, flag: override.flag)
            if let pinned = try managedEndpoint(
                named: override.configKey,
                layers: trustedLayers
            ), pinned != endpoint {
                throw CLIApplicationError.failed(
                    "\(override.flag) conflicts with an administrator-managed endpoint"
                )
            }
            environment[override.environmentKey] = endpoint
            if override.configKey == "xai_api_base_url" {
                environment[xaiCommandLineMarker] = endpoint
            }
        }

        return CLIApplicationContext(
            environment: environment,
            streams: context.streams,
            control: context.control
        )
    }

    private static func managedEndpointLayers(
        environment: [String: String]
    ) throws -> [TOMLValue] {
        let systemManaged = try loadSystemManagedConfig(environment: environment)
        let managed = try loadManagedConfig(environment: environment)

        // `requirementsLayers` intentionally soft-fails malformed files. An
        // endpoint override must not turn that omission into a policy bypass.
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        _ = try loadTomlFile(
            at: home.appendingPathComponent(REQUIREMENTS_FILENAME),
            environment: environment
        )
        if let directory = systemConfigDir() {
            _ = try loadTomlFile(
                at: directory.appendingPathComponent(REQUIREMENTS_FILENAME),
                environment: environment
            )
        }

        return [systemManaged, managed]
            + requirementsLayers(environment: environment).map(\.value)
    }

    private static func managedEndpoint(
        named key: String,
        layers: [TOMLValue]
    ) throws -> String? {
        var effective: String?
        for layer in layers {
            guard let value = layer[path: ["endpoints", key]] else { continue }
            guard let raw = value.stringValue else {
                throw CLIApplicationError.failed(
                    "administrator-managed endpoint \(key) is invalid"
                )
            }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            effective = try normalizedEndpoint(
                raw,
                flag: "administrator-managed endpoint \(key)"
            )
        }
        return effective
    }

    private static func normalizedEndpoint(_ raw: String, flag: String) throws -> String {
        let invalid = CLIApplicationError.failed(
            "\(flag) must be an absolute HTTPS endpoint or an explicit HTTP loopback endpoint"
        )
        guard !raw.isEmpty,
              !raw.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || $0.properties.isWhitespace
              }),
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let originalHost = components.host,
              !originalHost.isEmpty,
              components.user == nil,
              components.password == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil
        else {
            throw invalid
        }

        let host = originalHost.lowercased()
        let loopback = host == "localhost" || host == "127.0.0.1"
            || host == "::1" || host == "[::1]"
        guard scheme == "https" || (scheme == "http" && loopback),
              !components.path.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control
              }),
              !components.path.split(separator: "/").contains(where: {
                  $0 == "." || $0 == ".."
              })
        else {
            throw invalid
        }

        components.scheme = scheme
        components.host = host
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        guard let normalized = components.url?.absoluteString else {
            throw invalid
        }
        return normalized
    }
}
