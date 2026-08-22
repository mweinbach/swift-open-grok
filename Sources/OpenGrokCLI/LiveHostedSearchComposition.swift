import Foundation
import OpenGrokConfig
import OpenGrokSamplingTypes
import OpenGrokWorkspace

/// Session-owned authorization for tools executed inside a provider request.
/// Unlike client tools, these calls cannot stop at the local permission gate.
struct LiveHostedSearchPolicy: Sendable, Equatable {
    let backendSearchEnabled: Bool
    let webSearchAllowed: Bool
    let xSearchAllowed: Bool
    let allowedDomains: [String]?
    let excludedDomains: [String]?

    static let unrestricted = LiveHostedSearchPolicy(
        backendSearchEnabled: true,
        webSearchAllowed: true,
        xSearchAllowed: true,
        allowedDomains: nil,
        excludedDomains: nil
    )
}

enum LiveHostedSearchComposition {
    static func policy(
        environment: [String: String],
        configuration: TOMLValue,
        disableWebSearch: Bool,
        toolPolicy: LiveAgentToolPolicy?,
        permissionRules: [PermissionRule]
    ) -> LiveHostedSearchPolicy {
        let backendSearchEnabled = OpenGrokConfig.envBool(
            "GROK_BACKEND_SEARCH",
            environment: environment
        ) ?? configuration[path: ["features", "backend_tools"]]?.boolValue ?? true

        let allowedDomains = domains(
            configuration[path: ["toolset", "web_search", "allowed_domains"]]
        )
        // The existing HostedTool representation cannot express an exclude
        // list. Advertising an unrestricted search would silently violate the
        // configured boundary, so retain the policy but suppress hosted web.
        let excludedDomains = allowedDomains == nil
            ? domains(configuration[path: ["toolset", "web_search", "excluded_domains"]])
            : nil
        let hasUnenforceablePermission = permissionRules.contains { rule in
            (rule.tool == .any || rule.tool == .webSearch)
                && (rule.action == .deny || rule.action == .ask)
        }
        let searchPermitted = !disableWebSearch && !hasUnenforceablePermission
        return LiveHostedSearchPolicy(
            backendSearchEnabled: backendSearchEnabled,
            webSearchAllowed: searchPermitted
                && excludedDomains == nil
                && hostedToolAllowed("web_search", policy: toolPolicy),
            xSearchAllowed: searchPermitted
                && hostedToolAllowed("x_search", policy: toolPolicy),
            allowedDomains: allowedDomains,
            excludedDomains: excludedDomains
        )
    }

    static func resolve(
        provider: ModelProvider,
        backend: ApiBackend,
        modelSupportsBackendSearch: Bool,
        policy: LiveHostedSearchPolicy,
        availableFunctionTools: [ToolSpec],
        existingHostedTools: [HostedTool]
    ) -> [HostedTool] {
        guard backend == .responses,
              provider.profile.supportsBackend(backend),
              provider.profile.hostedToolDialect != nil
        else { return [] }

        let searchActive = modelSupportsBackendSearch && policy.backendSearchEnabled
        let hasClientReplacement = provider != .xai && availableFunctionTools.contains {
            $0.name == "web_search" || $0.name == "web__run"
        }
        let permitsWebSearch = searchActive
            && provider.profile.nativeWebSearch
            && policy.webSearchAllowed
            && !hasClientReplacement
        let permitsXSearch = searchActive
            && provider.profile.hostedToolDialect == .xai
            && policy.xSearchAllowed

        var tools: [HostedTool] = []
        var seen = Set<String>()
        for existing in hostedToolsForProvider(hostedTools: existingHostedTools, provider: provider) {
            let tool: HostedTool
            switch existing {
            case .webSearch(let mode, let domains, let location, let contextSize, let contentTypes):
                guard permitsWebSearch, mode != .disabled else { continue }
                tool = .webSearch(
                    mode: mode ?? .live,
                    allowedDomains: policy.allowedDomains ?? domains,
                    userLocation: location,
                    searchContextSize: contextSize,
                    searchContentTypes: contentTypes
                )
            case .xSearch:
                guard permitsXSearch else { continue }
                tool = existing
            case .clientCustom:
                tool = existing
            }
            if seen.insert(tool.wireName).inserted {
                tools.append(tool)
            }
        }

        if permitsWebSearch, seen.insert("web_search").inserted {
            tools.append(.webSearch(
                mode: .live,
                allowedDomains: policy.allowedDomains,
                userLocation: nil,
                searchContextSize: nil,
                searchContentTypes: nil
            ))
        }
        if permitsXSearch, seen.insert("x_search").inserted {
            tools.append(.xSearch)
        }
        return tools
    }

    private static func domains(_ value: TOMLValue?) -> [String]? {
        let domains = value?.arrayValue?
            .compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(MAX_WEB_SEARCH_DOMAINS)
        guard let domains, !domains.isEmpty else { return nil }
        return Array(domains)
    }

    private static func hostedToolAllowed(
        _ name: String,
        policy: LiveAgentToolPolicy?
    ) -> Bool {
        guard let policy else { return true }
        if matches(policy.denylist, name: name)
            || matches(policy.sessionDenylist, name: name)
        {
            return false
        }
        if !policy.allowlist.isEmpty, !matches(policy.allowlist, name: name) {
            return false
        }
        if let sessionAllowlist = policy.sessionAllowlist,
           !matches(sessionAllowlist, name: name)
        {
            return false
        }
        return true
    }

    private static func matches(_ entries: [String], name: String) -> Bool {
        entries.contains { entry in
            entry == "*"
                || entry == name
                || entry.split(separator: ":").last.map(String.init) == name
        }
    }
}
