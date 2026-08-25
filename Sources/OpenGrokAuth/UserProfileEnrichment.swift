import Foundation
import OpenGrokHTTP
import OpenGrokVersion

private let defaultXAIUserProfileProxyBaseURL = "https://cli-chat-proxy.grok.com/v1"
private let xaiUserProfileTimeout: TimeInterval = 10

/// Resolve only the explicitly trusted proxy authority, never a model endpoint.
/// Model URLs can belong to another provider or an untrusted project.
func xaiUserProfileURL(environment: [String: String]) -> URL? {
    let configured = environment["GROK_CLI_CHAT_PROXY_BASE_URL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let base: String
    if let configured, !configured.isEmpty {
        base = configured
    } else {
        base = defaultXAIUserProfileProxyBaseURL
    }

    guard var components = URLComponents(string: base),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased(),
          !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil
    else {
        return nil
    }

    let loopback = host == "localhost" || host == "127.0.0.1"
        || host == "::1" || host == "[::1]"
    guard scheme == "https" || (scheme == "http" && loopback) else {
        return nil
    }

    let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
        return nil
    }
    components.path = path.isEmpty ? "/user" : "/\(path)/user"
    return components.url
}

/// Best-effort `/user` enrichment before the first durable xAI session write.
/// Cancellation is the exception: an abandoned login must persist nothing.
func enrichXAIUserProfile(
    auth: GrokAuth,
    configuration: GrokComConfig,
    environment: [String: String],
    transport: any HTTPTransport
) async throws -> GrokAuth {
    try Task.checkCancellation()

    guard auth.authMode == .oidc,
          let expected = configuration.effectiveOIDC,
          let actualIssuer = auth.oidcIssuer,
          actualIssuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
              == expected.issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
          auth.oidcClientID == expected.clientID,
          !auth.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let url = xaiUserProfileURL(environment: environment)
    else {
        return auth
    }

    let request = HTTPRequest(
        method: .get,
        url: url,
        headers: [
            "Authorization": "Bearer \(auth.key)",
            xaiTokenAuthHeader: configuration.tokenHeader,
            "x-grok-client-version": OpenGrokVersion.compiledVersion,
            clientModeHeader: "interactive",
        ],
        timeout: xaiUserProfileTimeout,
        idempotency: .idempotent
    )

    let response: HTTPResponse
    do {
        response = try await transport.send(request)
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as HTTPError {
        if error == .cancelled || Task.isCancelled {
            throw CancellationError()
        }
        return auth
    } catch {
        if Task.isCancelled {
            throw CancellationError()
        }
        return auth
    }

    try Task.checkCancellation()
    guard (200..<300).contains(response.metadata.statusCode),
          let profile = try? JSONDecoder().decode(UserInfo.self, from: response.body),
          !profile.userID.isEmpty
    else {
        return auth
    }

    var enriched = auth
    enriched.applyUserProfileEnrichment(profile)
    return enriched
}
