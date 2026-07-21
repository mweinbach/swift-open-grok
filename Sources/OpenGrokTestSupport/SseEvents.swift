// SseEvents.swift
//
// Port of `xai-grok-test-support/src/sse.rs`. Produces the exact wire format
// the grok sampling client expects, validated against the real client. The
// Rust source builds `axum::response::sse::Event` values; the Swift port
// builds `SseEvent` values (defined in `Scripted.swift`) which render to the
// same `data: <payload>\n\n` / `event: <name>\ndata: <payload>\n\n` wire
// format. The wire bytes are identical — the Rust crate's integration tests
// pin the byte sequences through the real sampling client; the Swift port's
// tests pin the same bytes through the `SseEvent.render()` output.
//
// Builders:
//   * `chatCompletionEvents` / `chatCompletionEventsExact` — echo (collapsed)
//     vs byte-exact deltas.
//   * `responsesApiEvents` / `responsesApiEventsExact` — same split.
//   * `messagesApiEvents` — single-delta (byte-exact by construction).
//   * `responsesApiReasoningOnlyEvents` — reasoning-only turn (the
//     `EmptyReason::ReasoningOnly` doom-loop trigger).
//   * `responsesApiReasoningAndTextEvents` — ordinary reasoning-model turn.
//   * `responsesApiReasoningThenToolCallEvents` + its Chat Completions twin
//     `chatCompletionsReasoningThenToolCallEvents` — think-then-call turn.
//   * The doom-loop check trio:
//     `responsesApiDoomLoopCheckEvents`,
//     `responsesApiDoomLoopTerminalOnlyEvents`,
//     `responsesApiWithDoomLoopFrame`.
//
// The exact/echo split is load-bearing: `split_whitespace` would collapse
// fenced code blocks' newlines onto one line, so a client would never parse
// them as code blocks and diagram detection would silently fail. The
// byte-exact encoders preserve newlines and whitespace runs.

import Foundation

/// SSE event generators for the three inference APIs and the scripted
/// scenario builders.
public enum SseEvents {
    /// The non-standard doom-loop check event name
    /// (`xai_grok_sampling_types::DOOM_LOOP_CHECK_EVENT_TYPE`).
    public static let doomLoopCheckEvent = "response.doom_loop_check"

    // MARK: - Anthropic Messages

    /// Generate Anthropic Messages SSE events: one text block streamed as a
    /// single delta, terminated by a `message_delta` carrying `stopReason`.
    public static func messagesApiEvents(text: String, model: String, stopReason: String) -> [SseEvent] {
        return [
            .data(jsonString([
                ("type", .string("message_start")),
                ("message", .object([
                    ("id", .string("msg_test")),
                    ("type", .string("message")),
                    ("role", .string("assistant")),
                    ("content", .array([])),
                    ("model", .string(model)),
                    ("stop_reason", .null),
                    ("usage", .object([
                        ("input_tokens", .integer(10)),
                        ("output_tokens", .integer(0)),
                        ("cache_creation_input_tokens", .integer(0)),
                        ("cache_read_input_tokens", .integer(0)),
                    ])),
                ])),
            ])),
            .data(jsonString([
                ("type", .string("content_block_start")),
                ("index", .integer(0)),
                ("content_block", .object([
                    ("type", .string("text")),
                    ("text", .string("")),
                ])),
            ])),
            .data(jsonString([
                ("type", .string("content_block_delta")),
                ("index", .integer(0)),
                ("delta", .object([
                    ("type", .string("text_delta")),
                    ("text", .string(text)),
                ])),
            ])),
            .data(jsonString([("type", .string("content_block_stop")), ("index", .integer(0))])),
            .data(jsonString([
                ("type", .string("message_delta")),
                ("delta", .object([("stop_reason", .string(stopReason))])),
                ("usage", .object([
                    ("output_tokens", .integer(5)),
                    ("input_tokens", .integer(10)),
                ])),
            ])),
            .data(jsonString([("type", .string("message_stop"))])),
        ]
    }

