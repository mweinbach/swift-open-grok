// MinimalCommitPolicyTests.swift
//
// Port of the display-mode policy tests from
// `xai-grok-pager-minimal/src/commit_tests.rs` at the pin (650c1db7).
// Upstream drives the policy through `committed_appearance(&Appearance
// Config)`; the port's policy takes the `minimal_collapse_thinking` toggle
// directly (the appearance struct is renderer territory — M2), so
// `default_appearance()` maps to `collapseThinking: false` and
// `collapsed_appearance()` to `collapseThinking: true`.

import Testing
import OpenGrokMinimalScrollback

@Suite("Minimal commit display-mode policy")
struct MinimalCommitPolicyTests {
    // commit_tests.rs:996-1014
    @Test("commit display mode policy")
    func commitDisplayModePolicy() {
        #expect(
            minimalCommitDisplayMode(for: .thinking("reasoning"), collapseThinking: false)
                == .expanded
        )
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .edit, error: nil),
                collapseThinking: false
            ) == .expanded
        )
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .execute, error: nil),
                collapseThinking: false
            ) == .truncated
        )
        #expect(
            minimalCommitDisplayMode(for: .agentMessage("hi"), collapseThinking: false)
                == .expanded
        )
    }

    // commit_tests.rs:1016-1061 — successful lookups collapse; a FAILED
    // lookup must stay truncated, visible enough to show its error.
    @Test("commit display mode lookups collapse on success only")
    func commitDisplayModeLookupsCollapseOnSuccessOnly() {
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .search, error: nil),
                collapseThinking: false
            ) == .collapsed
        )
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .read, error: nil),
                collapseThinking: false
            ) == .collapsed
        )
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .listDir, error: nil),
                collapseThinking: false
            ) == .collapsed
        )

        let failed: [MinimalBlock] = [
            .toolCall(kind: .search, error: "regex parse error"),
            .toolCall(kind: .read, error: "file not found"),
            .toolCall(kind: .listDir, error: "no such directory"),
        ]
        for block in failed {
            #expect(
                minimalCommitDisplayMode(for: block, collapseThinking: false) == .truncated,
                "failed lookup must stay truncated: \(block)"
            )
        }
    }

    // commit_tests.rs:1063-1088
    @Test("collapse thinking toggle flips only reasoning")
    func collapseThinkingToggleFlipsOnlyReasoning() {
        #expect(
            minimalCommitDisplayMode(for: .thinking("reasoning"), collapseThinking: false)
                == .expanded,
            "default (K9): reasoning commits in full"
        )
        #expect(
            minimalCommitDisplayMode(for: .thinking("reasoning"), collapseThinking: true)
                == .collapsed
        )

        // Everything else is unaffected by the toggle.
        let unaffected: [MinimalBlock] = [
            .agentMessage("hi"),
            .toolCall(kind: .edit, error: nil),
            .toolCall(kind: .execute, error: nil),
            .toolCall(kind: .read, error: nil),
        ]
        for block in unaffected {
            #expect(
                minimalCommitDisplayMode(for: block, collapseThinking: true)
                    == minimalCommitDisplayMode(for: block, collapseThinking: false),
                "the toggle must only touch reasoning: \(block)"
            )
        }
    }

    // Not an upstream policy test, but the policy reads it: the remaining
    // lookup kinds and the success rule they share (commit.rs:129-135 +
    // tool/mod.rs:342-358 — lifecycle events are unconditionally
    // successful yet NOT in the collapse list, so they truncate).
    @Test("memory and integration search collapse; lifecycle and other truncate")
    func memoryAndIntegrationSearchCollapseLifecycleAndOtherTruncate() {
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .memorySearch, error: nil),
                collapseThinking: false
            ) == .collapsed
        )
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .integrationSearch, error: nil),
                collapseThinking: false
            ) == .collapsed
        )
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .lifecycle, error: nil),
                collapseThinking: false
            ) == .truncated
        )
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .other("custom_tool"), error: nil),
                collapseThinking: false
            ) == .truncated
        )
        // Edit stays expanded even when failed — diffs always full (K9);
        // the Edit arm precedes the success check upstream (commit.rs:128).
        #expect(
            minimalCommitDisplayMode(
                for: .toolCall(kind: .edit, error: "patch failed"),
                collapseThinking: false
            ) == .expanded
        )
    }
}
