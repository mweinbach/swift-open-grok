// AuthRetry.swift
//
// Exactly-one 401 refresh middleware over OpenGrokHTTP.
// Never replays non-idempotent / non-cloneable partial requests.

import Foundation
import OpenGrokHTTP

/// Stamps auth headers and retries on 401 at most `maxRetries` times
/// (default 1 = exactly-one refresh).
public struct AuthRetryMiddleware: Sendable {
    public var credentials: any AuthCredentialProvider
    /// Maximum refresh-and-retry attempts after the first 401. Default 1.
    public var maxRetries: UInt

    public init(credentials: any AuthCredentialProvider, maxRetries: UInt = 1) {
        self.credentials = credentials
        self.maxRetries = maxRetries
    }

    /// Send `request` with auth headers, refreshing once (or up to maxRetries)
    /// on 401 when the request is safe to replay.
    public func send(
        _ request: HTTPRequest,
        using transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        var req = applyAuth(request)
        let canReplay = request.idempotency == .idempotent && request.body != nil
            || request.idempotency == .idempotent
        // Always allow replay for GET/HEAD/etc. (idempotent); refuse for
        // non-idempotent once any response starts (we only have buffered send).

        let first = try await transport.send(req)
        if first.metadata.statusCode != 401 || maxRetries == 0 {
            return first
        }
        if request.idempotency == .nonIdempotent {
            // Do not replay partial / non-idempotent requests.
            return first
        }
        _ = canReplay

        var last = first
        for _ in 0..<maxRetries {
            let refreshed = await credentials.refreshAfterUnauthorized()
            if !refreshed { break }
            let snap = credentials.snapshot()
            guard snap.token != nil else { break }
            req = applyAuth(request)
            last = try await transport.send(req)
            if last.metadata.statusCode != 401 {
                return last
            }
        }
        return last
    }

    private func applyAuth(_ request: HTTPRequest) -> HTTPRequest {
        var req = request
        credentials.apply(to: &req.headers, baseURL: request.url.absoluteString)
        // Prefer token from snapshot Authorization if apply didn't set it.
        let snap = credentials.snapshot()
        if req.headers["Authorization"] == nil, let token = snap.token {
            req.headers["Authorization"] = "Bearer \(token)"
            if credentials.needsTokenAuthHeader() {
                req.headers[xaiTokenAuthHeader] = xaiTokenAuthValue
            }
        }
        return req
    }
}

/// Concurrent refresh single-flight: only one refresh runs; waiters share result.
public actor RefreshSingleFlight {
    private var inFlight: Task<Bool, Never>?

    public init() {}

    public func run(_ body: @escaping @Sendable () async -> Bool) async -> Bool {
        if let existing = inFlight {
            return await existing.value
        }
        let task = Task { await body() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}
