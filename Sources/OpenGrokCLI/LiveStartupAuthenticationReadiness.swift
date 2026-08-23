import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokConfigTypes
import OpenGrokModels
import OpenGrokProviderSession
import OpenGrokSamplingTypes

/// Answers the upstream auth/access/ZDR gate without inspecting an untrusted
/// project, opening a session, refreshing credentials, or executing auth.
enum LiveStartupAuthenticationReadiness {
    static func isReady(
        options: CLIExecutionOptions,
        environment: [String: String],
        remoteSettings: RemoteSettings?
    ) async -> Bool {
        let home = OpenGrokHomeResolver.resolve(environment: environment)
        let document: TOMLValue
        var configuredCatalog: ConfiguredModelCatalog
        do {
            document = try ConfigLayers.load(environment: environment).effectiveConfigBase()
            configuredCatalog = parseConfiguredModelCatalog(
                from: document,
                environment: environment
            )
            for (key, override) in try loadCustomModelOverrides(grokHome: home) {
                if let index = configuredCatalog.modelOverrides.firstIndex(where: { $0.0 == key }) {
                    configuredCatalog.modelOverrides[index] = (key, override)
                } else {
                    configuredCatalog.modelOverrides.append((key, override))
                }
            }
        } catch {
            return false
        }

        let ownerDefault = document[path: ["models", "default"]]?.stringValue
        let openCodeGoEnabled = document[path: ["models", "opencode_go_enabled_models"]]?
            .arrayValue?.compactMap(\.stringValue) ?? []
        let openRouterEnabled = document[path: ["models", "openrouter_enabled_models"]]?
            .arrayValue?.compactMap(\.stringValue) ?? []
        let catalog = resolveModelCatalog(input: CatalogResolutionInput(
            models: ModelsSectionConfig(
                default: ownerDefault,
                opencodeGoEnabledModels: openCodeGoEnabled,
                openRouterEnabledModels: openRouterEnabled
            ),
            configModels: configuredCatalog.modelOverrides
        ))

        let explicitProvider: ModelProvider?
        do {
            explicitProvider = try options.common.provider.map(
                OpenGrokLiveApplicationLauncher.resolveProvider
            )
        } catch {
            return false
        }

        var restoredProvider: ModelProvider?
        var restoredModel: String?
        if options.common.model == nil,
           explicitProvider == nil,
           let candidate = options.sessionToResume {
            let sessionID = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try LiveConversationStore.validateSessionID(sessionID)
                let store = LiveConversationStore(openGrokHome: home)
                guard let record = try await store.loadIfPresent(sessionID: sessionID) else {
                    return false
                }
                guard (record.currentModelID == nil) == (record.currentProvider == nil) else {
                    return false
                }
                restoredModel = record.currentModelID
                restoredProvider = record.currentProvider
            } catch {
                return false
            }
        }

        let routeProvider = explicitProvider ?? restoredProvider
        let requestedModel = options.common.model ?? restoredModel ?? ownerDefault
        let selectedEntry: ModelEntry?
        if let requestedModel, let routeProvider {
            selectedEntry = catalog.pairs().first { key, entry in
                entry.info.provider == routeProvider
                    && (key == requestedModel || entry.model == requestedModel)
            }?.1
            if selectedEntry == nil,
               findModelByID(catalog, modelID: requestedModel) != nil {
                return false
            }
        } else if let requestedModel {
            selectedEntry = findModelByID(catalog, modelID: requestedModel)
        } else if let routeProvider,
                  routeProvider == .runinfra
                    || routeProvider == .gemini
                    || routeProvider == .openRouter {
            selectedEntry = catalog.pairs().first { $0.1.info.provider == routeProvider }?.1
        } else {
            selectedEntry = nil
        }

        let provider = routeProvider ?? selectedEntry?.info.provider ?? .xai
        if provider == .openRouter, selectedEntry == nil {
            return false
        }
        let profile = selectedEntry.map(DefaultModelJSON.fromCatalogEntry)
        let configuredXAIBaseURL = document[path: ["endpoints", "xai_api_base_url"]]?
            .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: String
        if let selectedEntry {
            baseURL = selectedEntry.apiBaseURL ?? selectedEntry.info.baseURL
        } else {
            baseURL = OpenGrokLiveApplicationLauncher.resolveProviderBaseURL(
                provider: provider,
                model: profile,
                environment: environment,
                configuredXaiBaseURL: configuredXAIBaseURL?.isEmpty == false
                    ? configuredXAIBaseURL
                    : nil
            )
        }
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let namedAuthReady: Bool
        if let name = selectedEntry?.authProvider {
            guard let definition = configuredCatalog.providerDefinitions.authProvider(named: name),
                  trustedAuthExecutable(
                      definition,
                      workingDirectory: options.common.cwd,
                      environment: environment
                  ) else {
                return false
            }
            namedAuthReady = true
        } else {
            namedAuthReady = false
        }

