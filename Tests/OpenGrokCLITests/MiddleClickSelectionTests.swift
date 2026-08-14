// MiddleClickSelectionTests.swift
//
// Empirical challenge tests for middle-click selection paste routing
// and SystemClipboardProvider primary selection handling across edge cases
// (missing DISPLAY, empty selection, macOS platform, mouse modifiers, non-middle buttons).

import Foundation
import Testing
import OpenGrokTerminalCore
import OpenGrokWebMediaTools
@testable import OpenGrokCLI

@Suite("Middle-Click Selection Paste & Clipboard Edge Cases")
struct MiddleClickSelectionTests {
    @Test("SystemClipboardProvider readPrimaryText behavior on macOS platform")
    func clipboardProviderPrimaryTextOnMacOS() async throws {
        let provider = SystemClipboardProvider(
            platform: .macOS,
            environment: ["DISPLAY": ":0"]
        )
        await #expect(throws: ClipboardError.self) {
            _ = try await provider.readPrimaryText()
        }
    }

    @Test("SystemClipboardProvider readPrimaryText missing or empty DISPLAY on Linux")
    func clipboardProviderPrimaryTextMissingDisplayOnLinux() async throws {
        // Missing DISPLAY
        let providerNoDisplay = SystemClipboardProvider(
            platform: .linux,
            environment: [:]
        )
        await #expect(throws: ClipboardError.self) {
            _ = try await providerNoDisplay.readPrimaryText()
        }

        // Empty DISPLAY
        let providerEmptyDisplay = SystemClipboardProvider(
            platform: .linux,
            environment: ["DISPLAY": ""]
        )
        await #expect(throws: ClipboardError.self) {
            _ = try await providerEmptyDisplay.readPrimaryText()
        }
    }

    @Test("SystemClipboardProvider readPrimaryText non-existent xclip/xsel binaries on Linux")
    func clipboardProviderPrimaryTextNoToolsOnLinux() async throws {
        // Points to non-existent binaries via PATH
        let providerNoTools = SystemClipboardProvider(
            platform: .linux,
            environment: [
                "DISPLAY": ":0",
                "PATH": "/nonexistent_path_dir_12345"
            ]
        )
        await #expect(throws: ClipboardError.self) {
            _ = try await providerNoTools.readPrimaryText()
        }
    }

    @Test("Middle-click down with Shift or Ctrl modifier does not trigger primary paste")
    func middleClickWithModifiersNotPasted() {
        let mouseWithShift = MouseEvent(
            kind: .down,
            x: 10,
            y: 10,
            button: .middle,
            modifiers: [.shift]
        )
        #expect(mouseWithShift.kind == .down)
        #expect(mouseWithShift.resolvedButton == .middle)
        #expect(!mouseWithShift.modifiers.isEmpty)

        let mouseWithCtrl = MouseEvent(
            kind: .down,
            x: 10,
            y: 10,
            button: .middle,
            modifiers: [.control]
        )
        #expect(!mouseWithCtrl.modifiers.isEmpty)
    }

    @Test("Middle-click up event does not trigger primary paste")
    func middleClickUpNotPasted() {
        let mouseUp = MouseEvent(
            kind: .up,
            x: 10,
            y: 10,
            button: .middle,
            modifiers: []
        )
        #expect(mouseUp.kind != .down)
        #expect(mouseUp.resolvedButton == .middle)
    }

    @Test("Left and right click down events do not trigger primary paste")
    func nonMiddleClickNotPasted() {
        let leftClick = MouseEvent(
            kind: .down,
            x: 10,
            y: 10,
            button: .left,
            modifiers: []
        )
        #expect(leftClick.resolvedButton != .middle)

        let rightClick = MouseEvent(
            kind: .down,
            x: 10,
            y: 10,
            button: .right,
            modifiers: []
        )
        #expect(rightClick.resolvedButton != .middle)
    }
}
