// Attribution.swift
//
// 401 attribution callback hook for the sampling client.
// Mirrors Rust `attribution.rs`.

import Foundation

/// A logical 401-emitting site inside the sampling client.
public enum SamplingConsumer: String, Sendable, Equatable, Hashable {
    case chatCompletionsStream = "chat_completions_stream"
    case chatCompletions = "chat_completions"
    case responsesStream = "responses_stream"
    case responses = "responses"
    case messagesStream = "messages_stream"
    case messages = "messages"
    case standaloneWebSearch = "standalone_web_search"

    /// Stable string identifier for this emit site.
    public var asEndpoint: String { rawValue }
}

/// Maximum trailing bearer fragment shared with attribution callbacks.
///
/// JWT headers and provider-key prefixes are shared across credentials; only
/// their distinguishing Unicode-safe tail may cross the attribution boundary.
public let BEARER_SUFFIX_LEN = 12

/// Compatibility spelling for callers compiled against the original port.
public let SENT_BEARER_PREFIX_LEN = BEARER_SUFFIX_LEN

/// Hook invoked by ``SamplingClient`` at every 401 response site.
///
/// Implementations must be cheap and non-blocking. They run inside the
/// request's response-handling path.
public protocol Auth401AttributionCallback: Sendable {
    /// Record a 401 attribution event.
    ///
    /// - Parameters:
    ///   - consumer: which endpoint emitted the 401
    ///   - sentBearerPrefix: last ``BEARER_SUFFIX_LEN`` characters of the
    ///     bearer actually sent, or `nil` when no auth header was present
    func record401(consumer: SamplingConsumer, sentBearerPrefix: String?)
}

/// Last 12 extended grapheme clusters, preserving short and non-ASCII tokens.
public func scrubbedBearerSuffix(_ bearer: String) -> String {
    String(bearer.suffix(BEARER_SUFFIX_LEN))
}

/// Compatibility spelling; the returned fragment is always the bearer tail.
public func scrubbedBearerPrefix(_ bearer: String) -> String {
    scrubbedBearerSuffix(bearer)
}