        let explicitAPIKey: String?
        if namedAuthReady {
            explicitAPIKey = nil
        } else if let ownCredential = selectedEntry?.ownCredential(environment: environment) {
            explicitAPIKey = ownCredential
        } else {
            do {
                explicitAPIKey = try OpenGrokLiveApplicationLauncher.resolveProviderAPIKey(
                    provider: provider,
                    model: profile,
                    baseURL: baseURL,
                    environment: environment
                )
            } catch {
                return false
            }
        }

        let resolver = LiveCredentialResolver(environment: environment, openGrokHome: home)
        if provider != .xai {
            if namedAuthReady || explicitAPIKey != nil {
                return true
            }
            let endpointTrusted = trustedBuiltInSessionEndpoint(
                provider: provider,
                baseURL: baseURL
            ) || (provider == .codex
                && isTrustedCodexInferenceBaseURL(baseURL, environment: environment))
            return endpointTrusted && resolver.hasStoredCredential(for: provider)
        }

        let remote = remoteSettings.map(AllowlistedRemoteSettings.init(projecting:))
        if let message = remote?.gateMessage,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        let config = GrokComConfig.default(environment: environment)
        let apiKeyAllowed = !config.apiKeyAuthDisabled(environment: environment)
        let manager = AuthManager(grokHome: home, config: config, environment: environment)
        let account = await manager.currentOrExpired()
        let currentAccount = await manager.current()
        let refreshableAccount = account.map { auth in
            auth.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && makeXAIOIDCTokenRefresher(auth: auth, config: config) != nil
        } ?? false
        let endpointTrusted = trustedBuiltInSessionEndpoint(provider: .xai, baseURL: baseURL)
        let explicitUsable = apiKeyAllowed && explicitAPIKey != nil
        let deploymentUsable = endpointTrusted && deploymentKeyFromEnvironment(environment) != nil
        let accountUsable = endpointTrusted && (
            currentAccount != nil
                || (apiKeyAllowed && account?.authMode == .apiKey)
                || refreshableAccount
        )
        guard namedAuthReady || explicitUsable || deploymentUsable || accountUsable else {
            return false
        }

        let accountIsEffective = !namedAuthReady && !explicitUsable && !deploymentUsable
        if accountIsEffective,
           account?.isZDRTeam == true,
           remote?.zdrAccessEnabled != true {
            return false
        }
        return true
    }

    private static func trustedAuthExecutable(
        _ configuration: AuthProviderConfig,
        workingDirectory: String?,
        environment: [String: String]
    ) -> Bool {
        guard configuration.isUsable else { return false }
        let command = configuration.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable: String
        if configuration.args != nil {
            executable = command
        } else {
            guard let first = command.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else {
                return false
            }
            executable = String(first)
        }

        let resolved: String
        if isAbsoluteExecutablePath(executable) {
            resolved = executable
        } else {
            guard !executable.contains("/"),
                  !executable.contains("\\"),
                  let path = resolveExecutablePath(executable, environment: environment),
                  isAbsoluteExecutablePath(path) else {
                return false
            }
            resolved = path
        }

        let executableURL = URL(fileURLWithPath: resolved).standardizedFileURL
            .resolvingSymlinksInPath()
        guard (try? executableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return false
        }
        #if os(Windows)
        let executableExtensions = (environment["PATHEXT"] ?? ".COM;.EXE;.BAT;.CMD")
            .split(separator: ";")
        let extensionName = "." + executableURL.pathExtension
        guard executableExtensions.contains(where: {
            String($0).caseInsensitiveCompare(extensionName) == .orderedSame
        }) else {
            return false
        }
        #else
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return false
        }
        #endif

        let projectURL = URL(
            fileURLWithPath: workingDirectory ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        #if os(Windows)
        let executablePath = executableURL.path.replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        let projectPath = projectURL.path.replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        #else
        let executablePath = executableURL.path
        let projectPath = projectURL.path
        #endif
        return executablePath != projectPath
            && !executablePath.hasPrefix(projectPath + "/")
    }

    private static func isAbsoluteExecutablePath(_ path: String) -> Bool {
        #if os(Windows)
        let bytes = Array(path.utf8)
        if bytes.count >= 3,
           ((65...90).contains(bytes[0]) || (97...122).contains(bytes[0])),
           bytes[1] == 58,
           bytes[2] == 47 || bytes[2] == 92 {
            return true
        }
        guard path.hasPrefix("\\\\") || path.hasPrefix("//") else {
            return false
        }
        return path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).count >= 2
        #else
        return path.hasPrefix("/")
        #endif
    }
}
