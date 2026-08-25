import Foundation
import OpenGrokPagerRender
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import OpenGrokWebMediaTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Snapshot of the attachments belonging to exactly one genuine user turn.
struct LiveImageTurnReferences: Sendable {
    let sessionID: String
    let turnID: String
    let attachments: [Int: Data]

    init(sessionID: String, turnID: String, attachments: [PastedImage]) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.attachments = attachments.reduce(into: [:]) { result, image in
            guard image.displayNumber > 0, let bytes = image.encodedBytes else { return }
            result[image.displayNumber] = bytes
        }
    }
}

enum LiveImageReferenceResolver {
    static let maximumReferenceBytes = 400 * 1024
    static let maximumDecodePixels = 12_000_000
    private static let maximumInputBytes = 64 * 1024 * 1024

    static func attachmentNumber(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner: Substring
        if trimmed.first == "[", trimmed.last == "]" {
            inner = trimmed.dropFirst().dropLast()
        } else {
            inner = trimmed[...]
        }
        var token = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.count >= 5, token.prefix(5).lowercased() == "image" {
            token = String(token.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard token.hasPrefix("#"),
              let number = Int(token.dropFirst().trimmingCharacters(in: .whitespaces)),
              number > 0
        else { return nil }
        return number
    }

    static func resolve(
        _ reference: String,
        resources: ToolResources,
        attachments: LiveImageTurnReferences?
    ) throws -> String {
        let value = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ToolError.invalidArguments("image reference must not be empty")
        }

        let bytes: Data
        if let number = attachmentNumber(value) {
            guard let attachments, attachments.sessionID == resources.sessionId,
                  let attached = attachments.attachments[number]
            else {
                throw ToolError.invalidArguments(
                    "image reference \(value) matches no image attached to this message; ask the user to re-attach it"
                )
            }
            bytes = attached
        } else if value.hasPrefix("data:") {
            bytes = try decodeDataURL(value)
        } else {
            bytes = try loadWorkspaceImage(value, resources: resources)
        }

        let normalized = try normalize(bytes)
        return "data:\(normalized.mimeType);base64,\(normalized.data.base64EncodedString())"
    }

    private static func decodeDataURL(_ value: String) throws -> Data {
        guard value.hasPrefix("data:image/"),
              let comma = value.firstIndex(of: ","),
              value[..<comma].hasSuffix(";base64")
        else {
            throw ToolError.invalidArguments("image references require a base64 image data URL")
        }
        let encoded = value[value.index(after: comma)...]
        guard encoded.count <= maximumInputBytes * 4 / 3 + 4,
              let decoded = Data(base64Encoded: String(encoded)),
              !decoded.isEmpty
        else {
            throw ToolError.invalidArguments("image reference contains invalid or oversized base64 data")
        }
        return decoded
    }

    private static func normalize(_ bytes: Data) throws -> (data: Data, mimeType: String) {
        guard !bytes.isEmpty, bytes.count <= maximumInputBytes else {
            throw ToolError.invalidArguments("image reference contains no data or exceeds the input limit")
        }
        let format = ImageNormalizer.detectFormat(in: bytes)
        guard format != .unknown else {
            throw ToolError.invalidArguments("could not detect image format for reference")
        }
        if let dimensions = ImageNormalizer.detectDimensions(in: bytes),
           dimensions.height > 0,
           dimensions.width > maximumDecodePixels / dimensions.height {
            throw ToolError.invalidArguments(
                "image reference is too large to process (\(dimensions.width)×\(dimensions.height) pixels)"
            )
        }
        if bytes.count <= maximumReferenceBytes, format == .png || format == .jpeg {
            return (bytes, format.mimeType)
        }

        let options = ImageNormalizeOptions(
            maxSide: 768,
            maxPixels: 768 * 768,
            maxBytes: maximumReferenceBytes,
            minSide: 256,
            targetFormat: .jpeg,
            qualitySteps: [0.80, 0.65, 0.50, 0.35]
        )
        do {
            let result = try ImageNormalizer.normalize(image: bytes, options: options)
            guard result.data.count <= maximumReferenceBytes,
                  result.format == .jpeg || result.format == .png
            else {
                throw ToolError.invalidArguments("image reference could not be compressed under the Imagine API limit")
            }
            return (result.data, result.format.mimeType)
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.invalidArguments("failed to decode or compress image reference")
        }
    }

    private static func loadWorkspaceImage(
        _ reference: String,
        resources: ToolResources
    ) throws -> Data {
        let path: String
        if reference.hasPrefix("file://") {
            guard let url = URL(string: reference), url.isFileURL,
                  url.host == nil || url.host == "localhost"
            else {
                throw ToolError.invalidArguments("image reference must be a local file URL")
            }
            path = url.path
        } else {
            guard !reference.contains("://") else {
                throw ToolError.invalidArguments("remote image reference URLs are not supported")
            }
            path = reference
        }

        let candidate = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: resources.cwd))
            .standardizedFileURL
        let roots = ([resources.cwd] + resources.allowedRoots)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .sorted { $0.path.count > $1.path.count }
        guard let root = roots.first(where: {
            candidate.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/")
        }) else {
            throw ToolError.permissionDenied("image reference is outside the authorized workspace")
        }

        #if canImport(Darwin) || canImport(Glibc)
        let relative = candidate.path.dropFirst(root.path.count)
            .split(separator: "/")
            .map(String.init)
        guard let leaf = relative.last else {
            throw ToolError.invalidArguments("image reference must identify a regular file")
        }
        var descriptor = root.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ToolError.permissionDenied("image reference workspace is not safely accessible")
        }
        defer { close(descriptor) }

        for component in relative.dropLast() {
            let child = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else {
                throw ToolError.permissionDenied("image reference contains an unsafe or inaccessible directory")
            }
            close(descriptor)
            descriptor = child
        }

        let file = leaf.withCString {
            openat(descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard file >= 0 else {
            throw ToolError.permissionDenied("image reference is not a safely accessible regular file")
        }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size > 0,
              metadata.st_size <= off_t(maximumInputBytes)
        else {
            throw ToolError.invalidArguments("image reference must be a nonempty bounded regular file")
        }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        do {
            let bytes = try handle.readToEnd() ?? Data()
            guard bytes.count <= maximumInputBytes else {
                throw ToolError.invalidArguments("image reference exceeds the maximum input size")
            }
            return bytes
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.invalidArguments("image reference could not be read")
        }
        #else
        throw ToolError.permissionDenied("secure image reference loading is unavailable on this platform")
        #endif
    }
}
