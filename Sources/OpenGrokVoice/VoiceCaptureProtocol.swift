import Foundation

enum VoiceCaptureProtocol {
    static let readyTag = "READY"
    static let infoTag = "INFO"
    static let errTag = "ERR"
    static let infoFieldSeparator: Character = "\t"

    static func readyLine(device: String) -> String {
        "\(readyTag) \(sanitize(device))"
    }

    static func infoLine(name: String, detail: String) -> String {
        "\(infoTag) \(sanitize(name))\(infoFieldSeparator)\(sanitize(detail))"
    }

    static func errLine(message: String) -> String {
        "\(errTag) \(sanitize(message))"
    }

    static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: String(infoFieldSeparator), with: " ")
    }

    enum ParsedHeader: Equatable, Sendable {
        case ready(device: String)
        case info(name: String, detail: String)
        case error(message: String)
    }

    enum ParseError: Error, Equatable, Sendable {
        case unexpected(String)
        case oversized
        case eofBeforeHeader
    }

    static func parseHeaderLine(_ line: String) throws -> ParsedHeader {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard let space = trimmed.firstIndex(of: " ") else {
            throw ParseError.unexpected(trimmed)
        }
        let tag = String(trimmed[..<space])
        let payload = String(trimmed[trimmed.index(after: space)...])
        switch tag {
        case readyTag:
            return .ready(device: payload)
        case infoTag:
            if let tab = payload.firstIndex(of: infoFieldSeparator) {
                let name = String(payload[..<tab])
                let detail = String(payload[payload.index(after: tab)...])
                return .info(name: name, detail: detail)
            }
            return .info(name: payload, detail: "")
        case errTag:
            return .error(message: payload)
        default:
            throw ParseError.unexpected(trimmed)
        }
    }

    static func readHeader(from handle: FileHandle) throws -> ParsedHeader {
        var line = Data()
        while line.count < 4096 {
            guard let chunk = try handle.read(upToCount: 1), !chunk.isEmpty else {
                throw ParseError.eofBeforeHeader
            }
            if chunk[0] == UInt8(ascii: "\n") {
                let text = String(decoding: line, as: UTF8.self)
                return try parseHeaderLine(text)
            }
            line.append(chunk[0])
        }
        throw ParseError.oversized
    }

    static func emitHeaderLine(_ line: String) {
        emitHeaderLine(line, to: .standardOutput)
    }

    static func emitHeaderLine(_ line: String, to handle: FileHandle) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        try? handle.synchronize()
    }
}
