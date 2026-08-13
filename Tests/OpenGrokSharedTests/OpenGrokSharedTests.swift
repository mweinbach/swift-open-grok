// OpenGrokSharedTests.swift
//
// Deterministic tests for OpenGrokShared: identifiers, JSON values, error
// envelopes, session info, placeholder images, UI config, clipboard helpers,
// and stderr locking. Translated from the Rust test suites in
// xai-grok-shared/src/{ui_config,placeholder_images}.rs and the identity
// tests in xai-grok-workspace-types/src/identity.rs.

import Testing
import Foundation
@testable import OpenGrokShared

@Suite("Identifiers")
struct IdentifierTests {
    @Test("SessionID serializes as a bare JSON string")
    func sessionIDWireForm() throws {
        let id = SessionID("sess-123")
        let encoder = JSONEncoder()
        let data = try encoder.encode(id)
        let json = String(data: data, encoding: .utf8)
        #expect(json == #""sess-123""#)
        let decoded = try JSONDecoder().decode(SessionID.self, from: data)
        #expect(decoded == id)
    }

    @Test("ToolCallID serializes as a bare JSON string")
    func toolCallIDWireForm() throws {
        let id = ToolCallID("call-abc")
        let data = try JSONEncoder().encode(id)
        let json = String(data: data, encoding: .utf8)
        #expect(json == #""call-abc""#)
        let decoded = try JSONDecoder().decode(ToolCallID.self, from: data)
        #expect(decoded == id)
    }

    @Test("HunkID serializes as a bare JSON string")
    func hunkIDWireForm() throws {
        let id = HunkID("hunk-xyz")
        let data = try JSONEncoder().encode(id)
        let json = String(data: data, encoding: .utf8)
        #expect(json == #""hunk-xyz""#)
        let decoded = try JSONDecoder().decode(HunkID.self, from: data)
        #expect(decoded == id)
    }

    @Test("All identifiers implement CustomStringConvertible")
    func display() {
        #expect(SessionID("a").description == "a")
        #expect(TurnID("turn-1").description == "turn-1")
        #expect(ToolCallID("b").description == "b")
        #expect(TaskID("task-1").description == "task-1")
        #expect(WorktreeID("wt-1").description == "wt-1")
        #expect(ModelID("grok-3").description == "grok-3")
        #expect(RequestID("req-1").description == "req-1")
        #expect(HunkID("c").description == "c")
    }

    @Test("Identifiers are Comparable for deterministic ordering")
    func comparable() {
        let ids: [SessionID] = [SessionID("c"), SessionID("a"), SessionID("b")]
        let sorted = IdentifierOrdering.sorted(ids)
        #expect(sorted.map(\.rawValue) == ["a", "b", "c"])
    }

    @Test("Identifiers are Hashable for Set/Dictionary keys")
    func hashable() {
        let set: Set<ToolCallID> = [ToolCallID("x"), ToolCallID("x"), ToolCallID("y")]
        #expect(set.count == 2)
    }

    @Test("Identifiers are Sendable")
    func sendable() {
        // This compiles only if SessionID is Sendable.
        let id = SessionID("test")
        Task { @Sendable in
            _ = id
        }
    }

    @Test("RequestID.random() produces a non-empty UUID string")
    func requestIDRandom() {
        let id = RequestID.random()
        #expect(!id.isEmpty)
        #expect(id.rawValue.contains("-"))
    }

    @Test("Deduplicated sorted removes duplicates")
    func dedupedSorted() {
        let ids: [TurnID] = [TurnID("3"), TurnID("1"), TurnID("3"), TurnID("2")]
        let result = IdentifierOrdering.deduplicatedSorted(ids)
        #expect(result.map(\.rawValue) == ["1", "2", "3"])
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Decode null")
    func decodeNull() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("null".utf8))
        #expect(value.isNull)
    }

    @Test("Decode bool")
    func decodeBool() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8))
        #expect(value.boolValue == true)
    }

    @Test("Decode number as int64")
    func decodeInt() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("42".utf8))
        #expect(value.int64Value == 42)
    }

    @Test("Decode string")
    func decodeString() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#""hello""#.utf8))
        #expect(value.stringValue == "hello")
    }

    @Test("Decode array")
    func decodeArray() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("[1, 2, 3]".utf8))
        #expect(value.arrayValue?.count == 3)
        #expect(value[0]?.int64Value == 1)
    }

    @Test("Decode object and subscript")
    func decodeObject() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":1,"b":"x"}"#.utf8))
        #expect(value["a"]?.int64Value == 1)
        #expect(value["b"]?.stringValue == "x")
    }

    @Test("Round-trip preserves structure")
    func roundTrip() throws {
        let original: JSONValue = .object([
            "name": .string("test"),
            "count": .number(.int64(42)),
            "items": .array([.string("a"), .string("b")]),
        ])
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded["name"]?.stringValue == "test")
        #expect(decoded["count"]?.int64Value == 42)
        #expect(decoded["items"]?.arrayValue?.count == 2)
    }
}

