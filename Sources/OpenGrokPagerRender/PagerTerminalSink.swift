import Foundation
import OpenGrokTerminalCore

public enum PagerTerminalMode: Sendable, Equatable {
    case fullscreen
    case inline(height: Int)
}

public struct PagerTerminalCapabilities: Sendable, Equatable {
    public var colorDepth: TerminalColorDepth
    public var supportsCursorPositioning: Bool
    public var supportsCursorVisibility: Bool
    public var supportsHyperlinks: Bool
    public var supportsSynchronizedOutput: Bool
    public var supportsAlternateScreen: Bool

    public init(
        colorDepth: TerminalColorDepth = .trueColor,
        supportsCursorPositioning: Bool = true,
        supportsCursorVisibility: Bool = true,
        supportsHyperlinks: Bool = true,
        supportsSynchronizedOutput: Bool = true,
        supportsAlternateScreen: Bool = true
    ) {
        self.colorDepth = colorDepth
        self.supportsCursorPositioning = supportsCursorPositioning
        self.supportsCursorVisibility = supportsCursorVisibility
        self.supportsHyperlinks = supportsHyperlinks
        self.supportsSynchronizedOutput = supportsSynchronizedOutput
        self.supportsAlternateScreen = supportsAlternateScreen
    }

    public static let standard = PagerTerminalCapabilities()

    public static let conservative = PagerTerminalCapabilities(
        colorDepth: .monochrome,
        supportsCursorPositioning: false,
        supportsCursorVisibility: false,
        supportsHyperlinks: false,
        supportsSynchronizedOutput: false,
        supportsAlternateScreen: false
    )
}

public protocol PagerTerminalSink: AnyObject {
    var capabilities: PagerTerminalCapabilities { get }
    func write(bytes: [UInt8]) throws
    func flush() throws
}

public extension PagerTerminalSink {
    func write(_ string: String) throws {
        try write(bytes: Array(string.utf8))
    }
}

public struct PagerTerminalRendererConfiguration: Sendable, Equatable {
    public var mode: PagerTerminalMode
    public var useAlternateScreen: Bool
    public var useSynchronizedOutput: Bool
    /// Emit SGR mouse-reporting enable/disable bracketed with the alternate
    /// screen. DEC private modes are scoped per screen buffer on some
    /// terminals, so the disable has to land on the buffer that saw the enable.
    public var useMouseReporting: Bool
    /// Minimum gap between coalesced frames — upstream's `min_draw_interval`
    /// (`display_refresh_startup.rs:23`). Only the `requestFrame`/
    /// `flushPendingFrame` path honors it; a bare `render` call stays
    /// unthrottled for callers that own their own pacing. Resolve this with
    /// `PagerFrameClock.cadence(environment:policy:probedRefreshHz:)` so the
    /// `GROK_MIN_DRAW_MS` override and the auto-cadence setting both apply.
    public var paintCadence: TimeInterval

    public init(
        mode: PagerTerminalMode = .fullscreen,
        useAlternateScreen: Bool = true,
        useSynchronizedOutput: Bool = true,
        useMouseReporting: Bool = false,
        paintCadence: TimeInterval = PagerMotion.defaultPaintCadence
    ) {
        self.mode = mode
        self.useAlternateScreen = useAlternateScreen
        self.useSynchronizedOutput = useSynchronizedOutput
        self.useMouseReporting = useMouseReporting
        self.paintCadence = paintCadence
    }
}

public enum PagerTerminalRendererError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedCursorPositioning
    case invalidInlineHeight(Int)
    case alreadyRestored

    public var description: String {
        switch self {
        case .unsupportedCursorPositioning:
            return "Pager terminal rendering requires cursor positioning support"
        case .invalidInlineHeight(let height):
            return "Pager inline height must be greater than zero (got \(height))"
        case .alreadyRestored:
            return "Pager terminal renderer has already been restored"
        }
    }
}

public struct PagerTerminalRenderReport: Sendable, Equatable {
    public let changedCellCount: Int
    public let didUseFullRedraw: Bool
    public let didResize: Bool
    public let usedSynchronizedOutput: Bool

    public init(
        changedCellCount: Int,
        didUseFullRedraw: Bool,
        didResize: Bool,
        usedSynchronizedOutput: Bool
    ) {
        self.changedCellCount = changedCellCount
        self.didUseFullRedraw = didUseFullRedraw
        self.didResize = didResize
        self.usedSynchronizedOutput = usedSynchronizedOutput
    }
}
