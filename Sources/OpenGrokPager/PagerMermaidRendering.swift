import Foundation
import OpenGrokMermaid
import OpenGrokPagerRender
import OpenGrokTerminalCore

public struct PagerMermaidRender: Sendable, Equatable {
    public var lines: [String]

    public init(lines: [String]) {
        self.lines = lines
    }
}

public final class PagerMermaidWorker: @unchecked Sendable {
    public typealias RenderFunction = @Sendable (String, Int) -> PagerMermaidRender?

    private struct Key: Hashable {
        var source: String
        var width: Int
    }

    private enum Cached {
        case ready(PagerMermaidRender)
        case failed
    }

    public static let shared = PagerMermaidWorker()

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let timeout: TimeInterval
    private let renderFunction: RenderFunction
    private var cache: [Key: Cached] = [:]
    private var inFlight: [Key: DispatchGroup] = [:]

    public init(
        timeout: TimeInterval = 3,
        renderFunction: RenderFunction? = nil
    ) {
        self.timeout = max(0.01, timeout)
        self.renderFunction = renderFunction ?? Self.renderDefault
        queue = DispatchQueue(label: "open-grok.mermaid-render", qos: .userInitiated, attributes: .concurrent)
    }

    public func render(source: String, width: Int) -> PagerMermaidRender? {
        let key = Key(source: source, width: max(16, width))
        let group: DispatchGroup
        var shouldStart = false

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return value(from: cached)
        }
        if let pending = inFlight[key] {
            group = pending
        } else {
            group = DispatchGroup()
            group.enter()
            inFlight[key] = group
            shouldStart = true
        }
        lock.unlock()

        if shouldStart {
            queue.async { [self] in
                let rendered = renderFunction(key.source, key.width)
                lock.lock()
                cache[key] = rendered.map(Cached.ready) ?? .failed
                inFlight.removeValue(forKey: key)
                lock.unlock()
                group.leave()
            }
        }

        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        return cached.flatMap(value(from:))
    }

    public func removeAllCached() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func value(from cached: Cached) -> PagerMermaidRender? {
        switch cached {
        case .ready(let render): return render
        case .failed: return nil
        }
    }

    private static func renderDefault(source: String, width: Int) -> PagerMermaidRender? {
        guard let diagram = try? MermaidRenderer.parse(source) else { return nil }
        return PagerMermaidUnicodeRenderer.render(
            MermaidRenderer.layout(diagram),
            width: width
        )
    }
}

enum PagerMermaidUnicodeRenderer {
    static func render(_ layout: MermaidLayoutResult, width: Int) -> PagerMermaidRender? {
        guard !layout.nodes.isEmpty, layout.width > 0, layout.height > 0 else { return nil }

        let canvasWidth = min(100, max(16, width))
        let aspect = max(0.25, layout.width / layout.height)
        let canvasHeight = min(24, max(5, Int((Double(canvasWidth) / aspect * 0.45).rounded())))
        var canvas = Array(
            repeating: Array(repeating: Character(" "), count: canvasWidth),
            count: canvasHeight
        )

        func point(x: Double, y: Double) -> (x: Int, y: Int) {
            let normalizedX = min(1, max(0, x / layout.width))
            let normalizedY = min(1, max(0, y / layout.height))
            return (
                min(canvasWidth - 2, max(1, Int((normalizedX * Double(canvasWidth - 3)).rounded()) + 1)),
                min(canvasHeight - 2, max(1, Int((normalizedY * Double(canvasHeight - 3)).rounded()) + 1))
            )
        }

        for edge in layout.edges {
            let points = edge.points.map { point(x: $0.x, y: $0.y) }
            guard points.count >= 2 else { continue }
            for index in 1..<points.count {
                drawOrthogonal(from: points[index - 1], to: points[index], on: &canvas)
            }
        }

        for node in layout.nodes {
            let center = point(x: node.x, y: node.y)
            drawNode(label: node.label.isEmpty ? node.id : node.label, center: center, on: &canvas)
        }

        var lines = canvas.map { row in
            var text = String(row)
            while text.last == " " { text.removeLast() }
            return text
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return PagerMermaidRender(lines: lines)
    }

    private static func drawOrthogonal(
        from: (x: Int, y: Int),
        to: (x: Int, y: Int),
        on canvas: inout [[Character]]
    ) {
        let corner = (x: to.x, y: from.y)
        drawHorizontal(fromX: from.x, toX: corner.x, y: from.y, on: &canvas)
        drawVertical(fromY: corner.y, toY: to.y, x: corner.x, on: &canvas)
        set("┼", x: corner.x, y: corner.y, on: &canvas, replacingBlankOnly: true)
    }

    private static func drawHorizontal(
        fromX: Int,
        toX: Int,
        y: Int,
        on canvas: inout [[Character]]
    ) {
        let lower = min(fromX, toX)
        let upper = max(fromX, toX)
        guard lower <= upper else { return }
        for x in lower...upper {
            set("─", x: x, y: y, on: &canvas, replacingBlankOnly: true)
        }
    }

    private static func drawVertical(
        fromY: Int,
        toY: Int,
        x: Int,
        on canvas: inout [[Character]]
    ) {
        let lower = min(fromY, toY)
        let upper = max(fromY, toY)
        guard lower <= upper else { return }
        for y in lower...upper {
            set("│", x: x, y: y, on: &canvas, replacingBlankOnly: true)
        }
    }

    private static func drawNode(
        label: String,
        center: (x: Int, y: Int),
        on canvas: inout [[Character]]
    ) {
        guard let rowWidth = canvas.first?.count, rowWidth >= 5, canvas.count >= 3 else { return }
        let maximumLabelWidth = max(1, min(24, rowWidth - 4))
        let renderedLabel = truncateLabel(
            label.replacingOccurrences(of: "\n", with: " "),
            width: maximumLabelWidth
        )
        let boxWidth = min(rowWidth, max(5, UnicodeDisplayWidth.width(of: renderedLabel) + 4))
        let left = min(max(0, center.x - boxWidth / 2), rowWidth - boxWidth)
        let top = min(max(0, center.y - 1), canvas.count - 3)
        let right = left + boxWidth - 1

        set("┌", x: left, y: top, on: &canvas)
        set("┐", x: right, y: top, on: &canvas)
        set("└", x: left, y: top + 2, on: &canvas)
        set("┘", x: right, y: top + 2, on: &canvas)
        for x in (left + 1)..<right {
            set("─", x: x, y: top, on: &canvas)
            set("─", x: x, y: top + 2, on: &canvas)
        }
        set("│", x: left, y: top + 1, on: &canvas)
        set("│", x: right, y: top + 1, on: &canvas)

        let labelStart = left + max(1, (boxWidth - renderedLabel.count) / 2)
        for (offset, character) in renderedLabel.enumerated() where labelStart + offset < right {
            set(character, x: labelStart + offset, y: top + 1, on: &canvas)
        }
    }

    private static func set(
        _ character: Character,
        x: Int,
        y: Int,
        on canvas: inout [[Character]],
        replacingBlankOnly: Bool = false
    ) {
        guard canvas.indices.contains(y), canvas[y].indices.contains(x) else { return }
        if replacingBlankOnly, canvas[y][x] != " " { return }
        canvas[y][x] = character
    }

    private static func truncateLabel(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        var result = ""
        var used = 0
        for character in text {
            let characterWidth = max(0, UnicodeDisplayWidth.width(ofGrapheme: String(character)))
            guard used + characterWidth <= width else { break }
            result.append(character)
            used += characterWidth
        }
        return result
    }
}