@Suite("ErrorEnvelope")
struct ErrorEnvelopeTests {
    @Test("Permanent error is not retryable")
    func permanent() {
        let err = ErrorEnvelope.permanent(code: "permission_denied", message: "Not allowed")
        #expect(err.retryable == false)
        #expect(err.code == "permission_denied")
        #expect(err.message == "Not allowed")
    }

    @Test("Transient error is retryable")
    func transient() {
        let err = ErrorEnvelope.transient(code: "network_timeout", message: "Timed out")
        #expect(err.retryable == true)
    }

    @Test("With detail chaining")
    func withDetail() {
        let err = ErrorEnvelope.permanent(code: "test", message: "msg")
            .withDetail("status", .number(.int64(403)))
        #expect(err.details["status"]?.int64Value == 403)
    }

    @Test("Codable round-trip preserves fields")
    func codableRoundTrip() throws {
        let err = ErrorEnvelope(
            code: "test_error",
            message: "something went wrong",
            retryable: true,
            details: ["status": .number(.int64(500))],
            requestID: "req-123"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(err)
        let decoded = try JSONDecoder().decode(ErrorEnvelope.self, from: data)
        #expect(decoded.code == err.code)
        #expect(decoded.message == err.message)
        #expect(decoded.retryable == err.retryable)
        #expect(decoded.details["status"]?.int64Value == 500)
        #expect(decoded.requestID == "req-123")
    }

    @Test("Two envelopes with same fields are equal (no NSError identity)")
    func equality() {
        let a = ErrorEnvelope(code: "x", message: "y")
        let b = ErrorEnvelope(code: "x", message: "y")
        #expect(a == b)
    }

    @Test("LocalizedError returns message")
    func localizedError() {
        let err = ErrorEnvelope(code: "test", message: "display me")
        #expect(err.errorDescription == "display me")
    }
}

@Suite("SessionInfo")
struct SessionInfoTests {
    @Test("Codable round-trip")
    func roundTrip() throws {
        let info = SessionInfo(id: SessionID("sess-1"), cwd: "/tmp/project")
        let encoder = JSONEncoder()
        let data = try encoder.encode(info)
        let decoded = try JSONDecoder().decode(SessionInfo.self, from: data)
        #expect(decoded.id == info.id)
        #expect(decoded.cwd == info.cwd)
    }

    @Test("Wire form has id and cwd")
    func wireForm() throws {
        let info = SessionInfo(id: SessionID("s1"), cwd: "/home")
        let encoder = JSONEncoder()
        // .withoutEscapingSlashes matches serde_json's default (no `\/`
        // escaping) so the wire form is byte-significant against Rust.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(info)
        let json = String(data: data, encoding: .utf8)
        #expect(json == #"{"cwd":"/home","id":"s1"}"#)
    }
}

@Suite("ProxyReExport")
struct ProxyReExportTests {
    @Test("FeedbackTerminalInfo is accessible through OpenGrokShared without importing OpenGrokCLIChatProxyTypes")
    func feedbackTerminalInfoReExport() throws {
        // The Rust `xai-grok-shared` crate re-exports
        // `prod_mc_cli_chat_proxy_types::feedback_types::FeedbackTerminalInfo`.
        // The Swift port mirrors this with a public typealias in
        // OpenGrokShared. This test verifies that downstream consumers can
        // use `FeedbackTerminalInfo` from `OpenGrokShared` directly —
        // this file imports only `OpenGrokShared` (via `@testable import`),
        // NOT `OpenGrokCLIChatProxyTypes`.
        let info = FeedbackTerminalInfo(
            brand: "Terminal",
            multiplexer: "tmux",
            isSSH: true,
            isByobu: false,
            termVar: "xterm-256color"
        )
        #expect(info.brand == "Terminal")
        #expect(info.multiplexer == "tmux")
        #expect(info.isSSH == true)
        // Verify Codable round-trip works through the re-exported type.
        let encoder = JSONEncoder()
        let data = try encoder.encode(info)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FeedbackTerminalInfo.self, from: data)
        #expect(decoded.brand == "Terminal")
        #expect(decoded.isSSH == true)
    }
}

@Suite("PlaceholderImages")
struct PlaceholderImagesTests {
    @Test("extractPlaceholders basic")
    func extractBasic() {
        let text = "look at [Image #1: /tmp/a.png] and [Image #2: /home/user/b.jpg]"
        let matches = extractPlaceholders(text)
        #expect(matches.count == 2)
        #expect(matches[0].displayNumber == 1)
        #expect(matches[0].path == "/tmp/a.png")
        #expect(matches[1].displayNumber == 2)
        #expect(matches[1].path == "/home/user/b.jpg")
    }

