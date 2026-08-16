import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

enum LiveGboomPhase: Sendable, Equatable {
    case title
    case playing
    case won
    case dead
}

enum LiveGboomKeyOutcome: Sendable, Equatable {
    case close
    case changed
}

struct LiveGboomHud: Sendable, Equatable {
    var phase: LiveGboomPhase
    var hp: Int
    var kills: Int
    var total: Int
}

struct LiveGboomEnemy: Sendable, Equatable {
    var x: Double
    var y: Double
    var hp: Int
    var attackCooldown = 0.0

    var isAlive: Bool { hp > 0 }
}

struct LiveGboomState: Sendable {
    private static let fieldOfView = Double.pi / 3
    private static let map: [[UInt8]] = [
        Array("111111111111".utf8),
        Array("1..........1".utf8),
        Array("1.P..I.....1".utf8),
        Array("1..11......1".utf8),
        Array("1......2...1".utf8),
        Array("1..I.......1".utf8),
        Array("1.....33...1".utf8),
        Array("1.........I1".utf8),
        Array("1...4......1".utf8),
        Array("1.I........1".utf8),
        Array("1..........1".utf8),
        Array("111111111111".utf8),
    ]

    private(set) var phase: LiveGboomPhase = .title
    private(set) var playerX = 2.5
    private(set) var playerY = 2.5
    private(set) var playerAngle = 0.0
    private(set) var playerHP = 100
    private(set) var kills = 0
    private(set) var enemies: [LiveGboomEnemy]
    private var phaseTime = 0.0
    private var worldTime = 0.0
    private var lastTickSeconds: TimeInterval?
    private var lastMouseX: Int?
    private var generation: UInt64 = 0
    private var cachedFrame: (UInt64, Int, Int, Data)?

    init() {
        var result: [LiveGboomEnemy] = []
        for y in Self.map.indices {
            for x in Self.map[y].indices where Self.map[y][x] == Character("I").asciiValue {
                result.append(LiveGboomEnemy(x: Double(x) + 0.5, y: Double(y) + 0.5, hp: 100))
            }
        }
        enemies = result
    }

    var hud: LiveGboomHud {
        LiveGboomHud(phase: phase, hp: playerHP, kills: kills, total: enemies.count)
    }

    static func frameSizeForCells(cols: Int, rows: Int) -> (width: Int, height: Int) {
        var width = max(64, cols * 8)
        var height = max(64, rows * 16)
        let scale = min(1, min(480.0 / Double(width), 320.0 / Double(height)))
        width = max(64, Int(Double(width) * scale))
        height = max(64, Int(Double(height) * scale))
        return (width, height)
    }

    mutating func tick(seconds: TimeInterval) {
        let delta = lastTickSeconds.map { min(0.1, max(0, seconds - $0)) } ?? 0
        lastTickSeconds = seconds
        phaseTime += delta
        worldTime += delta
        if phase == .playing, delta > 0 {
            stepEnemies(delta: delta)
            if playerHP <= 0 {
                setPhase(.dead)
            } else if kills == enemies.count {
                setPhase(.won)
            }
        }
        generation &+= 1
    }

    mutating func handleKey(_ event: KeyEvent) -> LiveGboomKeyOutcome {
        if event.modifiers.subtracting(.shift).isEmpty {
            if event.key == .escape { return .close }
            if case .char(let character) = event.key, character.lowercased() == "q" {
                return .close
            }
        }
        switch phase {
        case .title:
            setPhase(.playing)
        case .playing:
            switch event.key {
            case .up, .char("w"), .char("W"): move(distance: 0.28, strafe: 0)
            case .down, .char("s"), .char("S"): move(distance: -0.24, strafe: 0)
            case .char("a"), .char("A"): move(distance: 0, strafe: -0.24)
            case .char("d"), .char("D"): move(distance: 0, strafe: 0.24)
            case .left: playerAngle = normalizeAngle(playerAngle - 0.14)
            case .right: playerAngle = normalizeAngle(playerAngle + 0.14)
            case .enter, .char(" "): fire()
            default: break
            }
            generation &+= 1
        case .won, .dead:
            if phaseTime >= 0.8 { return .close }
        }
        return .changed
    }

