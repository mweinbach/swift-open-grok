import Foundation
import OpenGrokToolRegistry
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

struct PDFDocumentPageImage: Sendable {
    let pageNumber: Int
    let bytes: Data
}

enum PDFDocumentExtractionResult: Sendable {
    case text(String, totalPages: Int)
    case images([PDFDocumentPageImage], totalPages: Int)
}

enum PDFDocumentExtractor {
    static func extract(
        _ bytes: Data,
        pages: String?,
        format: String?,
        deadline: DocumentExtractionDeadline
    ) throws -> PDFDocumentExtractionResult {
        try deadline.check()
        guard bytes.starts(with: Data("%PDF-".utf8)) else {
            throw DocumentExtractionError.invalid("Failed to open PDF: invalid document signature")
        }
        switch format {
        case .some(let value) where value != "text" && value != "image":
            throw DocumentExtractionError.invalid(
                "Invalid format '\(value)'. Supported values: 'image' (default), 'text'."
            )
        default:
            break
        }

        let document = try ParsedPDFDocument(bytes: bytes, deadline: deadline)
        let selected = try DocumentExtraction.selectedPages(
            specification: pages,
            count: document.pageCount
        )

        #if canImport(CoreGraphics) && canImport(ImageIO)
        if format != "text" {
            return .images(
                try renderPages(bytes, indices: selected, deadline: deadline),
                totalPages: document.pageCount
            )
        }
        #else
        if format == "image" {
            throw DocumentExtractionError.unsupported(
                "PDF image rendering is unavailable on this platform; use format=\"text\""
            )
        }
        #endif

        var sections: [String] = []
        for index in selected {
            try deadline.check()
            sections.append("--- Page \(index + 1) ---\n" + (try document.text(page: index, deadline: deadline)))
        }
        return .text(sections.joined(separator: "\n"), totalPages: document.pageCount)
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    private static func renderPages(
        _ bytes: Data,
        indices: [Int],
        deadline: DocumentExtractionDeadline
    ) throws -> [PDFDocumentPageImage] {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider),
              !document.isEncrypted || document.isUnlocked
        else {
            throw DocumentExtractionError.invalid("Failed to open PDF for image rendering")
        }
        var images: [PDFDocumentPageImage] = []
        for index in indices {
            try deadline.check()
            guard let page = document.page(at: index + 1) else {
                throw DocumentExtractionError.invalid("Failed to render PDF page \(index + 1)")
            }
            let bounds = page.getBoxRect(.mediaBox)
            let scale = 150.0 / 72.0
            let width = Int((bounds.width * scale).rounded(.up))
            let height = Int((bounds.height * scale).rounded(.up))
            guard width > 0, height > 0,
                  width <= 8192, height <= 8192,
                  width <= 12_000_000 / height
            else {
                throw DocumentExtractionError.limit("PDF page exceeds the safe image rendering dimensions")
            }
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw DocumentExtractionError.invalid("Unable to allocate the PDF page renderer")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.drawPDFPage(page)
            guard let image = context.makeImage() else {
                throw DocumentExtractionError.invalid("Failed to render PDF page \(index + 1)")
            }

            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                encoded,
                "public.jpeg" as CFString,
                1,
                nil
            ) else {
                throw DocumentExtractionError.invalid("Unable to encode the rendered PDF page")
            }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw DocumentExtractionError.invalid("Unable to finish encoding the rendered PDF page")
            }
            images.append(PDFDocumentPageImage(pageNumber: index + 1, bytes: encoded as Data))
        }
        return images
    }
    #endif
}

private struct ParsedPDFDocument: Sendable {
    private struct Object: Sendable {
        let number: Int
        let body: String
    }

    private let objects: [Int: Object]
    private let pageObjects: [Object]

    var pageCount: Int { pageObjects.count }