    @Test("extractPlaceholders with spaces in path")
    func extractSpaces() {
        let text = "[Image #3: /Users/me/My Pictures/cat.png]"
        let matches = extractPlaceholders(text)
        #expect(matches.count == 1)
        #expect(matches[0].path == "/Users/me/My Pictures/cat.png")
    }

    @Test("extractPlaceholders rejects partial and invalid forms")
    func rejectsInvalid() {
        #expect(extractPlaceholders("[Image #3] only").isEmpty)
        #expect(extractPlaceholders("[Image #4: ]").isEmpty)
        #expect(extractPlaceholders("[Image #5: /tmp/x.png").isEmpty)
        #expect(extractPlaceholders("[image #1: /tmp/x.png]").isEmpty)
        #expect(extractPlaceholders("[Image #: /tmp/x.png]").isEmpty)
        // Missing space after colon: producer always emits ": "
        #expect(extractPlaceholders("[Image #5:foo.png]").isEmpty)
    }

    @Test("extractPlaceholders unicode path")
    func unicode() {
        let text = "[Image #9: /tmp/café.png]"
        let matches = extractPlaceholders(text)
        #expect(matches.count == 1)
        #expect(matches[0].path == "/tmp/café.png")
    }

    @Test("extractPlaceholders large display number")
    func largeNumber() {
        let text = "[Image #99999: /tmp/a.png]"
        let matches = extractPlaceholders(text)
        #expect(matches.count == 1)
        #expect(matches[0].displayNumber == 99999)
    }

    @Test("extractPlaceholders display number zero is kept")
    func zeroNumber() {
        let text = "[Image #0: /tmp/a.png]"
        let matches = extractPlaceholders(text)
        #expect(matches.count == 1)
        #expect(matches[0].displayNumber == 0)
    }

    @Test("extractPlaceholders multiple on same line")
    func multipleSameLine() {
        let text = "[Image #1: /tmp/a.png] [Image #2: /tmp/b.png] [Image #3: /tmp/c.png]"
        let matches = extractPlaceholders(text)
        #expect(matches.count == 3)
        #expect(matches[0].displayNumber == 1)
        #expect(matches[1].displayNumber == 2)
        #expect(matches[2].displayNumber == 3)
    }

    @Test("extractPlaceholders caps at max per prompt")
    func capsAtMax() {
        let chunk = String(repeating: "[Image #1: /tmp/a.png] ", count: maxPlaceholdersPerPrompt + 5)
        let matches = extractPlaceholders(chunk)
        #expect(matches.count == maxPlaceholdersPerPrompt)
    }

    @Test("stripPaths drops path keeps anchor")
    func stripPathsBasic() {
        let result = stripPathsFromImagePlaceholders(
            "what is that?[Image #1: /Users/me/Desktop/x.png] thanks"
        )
        #expect(result == "what is that?[Image #1] thanks")
    }

    @Test("stripPaths handles multiple placeholders and spaces")
    func stripPathsMultiple() {
        let result = stripPathsFromImagePlaceholders(
            "[Image #1: /tmp/a.png] mid [Image #2: /home/u/My Pictures/b.jpg] tail"
        )
        #expect(result == "[Image #1] mid [Image #2] tail")
    }

    @Test("stripPaths returns input unchanged when no placeholders")
    func stripPathsNoMatch() {
        let text = "no placeholder here, just prose"
        #expect(stripPathsFromImagePlaceholders(text) == text)
    }

    @Test("stripPaths preserves unicode")
    func stripPathsUnicode() {
        let result = stripPathsFromImagePlaceholders(
            "café \u{202f}[Image #4: /Users/me/Desktop/Screenshot.png] ok"
        )
        #expect(result == "café \u{202f}[Image #4] ok")
    }

    @Test("mimeTypeFromBytes detects PNG")
    func mimePNG() {
        let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(mimeTypeFromBytes(Data(pngBytes)) == "image/png")
    }

    @Test("mimeTypeFromBytes detects JPEG")
    func mimeJPEG() {
        let jpegBytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        #expect(mimeTypeFromBytes(Data(jpegBytes)) == "image/jpeg")
    }

    @Test("mimeTypeFromBytes detects GIF")
    func mimeGIF() {
        let gifBytes: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        #expect(mimeTypeFromBytes(Data(gifBytes)) == "image/gif")
    }

    @Test("mimeTypeFromBytes returns octet-stream for unknown")
    func mimeUnknown() {
        #expect(mimeTypeFromBytes(Data([0x00, 0x01, 0x02])) == "application/octet-stream")
    }

    @Test("mimeToExtension maps known types")
    func mimeToExt() {
        #expect(mimeToExtension("image/png") == "png")
        #expect(mimeToExtension("image/jpeg") == "jpg")
        #expect(mimeToExtension("image/tiff") == "tiff")
        #expect(mimeToExtension("image/gif") == "gif")
        #expect(mimeToExtension("image/webp") == "webp")
        #expect(mimeToExtension("image/bmp") == "bmp")
        #expect(mimeToExtension("unknown") == "bin")
    }

