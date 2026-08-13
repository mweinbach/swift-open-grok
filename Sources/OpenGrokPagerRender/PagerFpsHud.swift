// PagerFpsHud.swift
//
// Release-safe FPS readout — `/debug fps`, `GROK_FPS` on this port.
//
// Ports `views/fps_hud.rs` at pin 650c1db7. The full frame profiler
// (`FrameMetrics`) is absent here, so this HUD owns the `GROK_FPS` env
// gate (`HONORS_GROK_FPS_ENV = true` in the reference's release-shaped
// builds). Do not consult `[animation].show_fps`, `GROK_NO_MOTION`,
// settings, or FrameMetrics — those are a different overlay.
//
// Mutable and Sendable so a live actor can hold it and snapshot a
// preformatted `PagerFpsHudOverlay` onto `PagerRenderState` each frame.
// The HUD object itself must not cross into render state.

import Foundation
import OpenGrokTerminalCore

/// Frame-duration ring buffer capacity (~4s at 30fps). `SAMPLE_CAP`.
public let pagerFpsHudSampleCapacity = 120
/// Overlay text refresh cadence; avoids re-sorting/formatting every frame.
public let pagerFpsHudRefreshInterval: TimeInterval = 0.250
/// Panel width in cells; each line is padded/truncated to this.
public let pagerFpsHudPanelWidth = 32
/// Title row, yellow on black (`fps_hud.rs:156`).
public let pagerFpsHudTitle = "fps debug  (/debug fps)"
/// Placeholder stats line before any samples (`format_stats` empty arm).
public let pagerFpsHudEmptyBody = "fps:- p50:- p95:-"

/// This HUD owns `GROK_FPS` because the dev `FrameMetrics` overlay is not
/// compiled in. Matches `HONORS_GROK_FPS_ENV: bool = true`.
public let pagerFpsHudHonorsGrokFpsEnvironment = true

/// Env-var name the live owner reads into `PagerFpsHud(environmentValue:)`.
public let pagerFpsHudEnvironmentVariable = "GROK_FPS"

/// Truthiness rule shared with `FrameMetrics` and `GROK_SCROLL_DEBUG`:
/// nonempty and not `"0"`. Empty / missing / `"0"` are off; `"1"`, `"full"`,
/// and `" "` are on.
public func pagerFpsHudEnvironmentIsTruthy(_ value: String?) -> Bool {
    guard let value, !value.isEmpty, value != "0" else { return false }
    return true
}

/// Owned per-frame render params (`None` unless enabled). Sendable snapshot
/// for `PagerRenderState` — never the HUD itself.
public struct PagerFpsHudOverlay: Sendable, Equatable {
    /// Cached stats line (`fps:{:.0} p50:{:.1}ms p95:{:.1}ms` or the
    /// empty placeholder).
    public var body: String
    /// Rows left free for overlays stacked above (the absent dev `GROK_FPS`
    /// line). Live owner passes `0`.
    public var topOffset: Int

    public init(body: String, topOffset: Int = 0) {
        self.body = body
        self.topOffset = max(0, topOffset)
    }
}

/// Runtime FPS HUD. `GROK_FPS` enables it at startup; `/debug fps` toggles
/// it live. Deliberately not a settings-registry entry.
///
/// Live owner:
/// - hold one instance in the session actor (`PagerFpsHud()` reads env)
/// - `/debug fps` → `toggle()`
/// - each layout: `currentOverlay(topOffset: 0)` → `PagerRenderState.fpsHud`
///   (nonmutating snapshot; must not consume the 250ms refresh)
/// - after a real paint+flush, `record(elapsedSeconds)` then
///   `refreshOverlayCache(now:)` so the *next* paint can show new stats
public struct PagerFpsHud: Sendable {
    public private(set) var isEnabled: Bool
    var samplesMilliseconds: [Double]
    var body: String
    /// Monotonic seconds of the last stats rewrite; `nil` forces a refresh.
    var lastRefresh: TimeInterval?

    public init() {
        self.init(environmentValue: ProcessInfo.processInfo.environment[pagerFpsHudEnvironmentVariable])
    }

    /// `environmentValue` is the raw `GROK_FPS` value. Tests pass `nil` /
    /// `"0"` / `"1"` rather than reading process env.
    public init(environmentValue: String?) {
        let envOn = pagerFpsHudHonorsGrokFpsEnvironment
            && pagerFpsHudEnvironmentIsTruthy(environmentValue)
        self.isEnabled = envOn
        self.samplesMilliseconds = []
        self.body = ""
        self.lastRefresh = nil
    }

    /// Rows the overlay occupies when enabled (for stacking overlays).
    public var overlayHeight: Int {
        isEnabled ? 2 : 0
    }

    /// `/debug fps` runtime toggle. Clears the ring and the cached line so
    /// a fresh enablement shows placeholders, not stale stats.
    public mutating func toggle() {
        isEnabled.toggle()
        samplesMilliseconds.removeAll(keepingCapacity: true)
        body = ""
        lastRefresh = nil
    }

    /// Record one frame's `draw_frame` wall duration in seconds. No-op while
    /// disabled. Caps at `pagerFpsHudSampleCapacity`.
    public mutating func record(_ frameDuration: TimeInterval) {
        guard isEnabled else { return }
        if samplesMilliseconds.count >= pagerFpsHudSampleCapacity {
            samplesMilliseconds.removeFirst()
        }
        samplesMilliseconds.append(frameDuration * 1000.0)
    }

