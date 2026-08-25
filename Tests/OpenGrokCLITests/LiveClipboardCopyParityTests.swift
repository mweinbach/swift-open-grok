import Foundation
import Testing
@testable import OpenGrokCLI

@Suite("Live clipboard native delivery and secure recovery")
struct LiveClipboardCopyParityTests {
    @Test("native clipboard succeeds without emitting local OSC 52")
    func nativeDelivery() throws {
        var copied = ""
        var escaped = Data()
        let result = try LivePagerClipboard.copy(
            "private text",
            environment: [:],
            nativeWrite: { value, _ in copied = value }
        ) { escaped.append($0) }

        #expect(copied == "private text")
        #if os(Linux)
        #expect(!escaped.isEmpty)
        #else
        #expect(escaped.isEmpty)
        #endif
        #expect(result == .native(backup: nil))
    }

    @Test("OSC 52 policy disables all terminal escape routes")
    func osc52KillSwitch() throws {
        var escaped = Data()
        #expect(throws: LiveClipboardCopy.Failure.noAvailableDestination) {
            try LivePagerClipboard.copy(
                "secret",
                environment: ["GROK_CLIPBOARD_NO_OSC52": "", "TMUX": "socket"],
                nativeWrite: { _, _ in throw LiveClipboardCopy.Failure.noAvailableDestination }
            ) { escaped.append($0) }
        }
        #expect(escaped.isEmpty)
    }

    @Test("owner-private recovery file remains available without clipboard")
    func privateFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("open-grok-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = [
            "OPENGROK_HOME": root.path,
            "GROK_CLIPBOARD_NO_OSC52": "1",
        ]
        let result = try LivePagerClipboard.copy(
            "confidential",
            environment: environment,
            nativeWrite: { _, _ in throw LiveClipboardCopy.Failure.noAvailableDestination }
        ) { _ in Issue.record("disabled OSC 52 must not be emitted") }

        let path = root.appendingPathComponent("last-copy.txt")
        #expect(result == .file(path))
        #expect(try String(contentsOf: path, encoding: .utf8) == "confidential")
        #if !os(Windows)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #endif
    }

    @Test("custom copy destination expands only the supplied home")
    func customDestination() {
        let result = LiveClipboardCopy.fallbackPath(environment: [
            "HOME": "/isolated/home",
            "GROK_COPY_FILE": "~/private/copy.txt",
        ])
        #expect(result?.path == "/isolated/home/private/copy.txt")
        #expect(LiveClipboardCopy.fallbackPath(environment: [:]) == nil)
    }

    @Test("symlinked recovery destinations are safely replaced without touching their target")
    func symlinkDestinationSafelyReplaced() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("open-grok-copy-link-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let protected = root.appendingPathComponent("protected")
        try "original".write(to: protected, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("last-copy.txt")
        try manager.createSymbolicLink(at: link, withDestinationURL: protected)

        let delivery = try LivePagerClipboard.copy(
            "secret",
            environment: ["OPENGROK_HOME": root.path, "GROK_CLIPBOARD_NO_OSC52": "1"],
            nativeWrite: { _, _ in throw LiveClipboardCopy.Failure.noAvailableDestination }
        ) { _ in }
        #expect(delivery == .file(link))
        #expect(try String(contentsOf: protected, encoding: .utf8) == "original")
        #expect(try String(contentsOf: link, encoding: .utf8) == "secret")
        let attributes = try manager.attributesOfItem(atPath: link.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #if !os(Windows)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #endif
    }

    @Test("tmux retains its passthrough envelope when native copy is unavailable")
    func tmuxPassthrough() throws {
        var emitted = Data()
        let result = try LivePagerClipboard.copy(
            "hello",
            environment: ["TMUX": "socket"],
            nativeWrite: { _, _ in throw LiveClipboardCopy.Failure.noAvailableDestination }
        ) { emitted.append($0) }

        let text = String(decoding: emitted, as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}Ptmux;"))
        #expect(text.hasSuffix("\u{1b}\\"))
        #expect(result == .terminal(backup: nil))
    }
}