    @Test("canonicalFromFileURI rejects non-file scheme")
    func canonicalNonFile() {
        #expect(canonicalFromFileURI("https://example.com/x.png") == nil)
        #expect(canonicalFromFileURI("/raw/path") == nil)
    }
}

@Suite("UIConfig")
struct UIConfigTests {
    @Test("swarmMode is optional and defaults nil")
    func swarmModeOptional() throws {
        #expect(UiConfig().swarmMode == nil)
        let json = #"{"swarm_mode":true}"#.data(using: .utf8)!
        let enabled = try JSONDecoder().decode(UiConfig.self, from: json)
        #expect(enabled.swarmMode == true)

        let jsonFalse = #"{"swarm_mode":false}"#.data(using: .utf8)!
        let disabled = try JSONDecoder().decode(UiConfig.self, from: jsonFalse)
        #expect(disabled.swarmMode == false)
    }

    @Test("codeMode defaults nil and migrates legacy booleans")
    func codeModeMigration() throws {
        #expect(UiConfig().codeMode == nil)

        let enabledJson = #"{"code_mode":true}"#.data(using: .utf8)!
        let enabled = try JSONDecoder().decode(UiConfig.self, from: enabledJson)
        #expect(enabled.codeMode == .codeMode)

        let disabledJson = #"{"code_mode":false}"#.data(using: .utf8)!
        let disabled = try JSONDecoder().decode(UiConfig.self, from: disabledJson)
        #expect(disabled.codeMode == .direct)

        let onlyJson = #"{"code_mode":"code_mode_only"}"#.data(using: .utf8)!
        let only = try JSONDecoder().decode(UiConfig.self, from: onlyJson)
        #expect(only.codeMode == .codeModeOnly)
    }

    @Test("codeMode re-serializes as canonical string")
    func codeModeEncode() throws {
        let config = UiConfig()
        var configCopy = config
        configCopy.codeMode = .codeMode
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configCopy)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains(#""code_mode":"code_mode""#))
    }

    @Test("codeMode rejects unknown explicit preference")
    func codeModeRejectsUnknown() {
        let json = #"{"code_mode":"automatic"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(UiConfig.self, from: json)
        }
    }

    @Test("pageFlipOnSend defaults on")
    func pageFlipDefault() {
        #expect(UiConfig().pageFlipOnSendEnabled() == true)
        var config = UiConfig()
        config.pageFlipOnSend = false
        #expect(config.pageFlipOnSendEnabled() == false)
    }

    @Test("keepTextSelection precedence")
    func keepTextSelectionPrecedence() {
        var config = UiConfig()
        #expect(config.keepTextSelectionEnabled() == false)

        config.selectionHighlightDurationMs = 0
        #expect(config.keepTextSelectionEnabled() == true)

        config.selectionHighlightDurationMs = 150
        #expect(config.keepTextSelectionEnabled() == false)

        config.selectionHighlightDurationMs = 0
        config.keepTextSelection = "flash"
        #expect(config.keepTextSelectionEnabled() == false)

        config.keepTextSelection = "hold"
        config.selectionHighlightDurationMs = 999
        #expect(config.keepTextSelectionEnabled() == true)

        config.keepTextSelection = "word_select"
        config.selectionHighlightDurationMs = nil
        #expect(config.keepTextSelectionEnabled() == true)
    }

    @Test("keepTextSelection deserializes legacy bool and string")
    func keepTextSelectionLegacy() throws {
        let trueJson = #"{"keep_text_selection": true}"#.data(using: .utf8)!
        let fromTrue = try JSONDecoder().decode(UiConfig.self, from: trueJson)
        #expect(fromTrue.keepTextSelection == "hold")

        let falseJson = #"{"keep_text_selection": false}"#.data(using: .utf8)!
        let fromFalse = try JSONDecoder().decode(UiConfig.self, from: falseJson)
        #expect(fromFalse.keepTextSelection == "flash")

        let holdJson = #"{"keep_text_selection": "hold"}"#.data(using: .utf8)!
        let fromHold = try JSONDecoder().decode(UiConfig.self, from: holdJson)
        #expect(fromHold.keepTextSelection == "hold")
    }

    @Test("resolvedKeepTextSelection precedence matches pin cache.rs")
    func resolvedKeepTextSelectionPrecedence() {
        // appearance/cache.rs text_selection_from_ui at 650c1db7.
        var config = UiConfig()
        #expect(config.resolvedKeepTextSelection() == "flash")

        config.selectionHighlightDurationMs = 0
        #expect(config.resolvedKeepTextSelection() == "hold")

        config.selectionHighlightDurationMs = nil
        config.doubleClickAction = "word_select"
        #expect(config.resolvedKeepTextSelection() == "word_select")

        // Explicit keep_text_selection always wins over legacy keys.
        config.keepTextSelection = "flash"
        config.doubleClickAction = "word_select"
        config.selectionHighlightDurationMs = 0
        #expect(config.resolvedKeepTextSelection() == "flash")

        config.keepTextSelection = "hold"
        #expect(config.resolvedKeepTextSelection() == "hold")

        config.keepTextSelection = "word_select"
        #expect(config.resolvedKeepTextSelection() == "word_select")

        // Non-canonical keep_text_selection falls through to legacy.
        config.keepTextSelection = "yes"
        config.doubleClickAction = "word_select"
        #expect(config.resolvedKeepTextSelection() == "word_select")
    }

    @Test("displayRefresh nested deserialize")
    func displayRefreshNested() throws {
        let json = #"{"display_refresh": {"auto_cadence_enabled": true, "floor_ms": 7, "probe_enabled": false}}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(UiConfig.self, from: json)
        #expect(config.displayRefresh.autoCadenceEnabled == true)
        #expect(config.displayRefresh.floorMs == 7)
        #expect(config.displayRefresh.probeEnabled == false)
        #expect(!config.displayRefresh.isDefault)
    }

    @Test("displayRefresh default is skipped shape")
    func displayRefreshDefault() {
        #expect(DisplayRefreshSettings().isDefault)
        #expect(UiConfig().displayRefresh.isDefault)
    }

    @Test("contextualHints default is skipped")
    func contextualHintsDefault() {
        #expect(ContextualHints().isDefault)
        #expect(UiConfig().contextualHints.isDefault)
    }

    @Test("ToolModePreference fromCanonical")
    func toolModeFromCanonical() {
        #expect(ToolModePreference.fromCanonical("direct") == .direct)
        #expect(ToolModePreference.fromCanonical("code_mode") == .codeMode)
        #expect(ToolModePreference.fromCanonical("code_mode_only") == .codeModeOnly)
        #expect(ToolModePreference.fromCanonical("invalid") == nil)
    }
}