    // MARK: - Chat Completions

    /// Generate ChatCompletions SSE events that stream `text` word-by-word
    /// (whitespace-collapsing; use `chatCompletionEventsExact` when the
    /// receiver must reconstruct `text` byte-for-byte).
    public static func chatCompletionEvents(text: String, model: String) -> [SseEvent] {
        let words = text.split { $0.isWhitespace }.map(String.init)
        return chatCompletionEventsFromDeltas(spacePrefixedDeltas(words), model: model)
    }

    /// Like `chatCompletionEvents` but byte-exact: concatenating the deltas
    /// reproduces `text` byte-for-byte (newlines and whitespace runs
    /// preserved). Fenced code blocks (mermaid etc.) need their newlines to
    /// parse as a block, which `split_whitespace` would destroy.
    ///
    /// Mirrors the Rust `chat_completion_deltas`: `text.split(' ')` keeps
    /// empty strings between consecutive spaces (so `omittingEmptySubsequences`
    /// MUST be `false`), and `spacePrefixedDeltas` prepends a space to every
    /// delta except the first — concatenating the deltas reconstructs `text`
    /// byte-for-byte.
    public static func chatCompletionEventsExact(text: String, model: String) -> [SseEvent] {
        // `split(separator:omittingEmptySubsequences:)` with `false` matches
        // Rust's `str::split(' ')`, which yields empty slices between
        // consecutive separators (the property that preserves whitespace runs).
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return chatCompletionEventsFromDeltas(spacePrefixedDeltas(words), model: model)
    }

    private static func chatCompletionEventsFromDeltas(_ deltas: [String], model: String) -> [SseEvent] {
        let n = deltas.count
        var events: [SseEvent] = []
        for (i, content) in deltas.enumerated() {
            let finishReason: JSONValue = (i + 1 == n) ? .string("stop") : .null
            let chunk: JSONValue
            if i == 0 {
                chunk = .object([
                    ("id", .string("chatcmpl-test")),
                    ("object", .string("chat.completion.chunk")),
                    ("created", .integer(1234567890)),
                    ("model", .string(model)),
                    ("choices", .array([
                        .object([
                            ("index", .integer(0)),
                            ("delta", .object([
                                ("role", .string("assistant")),
                                ("content", .string(content)),
                            ])),
                            ("finish_reason", finishReason),
                        ]),
                    ])),
                ])
            } else {
                chunk = .object([
                    ("id", .string("chatcmpl-test")),
                    ("object", .string("chat.completion.chunk")),
                    ("created", .integer(1234567890)),
                    ("model", .string(model)),
                    ("choices", .array([
                        .object([
                            ("index", .integer(0)),
                            ("delta", .object([("content", .string(content))])),
                            ("finish_reason", finishReason),
                        ]),
                    ])),
                ])
            }
            events.append(.data(try! chunk.encodeString()))
        }
        // Usage chunk
        let usage: JSONValue = .object([
            ("id", .string("chatcmpl-test")),
            ("object", .string("chat.completion.chunk")),
            ("created", .integer(1234567890)),
            ("model", .string(model)),
            ("choices", .array([])),
            ("usage", .object([
                ("prompt_tokens", .integer(10)),
                ("completion_tokens", .integer(Int64(n))),
                ("total_tokens", .integer(10 + Int64(n))),
            ])),
        ])
        events.append(.data(try! usage.encodeString()))
        events.append(.data("[DONE]"))
        return events
    }

    // MARK: - Responses API

    /// Generate Responses API SSE events that stream `text` word-by-word
    /// (whitespace-collapsing; use `responsesApiEventsExact` for byte-exact).
    public static func responsesApiEvents(text: String, model: String) -> [SseEvent] {
        let deltas = text.split { $0.isWhitespace }.map { "\($0) " }
        return responsesApiEventsFromDeltas(deltas, text: text, model: model)
    }

