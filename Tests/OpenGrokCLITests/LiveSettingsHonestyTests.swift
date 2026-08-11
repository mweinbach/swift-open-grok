import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import Testing
@testable import OpenGrokCLI

private final class SettingsDiscardingSink: PagerTerminalSink, @unchecked Sendable {
    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes: [UInt8]) throws {}

    func flush() throws {}
}

private func makeSettingsRenderer() -> LiveInteractiveControllerRenderer {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
        "opengrok-settings-honesty-\(UUID().uuidString)",
        isDirectory: true
    )
    let terminal = OpenGrokLiveTerminal(
        isTTY: { false },
        size: { OpenGrokLiveTerminalSize(width: 120, height: 40) },
        write: { _ in }
    )
    return LiveInteractiveControllerRenderer(
        mode: .fullScreen,
        terminal: terminal,
        sink: SettingsDiscardingSink(),
        workingDirectory: home.path,
        modelName: "test-model",
        sessionID: "settings-honesty",
        openGrokHome: home,
        environment: [
            "HOME": home.path,
            "OPENGROK_HOME": home.path,
        ]
    )
}

@Suite("Live settings honesty")
struct LiveSettingsHonestyTests {
    @Test("unsupported capability rows are absent from the live overlay")
    func unsupportedRowsAreAbsent() async {
        let overlay = await makeSettingsRenderer().settingsOverlay()
        let visibleKeys = Set(overlay.visibleRows.compactMap(\.settingKey))
        let voiceHidden = LiveVoiceCapabilities.hiddenSettingsKeys(
            when: LiveVoiceComposition.resolveCapabilities()
        )
        var unsupportedKeys: Set<String> = [
            "antigravity_subagents",
            "antigravity_skip_permissions",
        ]
        unsupportedKeys.formUnion(voiceHidden)

        #expect(visibleKeys.isDisjoint(with: unsupportedKeys))
        #expect(unsupportedKeys.allSatisfy { overlay.registry.find($0) != nil })
        // Dream and LSP are live; they must appear once their seams exist.
        #expect(visibleKeys.contains("memory.dream.enabled"))
        #expect(visibleKeys.contains("features.lsp_tools"))
        #expect(visibleKeys.isSuperset(of: [
            "permission_mode",
            "memory.enabled",
            "features.web_fetch",
        ]))
    }

    @Test("auto permission mode is offered once the heuristic classifier is live")
    func autoChoiceIsPresent() async throws {
        let overlay = await makeSettingsRenderer().settingsOverlay()
        let permissionMode = try #require(overlay.registry.find("permission_mode"))

        #expect(overlay.choices(for: permissionMode).map(\.canonical) == [
            "default",
            "ask",
            "auto",
            "always-approve",
        ])
    }
}