@Suite("ClipboardHelpers")
struct ClipboardHelperTests {
    @Test("osc52Sequence plain")
    func osc52Plain() {
        let data = osc52Sequence(text: "hi", tmuxPassthrough: false)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.hasPrefix("\u{1b}]52;c;"))
        #expect(str.hasSuffix("\u{07}"))
        #expect(!str.contains("tmux"))
    }

    @Test("osc52Sequence tmux passthrough")
    func osc52Tmux() {
        let data = osc52Sequence(text: "hi", tmuxPassthrough: true)
        let str = String(data: data, encoding: .utf8)!
        #expect(str.hasPrefix("\u{1b}Ptmux;"))
    }

    @Test("isRemoteSession detects SSH env vars")
    func remoteSession() {
        #expect(isRemoteSession(environment: ["SSH_CONNECTION": "1"]))
        #expect(isRemoteSession(environment: ["SSH_TTY": "/dev/pts/0"]))
        #expect(isRemoteSession(environment: ["SSH_CLIENT": "1.2.3.4"]))
        #expect(!isRemoteSession(environment: [:]))
    }

    @Test("isContainerizedWithoutDisplay detects Docker sentinel")
    func containerizedDocker() {
        let fm = TestFileManager(filesToExist: ["/.dockerenv"])
        #expect(isContainerizedWithoutDisplay(environment: [:], fileManager: fm) == true)
    }

    @Test("isContainerizedWithoutDisplay false when DISPLAY set")
    func containerizedDisplay() {
        #expect(isContainerizedWithoutDisplay(environment: ["DISPLAY": ":0"]) == false)
    }

    @Test("parseOsascriptFurlOutput handles none and paths")
    func parseFurl() {
        #expect(parseOsascriptFurlOutput("none") == nil)
        #expect(parseOsascriptFurlOutput("") == nil)
        #expect(parseOsascriptFurlOutput("/path/a\n/path/b") == "/path/a\n/path/b")
    }

    @Test("parseAttachmentsOutput parses furl and image class")
    func parseAttachments() {
        let raw = "<<<FURL>>>\n/path/to/file\n<<<IMAGE>>>\nIMAGE:PNGf"
        let result = parseAttachmentsOutput(raw)
        #expect(result.fileURLs == "/path/to/file")
        #expect(result.imageClass == "PNGf")
    }

    @Test("parseAttachmentsOutput file URLs take precedence (image NONE)")
    func parseAttachmentsFurlPrecedence() {
        let raw = "<<<FURL>>>\n/path/to/file\n<<<IMAGE>>>\nIMAGE:NONE"
        let result = parseAttachmentsOutput(raw)
        #expect(result.fileURLs == "/path/to/file")
        #expect(result.imageClass == nil)
    }
}

