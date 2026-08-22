import Testing
@testable import OpenGrokSampler

@Suite("Provider-native sampling lifecycle contracts")
struct SamplingEventLifecycleContractTests {
    @Test("response-start events preserve provider identity and all independent 64-bit input buckets")
    func responseStartedPreservesIdentityAndBuckets() {
        let event = SamplingEvent.responseStarted(
            requestId: RequestId("request_native"),
            messageID: "msg_real_provider_id",
            model: "claude-opus",
            inputTokens: UInt64(UInt32.max) + 1,
            cacheReadInputTokens: 40,
            cacheCreationInputTokens: 25
        )

        guard case .responseStarted(
            let requestID,
            let messageID,
            let model,
            let inputTokens,
            let cacheReadInputTokens,
            let cacheCreationInputTokens
        ) = event else {
            Issue.record("expected provider-native response-start event")
            return
        }

        #expect(requestID == RequestId("request_native"))
        #expect(messageID == "msg_real_provider_id")
        #expect(model == "claude-opus")
        #expect(inputTokens == UInt64(UInt32.max) + 1)
        #expect(cacheReadInputTokens == 40)
        #expect(cacheCreationInputTokens == 25)
    }

    @Test("reasoning completion preserves the provider's encrypted signature verbatim")
    func reasoningCompletedPreservesEncryptedSignature() {
        let event = SamplingEvent.reasoningCompleted(
            requestId: RequestId("request_native"),
            signature: "sig_encrypted:abc+/="
        )

        guard case .reasoningCompleted(let requestID, let signature) = event else {
            Issue.record("expected provider-native reasoning completion")
            return
        }
        #expect(requestID == RequestId("request_native"))
        #expect(signature == "sig_encrypted:abc+/=")
    }
}