    /// Like `responsesApiEvents` but byte-exact: concatenating the deltas
    /// reproduces `text` byte-for-byte (newlines and whitespace runs
    /// preserved).
    ///
    /// Mirrors the Rust `responses_api_deltas`: `text.split_inclusive(' ')`
    /// keeps each chunk's trailing space (and the final chunk if it has no
    /// trailing space), so concatenating the chunks reconstructs `text`
    /// byte-for-byte. Swift's `split(omittingEmptySubsequences:whereSeparator:)`
    /// does NOT include the separator, so we implement `split_inclusive`
    /// manually below.
    public static func responsesApiEventsExact(text: String, model: String) -> [SseEvent] {
        let deltas = splitInclusiveSpace(text)
        return responsesApiEventsFromDeltas(deltas, text: text, model: model)
    }

    // `deltas` and `text` deliberately disagree in echo mode: collapsed
    // deltas, uncollapsed `response.completed` text — inherited load-bearing
    // shell behavior, do not unify.
    private static func responsesApiEventsFromDeltas(_ deltas: [String], text: String, model: String) -> [SseEvent] {
        var events: [SseEvent] = []
        var seq: Int64 = 0

        // response.created
        events.append(.data(jsonString([
            ("type", .string("response.created")),
            ("sequence_number", .integer(seq)),
            ("response", .object([
                ("id", .string("resp_test")),
                ("object", .string("response")),
                ("created_at", .integer(1234567890)),
                ("model", .string(model)),
                ("status", .string("in_progress")),
                ("output", .array([])),
            ])),
        ])))
        seq += 1

        // Text deltas
        for chunk in deltas {
            events.append(.data(jsonString([
                ("type", .string("response.output_text.delta")),
                ("sequence_number", .integer(seq)),
                ("item_id", .string("item_test")),
                ("output_index", .integer(0)),
                ("content_index", .integer(0)),
                ("delta", .string(chunk)),
            ])))
            seq += 1
        }

        // response.completed
        events.append(.data(jsonString([
            ("type", .string("response.completed")),
            ("sequence_number", .integer(seq)),
            ("response", .object([
                ("id", .string("resp_test")),
                ("object", .string("response")),
                ("created_at", .integer(1234567890)),
                ("model", .string(model)),
                ("status", .string("completed")),
                ("output", .array([
                    .object([
                        ("type", .string("message")),
                        ("id", .string("msg_test")),
                        ("role", .string("assistant")),
                        ("status", .string("completed")),
                        ("content", .array([
                            .object([
                                ("type", .string("output_text")),
                                ("text", .string(text)),
                                ("annotations", .array([])),
                            ]),
                        ])),
                    ]),
                ])),
                ("usage", .object([
                    ("input_tokens", .integer(10)),
                    ("output_tokens", .integer(5)),
                    ("total_tokens", .integer(15)),
                    ("input_tokens_details", .object([("cached_tokens", .integer(0))])),
                    ("output_tokens_details", .object([("reasoning_tokens", .integer(0))])),
                ])),
            ])),
        ])))
        events.append(.data("[DONE]"))
        return events
    }

    // MARK: - Reasoning-only (doom-loop trigger)

