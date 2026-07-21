// OpenGrokInterjectionTests.swift
//
// Deterministic tests for OpenGrokInterjection, translated from the Rust
// `xai-interjection-core` test suites in `src/events.rs`,
// `src/format.rs`, and `src/buffer.rs`. They pin the FIFO drain order,
// the cross-clone shared-queue semantics, the cap-on-overflow rule, the
// byte-identical `<user_query>` envelope, and the UTF-8-boundary
// truncation behavior.

import Testing
import Foundation
@testable import OpenGrokInterjection

// MARK: - EventQueue

@Suite("EventQueue")
struct EventQueueTests {
    @Test("push and count")
    func pushAndCount() {
        let q = EventQueue<UInt32>()
        #expect(q.isEmpty)
        q.push(1)
        q.push(2)
        #expect(q.count == 2)
    }

    @Test("clones share one queue")
    func clonesShareQueue() {
        let q = EventQueue<UInt32>()
        let q2 = q.clone()
        q.push(7)
        #expect(q2.count == 1)
    }

    @Test("pushCapped drops the oldest events")
    func pushCappedDropsOldest() {
        let q = EventQueue<UInt32>()
        for i in 0..<UInt32(5) {
            q.pushCapped(i, max: 3)
        }
        #expect(q.drainMatching { _ in true } == [2, 3, 4])
        #expect(q.isEmpty)
    }

    @Test("drainMatching returns matched and retains the rest in FIFO order")
    func drainMatchingFIFO() {
        let q = EventQueue<UInt32>()
        for i in 0..<UInt32(6) {
            q.push(i)
        }
        let evens = q.drainMatching { $0 % 2 == 0 }
        #expect(evens == [0, 2, 4])
        #expect(q.drainMatching { _ in true } == [1, 3, 5])
    }

    @Test("pushCapped under limit keeps all")
    func pushCappedUnderLimit() {
        let q = EventQueue<UInt32>()
        q.pushCapped(1, max: 5)
        q.pushCapped(2, max: 5)
        #expect(q.drainMatching { _ in true } == [1, 2])
    }

    @Test("drainMatching with no matches retains all")
    func drainMatchingNoneMatch() {
        let q = EventQueue<UInt32>()
        q.push(1)
        q.push(2)
        let drained = q.drainMatching { $0 > 10 }
        #expect(drained.isEmpty)
        #expect(q.count == 2)
    }

    @Test("drainMatching on empty queue is empty")
    func drainMatchingEmpty() {
        let q = EventQueue<UInt32>()
        #expect(q.drainMatching { _ in true }.isEmpty)
    }

    @Test("drainAll empties in FIFO order")
    func drainAllFIFO() {
        let q = EventQueue<UInt32>()
        q.push(1)
        q.push(2)
        #expect(q.drainAll() == [1, 2])
        #expect(q.isEmpty)
    }

    @Test("clear discards all")
    func clearDiscardsAll() {
        let q = EventQueue<UInt32>()
        q.push(1)
        q.clear()
        #expect(q.isEmpty)
    }

    @Test("snapshot reads without draining")
    func snapshotNoDrain() {
        let q = EventQueue<UInt32>()
        q.push(9)
        #expect(q.snapshot() == [9])
        #expect(q.count == 1)
    }

    @Test("concurrent producers serialize safely")
    func concurrentProducers() async {
        let q = EventQueue<Int>()
        // 10 tasks each push 1000 events. The lock must serialize them;
        // after joining, the queue must contain exactly 10_000 events.
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<10 {
                group.addTask {
                    for i in 0..<1000 {
                        q.push(t * 1000 + i)
                    }
                }
            }
        }
        #expect(q.count == 10_000)
    }
}

// MARK: - Formatting

@Suite("Formatting")
struct FormattingTests {
    @Test("userQuery wraps the message in the canonical envelope")
    func userQueryEnvelope() {
        let out = userQuery("hello")
        #expect(out == "<user_query>\nhello\n</user_query>")
    }

    @Test("formatInterjection wraps in user_query with mid-turn note")
    func formatInterjectionWraps() {
        let out = formatInterjection("stop and fix the test first")
        #expect(out.hasPrefix("The user sent a message while you were working:\n<user_query>\n"))
        #expect(out.hasSuffix("\n</user_query>"))
        #expect(out.contains("stop and fix the test first"))
    }

    @Test("formatInterjection truncates at the UTF-8 boundary")
    func formatInterjectionTruncatesAtUTF8Boundary() {
        // Each `é` is one Unicode scalar (U+00E9) encoded as 2 UTF-8
        // bytes. The Rust test repeats `é` LARGE_PROMPT_THRESHOLD times
        // and asserts the truncated output contains `... [truncated]`
        // and stays under the threshold + a small slack.
        let s = String(repeating: "é", count: largePromptThreshold)
        #expect(s.utf8.count == largePromptThreshold * 2)
        let out = formatInterjection(s)
        #expect(out.contains("... [truncated]"))
        // The threshold counts UTF-8 BYTES; the prefix keeps scalars
        // whose start byte offset is < largePromptThreshold. With 2-byte
        // scalars, the prefix is largePromptThreshold/2 scalars =
        // largePromptThreshold bytes; plus the suffix and envelope.
        #expect(out.utf8.count < largePromptThreshold + 200)
    }

    @Test("formatInterjection leaves short text untouched")
    func formatInterjectionShortUntouched() {
        let out = formatInterjection("hi")
        #expect(!out.contains("[truncated]"))
    }
}

// MARK: - InterjectionBuffer / drainFormatted

@Suite("InterjectionBuffer")
struct InterjectionBufferTests {
    // A no-op attachment type for the untyped buffer tests.
    fileprivate struct NoAttach: Hashable, Sendable, Codable {
        var tag: Int
    }

    @Test("drainFormatted sanitizes, wraps, and preserves order")
    func drainFormattedSanitizesWrapsPreservesOrder() {
        let buf: InterjectionBuffer<NoAttach> = InterjectionBuffer<NoAttach>()
        buf.push(PendingInterjection(text: "look at [SECRET] one", attachments: []))
        buf.push(PendingInterjection(text: "two", attachments: []))

        let out = drainFormatted(buf) { t in
            t.replacingOccurrences(of: "[SECRET] ", with: "")
        }

        #expect(buf.isEmpty)
        #expect(out.count == 2, "one message per entry, never merged")

        #expect(out[0].text.contains("<user_query>\nlook at one\n</user_query>"))
        #expect(out[1].text.contains("<user_query>\ntwo\n</user_query>"))

        #expect(out[0].text.hasPrefix("The user sent a message while you were working:"))
    }

    @Test("drainFormatted with no sanitizer passes text through unchanged")
    func drainFormattedNoSanitizer() {
        let buf: InterjectionBuffer<NoAttach> = InterjectionBuffer<NoAttach>()
        buf.push(PendingInterjection(text: "hello", attachments: [NoAttach(tag: 1)]))
        let out = drainFormatted(buf)
        #expect(out.count == 1)
        #expect(out[0].text.contains("<user_query>\nhello\n</user_query>"))
        #expect(out[0].attachments == [NoAttach(tag: 1)])
    }

    @Test("PendingInterjection Codable round-trips with attachments")
    func pendingInterjectionCodable() throws {
        let original = PendingInterjection(text: "hi", attachments: [NoAttach(tag: 7)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingInterjection<NoAttach>.self, from: data)
        #expect(decoded == original)
    }
}
