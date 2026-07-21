// OpenGrokTerminalCoreTests.swift
import Foundation
import Testing
@testable import OpenGrokTerminalCore

@Suite("OpenGrokTerminalCore")
struct OpenGrokTerminalCoreTests {
    @Test("TerminalSize and Cell value types")
    func valueTypes() {
        let size = TerminalSize(width: 80, height: 24)
        #expect(size.width == 80 && size.height == 24)
        let cell = Cell(grapheme: "A", style: [.bold, .underline], displayWidth: 1)
        #expect(cell.grapheme == "A")
        #expect(cell.style.contains(.bold))
        #expect(cell.style.contains(.underline))
        #expect(!cell.style.contains(.reverse))
    }

    @Test("Input events are Sendable and equatable")
    func inputEvents() {
        let resize = InputEvent.resize(TerminalSize(width: 120, height: 40))
        let key = InputEvent.key(KeyEvent(key: "Enter", modifiers: [.control]))
        let paste = InputEvent.paste("hello")
        #expect(resize == .resize(TerminalSize(width: 120, height: 40)))
        #expect(key == .key(KeyEvent(key: "Enter", modifiers: [.control])))
        #expect(paste == .paste("hello"))
    }

    @Test("Default capabilities are true-color with full features")
    func defaultCapabilities() {
        let cap = TerminalCapability()
        #expect(cap.colorDepth == .trueColor)
        #expect(cap.supportsMouse)
        #expect(cap.supportsAlternateScreen)
    }
}
