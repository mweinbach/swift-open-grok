import Foundation
import OpenGrokConfigTypes

/// Resolve the local workflow feature flag from an already-composed TOML
/// document. The environment is injected so callers and tests do not mutate
/// process-global state.
public func resolveWorkflows(
    document: TOMLValue,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Resolved<Bool> {
    let config = WorkflowsConfig(
        enabled: document[path: ["workflows", "enabled"]]?.boolValue
    )
    return BoolFlag(envVar: "GROK_WORKFLOWS")
        .config(config.enabled)
        .defaultValue(true)
        .resolve(environment: environment)
}

/// Load the effective local authority document for an explicit session or
/// route directory, then resolve the workflow feature flag from it.
public func loadResolvedWorkflows(
    cwd: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> Resolved<Bool> {
    let document = try loadAuthorityComposition(
        cwd: cwd,
        environment: environment
    ).effective()
    return resolveWorkflows(document: document, environment: environment)
}
