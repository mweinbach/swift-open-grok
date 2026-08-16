import Foundation
import OpenGrokTerminalCore

public let pagerFFmpegHintText = "Install ffmpeg to view inline"

public struct PagerVideoCommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct PagerInlineVideoDecoder: Sendable {
    public typealias ExecutableResolver = @Sendable (String, [String: String]) -> String?
    public typealias CommandRunner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) -> PagerVideoCommandResult?

    private struct Metadata {
        var width: UInt32
        var height: UInt32
        var fps: Double
    }

    private let environment: [String: String]
    private let ffmpegPath: String?
    private let ffprobePath: String?
    private let runner: CommandRunner

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableResolver: ExecutableResolver? = nil,
        runner: CommandRunner? = nil
    ) {
        let resolver = executableResolver ?? Self.resolveExecutable
        self.environment = environment
        self.ffmpegPath = resolver("ffmpeg", environment)
        self.ffprobePath = resolver("ffprobe", environment)
        self.runner = runner ?? Self.runCommand
    }

    public var isAvailable: Bool {
        ffmpegPath != nil && ffprobePath != nil
    }

    public static func ffmpegAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        resolveExecutable("ffmpeg", environment: environment) != nil
            && resolveExecutable("ffprobe", environment: environment) != nil
    }

    public func load(path: String) -> PagerLoadedInlineMedia? {
        guard let ffmpegPath, let ffprobePath else { return nil }
        let metadata = probe(path: path, executable: ffprobePath)
        guard let poster = poster(path: path, executable: ffmpegPath) else { return nil }

        let posterDimensions = Self.pngDimensions(poster)
            ?? metadata.map { ($0.width, $0.height) }
            ?? (1, 1)
        var frames = [PagerInlineMediaFrame(
            pngData: poster,
            width: posterDimensions.0,
            height: posterDimensions.1
        )]

        if let metadata {
            frames.append(contentsOf: extractFrames(
                path: path,
                executable: ffmpegPath,
                metadata: metadata
            ))
        }
        return PagerLoadedInlineMedia(
            frames: frames,
            fps: frames.count > 1 ? min(10, max(1, metadata?.fps ?? 10)) : 0
        )
    }

    private func probe(path: String, executable: String) -> Metadata? {
        let arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height,r_frame_rate:format=duration",
            "-of", "json",
            path,
        ]
        guard let result = runner(executable, arguments, environment),
              result.status == 0,
              let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let stream = (object["streams"] as? [[String: Any]])?.first,
              let width = (stream["width"] as? NSNumber)?.uint32Value,
              let height = (stream["height"] as? NSNumber)?.uint32Value,
              width > 0,
              height > 0
        else { return nil }

        let fps = Self.parseFrameRate(stream["r_frame_rate"] as? String) ?? 10
        return Metadata(width: width, height: height, fps: fps)
    }

    private func poster(path: String, executable: String) -> Data? {
        func extract(seek: Bool) -> Data? {
            var arguments = ["-hide_banner", "-loglevel", "error"]
            if seek { arguments.append(contentsOf: ["-ss", "1"]) }
            arguments.append(contentsOf: [
                "-i", path,
                "-frames:v", "1",
                "-f", "image2pipe",
                "-vcodec", "png",
                "-",
            ])
            guard let result = runner(executable, arguments, environment),
                  result.status == 0,
                  !result.stdout.isEmpty,
                  let png = prepareKittyOverlayImageBytes(result.stdout)
            else { return nil }
            return png
        }
        return extract(seek: true) ?? extract(seek: false)
    }

    private func extractFrames(
        path: String,
        executable: String,
        metadata: Metadata
    ) -> [PagerInlineMediaFrame] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-video-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: directory) }

        let targetFPS = min(10, max(1, metadata.fps))
        let filter = metadata.width > 640
            ? "fps=\(targetFPS),scale=640:-2"
            : "fps=\(targetFPS)"
        let pattern = directory.appendingPathComponent("%06d.png").path
        let arguments = [
            "-hide_banner", "-loglevel", "error",
            "-i", path,
            "-vf", filter,
            "-q:v", "5",
            pattern,
        ]
        guard let result = runner(executable, arguments, environment), result.status == 0 else {
            return []
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let png = prepareKittyOverlayImageBytes(data),
                  let dimensions = Self.pngDimensions(png)
            else { return nil }
            return PagerInlineMediaFrame(
                pngData: png,
                width: dimensions.width,
                height: dimensions.height
            )
        }
    }

    private static func parseFrameRate(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        let pieces = value.split(separator: "/", maxSplits: 1).compactMap { Double($0) }
        if pieces.count == 2, pieces[1] != 0 { return pieces[0] / pieces[1] }
        return Double(value)
    }

    private static func pngDimensions(_ data: Data) -> (width: UInt32, height: UInt32)? {
        guard data.count >= 24, data.starts(with: KittyGraphics.pngSignature) else { return nil }
        let bytes = [UInt8](data[16..<24])
        let width = bytes[0...3].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = bytes[4...7].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func resolveExecutable(
        _ name: String,
        environment: [String: String]
    ) -> String? {
        let separator: Character = environment["PATHEXT"] == nil ? ":" : ";"
        let extensions: [String]
        #if os(Windows)
        extensions = environment["PATHEXT"]?.split(separator: ";").map(String.init)
            ?? [".EXE", ".CMD", ".BAT"]
        #else
        extensions = [""]
        #endif

        for directory in (environment["PATH"] ?? "").split(separator: separator) {
            for ext in extensions {
                let candidate = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(name + ext)
                    .path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func runCommand(
        _ executable: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) -> PagerVideoCommandResult? {
        #if os(Windows)
        return nil
        #else
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return PagerVideoCommandResult(
                status: process.terminationStatus,
                stdout: outputData,
                stderr: errorData
            )
        } catch {
            return nil
        }
        #endif
    }
}
