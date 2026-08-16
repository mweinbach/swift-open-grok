import Foundation
import OpenGrokTerminalCore

public struct PagerInlineMediaFrame: Sendable, Equatable {
    public var pngData: Data
    public var width: UInt32
    public var height: UInt32

    public init(pngData: Data, width: UInt32, height: UInt32) {
        self.pngData = pngData
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct PagerLoadedInlineMedia: Sendable, Equatable {
    public var frames: [PagerInlineMediaFrame]
    public var fps: Double

    public init(pngData: Data, width: UInt32, height: UInt32) {
        self.frames = [PagerInlineMediaFrame(pngData: pngData, width: width, height: height)]
        self.fps = 0
    }

    public init(frames: [PagerInlineMediaFrame], fps: Double) {
        self.frames = frames
        self.fps = max(0, fps)
    }

    public var pngData: Data { frames.first?.pngData ?? Data() }
    public var width: UInt32 { frames.first?.width ?? 1 }
    public var height: UInt32 { frames.first?.height ?? 1 }
}

public struct PagerInlineMediaCompositor {
    public typealias Loader = @Sendable (PagerMediaRef) -> PagerLoadedInlineMedia?

    private struct Entry {
        var imageID: UInt32
        var loaded: PagerLoadedInlineMedia
        var currentFrame: Int
        var lastFrameTime: TimeInterval
        var finished: Bool
    }

    private var entries: [PagerMediaRef: Entry] = [:]
    private var nextImageID: UInt32 = 2
    private let active: Bool
    private let loader: Loader

    public init(active: Bool, loader: Loader? = nil) {
        self.active = active
        self.loader = loader ?? Self.loadImage
    }

    public init(
        environment: [String: String],
        enabled: Bool,
        terminalProgram: String? = nil,
        loader: Loader? = nil
    ) {
        let brand = terminalProgram.map(MouseScrollTerminalBrand.from(termProgram:))
            ?? detectTerminalBrandFromEnv(environment)
        let protocolName = detectGraphicsProtocol(environment: environment)
        let safeScrollbackBrand = brand == .kitty || brand == .ghostty || brand == .wezTerm
        self.init(
            active: enabled && protocolName == .kitty && safeScrollbackBrand
                && !scrollbackInlineOverlayForcedOff(),
            loader: loader
        )
    }

    @discardableResult
    public mutating func postFlush(
        placements: [PagerInlineMediaPlacement],
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        write: (String) throws -> Void
    ) throws -> Bool {
        guard active else {
            entries.removeAll(keepingCapacity: true)
            return false
        }

        let visible = Set(placements.map(\.media))
        var wrote = false
        for media in entries.keys.filter({ !visible.contains($0) }) {
            if let entry = entries.removeValue(forKey: media) {
                try write(clearKittyImage(imageId: entry.imageID))
                wrote = true
            }
        }

        for placement in placements.sorted(by: Self.placementOrder) {
            var entry: Entry
            if let existing = entries[placement.media] {
                entry = existing
            } else {
                guard let loaded = loader(placement.media) else { continue }
                guard !loaded.frames.isEmpty else { continue }
                let imageID = allocateImageID()
                entry = Entry(
                    imageID: imageID,
                    loaded: loaded,
                    currentFrame: 0,
                    lastFrameTime: now,
                    finished: loaded.frames.count <= 1
                )
                entries[placement.media] = entry
                try write(transmitKittyImage(
                    imageData: loaded.frames[0].pngData,
                    imageId: imageID
                ))
                wrote = true
            }

            if !entry.finished, entry.loaded.fps > 0 {
                let frameDuration = 1 / entry.loaded.fps
                if now - entry.lastFrameTime >= frameDuration {
                    if entry.currentFrame + 1 >= entry.loaded.frames.count {
                        entry.finished = true
                    } else {
                        entry.currentFrame += 1
                        entry.lastFrameTime = now
                        let frame = entry.loaded.frames[entry.currentFrame]
                        try write(transmitKittyImage(
                            imageData: frame.pngData,
                            imageId: entry.imageID
                        ))
                        wrote = true
                    }
                    entries[placement.media] = entry
                }
            }

            let frame = entry.loaded.frames[entry.currentFrame]
            let width = UInt16(clamping: max(1, placement.rect.width))
            let height = UInt16(clamping: max(1, placement.rect.height))
            let fullRows = UInt16(clamping: max(1, placement.fullRowCount))
            let topCropRows = UInt16(clamping: placement.sourceRowOffset)
            let cursor = ANSIOutput.moveTo(column: placement.rect.x, row: placement.rect.y)
            let image = KittyGraphics.placeForScrollback(
                imageId: entry.imageID,
                imgW: frame.width,
                imgH: frame.height,
                areaWidth: width,
                areaHeight: height,
                fullRows: fullRows,
                topCropRows: topCropRows
            )
            try write(cursor + image)
            wrote = true
        }
        return wrote
    }

    @discardableResult
    public mutating func clearAll(write: (String) throws -> Void) throws -> Bool {
        guard !entries.isEmpty else { return false }
        for entry in entries.values.sorted(by: { $0.imageID < $1.imageID }) {
            try write(clearKittyImage(imageId: entry.imageID))
        }
        entries.removeAll(keepingCapacity: true)
        return true
    }

    public var transmittedCount: Int { entries.count }

    private mutating func allocateImageID() -> UInt32 {
        defer {
            nextImageID = nextImageID == UInt32.max ? 2 : nextImageID + 1
        }
        return nextImageID
    }

    private static func placementOrder(
        _ lhs: PagerInlineMediaPlacement,
        _ rhs: PagerInlineMediaPlacement
    ) -> Bool {
        if lhs.rect.y != rhs.rect.y { return lhs.rect.y < rhs.rect.y }
        return lhs.rect.x < rhs.rect.x
    }

    private static func loadImage(_ media: PagerMediaRef) -> PagerLoadedInlineMedia? {
        switch media.kind {
        case .image:
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: media.path)),
                  let png = prepareKittyOverlayImageBytes(bytes),
                  let dimensions = pngDimensions(png)
            else { return nil }
            return PagerLoadedInlineMedia(
                pngData: png,
                width: dimensions.width,
                height: dimensions.height
            )
        case .video:
            return PagerInlineVideoDecoder().load(path: media.path)
        }
    }

    private static func pngDimensions(_ data: Data) -> (width: UInt32, height: UInt32)? {
        guard data.count >= 24, data.starts(with: KittyGraphics.pngSignature) else { return nil }
        let bytes = [UInt8](data[16..<24])
        let width = bytes[0...3].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = bytes[4...7].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
