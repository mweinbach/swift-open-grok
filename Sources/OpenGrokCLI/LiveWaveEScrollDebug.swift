import Foundation
import OpenGrokPagerRender

extension LiveInteractiveControllerRenderer {
    static func waveEScrollLogURL(
        environmentValue: String?,
        openGrokHome: URL
    ) -> URL? {
        guard let environmentValue else { return nil }
        let value = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != "0" else { return nil }
        if value.isEmpty || value == "1" {
            return defaultWaveEScrollLogURL(openGrokHome: openGrokHome)
        }
        return URL(fileURLWithPath: value)
    }

    static func defaultWaveEScrollLogURL(openGrokHome: URL) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return openGrokHome
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("scroll-log-\(timestamp).jsonl")
    }

    func currentScrollDebugOverlay() -> PagerScrollDebugOverlay {
        scrollDebugOverlay ?? PagerScrollDebugOverlay(
            rawDelta: 0,
            normalizedDelta: 0,
            scrollOffset: scrollOffset,
            maximumOffset: lastMaximumScrollOffset,
            followingTail: followsBottom
        )
    }

    func updateScrollDiagnostics(
        rawDelta: Int,
        normalizedDelta: Int,
        trigger: String,
        now: TimeInterval
    ) {
        let overlay = PagerScrollDebugOverlay(
            rawDelta: rawDelta,
            normalizedDelta: normalizedDelta,
            scrollOffset: scrollOffset,
            maximumOffset: lastMaximumScrollOffset,
            followingTail: followsBottom
        )
        scrollDebugOverlay = overlay
        guard let url = scrollLogURL else { return }

        let record: [String: Any] = [
            "timestamp_ms": now * 1_000,
            "trigger": trigger,
            "raw_delta": rawDelta,
            "normalized_delta": normalizedDelta,
            "scroll_offset": overlay.scrollOffset,
            "maximum_offset": overlay.maximumOffset,
            "following_tail": overlay.followingTail,
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) + Data([0x0A])
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    scrollLogURL = nil
                    return
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            scrollLogURL = nil
        }
    }
}
