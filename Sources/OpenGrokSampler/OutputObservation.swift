import Foundation

/// Monotonic, request-scoped evidence that a provider produced output.
///
/// Keep one instance across every attempt. Responses providers can execute a
/// hosted tool or emit a refusal without producing a forwarded display event,
/// so their raw stream must share this cell with the ordinary event observer.
public final class SamplingOutputObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var outputObserved = false

    public init() {}

    public var hasOutput: Bool {
        lock.withLock { outputObserved }
    }

    /// Observe a public sampler event from any provider dialect.
    public func observe(_ event: SamplingEvent) {
        switch event {
        case .firstToken,
             .channelToken,
             .toolCallDelta,
             .toolCallArgumentsComplete,
             .backendToolCallStarted,
             .backendToolCallCompleted,
             .completed:
            recordOutput()
        case .streamStarted,
             .responseStarted,
             .reasoningCompleted,
             .retrying,
             .failed,
             .modelMetadata:
            break
        }
    }

    func observeResponsesEvent(_ event: ResponsesStreamEvent) {
        guard responsesEventMayHaveOutput(event) else { return }
        recordOutput()
    }

    private func recordOutput() {
        lock.withLock {
            outputObserved = true
        }
    }
}
