import Foundation
import OpenGrokHTTP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WebMediaPlatform: String, Codable, Sendable, Hashable, CaseIterable {
    case macOS = "macos"
    case linux
    case windows
    case other

    public static var current: WebMediaPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        return .other
        #endif
    }
}

public enum WebMediaCapability: String, Codable, Sendable, Hashable, CaseIterable {
    case clipboardText = "clipboard_text"
    case clipboardImage = "clipboard_image"
    case clipboardFileURLs = "clipboard_file_urls"
    case osc52Clipboard = "osc52_clipboard"
    case webSearch = "web_search"
    case webFetch = "web_fetch"
    case imageGeneration = "image_generation"
    case imageEditing = "image_editing"
    case videoGeneration = "video_generation"
}

public enum WebMediaToolError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case capabilityUnavailable(capability: WebMediaCapability, platform: WebMediaPlatform, detail: String)
    case commandUnavailable(String)
    case commandFailed(command: String, status: Int32, detail: String)
    case commandTimedOut(command: String, timeout: TimeInterval)
    case emptyClipboard
    case unauthorized(tool: String)
    case rateLimited(tool: String)
    case remoteFailure(tool: String, status: Int, detail: String)
    case malformedResponse(tool: String, detail: String)
    case responseTooLarge(tool: String, limit: Int)
    case blockedURL(String)
    case crossHostRedirect(originalHost: String, redirectURL: String)
    case contentTypeMismatch(contentType: String, url: String)
    case http(HTTPError)

    public var description: String {
        switch self {
        case .invalidConfiguration(let detail):
            return "invalid web/media configuration: \(detail)"
        case .invalidRequest(let detail):
            return "invalid web/media request: \(detail)"
        case .capabilityUnavailable(let capability, let platform, let detail):
            return "capability \(capability.rawValue) is unavailable on \(platform.rawValue): \(detail)"
        case .commandUnavailable(let command):
            return "clipboard command is unavailable: \(command)"
        case .commandFailed(let command, let status, let detail):
            return "clipboard command \(command) failed with status \(status): \(detail)"
        case .commandTimedOut(let command, let timeout):
            return "clipboard command \(command) timed out after \(timeout) seconds"
        case .emptyClipboard:
            return "clipboard has no supported content"
        case .unauthorized(let tool):
            return "\(tool) authentication failed"
        case .rateLimited(let tool):
            return "\(tool) is rate limited"
        case .remoteFailure(let tool, let status, let detail):
            return "\(tool) failed with HTTP status \(status): \(detail)"
        case .malformedResponse(let tool, let detail):
            return "\(tool) returned a malformed response: \(detail)"
        case .responseTooLarge(let tool, let limit):
            return "\(tool) response exceeded \(limit) bytes"
        case .blockedURL(let url):
            return "web_fetch blocked URL: \(url)"
        case .crossHostRedirect(let originalHost, let redirectURL):
            return "web_fetch refused cross-host redirect from \(originalHost) to \(redirectURL)"
        case .contentTypeMismatch(let contentType, let url):
            return "web_fetch content does not match \(contentType) from \(url)"
        case .http(let error):
            return error.description
        }
    }
}

public enum ClipboardError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case accessDenied(String)
    case unsupported(String)
    case capabilityUnavailable(capability: WebMediaCapability, platform: WebMediaPlatform, detail: String)
    case commandFailed(String)
    case timedOut(String)
    case invalidContent(String)

    public var description: String {
        switch self {
        case .empty:
            return WebMediaToolError.emptyClipboard.description
        case .accessDenied(let detail):
            return "clipboard access denied: \(detail)"
        case .unsupported(let detail):
            return "clipboard unsupported: \(detail)"
        case .capabilityUnavailable(let capability, let platform, let detail):
            return "clipboard capability \(capability.rawValue) is unavailable on \(platform.rawValue): \(detail)"
        case .commandFailed(let detail):
            return "clipboard command failed: \(detail)"
        case .timedOut(let detail):
            return "clipboard command timed out: \(detail)"
        case .invalidContent(let detail):
            return "invalid clipboard content: \(detail)"
        }
    }
}

public struct ClipboardImage: Sendable, Equatable, Hashable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) throws {
        guard !data.isEmpty else {
            throw ClipboardError.invalidContent("image data is empty")
        }
        guard mimeType.hasPrefix("image/") else {
            throw ClipboardError.invalidContent("mime type must begin with image/")
        }
        self.data = data
        self.mimeType = mimeType
    }
}

public enum ClipboardContent: Sendable, Equatable {
    case text(String)
    case image(Data)
}