    /// Nonmutating snapshot of the cached overlay. Does **not** rewrite
    /// `body` or consume the 250ms refresh — action-time layouts
    /// (`currentPageScrollRows`) and coalesced frames must call this, not
    /// `overlay(now:)`. Empty cache paints the placeholder. `nil` while
    /// disabled.
    public func currentOverlay(topOffset: Int = 0) -> PagerFpsHudOverlay? {
        guard isEnabled else { return nil }
        return PagerFpsHudOverlay(
            body: body.isEmpty ? pagerFpsHudEmptyBody : body,
            topOffset: topOffset
        )
    }

    /// Rewrite the cached stats line at most every 250ms. Call only after a
    /// real paint so unpainted layouts cannot steal the cadence from the
    /// next committed frame. Pass a monotonic `now`; do not hide a clock
    /// inside the HUD.
    public mutating func refreshOverlayCache(now: TimeInterval) {
        guard isEnabled else { return }
        let needsRefresh: Bool
        if let lastRefresh {
            needsRefresh = now - lastRefresh >= pagerFpsHudRefreshInterval
        } else {
            needsRefresh = true
        }
        if needsRefresh {
            body = pagerFormatFpsStats(samplesMilliseconds: samplesMilliseconds)
            lastRefresh = now
        }
    }

    /// Refresh-then-snapshot. Package tests pin the 250ms cadence through
    /// this mutating entry; the live owner uses `currentOverlay` on layout
    /// and `refreshOverlayCache` only after a committed paint.
    public mutating func overlay(topOffset: Int, now: TimeInterval) -> PagerFpsHudOverlay? {
        refreshOverlayCache(now: now)
        return currentOverlay(topOffset: topOffset)
    }
}

/// Mean/percentile line from the ring buffer; placeholder before samples.
/// Mean FPS is `1000/mean_ms`; `mean_ms <= 1e-6` → `0`. p50/p95 are linear
/// interpolation on the sorted millisecond samples.
public func pagerFormatFpsStats(samplesMilliseconds: [Double]) -> String {
    if samplesMilliseconds.isEmpty {
        return pagerFpsHudEmptyBody
    }
    var ms = samplesMilliseconds
    ms.sort { a, b in
        switch (a.isNaN, b.isNaN) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): return a < b
        }
    }
    let meanMs = ms.reduce(0, +) / Double(ms.count)
    let fps = meanMs > 1e-6 ? 1000.0 / meanMs : 0.0
    let p50 = pagerFpsPercentile(sorted: ms, percent: 50)
    let p95 = pagerFpsPercentile(sorted: ms, percent: 95)
    // POSIX so `{:.0}` / `{:.1}` stay `.`-decimal regardless of host locale.
    // Pass Doubles as `[CVarArg]` — `[NSNumber]` is the wrong ABI for `%f`
    // on this toolchain and paints `fps:-0 p50:-0.0ms…`.
    return String(
        format: "fps:%.0f p50:%.1fms p95:%.1fms",
        locale: Locale(identifier: "en_US_POSIX"),
        arguments: [fps, p50, p95] as [CVarArg]
    )
}

/// Linear-interpolation percentile from a sorted slice (`percentile` in
/// `fps_hud.rs:129-140`).
public func pagerFpsPercentile(sorted: [Double], percent: Double) -> Double {
    if sorted.isEmpty { return 0 }
    let rank = (percent / 100.0) * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    if lower + 1 >= sorted.count {
        return sorted[lower]
    }
    let frac = rank - Double(lower)
    return sorted[lower] + (sorted[lower + 1] - sorted[lower]) * frac
}

/// Paint the two-line panel in the top-right corner of `area`, theme-agnostic
/// debug chrome on every cell including padding (`FpsOverlay::render`).
public func renderPagerFpsHudOverlay(
    _ overlay: PagerFpsHudOverlay,
    area: TerminalRect,
    buffer: inout CellBuffer
) {
    renderPagerDebugPanel(
        area: area,
        buffer: &buffer,
        topOffset: overlay.topOffset,
        width: pagerFpsHudPanelWidth,
        lines: [pagerFpsHudTitle, overlay.body]
    )
}

/// Theme-agnostic debug panel hugging `area`'s right edge, `top_offset` rows
/// down: first line yellow on black, the rest white on black, every line
/// truncated/padded to `width` so explicit debug chrome covers the whole
/// rect (`debug_style::render_panel`). Modifiers are empty — painting
/// replaces the cell, shedding whatever themed bold/italic sat underneath.
func renderPagerDebugPanel(
    area: TerminalRect,
    buffer: inout CellBuffer,
    topOffset: Int,
    width: Int,
    lines: [String]
) {
    let w = min(max(0, width), area.width)
    if w == 0 { return }
    let x = area.x + area.width - w
    let y0 = area.y + max(0, topOffset)
    let bottom = area.y + area.height
    if y0 >= bottom { return }
    let h = min(lines.count, bottom - y0)
    if h <= 0 { return }
    paintBlank(
        &buffer,
        area: TerminalRect(x: x, y: y0, width: w, height: h),
        foreground: .white,
        background: .black
    )
    for (index, line) in lines.prefix(h).enumerated() {
        var text = String(line.prefix(w))
        while text.count < w {
            text.append(" ")
        }
        let isTitle = index == 0
        _ = buffer.setString(
            x: x,
            y: y0 + index,
            text: text,
            style: [],
            foreground: isTitle ? .yellow : .white,
            background: .black
        )
    }
}