    mutating func handleMouse(_ event: MouseEvent, region: TerminalRect) {
        guard phase == .playing else { return }
        guard region.contains(x: event.x, y: event.y) else {
            lastMouseX = nil
            return
        }
        switch event.kind {
        case .down where event.button == 0:
            fire()
        case .move, .drag:
            if let lastMouseX {
                let delta = min(12, max(-12, event.x - lastMouseX))
                playerAngle = normalizeAngle(playerAngle + Double(delta) * 0.035)
                generation &+= 1
            }
            lastMouseX = event.x
        default:
            break
        }
    }

    mutating func framePNG(width: Int, height: Int) -> Data? {
        guard width >= 8, height >= 8 else { return nil }
        if let cachedFrame,
           cachedFrame.0 == generation,
           cachedFrame.1 == width,
           cachedFrame.2 == height {
            return cachedFrame.3
        }
        var frame = LiveGboomFrameBuffer(width: width, height: height)
        switch phase {
        case .title: renderTitle(into: &frame)
        case .playing: renderWorld(into: &frame)
        case .won: renderEnd(into: &frame, color: (255, 214, 80))
        case .dead: renderEnd(into: &frame, color: (214, 43, 43))
        }
        guard let png = LiveGboomPNG.encodeRGB(pixels: frame.pixels, width: width, height: height) else {
            return nil
        }
        cachedFrame = (generation, width, height, png)
        return png
    }

    private mutating func setPhase(_ next: LiveGboomPhase) {
        phase = next
        phaseTime = 0
        lastMouseX = nil
        generation &+= 1
    }

    private mutating func move(distance: Double, strafe: Double) {
        let forwardX = cos(playerAngle)
        let forwardY = sin(playerAngle)
        let nextX = playerX + forwardX * distance - forwardY * strafe
        let nextY = playerY + forwardY * distance + forwardX * strafe
        if !isBlocked(x: nextX, y: playerY) { playerX = nextX }
        if !isBlocked(x: playerX, y: nextY) { playerY = nextY }
    }

    private mutating func fire() {
        var target: (index: Int, distance: Double)?
        for index in enemies.indices where enemies[index].isAlive {
            let dx = enemies[index].x - playerX
            let dy = enemies[index].y - playerY
            let distance = hypot(dx, dy)
            let difference = abs(normalizeAngle(atan2(dy, dx) - playerAngle))
            guard difference < 0.11,
                  hasLineOfSight(toX: enemies[index].x, y: enemies[index].y) else { continue }
            if target == nil || distance < target!.distance { target = (index, distance) }
        }
        if let target {
            enemies[target.index].hp -= 50
            if enemies[target.index].hp <= 0 { kills += 1 }
        }
        generation &+= 1
    }

    private mutating func stepEnemies(delta: Double) {
        var damage = 0
        for index in enemies.indices where enemies[index].isAlive {
            enemies[index].attackCooldown = max(0, enemies[index].attackCooldown - delta)
            let dx = playerX - enemies[index].x
            let dy = playerY - enemies[index].y
            let distance = max(0.001, hypot(dx, dy))
            guard distance < 7.5,
                  hasLineOfSight(fromX: enemies[index].x, y: enemies[index].y, toX: playerX, y: playerY)
            else { continue }
            if distance < 0.85 {
                if enemies[index].attackCooldown == 0 {
                    damage += 7
                    enemies[index].attackCooldown = 0.8
                }
                continue
            }
            let step = min(distance - 0.8, delta * 0.65)
            let nextX = enemies[index].x + dx / distance * step
            let nextY = enemies[index].y + dy / distance * step
            if !isBlocked(x: nextX, y: enemies[index].y) { enemies[index].x = nextX }
            if !isBlocked(x: enemies[index].x, y: nextY) { enemies[index].y = nextY }
        }
        playerHP = max(0, playerHP - damage)
    }

    private func renderTitle(into frame: inout LiveGboomFrameBuffer) {
        renderFire(into: &frame, intensity: 0.72)
        frame.drawLogo(y: frame.height / 6, scale: max(2, min(10, frame.width / 38)))
    }