    init(bytes: Data, deadline: DocumentExtractionDeadline) throws {
        guard let source = String(data: bytes, encoding: .isoLatin1),
              !source.contains("/Encrypt")
        else {
            throw DocumentExtractionError.unsupported("Encrypted or invalid PDFs cannot be extracted")
        }
        let expression = try NSRegularExpression(
            pattern: #"(?ms)(?<!\d)(\d{1,9})\s+\d{1,5}\s+obj\s*(.*?)\bendobj\b"#
        )
        let full = source as NSString
        var range = NSRange(location: 0, length: full.length)
        var collected: [Int: Object] = [:]
        var order: [Int] = []
        while range.length > 0,
              let match = expression.firstMatch(in: source, range: range) {
            try deadline.check()
            guard let number = Int(full.substring(with: match.range(at: 1))),
                  collected[number] == nil,
                  collected.count < 10_000
            else {
                throw DocumentExtractionError.invalid("PDF contains invalid or excessive indirect objects")
            }
            let object = Object(number: number, body: full.substring(with: match.range(at: 2)))
            collected[number] = object
            order.append(number)
            let next = match.range.location + match.range.length
            range = NSRange(location: next, length: full.length - next)
        }
        guard !collected.isEmpty else {
            throw DocumentExtractionError.invalid("Failed to open PDF: no readable indirect objects")
        }
        self.objects = collected

        if let catalog = order.compactMap({ collected[$0] }).first(where: {
            Self.contains($0.body, pattern: #"/Type\s*/Catalog\b"#)
        }), let root = Self.firstReference(in: catalog.body, key: "Pages") {
            var stack = Set<Int>()
            var pages: [Object] = []
            try Self.collectPages(
                root,
                objects: collected,
                visiting: &stack,
                into: &pages,
                depth: 0,
                deadline: deadline
            )
            self.pageObjects = pages
        } else {
            self.pageObjects = order.compactMap { number in
                guard let object = collected[number],
                      Self.contains(object.body, pattern: #"/Type\s*/Page(?!s\b)"#)
                else { return nil }
                return object
            }
        }
        guard !pageObjects.isEmpty, pageObjects.count <= 100_000 else {
            throw DocumentExtractionError.invalid("PDF has no pages or exceeds the page safety limit")
        }
    }

    func text(page index: Int, deadline: DocumentExtractionDeadline) throws -> String {
        let page = pageObjects[index]
        let references = Self.contentReferences(page.body)
        guard !references.isEmpty else { return "" }
        var pieces: [String] = []
        for reference in references {
            try deadline.check()
            guard let object = objects[reference] else {
                throw DocumentExtractionError.invalid("PDF page references a missing content stream")
            }
            pieces.append(try PDFTextOperators.extract(
                stream(from: object, deadline: deadline),
                deadline: deadline
            ))
        }
        return pieces.joined(separator: "\n")
    }

    private func stream(from object: Object, deadline: DocumentExtractionDeadline) throws -> Data {
        guard let streamRange = object.body.range(of: "stream") else {
            throw DocumentExtractionError.invalid("PDF content object has no stream")
        }
        var start = streamRange.upperBound
        if object.body[start...].hasPrefix("\r\n") {
            start = object.body.index(start, offsetBy: 2)
        } else if start < object.body.endIndex,
                  (object.body[start] == "\n" || object.body[start] == "\r") {
            start = object.body.index(after: start)
        } else {
            throw DocumentExtractionError.invalid("PDF content stream has an invalid delimiter")
        }
        guard let end = object.body.range(of: "endstream", range: start..<object.body.endIndex) else {
            throw DocumentExtractionError.invalid("PDF content stream is truncated")
        }
        var raw = Data(object.body[start..<end.lowerBound].unicodeScalars.map { UInt8($0.value) })
        if let length = Self.firstInteger(in: object.body, key: "Length") {
            guard length >= 0, length <= raw.count else {
                throw DocumentExtractionError.invalid("PDF content stream length is invalid")
            }
            raw = Data(raw.prefix(length))
        } else {
            while raw.last == 10 || raw.last == 13 { raw.removeLast() }
        }
        guard raw.count <= DocumentExtraction.maximumXMLBytes else {
            throw DocumentExtractionError.limit("PDF content stream exceeds its size limit")
        }
        if Self.contains(object.body, pattern: #"/Filter\s*(?:\[\s*)?/FlateDecode\b"#) {
            return try DocumentInflater.inflate(
                raw,
                raw: false,
                expectedSize: nil,
                maximumOutput: DocumentExtraction.maximumXMLBytes,
                deadline: deadline
            )
        }
        if Self.contains(object.body, pattern: #"/Filter\s"#) {
            throw DocumentExtractionError.unsupported("PDF uses an unsupported content stream filter")
        }
        return raw
    }

    private static func collectPages(
        _ number: Int,
        objects: [Int: Object],
        visiting: inout Set<Int>,
        into pages: inout [Object],
        depth: Int,
        deadline: DocumentExtractionDeadline
    ) throws {
        try deadline.check()
        guard depth < 64, visiting.insert(number).inserted,
              let object = objects[number]
        else {
            throw DocumentExtractionError.invalid("PDF contains a cyclic or invalid page tree")
        }
        defer { visiting.remove(number) }
        if contains(object.body, pattern: #"/Type\s*/Page(?!s\b)"#) {
            pages.append(object)
            guard pages.count <= 100_000 else {
                throw DocumentExtractionError.limit("PDF exceeds the page safety limit")
            }
            return
        }
        let children = arrayReferences(in: object.body, key: "Kids")
        guard !children.isEmpty else {
            throw DocumentExtractionError.invalid("PDF page tree has no children")
        }
        for child in children {
            try collectPages(child, objects: objects, visiting: &visiting, into: &pages, depth: depth + 1, deadline: deadline)
        }
    }

    private static func contentReferences(_ body: String) -> [Int] {
        if let single = firstReference(in: body, key: "Contents") { return [single] }
        return arrayReferences(in: body, key: "Contents")
    }

    private static func firstReference(in body: String, key: String) -> Int? {
        firstCapture(in: body, pattern: "/\(key)\\s+(\\d+)\\s+\\d+\\s+R").flatMap(Int.init)
    }

    private static func firstInteger(in body: String, key: String) -> Int? {
        firstCapture(in: body, pattern: "/\(key)\\s+(\\d+)(?!\\s+\\d+\\s+R)").flatMap(Int.init)
    }

    private static func arrayReferences(in body: String, key: String) -> [Int] {
        guard let contents = firstCapture(in: body, pattern: "/\(key)\\s*\\[([^\\]]*)\\]") else {
            return []
        }
        let expression = try? NSRegularExpression(pattern: #"(\d+)\s+\d+\s+R"#)
        let value = contents as NSString
        return expression?.matches(in: contents, range: NSRange(location: 0, length: value.length))
            .compactMap { Int(value.substring(with: $0.range(at: 1))) } ?? []
    }

    private static func firstCapture(in source: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: source,
                range: NSRange(location: 0, length: (source as NSString).length)
              )
        else { return nil }
        return (source as NSString).substring(with: match.range(at: 1))
    }

    private static func contains(_ source: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        ) != nil
    }
}

private enum PDFTextOperators {
    static func extract(_ data: Data, deadline: DocumentExtractionDeadline) throws -> String {
        let bytes = Array(data)
        var cursor = 0
        var operands: [Data] = []
        var text = ""

        while cursor < bytes.count {
            if cursor.isMultiple(of: 2048) { try deadline.check() }
            switch bytes[cursor] {
            case 0x28:
                operands.append(try literal(bytes, cursor: &cursor))
            case 0x3C where cursor + 1 < bytes.count && bytes[cursor + 1] != 0x3C:
                operands.append(try hexadecimal(bytes, cursor: &cursor))
            case 0x25:
                while cursor < bytes.count, bytes[cursor] != 10, bytes[cursor] != 13 { cursor += 1 }
            default:
                if isWhitespace(bytes[cursor]) || bytes[cursor] == 0x5B || bytes[cursor] == 0x5D {
                    cursor += 1
                    continue
                }
                let start = cursor
                while cursor < bytes.count, !isWhitespace(bytes[cursor]),
                      ![0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D].contains(bytes[cursor]) {
                    cursor += 1
                }
                guard cursor > start else {
                    cursor += 1
                    continue
                }
                let token = String(decoding: bytes[start..<cursor], as: UTF8.self)
                switch token {
                case "Tj", "TJ", "'", "\"":
                    if (token == "'" || token == "\"") && !text.isEmpty && !text.hasSuffix("\n") {
                        text += "\n"
                    }
                    for operand in operands { text += decode(operand) }
                    operands.removeAll(keepingCapacity: true)
                case "Td", "TD", "T*", "ET":
                    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                    operands.removeAll(keepingCapacity: true)
                case "BT":
                    operands.removeAll(keepingCapacity: true)
                default:
                    break
                }
                if text.utf8.count > defaultToolOutputBytes * 4 {
                    throw DocumentExtractionError.limit("PDF extracted text exceeds the output safety limit")
                }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func literal(_ source: [UInt8], cursor: inout Int) throws -> Data {
        cursor += 1
        var depth = 1
        var output = Data()
        while cursor < source.count {
            let byte = source[cursor]
            cursor += 1
            if byte == 0x5C {
                guard cursor < source.count else { break }
                let escaped = source[cursor]
                cursor += 1
                switch escaped {
                case 0x6E: output.append(10)
                case 0x72: output.append(13)
                case 0x74: output.append(9)
                case 0x62: output.append(8)
                case 0x66: output.append(12)
                case 10: break
                case 13:
                    if cursor < source.count, source[cursor] == 10 { cursor += 1 }
                case 48...55:
                    var value = Int(escaped - 48)
                    for _ in 0..<2 where cursor < source.count {
                        guard (48...55).contains(source[cursor]) else { break }
                        value = value * 8 + Int(source[cursor] - 48)
                        cursor += 1
                    }
                    output.append(UInt8(value & 0xFF))
                default:
                    output.append(escaped)
                }
            } else if byte == 0x28 {
                depth += 1
                guard depth <= 32 else {
                    throw DocumentExtractionError.invalid("PDF text string nesting is excessive")
                }
                output.append(byte)
            } else if byte == 0x29 {
                depth -= 1
                if depth == 0 { return output }
                output.append(byte)
            } else {
                output.append(byte)
            }
        }
        throw DocumentExtractionError.invalid("PDF contains an unterminated text string")
    }

    private static func hexadecimal(_ source: [UInt8], cursor: inout Int) throws -> Data {
        cursor += 1
        var digits: [UInt8] = []
        while cursor < source.count, source[cursor] != 0x3E {
            let byte = source[cursor]
            cursor += 1
            if isWhitespace(byte) { continue }
            guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else {
                throw DocumentExtractionError.invalid("PDF contains an invalid hexadecimal text string")
            }
            digits.append(byte)
        }
        guard cursor < source.count else {
            throw DocumentExtractionError.invalid("PDF contains an unterminated hexadecimal text string")
        }
        cursor += 1
        if digits.count.isMultiple(of: 2) == false { digits.append(48) }
        var output = Data()
        for index in stride(from: 0, to: digits.count, by: 2) {
            let pair = String(decoding: digits[index...index + 1], as: UTF8.self)
            guard let byte = UInt8(pair, radix: 16) else {
                throw DocumentExtractionError.invalid("PDF hexadecimal text cannot be decoded")
            }
            output.append(byte)
        }
        return output
    }

    private static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian) ?? ""
        }
        if data.count >= 2, data.count.isMultiple(of: 2), data.first == 0 {
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }
}
