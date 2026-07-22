// Collect.swift
//
// Buffered consumer for SamplingEvent streams.
// Mirrors Rust `stream/collect.rs`.

import Foundation
import OpenGrokSamplingTypes

/// Drain a ``SamplingEvent`` stream, returning the final response.
///
/// Returns on the first Completed or Failed; intermediate events are dropped.
public func collectResponse(
    _ stream: AsyncStream<SamplingEvent>
) async -> Result<(ConversationResponse, InferenceLatencyStats), SamplingErrorInfo> {
    for await event in stream {
        switch event {
        case .completed(_, let response, let metrics):
            return .success((response, metrics))
        case .failed(_, let error):
            return .failure(error)
        default:
            continue
        }
    }
    return .failure(SamplingErrorInfo(
        kind: .api,
        message: "stream ended without Completed or Failed",
        isRetryable: false
    ))
}