    private func renderEnd(into frame: inout LiveGboomFrameBuffer, color: (UInt8, UInt8, UInt8)) {
        renderFire(into: &frame, intensity: 0.52)
        let size = min(frame.width, frame.height) / 3
        frame.fillRect(
            x: (frame.width - size) / 2,
            y: frame.height / 5,
            width: size,
            height: size,
            color: color
        )
        frame.fillRect(
            x: frame.width / 2 - size / 5,
            y: frame.height / 5 + size / 2,
            width: size * 2 / 5,
            height: size / 2,
            color: (12, 8, 8)
        )
    }

    private func renderFire(into frame: inout LiveGboomFrameBuffer, intensity: Double) {
        frame.fill((7, 7, 9))
        let horizon = Int(Double(frame.height) * 0.42)
        for y in horizon..<frame.height {
            let vertical = Double(y - horizon) / Double(max(1, frame.height - horizon))
            for x in 0..<frame.width {
                let wave = sin(Double(x) * 0.085 + worldTime * 4.2)
                    + sin(Double(x) * 0.031 - worldTime * 7.1)
                let flame = max(0, vertical + wave * 0.12 - Double((x * 17 + y * 31) % 19) / 180)
                frame.setPixel(x: x, y: y, color: (
                    UInt8(clamping: Int(255 * min(1, flame * 1.55 * intensity))),
                    UInt8(clamping: Int(150 * min(1, max(0, flame - 0.18) * 1.9 * intensity))),
                    UInt8(clamping: Int(38 * min(1, max(0, flame - 0.58) * 2.8 * intensity)))
                ))
            }
        }
    }

    private func renderWorld(into frame: inout LiveGboomFrameBuffer) {
        let horizon = frame.height / 2
        for y in 0..<frame.height {
            let t = Double(y) / Double(max(1, frame.height - 1))
            let color: (UInt8, UInt8, UInt8) = y < horizon
                ? (UInt8(clamping: 14 + Int(14 * t)), UInt8(clamping: 14 + Int(12 * t)), UInt8(clamping: 20 + Int(15 * t)))
                : (UInt8(clamping: 30 - Int(15 * t)), UInt8(clamping: 24 - Int(11 * t)), UInt8(clamping: 22 - Int(8 * t)))
            for x in 0..<frame.width { frame.setPixel(x: x, y: y, color: color) }
        }
        var depths = Array(repeating: 30.0, count: frame.width)
        for x in 0..<frame.width {
            let camera = (Double(x) / Double(max(1, frame.width - 1)) - 0.5) * Self.fieldOfView
            let rayAngle = playerAngle + camera
            let rayX = cos(rayAngle)
            let rayY = sin(rayAngle)
            var distance = 0.03
            var wall: UInt8 = 49
            while distance < 24 {
                wall = mapValue(x: playerX + rayX * distance, y: playerY + rayY * distance)
                if wall != 0 { break }
                distance += 0.025
            }
            let corrected = max(0.05, distance * cos(camera))
            depths[x] = corrected
            let wallHeight = min(frame.height * 2, Int(Double(frame.height) / corrected))
            let top = max(0, horizon - wallHeight / 2)
            let bottom = min(frame.height, horizon + wallHeight / 2)
            let base: (Int, Int, Int)
            switch wall {
            case 50: base = (112, 73, 43)
            case 51: base = (78, 90, 108)
            case 52: base = (91, 61, 96)
            default: base = (126, 46, 38)
            }
            let shade = max(0.24, min(1, 1.6 / corrected))
            let color = (
                UInt8(clamping: Int(Double(base.0) * shade)),
                UInt8(clamping: Int(Double(base.1) * shade)),
                UInt8(clamping: Int(Double(base.2) * shade))
            )
            for y in top..<bottom { frame.setPixel(x: x, y: y, color: color) }
        }
        let projected = enemies.enumerated().compactMap { index, enemy -> (Int, Double, Double)? in
            guard enemy.isAlive else { return nil }
            let dx = enemy.x - playerX
            let dy = enemy.y - playerY
            let distance = hypot(dx, dy)
            let angle = normalizeAngle(atan2(dy, dx) - playerAngle)
            return abs(angle) < Self.fieldOfView * 0.65 ? (index, distance, angle) : nil
        }.sorted { $0.1 > $1.1 }
        for (index, distance, angle) in projected {
            let centerX = Int((angle / Self.fieldOfView + 0.5) * Double(frame.width))
            let size = min(frame.height, max(8, Int(Double(frame.height) / max(0.25, distance) * 0.72)))
            let top = horizon - size / 2
            let left = centerX - size / 2
            for spriteY in 0..<size {
                let normalizedY = (Double(spriteY) / Double(max(1, size - 1)) - 0.5) * 2
                for spriteX in 0..<size {
                    let normalizedX = (Double(spriteX) / Double(max(1, size - 1)) - 0.5) * 2
                    guard normalizedX * normalizedX + normalizedY * normalizedY < 0.72 else { continue }
                    let x = left + spriteX
                    let y = top + spriteY
                    guard frame.contains(x: x, y: y), depths[x] > distance else { continue }
                    let eye = abs(normalizedY + 0.22) < 0.08 && abs(abs(normalizedX) - 0.24) < 0.09
                    frame.setPixel(x: x, y: y, color: eye
                        ? (255, 215, 72)
                        : enemies[index].hp < 100 ? (238, 82, 55) : (177, 52, 38))
                }
            }
        }
        let centerX = frame.width / 2
        let centerY = frame.height / 2
        for offset in -6...6 where abs(offset) > 1 {
            frame.setPixel(x: centerX + offset, y: centerY, color: (240, 230, 205))
            frame.setPixel(x: centerX, y: centerY + offset, color: (240, 230, 205))
        }
        let gunWidth = max(18, frame.width / 7)
        let gunTop = frame.height - max(18, frame.height / 5)
        frame.fillRect(x: centerX - gunWidth / 2, y: gunTop, width: gunWidth, height: frame.height - gunTop, color: (58, 55, 52))
    }