    /// Generate Responses API SSE events for a reasoning-only completion: the
    /// model streams reasoning summary deltas and finishes with a `reasoning`
    /// output item but NO message / output-text and no tool call. The shell's
    /// collector synthesizes an empty assistant, so the response classifies as
    /// `EmptyReason::ReasoningOnly` — the trigger that makes the sampler
    /// resample (the model doomloop).
    public static func responsesApiReasoningOnlyEvents(reasoning: String, model: String) -> [SseEvent] {
        var events: [SseEvent] = []
        var seq: Int64 = 0

        events.append(.data(jsonString([
            ("type", .string("response.created")),
            ("sequence_number", .integer(seq)),
            ("response", .object([
                ("id", .string("resp_test")),
                ("object", .string("response")),
                ("created_at", .integer(1234567890)),
                ("model", .string(model)),
                ("status", .string("in_progress")),
                ("output", .array([])),
            ])),
        ])))
        seq += 1

        for word in reasoning.split { $0.isWhitespace } {
            events.append(.data(jsonString([
                ("type", .string("response.reasoning_summary_text.delta")),
                ("sequence_number", .integer(seq)),
                ("item_id", .string("reasoning_item_1")),
                ("output_index", .integer(0)),
                ("summary_index", .integer(0)),
                ("delta", .string("\(word) ")),
            ])))
            seq += 1
        }

        events.append(.data(jsonString([
            ("type", .string("response.completed")),
            ("sequence_number", .integer(seq)),
            ("response", .object([
                ("id", .string("resp_test")),
                ("object", .string("response")),
                ("created_at", .integer(1234567890)),
                ("model", .string(model)),
                ("status", .string("completed")),
                ("output", .array([
                    .object([
                        ("type", .string("reasoning")),
                        ("id", .string("reasoning_item_1")),
                        ("summary", .array([
                            .object([
                                ("type", .string("summary_text")),
                                ("text", .string(reasoning)),
                            ]),
                        ])),
                        ("status", .string("completed")),
                    ]),
                ])),
                ("usage", .object([
                    ("input_tokens", .integer(10)),
                    ("output_tokens", .integer(5)),
                    ("total_tokens", .integer(15)),
                    ("input_tokens_details", .object([("cached_tokens", .integer(0))])),
                    ("output_tokens_details", .object([("reasoning_tokens", .integer(5))])),
                ])),
            ])),
        ])))
        events.append(.data("[DONE]"))
        return events
    }

    // MARK: - Reasoning + text (ordinary reasoning-model turn)

    /// Generate Responses API SSE events for a completion that streams
    /// reasoning summary deltas FIRST and then a normal text answer. The
    /// `response.completed` carries both output items (`reasoning` +
    /// `message`), so the collector yields `[Reasoning, Assistant(text)]` —
    /// a full, non-empty turn.
    public static func responsesApiReasoningAndTextEvents(reasoning: String, text: String, model: String) -> [SseEvent] {
        var events: [SseEvent] = []
        var seq: Int64 = 0

        events.append(.data(jsonString([
            ("type", .string("response.created")),
            ("sequence_number", .integer(seq)),
            ("response", .object([
                ("id", .string("resp_test")),
                ("object", .string("response")),
                ("created_at", .integer(1234567890)),
                ("model", .string(model)),
                ("status", .string("in_progress")),
                ("output", .array([])),
            ])),
        ])))
        seq += 1

        for word in reasoning.split { $0.isWhitespace } {
            events.append(.data(jsonString([
                ("type", .string("response.reasoning_summary_text.delta")),
                ("sequence_number", .integer(seq)),
                ("item_id", .string("reasoning_item_1")),
                ("output_index", .integer(0)),
                ("summary_index", .integer(0)),
                ("delta", .string("\(word) ")),
            ])))
            seq += 1
        }

        for word in text.split { $0.isWhitespace } {
            events.append(.data(jsonString([
                ("type", .string("response.output_text.delta")),
                ("sequence_number", .integer(seq)),
                ("item_id", .string("item_test")),
                ("output_index", .integer(1)),
                ("content_index", .integer(0)),
                ("delta", .string("\(word) ")),
            ])))
            seq += 1
        }

        events.append(.data(jsonString([
            ("type", .string("response.completed")),
            ("sequence_number", .integer(seq)),
            ("response", .object([
                ("id", .string("resp_test")),
                ("object", .string("response")),
                ("created_at", .integer(1234567890)),
                ("model", .string(model)),
                ("status", .string("completed")),
                ("output", .array([
                    .object([
                        ("type", .string("reasoning")),
                        ("id", .string("reasoning_item_1")),
                        ("summary", .array([
                            .object([("type", .string("summary_text")), ("text", .string(reasoning))]),
                        ])),
                        ("status", .string("completed")),
                    ]),
                    .object([
                        ("type", .string("message")),
                        ("id", .string("msg_test")),
                        ("role", .string("assistant")),
                        ("status", .string("completed")),
                        ("content", .array([
                            .object([
                                ("type", .string("output_text")),
                                ("text", .string(text)),
                                ("annotations", .array([])),
                            ]),
                        ])),
                    ]),
                ])),
                ("usage", .object([
                    ("input_tokens", .integer(10)),
                    ("output_tokens", .integer(10)),
                    ("total_tokens", .integer(20)),
                    ("input_tokens_details", .object([("cached_tokens", .integer(0))])),
                    ("output_tokens_details", .object([("reasoning_tokens", .integer(5))])),
                ])),
            ])),
        ])))
        events.append(.data("[DONE]"))
        return events
    }