/// A test FileManager that reports specific paths as existing.
private final class TestFileManager: FileManager, @unchecked Sendable {
    let filesToExist: Set<String>

    init(filesToExist: Set<String>) {
        self.filesToExist = filesToExist
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        filesToExist.contains(path)
    }
}

@Suite("StderrLocking")
struct StderrTests {
    @Test("withLockedStderr executes body")
    func withLocked() throws {
        let result = try withLockedStderr { _ in 42 }
        #expect(result == 42)
    }

    @Test("writeStderr does not throw")
    func writeStderr() {
        #expect(throws: Never.self) {
            try OpenGrokShared.writeStderr("test\n")
        }
    }
}

// MARK: - PlaceholderMatch byteSpan (UTF-8 offsets, no trap)
//
// The previous implementation called `utf16Offset(in: "")` on indices
// derived from a different source string, which trapped with
// `Fatal error: String index is out of bounds`. The byteSpan is now stored
// explicitly at match time and is independent of the source string's
// lifetime.

@Suite("PlaceholderMatchByteSpan")
struct PlaceholderMatchByteSpanTests {
    @Test("byteSpan returns ASCII UTF-8 offsets and does not trap")
    func asciiByteSpan() {
        let text = "before [Image #7: /tmp/a.png] after"
        let matches = extractPlaceholders(text)
        #expect(matches.count == 1)
        let span = matches[0].byteSpan
        // The match starts at "before " (7 bytes) and covers the full
        // placeholder; the end is the byte offset after the closing "]".
        let expected = "[Image #7: /tmp/a.png]"
        let startByte = text.utf8.distance(from: text.utf8.startIndex, to: text.range(of: expected)!.lowerBound)
        let endByte = text.utf8.distance(from: text.utf8.startIndex, to: text.range(of: expected)!.upperBound)
        #expect(span.start == startByte)
        #expect(span.end == endByte)
        // Slicing the UTF-8 view by the stored offsets yields the match.
        let sliced = String(text.utf8[text.utf8.index(text.utf8.startIndex, offsetBy: span.start)..<text.utf8.index(text.utf8.startIndex, offsetBy: span.end)])
        #expect(sliced == expected)
    }

    @Test("byteSpan returns correct UTF-8 offsets for multibyte Unicode")
    func multibyteByteSpan() {
        // "café" is 5 bytes in UTF-8 (é is 2 bytes). The placeholder starts
        // after "café " (6 bytes).
        let text = "café [Image #4: /tmp/写真.png] ok"
        let matches = extractPlaceholders(text)
        #expect(matches.count == 1)
        let span = matches[0].byteSpan
        let expected = "[Image #4: /tmp/写真.png]"
        let startByte = text.utf8.distance(from: text.utf8.startIndex, to: text.range(of: expected)!.lowerBound)
        let endByte = text.utf8.distance(from: text.utf8.startIndex, to: text.range(of: expected)!.upperBound)
        #expect(span.start == startByte)
        #expect(span.end == endByte)
        // Slicing the UTF-8 view by the stored offsets yields the match.
        let sliced = String(text.utf8[text.utf8.index(text.utf8.startIndex, offsetBy: span.start)..<text.utf8.index(text.utf8.startIndex, offsetBy: span.end)])
        #expect(sliced == expected)
    }

    @Test("byteSpan is accessible after the source string is no longer reachable")
    func byteSpanOutlivesSource() {
        // Store only the match, not the source string. Accessing byteSpan
        // must NOT trap (the old implementation did because it re-derived
        // offsets from String.Index against "").
        let match: PlaceholderMatch = {
            let text = "[Image #1: /tmp/a.png]"
            return extractPlaceholders(text)[0]
        }()
        // The source string `text` is out of scope here; byteSpan must still
        // be accessible.
        #expect(match.byteSpan.start == 0)
        #expect(match.byteSpan.end == 22)
    }
}

// MARK: - PlaceholderImages path containment (adversarial)
//
// The previous implementation used `canonicalPath.hasPrefix(prefix.path)`,
// which authorised `/tmp/allowed-escape/secret.png` when the allowlist
// contained `/tmp/allowed`. The component-aware check rejects that.

@Suite("PlaceholderImagePathContainment")
struct PlaceholderImagePathContainmentTests {
    @Test("sibling-prefix escape is rejected (component-aware containment)")
    func siblingPrefixEscape() throws {
        let allowedDir = try makeTempDir(prefix: "allowed")
        let escapeDir = try makeTempDir(prefix: "allowed-escape")
        // Write a forged PNG (valid header) in the escape directory.
        let forgedPath = escapeDir.appendingPathComponent("secret.png")
        try Data(validPNGBytes).write(to: forgedPath)

        // The allowlist contains ONLY `allowed`, not `allowed-escape`.
        let result = loadPlaceholderImage(
            pathString: forgedPath.path,
            allowedPrefixes: [allowedDir]
        )
        // The string-prefix check would accept this; the component-aware
        // check rejects it because `allowed-escape` is not `allowed`.
        #expect(isFailure(result))
        if case .failure(let err) = result {
            #expect(err == .outsideAllowedPrefixes)
        }
    }

