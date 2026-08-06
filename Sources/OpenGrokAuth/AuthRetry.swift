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

/// HTTPTransport decorator that performs one pre-body 401 refresh/replay.
/// Streaming POSTs are replayable only until response body bytes are exposed.
public struct AuthRetryTransport: HTTPTransport, Sendable {
    public let transport: any HTTPTransport
    public let credentials: any AuthCredentialProvider
    public let maxRetries: UInt

    public init(
        transport: any HTTPTransport,
        credentials: any AuthCredentialProvider,
        maxRetries: UInt = 1
    ) {
        self.transport = transport
        self.credentials = credentials
        self.maxRetries = maxRetries
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await AuthRetryMiddleware(credentials: credentials, maxRetries: maxRetries)
            .send(request, using: transport)
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<HTTPStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var retryCount: UInt = 0
                    while true {
                        try Task.checkCancellation()
                        let stamped = stamp(request)
                        var pending: [HTTPStreamEvent] = []
                        var sawBody = false
                        var sawMetadata = false
                        var shouldRetry = false
                        var iterator = transport.stream(stamped).makeAsyncIterator()

                        while let event = try await iterator.next() {
                            switch event {
                            case .metadata(let metadata):
                                sawMetadata = true
                                if metadata.statusCode == 401,
                                   retryCount < maxRetries,
                                   !sawBody,
                                   await credentials.refreshAfterUnauthorized(),
                                   credentials.snapshot().token != nil
                                {
                                    retryCount += 1
                                    shouldRetry = true
                                    break
                                }
                                continuation.yield(.metadata(metadata))
                                for buffered in pending {
                                    continuation.yield(buffered)
                                }
                                pending.removeAll(keepingCapacity: false)
                            case .body(let data):
                                if data.isEmpty { continue }
                                if sawMetadata {
                                    continuation.yield(.body(data))
                                } else {
                                    pending.append(.body(data))
                                }
                                sawBody = true
                            case .end:
                                continuation.yield(.end)
                            }
                            if shouldRetry { break }
                        }

                        if shouldRetry { continue }
                        continuation.finish()
                        return
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: HTTPError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stamp(_ request: HTTPRequest) -> HTTPRequest {
        var stamped = request
        credentials.apply(to: &stamped.headers, baseURL: request.url.absoluteString)
        if stamped.headers["Authorization"] == nil,
           let token = credentials.snapshot().token
        {
            stamped.headers["Authorization"] = "Bearer \(token)"
            if credentials.needsTokenAuthHeader() {
                stamped.headers[xaiTokenAuthHeader] = xaiTokenAuthValue
            }
        }
        return stamped
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