    // MARK: - Reasoning then tool call

    /// Generate Responses API SSE events for a turn that streams reasoning
    /// summary deltas FIRST and then issues one `function_call` — the shape a
    /// reasoning-capable model produces when it thinks before its first tool
    /// call. The tool call keeps the turn non-empty (no
    /// `EmptyReason::ReasoningOnly` resample).
    public static func responsesApiReasoningThenToolCallEvents(
        reasoning: String,
        callId: String,
        name: String,
        arguments: String,
        model: String
    ) -> [SseEvent] {
        var events: [SseEvent] = []
        var seq: Int64 = 0

        events.append(.data(jsonString([
            ("type", .string("response.created")),
            ("sequence_number", .integer(seq)),
            ("response", .object([
                ("id", .string("resp_test")),
                ("object", .string("response")),
                ("created_at", .integer(1234567890)),
                ("model", .string(model)),
                ("status", .string("in_progress")),
                ("output", .array([])),
            ])),
        ])))
        seq += 1

        for word in reasoning.split { $0.isWhitespace } {
            events.append(.data(jsonString([
                ("type", .string("response.reasoning_summary_text.delta")),
                ("sequence_number", .integer(seq)),
                ("item_id", .string("reasoning_item_1")),
                ("output_index", .integer(0)),
                ("summary_index", .integer(0)),
                ("delta", .string("\(word) ")),
            ])))
            seq += 1
        }

        events.append(.data(jsonString([
            ("type", .string("response.function_call_arguments.delta")),
            ("sequence_number", .integer(seq)),
            ("item_id", .string(callId)),
            ("output_index", .integer(1)),
            ("delta", .string(arguments)),
        ])))
        seq += 1

        events.append(.data(jsonString([
            ("type", .string("response.completed")),
            ("sequence_number", .integer(seq)),
            ("response", .object([
                ("id", .string("resp_test")),
                ("object", .string("response")),
                ("created_at", .integer(1234567890)),
                ("model", .string(model)),
                ("status", .string("completed")),
                ("output", .array([
                    .object([
                        ("type", .string("reasoning")),
                        ("id", .string("reasoning_item_1")),
                        ("summary", .array([
                            .object([("type", .string("summary_text")), ("text", .string(reasoning))]),
                        ])),
                        ("status", .string("completed")),
                    ]),
                    .object([
                        ("type", .string("function_call")),
                        ("call_id", .string(callId)),
                        ("name", .string(name)),
                        ("arguments", .string(arguments)),
                    ]),
                ])),
                ("usage", .object([
                    ("input_tokens", .integer(10)),
                    ("output_tokens", .integer(20)),
                    ("total_tokens", .integer(30)),
                    ("input_tokens_details", .object([("cached_tokens", .integer(0))])),
                    ("output_tokens_details", .object([("reasoning_tokens", .integer(5))])),
                ])),
            ])),
        ])))
        events.append(.data("[DONE]"))
        return events
    }

