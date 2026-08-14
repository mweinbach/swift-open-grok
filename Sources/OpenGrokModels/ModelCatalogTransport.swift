// ModelCatalogTransport.swift
//
// Injected HTTP transport and credential snapshots for live model-catalog
// discovery. This module never reaches into an auth store: every secret
// arrives as a caller-built snapshot, and every request goes through a
// `ModelCatalogTransport` the caller supplies.
//
// Port of the request shapes in `crates/codegen/xai-grok-shell/src/`:
//   codex_models.rs:487-515      Codex `/models` headers
//   wafer_models.rs:151-156      Wafer `/models`
//   kimi_models.rs:246-251       Kimi `/models`
//   fireworks_models.rs:233-238  Fireworks `/models`
//   deepseek_models.rs:197-206   DeepSeek `/models`
//   meta_models.rs:178-201       Meta `/models`
//   opencode_go_models.rs:165-195 OpenCode Go `/models` + models.dev

import Foundation
import OpenGrokSamplingTypes

// MARK: - Partitions

/// One independently refreshable provider catalog partition.
///
/// Partitions are the isolation unit: a refresh of one may never read another
/// partition's credentials nor add/remove another partition's models.
public enum ModelCatalogPartition: String, Sendable, Equatable, Hashable, CaseIterable {
    case codex
    case kimi
    case fireworks
    case deepSeek
    case meta
    case openCodeGo
    case wafer
    case zai

    public var provider: ModelProvider {
        switch self {
        case .codex: return .codex
        case .kimi: return .kimi
        case .fireworks: return .fireworks
        case .deepSeek: return .deepseek
        case .meta: return .meta
        case .openCodeGo: return .openCodeGo
        case .wafer: return .wafer
        case .zai: return .zai
        }
    }
}

// MARK: - Wire

public struct ModelCatalogHeader: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A catalog HTTP request. Header order is preserved so tests can pin the
/// exact header sequence upstream sends.
public struct ModelCatalogRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    public var headers: [ModelCatalogHeader]
    public var timeout: TimeInterval

    public init(
        method: String = "GET",
        url: String,
        headers: [ModelCatalogHeader] = [],
        timeout: TimeInterval
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.timeout = timeout
    }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct ModelCatalogResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [ModelCatalogHeader]
    public var body: Data

    public init(status: Int, headers: [ModelCatalogHeader] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Performs catalog HTTP requests. Implementations may hit the network or
/// replay fixtures; they must honor cancellation.
public protocol ModelCatalogTransport: Sendable {
    func send(
        _ request: ModelCatalogRequest,
        cancellation: CancellationToken?
    ) async throws -> ModelCatalogResponse
}

/// Transport that never reaches the network. Every catalog fetch through it
/// fails, leaving the embedded catalog in place.
public struct OfflineCatalogTransport: ModelCatalogTransport {
    public init() {}

    public func send(
        _ request: ModelCatalogRequest,
        cancellation: CancellationToken?
    ) async throws -> ModelCatalogResponse {
        try cancellation?.throwIfCancelled()
        throw ModelsError.remoteMalformed("offline transport: \(request.url) not fetched")
    }
}

// MARK: - Credential snapshots

/// Bearer material plus a caller-computed non-secret identity digest for one
/// API-key provider partition.
///
/// The digest is computed by the caller (which owns the auth store) so this
/// module never holds the material needed to derive one. Cached and in-memory
/// catalogs are keyed by it: a snapshot never survives a credential change.
public struct ProviderCatalogCredential: Sendable, Equatable {
    public var apiKey: String
    public var fingerprint: String

    public init(apiKey: String, fingerprint: String) {
        self.apiKey = apiKey
        self.fingerprint = fingerprint
    }
}

/// Codex OAuth snapshot. `fingerprint` digests only stable principal claims
/// (account id / user id / email / workspace flag) and never bearer material —
/// `account_fingerprint`, `codex_models.rs:885-907`.
public struct CodexCatalogCredential: Sendable, Equatable {
    public var accessToken: String
    public var accountID: String?
    public var accountIsFedramp: Bool
    public var fingerprint: String

    public init(
        accessToken: String,
        accountID: String? = nil,
        accountIsFedramp: Bool = false,
        fingerprint: String
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.accountIsFedramp = accountIsFedramp
        self.fingerprint = fingerprint
    }
}

/// Vends per-partition credential snapshots.
///
/// The broker is the only credential surface this module sees. Each partition
/// actor is constructed with a closure bound to its own partition, so a Codex
/// refresh has no expressible way to name the xAI or Wafer partition.
public protocol ModelCatalogCredentialBroker: Sendable {
    /// API-key material for one partition, or `nil` when unauthenticated.
    /// `nil` is never an error: the partition stays embedded-only.
    func credential(for partition: ModelCatalogPartition) async -> ProviderCatalogCredential?

    /// Codex OAuth material, or `nil` when no Codex session exists.
    ///
    /// `forceRefresh` re-mints the bearer after a 401 — one retry only,
    /// matching `codex_models.rs:373-382`.
    func codexCredential(forceRefresh: Bool) async -> CodexCatalogCredential?
}

/// Broker with no credentials at all: every partition stays embedded-only.
public struct EmptyCredentialBroker: ModelCatalogCredentialBroker {
    public init() {}

    public func credential(for partition: ModelCatalogPartition) async -> ProviderCatalogCredential? {
        nil
    }

    public func codexCredential(forceRefresh: Bool) async -> CodexCatalogCredential? {
        nil
    }
}

// MARK: - Shared request helpers

public enum ModelCatalogRequests {
    /// `format!("{}/models", base_url.trim_end_matches('/'))` — the shape every
    /// OpenAI-compatible provider catalog uses.
    public static func modelsURL(baseURL: String) -> String {
        "\(trimTrailingSlashes(baseURL))/models"
    }

    /// Bearer-only catalog request. Wafer, Kimi, Fireworks, DeepSeek, Meta and
    /// OpenCode Go all send exactly this and nothing more — notably no
    /// originator/version headers, which are Codex-only.
    public static func bearerRequest(
        url: String,
        apiKey: String,
        timeout: TimeInterval
    ) -> ModelCatalogRequest {
        ModelCatalogRequest(
            url: url,
            headers: [ModelCatalogHeader("Authorization", "Bearer \(apiKey)")],
            timeout: timeout
        )
    }
}