    @Test("path exactly equal to allowed prefix is accepted")
    func exactPrefix() throws {
        let allowedDir = try makeTempDir(prefix: "allowed")
        let pngPath = allowedDir.appendingPathComponent("ok.png")
        try Data(validPNGBytes).write(to: pngPath)

        let result = loadPlaceholderImage(
            pathString: pngPath.path,
            allowedPrefixes: [allowedDir]
        )
        #expect(isSuccess(result))
    }

    @Test("path under allowed prefix subdirectory is accepted")
    func subdirectory() throws {
        let allowedDir = try makeTempDir(prefix: "allowed")
        let subDir = allowedDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let pngPath = subDir.appendingPathComponent("ok.png")
        try Data(validPNGBytes).write(to: pngPath)

        let result = loadPlaceholderImage(
            pathString: pngPath.path,
            allowedPrefixes: [allowedDir]
        )
        #expect(isSuccess(result))
    }

    @Test("symlink resolving outside the allowlist is rejected")
    func symlinkEscape() throws {
        let allowedDir = try makeTempDir(prefix: "allowed")
        let outsideDir = try makeTempDir(prefix: "outside")
        let targetPng = outsideDir.appendingPathComponent("real.png")
        try Data(validPNGBytes).write(to: targetPng)

        // Create a symlink inside allowedDir pointing to the outside file.
        let linkPath = allowedDir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: targetPng)

        // resolvingSymlinksInPath() follows the symlink to `outsideDir`,
        // which is NOT in the allowlist → rejected.
        let result = loadPlaceholderImage(
            pathString: linkPath.path,
            allowedPrefixes: [allowedDir]
        )
        #expect(isFailure(result))
        if case .failure(let err) = result {
            #expect(err == .outsideAllowedPrefixes)
        }
    }
}

// MARK: - PlaceholderImages image-header validation (adversarial)
//
// The previous implementation accepted any file with valid PNG/JPEG magic
// bytes. Rust routes bytes through `image::ImageReader` +
// `into_dimensions`, rejecting forged files with magic + garbage tail. The
// pure-Swift `validateImageHeader` parses the structural header to reject
// such forgeries.

@Suite("PlaceholderImageHeaderValidation")
struct PlaceholderImageHeaderValidationTests {
    @Test("valid PNG passes header validation")
    func validPNG() {
        #expect(validateImageHeader(Data(validPNGBytes)) == "image/png")
    }

    @Test("PNG magic + garbage tail is rejected (forgery defence)")
    func pngMagicForgery() {
        // A file whose first 8 bytes are PNG magic but whose tail is
        // arbitrary content (e.g. a private key) must be rejected. The
        // old magic-byte-only check accepted this.
        var forged: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        forged.append(contentsOf: Array("PRIVATE KEY DATA - not a real PNG".utf8))
        #expect(validateImageHeader(Data(forged)) == nil)
    }

    @Test("PNG with truncated IHDR is rejected")
    func truncatedPNG() {
        // Only the 8-byte signature, no IHDR chunk.
        let truncated: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(validateImageHeader(Data(truncated)) == nil)
    }

    @Test("PNG with wrong IHDR length is rejected")
    func wrongIHDRLen() {
        // Signature + IHDR length=0 (not 13) + type.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes.append(contentsOf: [0, 0, 0, 0]) // length = 0
        bytes.append(contentsOf: [0x49, 0x48, 0x44, 0x52]) // "IHDR"
        bytes.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]) // 13 bytes of payload
        #expect(validateImageHeader(Data(bytes)) == nil)
    }

    @Test("PNG with zero dimensions is rejected")
    func zeroDimensionPNG() {
        // Valid IHDR chunk but width=0, height=0.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes.append(contentsOf: [0, 0, 0, 13]) // length = 13
        bytes.append(contentsOf: [0x49, 0x48, 0x44, 0x52]) // "IHDR"
        bytes.append(contentsOf: [0, 0, 0, 0]) // width = 0
        bytes.append(contentsOf: [0, 0, 0, 0]) // height = 0
        bytes.append(contentsOf: [8, 6, 0, 0, 0]) // depth, color, comp, filter, interlace
        #expect(validateImageHeader(Data(bytes)) == nil)
    }

    @Test("JPEG magic + garbage tail is rejected")
    func jpegMagicForgery() {
        var forged: [UInt8] = [0xFF, 0xD8, 0xFF]
        forged.append(contentsOf: Array("PRIVATE KEY - not a real JPEG".utf8))
        #expect(validateImageHeader(Data(forged)) == nil)
    }

    @Test("non-image bytes are rejected")
    func nonImage() {
        #expect(validateImageHeader(Data("hello world".utf8)) == nil)
        #expect(validateImageHeader(Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    @Test("loadPlaceholderImage rejects forged PNG with valid magic and .png extension")
    func loadRejectsForgery() throws {
        let allowedDir = try makeTempDir(prefix: "allowed")
        let forgedPath = allowedDir.appendingPathComponent("forged.png")
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes.append(contentsOf: Array("PRIVATE KEY DATA".utf8))
        try Data(bytes).write(to: forgedPath)

        let result = loadPlaceholderImage(
            pathString: forgedPath.path,
            allowedPrefixes: [allowedDir]
        )
        #expect(isFailure(result))
        if case .failure(let err) = result {
            #expect(err == .notAnImage)
        }
    }

    @Test("loadPlaceholderImage accepts a real PNG")
    func loadAcceptsRealPNG() throws {
        let allowedDir = try makeTempDir(prefix: "allowed")
        let pngPath = allowedDir.appendingPathComponent("ok.png")
        try Data(validPNGBytes).write(to: pngPath)

        let result = loadPlaceholderImage(
            pathString: pngPath.path,
            allowedPrefixes: [allowedDir]
        )
        #expect(isSuccess(result))
        if case .success(let loaded) = result {
            #expect(loaded.mimeType == "image/png")
        }
    }
}