    /// Chat Completions twin of `responsesApiReasoningThenToolCallEvents`:
    /// `reasoning_content` deltas, then one `tool_calls` delta, then a
    /// `finish_reason: "tool_calls"` chunk with usage.
    public static func chatCompletionsReasoningThenToolCallEvents(
        reasoning: String,
        callId: String,
        name: String,
        arguments: String,
        model: String
    ) -> [SseEvent] {
        var events: [SseEvent] = []
        for word in reasoning.split { $0.isWhitespace } {
            events.append(.data(jsonString([
                ("id", .string("chatcmpl-test")),
                ("object", .string("chat.completion.chunk")),
                ("created", .integer(1234567890)),
                ("model", .string(model)),
                ("choices", .array([
                    .object([
                        ("index", .integer(0)),
                        ("delta", .object([("reasoning_content", .string("\(word) "))])),
                        ("finish_reason", .null),
                    ]),
                ])),
            ])))
        }
        events.append(.data(jsonString([
            ("id", .string("chatcmpl-test")),
            ("object", .string("chat.completion.chunk")),
            ("created", .integer(1234567890)),
            ("model", .string(model)),
            ("choices", .array([
                .object([
                    ("index", .integer(0)),
                    ("delta", .object([
                        ("role", .string("assistant")),
                        ("content", .null),
                        ("tool_calls", .array([
                            .object([
                                ("index", .integer(0)),
                                ("id", .string(callId)),
                                ("type", .string("function")),
                                ("function", .object([
                                    ("name", .string(name)),
                                    ("arguments", .string(arguments)),
                                ])),
                            ]),
                        ])),
                    ])),
                    ("finish_reason", .null),
                ]),
            ])),
        ])))
        events.append(.data(jsonString([
            ("id", .string("chatcmpl-test")),
            ("object", .string("chat.completion.chunk")),
            ("created", .integer(1234567890)),
            ("model", .string(model)),
            ("choices", .array([
                .object([
                    ("index", .integer(0)),
                    ("delta", .object([:])),
                    ("finish_reason", .string("tool_calls")),
                ]),
            ])),
            ("usage", .object([
                ("prompt_tokens", .integer(10)),
                ("completion_tokens", .integer(20)),
                ("total_tokens", .integer(30)),
            ])),
        ])))
        events.append(.data("[DONE]"))
        return events
    }

    // MARK: - Doom-loop check trio

    /// Generate Responses API SSE events for a server-detected doom loop: a
    /// reasoning-only stream followed by named `response.doom_loop_check`
    /// frames re-sent with the growing cumulative trigger set (one frame per
    /// prefix of `triggers`), and a terminal `response.completed` whose
    /// response object carries the full set under `doom_loop_check.triggers`.
    public static func responsesApiDoomLoopCheckEvents(
        triggers: [String],
        reasoning: String,
        model: String
    ) -> [SseEvent] {
        var events = responsesApiReasoningOnlyEvents(reasoning: reasoning, model: model)
        // Cumulative frames land between the deltas and the terminal event.
        for prefixLen in 1...triggers.count {
            let at = events.count - 2
            events.insert(
                doomLoopCheckFrame(triggers: Array(triggers.prefix(prefixLen)), seq: Int64(at)),
                at: at
            )
        }
        return withTerminalDoomLoopField(events, triggers: triggers)
    }

    /// Generate Responses API SSE events for an ordinary reasoning + text
    /// turn whose terminal `response.completed` object carries
    /// `doom_loop_check.triggers` with NO mid-stream check frame — the
    /// terminal-only copy of the signal.
    public static func responsesApiDoomLoopTerminalOnlyEvents(
        triggers: [String],
        reasoning: String,
        text: String,
        model: String
    ) -> [SseEvent] {
        withTerminalDoomLoopField(
            responsesApiReasoningAndTextEvents(reasoning: reasoning, text: text, model: model),
            triggers: triggers
        )
    }

