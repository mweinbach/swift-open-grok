// RemoteFetchPolicy.swift
//
// Deployment-authoritative gate for xAI model and remote-settings requests.
// A plain effective-config merge is deliberately unsuitable: its user layer
// overrides managed configuration, while this security gate must do the reverse.

import Foundation

/// Resolve `[features].remote_fetch` using deployment-policy precedence.
///
/// Requirements outrank managed policy, managed policy outranks user config,
/// and an absent policy defaults to enabled. There is intentionally no
/// environment override: an inherited process variable must not re-arm an
/// administrator's network-deny decision.
///
/// When an unrelated user config is malformed, independently reload the
/// requirements and managed tiers before falling back. Otherwise corrupting a
/// user-writable config file would silently bypass an existing deployment pin.
public func resolveTrustedRemoteFetchEnabled(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    do {
        return remoteFetchEnabled(from: try ConfigLayers.load(environment: environment))
    } catch {
        return remoteFetchEnabledFromPolicyLayers(
            requirements: loadMergedRequirements(environment: environment),
            managed: try? loadManagedConfig(environment: environment),
            systemManaged: try? loadSystemManagedConfig(environment: environment)
        )
    }
}

func remoteFetchEnabled(from layers: ConfigLayers) -> Bool {
    firstRemoteFetchPolicy(in: [
        layers.mdmRequirements,
        layers.systemRequirements,
        layers.userRequirements,
        layers.managed,
        layers.systemManaged,
        layers.user,
    ]) ?? true
}

func remoteFetchEnabledFromPolicyLayers(
    requirements: TOMLValue?,
    managed: TOMLValue?,
    systemManaged: TOMLValue?
) -> Bool {
    firstRemoteFetchPolicy(in: [requirements, managed, systemManaged]) ?? true
}

private func firstRemoteFetchPolicy(in layers: [TOMLValue?]) -> Bool? {
    for layer in layers {
        guard case let .boolean(enabled)? = layer?[path: ["features", "remote_fetch"]] else {
            continue
        }
        return enabled
    }
    return nil
}