// MARK: - SessionInfo resolver unavailability
//
// The PlaceholderSessionDirectoryResolver is marked @available(*, unavailable)
// because it used FNV-1a, which is incompatible with Rust's sessions_cwd_dir
// (URL-encoding + blake3). These tests pin that the protocol is still
// available for injection and that a custom resolver works.

@Suite("SessionInfoResolver")
struct SessionInfoResolverTests {
    @Test("custom SessionDirectoryResolver can be injected")
    func customResolver() {
        // A test-only resolver that does NOT use the incompatible FNV-1a.
        struct TestResolver: SessionDirectoryResolver {
            let base: URL
            func sessionsCWDDirectory(cwd: String) -> URL {
                base.appendingPathComponent("sessions", isDirectory: true)
                    .appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
            }
            func sessionDirectory(for info: SessionInfo) -> URL {
                sessionsCWDDirectory(cwd: info.cwd)
                    .appendingPathComponent(info.id.rawValue, isDirectory: true)
            }
        }
        let resolver = TestResolver(base: URL(fileURLWithPath: "/tmp/test"))
        let info = SessionInfo(id: SessionID("sess-1"), cwd: "/Users/me/project")
        let dir = resolver.sessionDirectory(for: info)
        #expect(dir.path.contains("sessions"))
        #expect(dir.path.contains("sess-1"))
        #expect(dir.path.contains("_Users_me_project"))
    }

    @Test("cwd-to-session-directory compatibility vector is stable")
    func cwdDirectoryStability() {
        struct TestResolver: SessionDirectoryResolver {
            let base: URL
            func sessionsCWDDirectory(cwd: String) -> URL {
                base.appendingPathComponent("sessions", isDirectory: true)
                    .appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
            }
            func sessionDirectory(for info: SessionInfo) -> URL {
                sessionsCWDDirectory(cwd: info.cwd)
                    .appendingPathComponent(info.id.rawValue, isDirectory: true)
            }
        }
        let resolver = TestResolver(base: URL(fileURLWithPath: "/tmp/test"))
        // The same cwd must always resolve to the same directory.
        let dir1 = resolver.sessionsCWDDirectory(cwd: "/Users/me/project")
        let dir2 = resolver.sessionsCWDDirectory(cwd: "/Users/me/project")
        #expect(dir1 == dir2)
        // Different cwds resolve to different directories.
        let dir3 = resolver.sessionsCWDDirectory(cwd: "/Users/me/other")
        #expect(dir1 != dir3)
    }
}

// MARK: - Test helpers

/// `true` when `result` is a `.failure` case. `Result` does not provide
/// `isFailure`/`isSuccess` in the Swift standard library, so this helper
/// covers the pattern.
private func isFailure<T, E: Error>(_ result: Result<T, E>) -> Bool {
    if case .failure = result { return true }
    return false
}

/// `true` when `result` is a `.success` case.
private func isSuccess<T, E: Error>(_ result: Result<T, E>) -> Bool {
    if case .success = result { return true }
    return false
}

/// Minimal valid 1x1 PNG (real format, decodable by `image` crate).
/// Matches the PNG_BYTES constant in the Rust placeholder_images tests.
private let validPNGBytes: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
    0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
    0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00,
    0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]

/// Create a unique temporary directory with the given name prefix.
private func makeTempDir(prefix: String) throws -> URL {
    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    let uniqueDir = tempRoot.appendingPathComponent("opengrok-test-\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: uniqueDir, withIntermediateDirectories: true)
    return uniqueDir
}