    private func mapValue(x: Double, y: Double) -> UInt8 {
        let cellX = Int(floor(x))
        let cellY = Int(floor(y))
        guard Self.map.indices.contains(cellY), Self.map[cellY].indices.contains(cellX) else { return 49 }
        let value = Self.map[cellY][cellX]
        return value >= 49 && value <= 52 ? value : 0
    }

    private func isBlocked(x: Double, y: Double) -> Bool {
        let radius = 0.18
        return mapValue(x: x - radius, y: y - radius) != 0
            || mapValue(x: x + radius, y: y - radius) != 0
            || mapValue(x: x - radius, y: y + radius) != 0
            || mapValue(x: x + radius, y: y + radius) != 0
    }

    private func hasLineOfSight(toX: Double, y: Double) -> Bool {
        hasLineOfSight(fromX: playerX, y: playerY, toX: toX, y: y)
    }

    private func hasLineOfSight(fromX: Double, y fromY: Double, toX: Double, y toY: Double) -> Bool {
        let distance = hypot(toX - fromX, toY - fromY)
        let steps = max(1, Int(distance / 0.05))
        for step in 1..<steps {
            let t = Double(step) / Double(steps)
            if mapValue(x: fromX + (toX - fromX) * t, y: fromY + (toY - fromY) * t) != 0 {
                return false
            }
        }
        return true
    }

    private func normalizeAngle(_ value: Double) -> Double {
        var angle = value
        while angle > Double.pi { angle -= Double.pi * 2 }
        while angle < -Double.pi { angle += Double.pi * 2 }
        return angle
    }
}

