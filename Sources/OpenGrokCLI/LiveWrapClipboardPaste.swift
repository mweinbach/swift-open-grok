import Foundation
import OpenGrokPagerRender
import OpenGrokTerminalCore
import OpenGrokTTY
import OpenGrokWebMediaTools

struct LiveClipboardPasteSnapshot: Sendable, Equatable {
    var text: String?
    var fileURLs: [URL]
    var imageData: Data?
    var imageMIMEType: String?

    init(
        text: String? = nil,
        fileURLs: [URL] = [],
        imageData: Data? = nil,
        imageMIMEType: String? = nil
    ) {
        self.text = text
        self.fileURLs = fileURLs
        self.imageData = imageData
        self.imageMIMEType = imageMIMEType
    }
}

struct LiveWrapClipboardPasteCoordinator: Sendable {
    typealias Probe = @Sendable () async -> LiveClipboardPasteSnapshot
    typealias Writer = @Sendable (Data) async throws -> Void

    private let sinkActive: Bool
    private let probe: Probe
    private let write: Writer

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probe: @escaping Probe = Self.probeSystemClipboard,
        write: @escaping Writer
    ) {
        self.sinkActive = environment["GROK_OSC52_SINK"] != nil
            || environment["LC_GROK_OSC52_SINK"] != nil
        self.probe = probe
        self.write = write
    }

    func handle(_ event: TerminalInputEvent) async -> [InputEvent]? {
        guard Self.isPasteChord(event) else { return nil }
        let snapshot = await probe()

        if !snapshot.fileURLs.isEmpty {
            return [.paste(snapshot.fileURLs.map(\.path).joined(separator: "\n"))]
        }
        if let data = snapshot.imageData,
           !data.isEmpty,
           let mimeType = snapshot.imageMIMEType,
           !mimeType.isEmpty
        {
            return [.paste(encodeWrapImagePayload(data: data, mimeType: mimeType))]
        }
        if let text = snapshot.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return [.paste(text)]
        }

        var request: [UInt8]?
        let emitted = maybeRequestWrapHostImage(
            sinkActive: sinkActive,
            localImage: false,
            localText: false,
            localFileURLs: false
        ) { request = $0 }
        if emitted, let request {
            try? await write(Data(request))
        }
        return []
    }

    static func probeSystemClipboard() async -> LiveClipboardPasteSnapshot {
        let provider = SystemClipboardProvider()
        if let attachments = try? await provider.readAttachments() {
            if !attachments.fileURLs.isEmpty {
                return LiveClipboardPasteSnapshot(fileURLs: attachments.fileURLs)
            }
            if let image = attachments.image {
                return LiveClipboardPasteSnapshot(
                    imageData: image.data,
                    imageMIMEType: image.mimeType
                )
            }
        }
        guard let content = try? await provider.read() else {
            return LiveClipboardPasteSnapshot()
        }
        switch content {
        case .text(let text):
            return LiveClipboardPasteSnapshot(text: text)
        case .image(let data):
            return LiveClipboardPasteSnapshot(
                imageData: data,
                imageMIMEType: mimeType(for: data)
            )
        }
    }

    private static func isPasteChord(_ event: TerminalInputEvent) -> Bool {
        switch event {
        case .control(.character(0x16)):
            return true
        case .key(.character(let text, let modifiers)):
            return text.lowercased() == "v"
                && (modifiers.contains(.control) || modifiers.contains(.meta))
        default:
            return false
        }
    }
}
