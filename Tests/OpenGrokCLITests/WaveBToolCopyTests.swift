// WaveBToolCopyTests.swift
// B-INTERACTION copy: execute → ANSI-stripped plain text, edit → unified patch.
// Rust: execute.rs:copy_text via render_terminal_plain, edit.rs:copy_text→diffHunksToPatch at pin 650c1db7.

import Foundation
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

@Suite("Wave B tool copy (B-INTERACTION B3)")
struct WaveBToolCopyTests {
    @Test("execute strips SGR")
    func strips() {
        let raw = "\u{001B}[31mred\u{001B}[0m plain"
        let item = PagerConversationItem.tool(PagerToolCard(name: "run_terminal_cmd", input: "echo hi", output: raw, state: .succeeded))
        let c = LiveScrollbackSelection.copyContent(of: item)
        #expect(c == "red plain" && !c.contains("\u{001B}"))
    }
    @Test("execute keeps newlines")
    func newlines() {
        let raw = "a\nb\nc"
        let item = PagerConversationItem.tool(PagerToolCard(name: "bash", input: "cmd", output: raw, state: .succeeded))
        #expect(LiveScrollbackSelection.copyContent(of: item) == raw)
    }
    @Test("edit is unified patch")
    func editPatch() {
        let rawInput = #"{"file_path":"Sources/Foo.swift","old_string":"let x = 1","new_string":"let x = 2"}"#
        let item = PagerConversationItem.tool(PagerToolCard.make(name: "search_replace", rawInput: rawInput, output: "updated"))
        let c = LiveScrollbackSelection.copyContent(of: item)
        #expect(c.hasPrefix("--- a/") && c.contains("+++ b/") && c.contains("@@ "))
        #expect(c.contains("-let x = 1") && c.contains("+let x = 2"))
    }
    @Test("write is patch")
    func writePatch() {
        let rawInput = #"{"file_path":"new.swift","content":"hello\n"}"#
        let item = PagerConversationItem.tool(PagerToolCard.make(name: "write", rawInput: rawInput))
        let c = LiveScrollbackSelection.copyContent(of: item)
        #expect(c.hasPrefix("--- a/") && c.contains("+hello"))
    }
    @Test("execute fallback to input")
    func fallback() {
        let item = PagerConversationItem.tool(PagerToolCard(name: "bash", input: "ls -la", output: nil, state: .succeeded))
        #expect(LiveScrollbackSelection.copyContent(of: item) == "ls -la")
    }
    @Test("copy via apply strips")
    func viaApplyStrips() {
        var items: [PagerConversationItem] = [.tool(PagerToolCard(name: "bash", input: "cmd", output: "\u{001B}[32mok\u{001B}[0m", state: .succeeded))]
        var sel = LiveScrollbackSelection()
        sel.select(at: 0, itemCount: items.count)
        #expect(sel.apply(.copyBlockContent, items: &items).clipboard == "ok")
    }
    @Test("edit via apply is patch")
    func viaApplyPatch() throws {
        let rawInput = #"{"file_path":"a.swift","old_string":"a","new_string":"b"}"#
        var items: [PagerConversationItem] = [.tool(PagerToolCard.make(name: "search_replace", rawInput: rawInput, output: "updated"))]
        var sel = LiveScrollbackSelection()
        sel.select(at: 0, itemCount: items.count)
        let clip = try #require(sel.apply(.copyBlockContent, items: &items).clipboard)
        #expect(clip.hasPrefix("--- a/") && clip.contains("-a") && clip.contains("+b"))
    }
}