private struct LiveGboomFrameBuffer {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = Array(repeating: 0, count: width * height * 3)
    }

    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    mutating func fill(_ color: (UInt8, UInt8, UInt8)) {
        for index in stride(from: 0, to: pixels.count, by: 3) {
            pixels[index] = color.0
            pixels[index + 1] = color.1
            pixels[index + 2] = color.2
        }
    }

    mutating func setPixel(x: Int, y: Int, color: (UInt8, UInt8, UInt8)) {
        guard contains(x: x, y: y) else { return }
        let index = (y * width + x) * 3
        pixels[index] = color.0
        pixels[index + 1] = color.1
        pixels[index + 2] = color.2
    }

    mutating func fillRect(x: Int, y: Int, width: Int, height: Int, color: (UInt8, UInt8, UInt8)) {
        for row in max(0, y)..<min(self.height, y + height) {
            for column in max(0, x)..<min(self.width, x + width) {
                setPixel(x: column, y: row, color: color)
            }
        }
    }

    mutating func drawLogo(y: Int, scale: Int) {
        let glyphs: [[UInt8]] = [
            [14, 17, 16, 23, 17, 17, 14],
            [30, 17, 17, 30, 17, 17, 30],
            [14, 17, 17, 17, 17, 17, 14],
            [14, 17, 17, 17, 17, 17, 14],
            [17, 27, 21, 21, 17, 17, 17],
        ]
        let totalWidth = glyphs.count * 6 * scale - scale
        var x = (width - totalWidth) / 2
        for glyph in glyphs {
            for (row, bits) in glyph.enumerated() {
                for column in 0..<5 where bits & (1 << (4 - column)) != 0 {
                    fillRect(x: x + column * scale, y: y + row * scale, width: scale, height: scale, color: (214, 43, 43))
                }
            }
            x += 6 * scale
        }
    }
}

private enum LiveGboomPNG {
    static func encodeRGB(pixels: [UInt8], width: Int, height: Int) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        let bytes = Data(pixels)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 24,
                  bytesPerRow: width * 3,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
        #else
        return encodeStoredRGB(pixels: pixels, width: width, height: height)
        #endif
    }

    private static func encodeStoredRGB(pixels: [UInt8], width: Int, height: Int) -> Data? {
        guard pixels.count == width * height * 3 else { return nil }
        var scanlines = Data(capacity: pixels.count + height)
        for row in 0..<height {
            scanlines.append(0)
            let start = row * width * 3
            scanlines.append(contentsOf: pixels[start..<(start + width * 3)])
        }
        var compressed = Data([0x78, 0x01])
        var offset = 0
        while offset < scanlines.count {
            let count = min(65_535, scanlines.count - offset)
            compressed.append(offset + count == scanlines.count ? 0x01 : 0x00)
            compressed.append(UInt8(count & 0xff))
            compressed.append(UInt8((count >> 8) & 0xff))
            let complement = (~count) & 0xffff
            compressed.append(UInt8(complement & 0xff))
            compressed.append(UInt8((complement >> 8) & 0xff))
            compressed.append(contentsOf: scanlines[offset..<(offset + count)])
            offset += count
        }
        appendUInt32(adler32(scanlines), to: &compressed)

        var png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        var header = Data()
        appendUInt32(UInt32(width), to: &header)
        appendUInt32(UInt32(height), to: &header)
        header.append(contentsOf: [8, 2, 0, 0, 0])
        appendChunk(type: "IHDR", payload: header, to: &png)
        appendChunk(type: "IDAT", payload: compressed, to: &png)
        appendChunk(type: "IEND", payload: Data(), to: &png)
        return png
    }

    private static func appendChunk(type: String, payload: Data, to data: inout Data) {
        appendUInt32(UInt32(payload.count), to: &data)
        let typeData = Data(type.utf8)
        data.append(typeData)
        data.append(payload)
        var crcInput = typeData
        crcInput.append(payload)
        appendUInt32(crc32(crcInput), to: &data)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var first: UInt32 = 1
        var second: UInt32 = 0
        for byte in data {
            first = (first + UInt32(byte)) % 65_521
            second = (second + first) % 65_521
        }
        return (second << 16) | first
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0)
            }
        }
        return crc ^ 0xffff_ffff
    }
}

enum LiveGboomOverlay {
    static let overlayID = "gboom"
    static let imageID: UInt32 = 1
    static let unavailableMessage = "No demons here — GBOOM needs a graphics-capable terminal (kitty, Ghostty, WezTerm, iTerm2)"