    /// Splice ONE named `response.doom_loop_check` frame with an arbitrary
    /// `data:` payload — a byte-exact wire fixture or a malformed variant —
    /// into an otherwise-normal reasoning + text turn, right after
    /// `response.created`.
    public static func responsesApiWithDoomLoopFrame(
        checkFrameData: String,
        reasoning: String,
        text: String,
        model: String
    ) -> [SseEvent] {
        var events = responsesApiReasoningAndTextEvents(reasoning: reasoning, text: text, model: model)
        events.insert(.withEvent(doomLoopCheckEvent, data: checkFrameData), at: 1)
        return events
    }

    // MARK: - Internal helpers

    /// One named `response.doom_loop_check` frame carrying the (cumulative)
    /// trigger set, in the inference API's wire shape.
    private static func doomLoopCheckFrame(triggers: [String], seq: Int64) -> SseEvent {
        .withEvent(
            doomLoopCheckEvent,
            data: jsonString([
                ("sequence_number", .integer(seq)),
                ("type", .string(doomLoopCheckEvent)),
                ("doom_loop_check", .object([
                    ("triggers", .array(triggers.map { .string($0) })),
                ])),
            ])
        )
    }

    /// Inject `doom_loop_check.triggers` into a turn's terminal
    /// `response.completed` object. Crashes when the turn has no completed
    /// frame: every builder emits one, so a miss is a script bug.
    private static func withTerminalDoomLoopField(_ events: [SseEvent], triggers: [String]) -> [SseEvent] {
        var out = events
        let patched = out.indices.contains { i in
            let e = out[i]
            if e.data == "[DONE]" { return false }
            guard var value = try? JSONValue.decode(e.data) else { return false }
            if value["type"].stringValue != "response.completed" { return false }
            // value["response"]["doom_loop_check"] = { "triggers": [...] }
            var response = value["response"]
            if case .object(var dict) = response {
                dict["doom_loop_check"] = .object([
                    ("triggers", .array(triggers.map { .string($0) })),
                ])
                response = .object(dict)
                if case .object(var topDict) = value {
                    topDict["response"] = response
                    value = .object(topDict)
                }
            }
            out[i] = .data(try! value.encodeString())
            return true
        }
        precondition(patched, "turn builders always emit a response.completed frame")
        return out
    }

    /// Shape words into chat deltas: first word bare, each subsequent one
    /// ` {word}` — the source iterator decides collapsing (echo) vs
    /// byte-exact (fixed).
    private static func spacePrefixedDeltas(_ words: [String]) -> [String] {
        words.enumerated().map { i, word in i == 0 ? word : " \(word)" }
    }

    /// Build a JSON object string from an ordered list of key/value pairs.
    /// Order matters for some wire-format pins (the Rust `serde_json::json!`
    /// macro preserves insertion order via `preserve_order`). The Swift port
    /// uses `JSONValue.object([:])` which is a dictionary (unordered), but
    /// the actual bytes are produced by `JSONSerialization` which sorts keys
    /// alphabetically by default. Tests parse the output back to JSON and
    /// key off `type` tags, never byte-comparing object key order — the same
    /// contract the Rust source documents for its scripted builders.
    private static func jsonString(_ pairs: [(String, JSONValue)]) -> String {
        let value = JSONValue.object(pairs)
        return (try? value.encodeString()) ?? "{}"
    }

    /// `str::split_inclusive(' ')` in Swift: splits `text` on `' '` but keeps
    /// the trailing space in each chunk (the chunk that contains the
    /// separator includes the separator). The final chunk keeps its trailing
    /// characters even if no separator follows. Empty chunks ARE produced
    /// for consecutive separators (the separator is part of the empty
    /// preceding chunk).
    ///
    /// Mirrors Rust's `str::split_inclusive(' ')` byte-for-byte so that
    /// concatenating the deltas reconstructs `text` byte-for-byte — the
    /// load-bearing property that fenced code blocks (mermaid) survive
    /// streaming without their newlines collapsing onto one line.
    private static func splitInclusiveSpace(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == " " {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