public struct ClipboardAttachments: Sendable, Equatable, Hashable {
    public var fileURLs: [URL]
    public var image: ClipboardImage?

    public init(fileURLs: [URL] = [], image: ClipboardImage? = nil) {
        self.fileURLs = fileURLs
        self.image = image
    }
}

public protocol ClipboardProvider: Sendable {
    func read() async throws -> ClipboardContent
    func write(_ content: ClipboardContent) async throws
}

public protocol ClipboardMediaProvider: ClipboardProvider {
    func readImage() async throws -> ClipboardImage
    func writeImage(_ image: ClipboardImage) async throws
    func readAttachments() async throws -> ClipboardAttachments
    func readPrimaryText() async throws -> String
}

public struct ClipboardCommandResult: Sendable, Equatable, Hashable {
    public var status: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(status: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var succeeded: Bool { status == 0 }
}

public protocol ClipboardCommandRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval
    ) throws -> ClipboardCommandResult
}

public struct SystemClipboardCommandRunner: ClipboardCommandRunner {
    public var environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
    }

    public func run(
        executable: String,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval
    ) throws -> ClipboardCommandResult {
        guard let executablePath = resolveExecutable(executable) else {
            throw ClipboardError.unsupported(executable)
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("open-grok-clipboard-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let outputURL = root.appendingPathComponent("stdout")
        let errorURL = root.appendingPathComponent("stderr")
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        fileManager.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        var inputHandle: FileHandle?
        if let input {
            let inputURL = root.appendingPathComponent("stdin")
            try input.write(to: inputURL, options: .atomic)
            inputHandle = try FileHandle(forReadingFrom: inputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
        } catch {
            try? inputHandle?.close()
            throw ClipboardError.commandFailed("\(executable): \(error)")
        }

        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                while process.isRunning {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                try? inputHandle?.close()
                throw ClipboardError.timedOut(executable)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try? inputHandle?.close()
        try? outputHandle.synchronize()
        try? errorHandle.synchronize()
        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        let error = (try? Data(contentsOf: errorURL)) ?? Data()
        return ClipboardCommandResult(
            status: process.terminationStatus,
            standardOutput: output,
            standardError: error
        )
    }

    private func resolveExecutable(_ executable: String) -> String? {
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }
        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(executable).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

public struct SystemClipboardProvider: ClipboardMediaProvider {
    public var platform: WebMediaPlatform
    public var environment: [String: String]
    public var commandRunner: any ClipboardCommandRunner
    public var commandTimeout: TimeInterval

    public init(
        platform: WebMediaPlatform = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: any ClipboardCommandRunner = SystemClipboardCommandRunner(),
        commandTimeout: TimeInterval = 2
    ) {
        self.platform = platform
        self.environment = environment
        self.commandRunner = commandRunner
        self.commandTimeout = commandTimeout
    }

    public func read() async throws -> ClipboardContent {
        if let text = try readTextIfAvailable(), !text.isEmpty {
            return .text(text)
        }
        if let image = try readImageIfAvailable() {
            return .image(image.data)
        }
        throw ClipboardError.empty
    }

    public func write(_ content: ClipboardContent) async throws {
        switch content {
        case .text(let text):
            try writeText(text)
        case .image(let data):
            let image = try ClipboardImage(data: data, mimeType: mimeType(for: data))
            try await writeImage(image)
        }
    }

    public func readImage() async throws -> ClipboardImage {
        guard let image = try readImageIfAvailable() else {
            throw ClipboardError.empty
        }
        return image
    }

    public func writeImage(_ image: ClipboardImage) async throws {
        try validatePlatformCapability(.clipboardImage)
        switch platform {
        case .macOS:
            try writeMacOSImage(image)
        case .linux:
            try writeLinuxImage(image)
        case .windows, .other:
            throw ClipboardError.unsupported("image clipboard on \(platform.rawValue)")
        }
    }

    public func readAttachments() async throws -> ClipboardAttachments {
        try validatePlatformCapability(.clipboardFileURLs)
        let files = try readFileURLsIfAvailable()
        let image = files.isEmpty ? try readImageIfAvailable() : nil
        guard !files.isEmpty || image != nil else { throw ClipboardError.empty }
        return ClipboardAttachments(fileURLs: files, image: image)
    }

    public func readPrimaryText() async throws -> String {
        guard platform == .linux else {
            throw ClipboardError.capabilityUnavailable(
                capability: .clipboardText,
                platform: platform,
                detail: "primary selection is Linux/X11-only"
            )
        }
        guard let display = environment["DISPLAY"], !display.isEmpty else {
            throw ClipboardError.capabilityUnavailable(
                capability: .clipboardText,
                platform: platform,
                detail: "primary selection requires DISPLAY"
            )
        }
        let specs = [
            ClipboardCommandSpec(executable: "xclip", arguments: ["-o", "-selection", "primary"]),
            ClipboardCommandSpec(executable: "xsel", arguments: ["--primary", "--output"])
        ]
        guard let result = try runFirst(specs), result.succeeded else { throw ClipboardError.empty }
        guard let text = String(data: result.standardOutput, encoding: .utf8), !text.isEmpty else {
            throw ClipboardError.empty
        }
        return text
    }

    public func capabilityStatus() -> [WebMediaCapability: Bool] {
        var status: [WebMediaCapability: Bool] = [
            .clipboardText: false,
            .clipboardImage: false,
            .clipboardFileURLs: false,
            .osc52Clipboard: true
        ]
        switch platform {
        case .macOS:
            status[.clipboardText] = true
            status[.clipboardImage] = true
            status[.clipboardFileURLs] = true
        case .linux:
            let hasDisplay = !(environment["DISPLAY"] ?? "").isEmpty || !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty
            status[.clipboardText] = hasDisplay
            status[.clipboardImage] = hasDisplay
            status[.clipboardFileURLs] = hasDisplay
        case .windows, .other:
            break
        }
        return status
    }

    public func writeOSC52(_ text: String, tmuxPassthrough: Bool = false) throws {
        guard !text.isEmpty else { throw ClipboardError.invalidContent("text is empty") }
        let encoded = Data(text.utf8).base64EncodedString()
        let sequence: String
        if tmuxPassthrough {
            sequence = "\u{001B}Ptmux;\u{001B}\u{001B}]52;c;\(encoded)\u{0007}\u{001B}\\"
        } else {
            sequence = "\u{001B}]52;c;\(encoded)\u{0007}"
        }
        FileHandle.standardError.write(Data(sequence.utf8))
    }

    public func isRemoteSession() -> Bool {
        environment["SSH_CONNECTION"]?.isEmpty == false
            || environment["SSH_TTY"]?.isEmpty == false
            || environment["SSH_CLIENT"]?.isEmpty == false
    }

    private func readTextIfAvailable() throws -> String? {
        let specs = textReadSpecs()
        guard !specs.isEmpty else {
            try validatePlatformCapability(.clipboardText)
            return nil
        }
        guard let result = try runFirst(specs), result.succeeded else { return nil }
        return String(data: result.standardOutput, encoding: .utf8)
    }

    private func readImageIfAvailable() throws -> ClipboardImage? {
        let specs = imageReadSpecs()
        guard !specs.isEmpty else {
            try validatePlatformCapability(.clipboardImage)
            return nil
        }
        guard let result = try runFirst(specs), result.succeeded, !result.standardOutput.isEmpty else { return nil }
        let data = result.standardOutput
        let mime = mimeType(for: data)
        guard mime != "application/octet-stream" else { return nil }
        return try ClipboardImage(data: data, mimeType: mime)
    }

    private func readFileURLsIfAvailable() throws -> [URL] {
        let specs = fileURLReadSpecs()
        guard let result = try runFirst(specs), result.succeeded,
              let output = String(data: result.standardOutput, encoding: .utf8)
        else { return [] }
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.lowercased() != "none" else { return nil }
                if value.hasPrefix("file://") { return URL(string: value) }
                return URL(fileURLWithPath: value)
            }
    }

    private func writeText(_ text: String) throws {
        try validatePlatformCapability(.clipboardText)
        guard !text.isEmpty else { throw ClipboardError.invalidContent("text is empty") }
        let specs = textWriteSpecs()
        guard !specs.isEmpty else { throw ClipboardError.unsupported("no clipboard writer for \(platform.rawValue)") }
        var lastFailure: ClipboardError?
        for spec in specs {
            do {
                let result = try commandRunner.run(
                    executable: spec.executable,
                    arguments: spec.arguments,
                    input: Data(text.utf8),
                    timeout: commandTimeout
                )
                if result.succeeded { return }
                lastFailure = .commandFailed(spec.executable)
            } catch let error as ClipboardError {
                lastFailure = error
            }
        }
        throw lastFailure ?? ClipboardError.unsupported("no clipboard writer succeeded")
    }

    private func writeMacOSImage(_ image: ClipboardImage) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("open-grok-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("clipboard.\(extensionForMime(image.mimeType))")
        try image.data.write(to: file, options: .atomic)
        let escaped = file.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "set the clipboard to (read (POSIX file \"\(escaped)\") as \u{00AB}class \(appleScriptClass(for: image.mimeType))\u{00BB})"
        let result = try commandRunner.run(executable: "osascript", arguments: ["-e", script], input: nil, timeout: commandTimeout)
        guard result.succeeded else { throw ClipboardError.commandFailed("osascript") }
    }

    private func writeLinuxImage(_ image: ClipboardImage) throws {
        let specs = imageWriteSpecs(mimeType: image.mimeType)
        guard !specs.isEmpty else { throw ClipboardError.unsupported("no Linux image clipboard writer") }
        var lastFailure: ClipboardError?
        for spec in specs {
            do {
                let result = try commandRunner.run(executable: spec.executable, arguments: spec.arguments, input: image.data, timeout: commandTimeout)
                if result.succeeded { return }
                lastFailure = .commandFailed(spec.executable)
            } catch let error as ClipboardError {
                lastFailure = error
            }
        }
        throw lastFailure ?? ClipboardError.unsupported("no Linux image clipboard writer succeeded")
    }

    private func runFirst(_ specs: [ClipboardCommandSpec]) throws -> ClipboardCommandResult? {
        var foundCommand = false
        var lastFailure: ClipboardError?
        for spec in specs {
            do {
                let result = try commandRunner.run(executable: spec.executable, arguments: spec.arguments, input: nil, timeout: commandTimeout)
                foundCommand = true
                if result.succeeded { return result }
                lastFailure = .commandFailed(spec.executable)
            } catch let error as ClipboardError {
                switch error {
                case .unsupported:
                    continue
                default:
                    foundCommand = true
                    lastFailure = error
                }
            }
        }
        if !foundCommand, let first = specs.first {
            throw ClipboardError.unsupported(first.executable)
        }
        if let lastFailure { throw lastFailure }
        return nil
    }

    private func validatePlatformCapability(_ capability: WebMediaCapability) throws {
        guard platform == .macOS || platform == .linux else {
            throw ClipboardError.capabilityUnavailable(
                capability: capability,
                platform: platform,
                detail: "native clipboard integration is implemented only for macOS and Linux"
            )
        }
        if platform == .linux {
            let hasDisplay = !(environment["DISPLAY"] ?? "").isEmpty || !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty
            guard hasDisplay else {
                throw ClipboardError.capabilityUnavailable(
                    capability: capability,
                    platform: platform,
                    detail: "Linux clipboard requires DISPLAY or WAYLAND_DISPLAY"
                )
            }
        }
    }

    private func textReadSpecs() -> [ClipboardCommandSpec] {
        switch platform {
        case .macOS:
            return [ClipboardCommandSpec(executable: "/usr/bin/pbpaste", arguments: ["-Prefer", "txt"])]
        case .linux:
            return linuxTextReadSpecs()
        case .windows, .other:
            return []
        }
    }

    private func imageReadSpecs() -> [ClipboardCommandSpec] {
        switch platform {
        case .macOS:
            return [ClipboardCommandSpec(executable: "/usr/bin/pbpaste", arguments: ["-Prefer", "png"])]
        case .linux:
            var specs: [ClipboardCommandSpec] = []
            if !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty { specs.append(ClipboardCommandSpec(executable: "wl-paste", arguments: ["-t", "image/png"])) }
            if !(environment["DISPLAY"] ?? "").isEmpty {
                specs.append(ClipboardCommandSpec(executable: "xclip", arguments: ["-selection", "clipboard", "-t", "image/png", "-o"]))
            }
            return specs
        case .windows, .other:
            return []
        }
    }

    private func fileURLReadSpecs() -> [ClipboardCommandSpec] {
        switch platform {
        case .macOS:
            let script = "try\nset theFiles to the clipboard as list\nset output to \"\"\nrepeat with itemRef in theFiles\ntry\nset output to output & (POSIX path of (contents of itemRef as «class furl»)) & linefeed\nend try\nend repeat\nif output is not \"\" then return output\ntry\nreturn POSIX path of (the clipboard as «class furl»)\non error\nreturn \"none\"\nend try\non error\nreturn \"none\"\nend try"
            return [ClipboardCommandSpec(executable: "osascript", arguments: ["-e", script])]
        case .linux:
            if !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty { return [ClipboardCommandSpec(executable: "wl-paste", arguments: ["-t", "text/uri-list"])] }
            if !(environment["DISPLAY"] ?? "").isEmpty { return [ClipboardCommandSpec(executable: "xclip", arguments: ["-selection", "clipboard", "-t", "text/uri-list", "-o"])] }
            return []
        case .windows, .other:
            return []
        }
    }

    private func textWriteSpecs() -> [ClipboardCommandSpec] {
        switch platform {
        case .macOS:
            return [ClipboardCommandSpec(executable: "/usr/bin/pbcopy", arguments: [])]
        case .linux:
            var specs: [ClipboardCommandSpec] = []
            if !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty { specs.append(ClipboardCommandSpec(executable: "wl-copy", arguments: [])) }
            if !(environment["DISPLAY"] ?? "").isEmpty {
                specs.append(ClipboardCommandSpec(executable: "xclip", arguments: ["-selection", "clipboard", "-i"]))
                specs.append(ClipboardCommandSpec(executable: "xsel", arguments: ["--clipboard", "--input"]))
            }
            return specs
        case .windows, .other:
            return []
        }
    }

    private func imageWriteSpecs(mimeType: String) -> [ClipboardCommandSpec] {
        switch platform {
        case .linux:
            var specs: [ClipboardCommandSpec] = []
            if !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty { specs.append(ClipboardCommandSpec(executable: "wl-copy", arguments: ["-t", mimeType])) }
            if !(environment["DISPLAY"] ?? "").isEmpty { specs.append(ClipboardCommandSpec(executable: "xclip", arguments: ["-selection", "clipboard", "-t", mimeType, "-i"])) }
            return specs
        default:
            return []
        }
    }

    private func linuxTextReadSpecs() -> [ClipboardCommandSpec] {
        var specs: [ClipboardCommandSpec] = []
        if !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty { specs.append(ClipboardCommandSpec(executable: "wl-paste", arguments: ["--no-newline", "-t", "text"])) }
        if !(environment["DISPLAY"] ?? "").isEmpty {
            specs.append(ClipboardCommandSpec(executable: "xclip", arguments: ["-o", "-selection", "clipboard"]))
            specs.append(ClipboardCommandSpec(executable: "xsel", arguments: ["--clipboard", "--output"]))
        }
        return specs
    }
}

public struct ClipboardCommandSpec: Sendable, Equatable, Hashable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct BootstrapClipboardProvider: ClipboardProvider {
    public init() {}

    public func read() async throws -> ClipboardContent {
        throw ClipboardError.unsupported("BootstrapClipboardProvider has been replaced by SystemClipboardProvider")
    }

    public func write(_ content: ClipboardContent) async throws {
        throw ClipboardError.unsupported("BootstrapClipboardProvider has been replaced by SystemClipboardProvider")
    }
}

public struct OSC52ClipboardProvider: ClipboardProvider {
    public var environment: [String: String]
    public var tmuxPassthrough: Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tmuxPassthrough: Bool = false
    ) {
        self.environment = environment
        self.tmuxPassthrough = tmuxPassthrough
    }

    public func read() async throws -> ClipboardContent {
        throw ClipboardError.capabilityUnavailable(
            capability: .osc52Clipboard,
            platform: .current,
            detail: "OSC 52 is a write-only terminal protocol"
        )
    }

    public func write(_ content: ClipboardContent) async throws {
        guard case .text(let text) = content else {
            throw ClipboardError.capabilityUnavailable(
                capability: .osc52Clipboard,
                platform: .current,
                detail: "OSC 52 supports text only"
            )
        }
        guard !text.isEmpty else { throw ClipboardError.invalidContent("text is empty") }
        let encoded = Data(text.utf8).base64EncodedString()
        let sequence: String
        if tmuxPassthrough {
            sequence = "\u{001B}Ptmux;\u{001B}\u{001B}]52;c;\(encoded)\u{0007}\u{001B}\\"
        } else {
            sequence = "\u{001B}]52;c;\(encoded)\u{0007}"
        }
        FileHandle.standardError.write(Data(sequence.utf8))
    }
}

public func mimeType(for data: Data) -> String {
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
    if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
    if data.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.count > 11 && data[8...11] == Data("WEBP".utf8) { return "image/webp" }
    if data.starts(with: [0x42, 0x4D]) { return "image/bmp" }
    return "application/octet-stream"
}

public func extensionForMime(_ mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/png": return "png"
    case "image/jpeg": return "jpg"
    case "image/tiff": return "tiff"
    case "image/gif": return "gif"
    case "image/webp": return "webp"
    case "image/bmp": return "bmp"
    default: return "bin"
    }
}

private func appleScriptClass(for mimeType: String) -> String {
    switch mimeType.lowercased() {
    case "image/png": return "PNGf"
    case "image/tiff": return "TIFF"
    default: return "JPEG"
    }
}