    static func make(hud: LiveGboomHud) -> PagerOverlay {
        let phaseTitle: String
        switch hud.phase {
        case .title: phaseTitle = "GBOOM"
        case .playing: phaseTitle = "GBOOM"
        case .won: phaseTitle = "GBOOM · VICTORY"
        case .dead: phaseTitle = "GBOOM · YOU DIED"
        }
        let hints = hud.phase == .playing
            ? [
                PagerOverlayHint(key: "WASD/←→", label: "move"),
                PagerOverlayHint(key: "Space", label: "fire"),
                PagerOverlayHint(key: "Esc", label: "quit"),
            ]
            : [PagerOverlayHint(key: "Esc", label: "quit")]
        return PagerOverlay(
            id: overlayID,
            title: "\(phaseTitle)  ·  HP \(hud.hp)  ·  KILLS \(hud.kills)/\(hud.total)",
            presentation: .centeredModal(PagerModalSizing(
                widthFraction: 0.9,
                maximumWidth: 180,
                minimumWidth: 30,
                verticalMargin: 1,
                horizontalPadding: 0,
                verticalPadding: 0,
                footerLines: 2
            )),
            hints: hints,
            content: .text(PagerTextOverlay(lines: [])),
            dismissOnEscape: false
        )
    }
}

extension LiveInteractiveControllerRenderer {
    func presentGboom() throws {
        guard mode == .fullScreen,
              detectGraphicsProtocol(environment: environment) == .kitty else {
            note(LiveGboomOverlay.unavailableMessage)
            try renderState()
            return
        }
        gboom = LiveGboomState()
        overlays.push(LiveGboomOverlay.make(hud: gboom!.hud))
        publishMotionState()
        try renderState()
    }

    func refreshGboomOverlay() {
        guard let gboom else { return }
        overlays.push(LiveGboomOverlay.make(hud: gboom.hud))
    }

    func handleGboomKey(_ event: KeyEvent) throws -> OpenGrokPagerInputRouting {
        guard var game = gboom else { return .notHandled }
        switch game.handleKey(event) {
        case .close:
            try closeGboom()
        case .changed:
            gboom = game
            refreshGboomOverlay()
            try renderState()
        }
        return .consumed
    }

    func handleGboomMouse(_ event: MouseEvent) throws -> OpenGrokPagerInputRouting {
        guard var game = gboom else { return .notHandled }
        guard let bounds = lastOverlayBounds.last(where: { $0.id == LiveGboomOverlay.overlayID }) else {
            return .consumed
        }
        if event.kind == .down,
           bounds.closeButton?.contains(x: event.x, y: event.y) == true {
            try closeGboom()
            return .consumed
        }
        game.handleMouse(event, region: bounds.content)
        gboom = game
        refreshGboomOverlay()
        try renderState()
        return .consumed
    }

    func closeGboom() throws {
        gboom = nil
        overlays.dismiss(id: LiveGboomOverlay.overlayID)
        publishMotionState()
        _ = try clearGboomImage()
        try renderState()
    }

    @discardableResult
    func clearGboomImage() throws -> Bool {
        guard gboomImageVisible else { return false }
        try sink.write(clearKittyImage(imageId: LiveGboomOverlay.imageID))
        try sink.flush()
        gboomImageVisible = false
        return true
    }

    @discardableResult
    func postFlushGboom(_ result: PagerRenderResult) throws -> Bool {
        guard var game = gboom,
              let bounds = result.overlays.last(where: { $0.id == LiveGboomOverlay.overlayID }),
              bounds.content.width >= 10,
              bounds.content.height >= 4 else {
            return try clearGboomImage()
        }
        let size = LiveGboomState.frameSizeForCells(
            cols: bounds.content.width,
            rows: bounds.content.height
        )
        guard let png = game.framePNG(width: size.width, height: size.height) else {
            return try clearGboomImage()
        }
        gboom = game
        try sink.write(transmitKittyImage(imageData: png, imageId: LiveGboomOverlay.imageID))
        try sink.write("\u{1b}[\(bounds.content.y + 1);\(bounds.content.x + 1)H")
        try sink.write(placeKittyImage(
            imageId: LiveGboomOverlay.imageID,
            cols: UInt16(clamping: bounds.content.width),
            rows: UInt16(clamping: bounds.content.height),
            z: 1
        ))
        gboomImageVisible = true
        return true
    }
}
