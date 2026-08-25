import Foundation
import OpenGrokToolRegistry
#if canImport(FoundationXML)
import FoundationXML
#endif

enum PowerPointDocumentExtractor {
    static func extract(_ bytes: Data, deadline: DocumentExtractionDeadline) throws -> String {
        let archive = try SafePowerPointArchive(bytes: bytes, deadline: deadline)
        let slideNumbers = archive.names.compactMap { name -> Int? in
            guard name.hasPrefix("ppt/slides/slide"), name.hasSuffix(".xml") else { return nil }
            let number = name.dropFirst("ppt/slides/slide".count).dropLast(".xml".count)
            guard !number.isEmpty, number.allSatisfy(\.isNumber),
                  let value = Int(number), value > 0, value <= Int(UInt32.max)
            else { return nil }
            return value
        }.sorted()
        guard !slideNumbers.isEmpty else {
            throw DocumentExtractionError.invalid("No slides found in PPTX")
        }

        var output = ""
        var totalInflated = 0
        for number in slideNumbers {
            try deadline.check()
            let slideName = "ppt/slides/slide\(number).xml"
            let slide = try archive.read(slideName, deadline: deadline)
            totalInflated += slide.count
            guard totalInflated <= DocumentExtraction.maximumXMLBytes else {
                throw DocumentExtractionError.limit("PowerPoint XML exceeds the total decompressed size limit")
            }
            let slideText = try DrawingMLTextExtractor.extract(slide, deadline: deadline)

            if !output.isEmpty { output += "\n\n" }
            output += "--- Slide \(number) ---\n"
            output += slideText

            let notesName = "ppt/notesSlides/notesSlide\(number).xml"
            if archive.contains(notesName) {
                let notes = try archive.read(notesName, deadline: deadline)
                totalInflated += notes.count
                guard totalInflated <= DocumentExtraction.maximumXMLBytes else {
                    throw DocumentExtractionError.limit("PowerPoint XML exceeds the total decompressed size limit")
                }
                if let text = try? DrawingMLTextExtractor.extract(notes, deadline: deadline),
                   !text.isEmpty {
                    output += "\n\nSpeaker Notes:\n"
                    output += text
                }
            }
            guard output.utf8.count <= defaultToolOutputBytes * 4 else {
                throw DocumentExtractionError.limit("PowerPoint extracted text exceeds the output safety limit")
            }
        }
        return output
    }
}

private struct SafePowerPointArchive: Sendable {
    private struct Entry: Sendable {
        let name: String
        let compression: UInt16
        let checksum: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: Data
    private let entries: [String: Entry]

    var names: [String] { Array(entries.keys) }

    init(bytes: Data, deadline: DocumentExtractionDeadline) throws {
        self.bytes = bytes
        guard bytes.count >= 22 else {
            throw DocumentExtractionError.invalid("Failed to open PPTX archive: missing ZIP directory")
        }

        let minimum = max(0, bytes.count - 65_557)
        var directoryEnd: Int?
        for offset in stride(from: bytes.count - 22, through: minimum, by: -1) {
            if offset.isMultiple(of: 2048) { try deadline.check() }
            if Self.read32(bytes, offset) == 0x0605_4B50,
               let commentLength = Self.read16(bytes, offset + 20),
               offset + 22 + Int(commentLength) == bytes.count {
                directoryEnd = offset
                break
            }
        }
        guard let end = directoryEnd,
              Self.read16(bytes, end + 4) == 0,
              Self.read16(bytes, end + 6) == 0,
              let count = Self.read16(bytes, end + 10),
              Self.read16(bytes, end + 8) == count,
              count > 0,
              count <= 4096,
              let centralSize = Self.read32(bytes, end + 12),
              let centralOffset = Self.read32(bytes, end + 16),
              centralOffset != UInt32.max,
              Int(centralOffset) <= end,
              Int(centralSize) <= end - Int(centralOffset)
        else {
            throw DocumentExtractionError.invalid("Failed to open PPTX archive: invalid ZIP central directory")
        }

        var collected: [String: Entry] = [:]
        var offset = Int(centralOffset)
        let centralEnd = offset + Int(centralSize)
        for _ in 0..<Int(count) {
            try deadline.check()
            guard offset <= centralEnd - 46,
                  Self.read32(bytes, offset) == 0x0201_4B50,
                  let flags = Self.read16(bytes, offset + 8),
                  flags & 0x0001 == 0,
                  let method = Self.read16(bytes, offset + 10),
                  method == 0 || method == 8,
                  let checksum = Self.read32(bytes, offset + 16),
                  let compressed = Self.read32(bytes, offset + 20),
                  let uncompressed = Self.read32(bytes, offset + 24),
                  compressed != UInt32.max,
                  uncompressed != UInt32.max,
                  Int(uncompressed) < DocumentExtraction.maximumXMLBytes,
                  let nameLength = Self.read16(bytes, offset + 28),
                  let extraLength = Self.read16(bytes, offset + 30),
                  let commentLength = Self.read16(bytes, offset + 32),
                  let localOffset = Self.read32(bytes, offset + 42),
                  localOffset != UInt32.max
            else {
                throw DocumentExtractionError.invalid("PPTX contains an unsafe or unsupported ZIP entry")
            }
            let headerSize = 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
            guard headerSize <= centralEnd - offset,
                  let name = String(
                    data: bytes.subdata(in: (offset + 46)..<(offset + 46 + Int(nameLength))),
                    encoding: .utf8
                  ),
                  Self.safeEntryName(name),
                  collected[name] == nil
            else {
                throw DocumentExtractionError.invalid("PPTX contains a duplicate or unsafe archive path")
            }
            collected[name] = Entry(
                name: name,
                compression: method,
                checksum: checksum,
                compressedSize: Int(compressed),
                uncompressedSize: Int(uncompressed),
                localHeaderOffset: Int(localOffset)
            )
            offset += headerSize
        }
        guard offset == centralEnd else {
            throw DocumentExtractionError.invalid("PPTX central directory has an invalid length")
        }
        self.entries = collected
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func read(_ name: String, deadline: DocumentExtractionDeadline) throws -> Data {
        guard let entry = entries[name] else {
            throw DocumentExtractionError.invalid("Required PowerPoint slide entry is missing")
        }
        let start = entry.localHeaderOffset
        guard start <= bytes.count - 30,
              Self.read32(bytes, start) == 0x0403_4B50,
              let flags = Self.read16(bytes, start + 6),
              flags & 0x0001 == 0,
              Self.read16(bytes, start + 8) == entry.compression,
              let nameLength = Self.read16(bytes, start + 26),
              let extraLength = Self.read16(bytes, start + 28)
        else {
            throw DocumentExtractionError.invalid("PPTX entry has an invalid local ZIP header")
        }
        let dataStart = start + 30 + Int(nameLength) + Int(extraLength)
        guard dataStart >= start,
              dataStart <= bytes.count,
              entry.compressedSize <= bytes.count - dataStart,
              String(data: bytes.subdata(in: (start + 30)..<(start + 30 + Int(nameLength))), encoding: .utf8) == name
        else {
            throw DocumentExtractionError.invalid("PPTX entry metadata does not match its archive payload")
        }

        let compressed = bytes.subdata(in: dataStart..<(dataStart + entry.compressedSize))
        let output: Data
        switch entry.compression {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw DocumentExtractionError.invalid("Stored PPTX entry has inconsistent lengths")
            }
            output = compressed
        case 8:
            output = try DocumentInflater.inflate(
                compressed,
                raw: true,
                expectedSize: entry.uncompressedSize,
                maximumOutput: DocumentExtraction.maximumXMLBytes - 1,
                deadline: deadline
            )
        default:
            throw DocumentExtractionError.unsupported("Unsupported PowerPoint archive compression")
        }
        guard try Self.crc32(output, deadline: deadline) == entry.checksum else {
            throw DocumentExtractionError.invalid("PPTX entry failed its integrity check")
        }
        return output
    }

    private static func safeEntryName(_ name: String) -> Bool {
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              !name.contains("\\"),
              !name.contains("\0"),
              !name.contains(":")
        else { return false }
        let normalized = name.hasSuffix("/") ? String(name.dropLast()) : name
        guard !normalized.isEmpty else { return false }
        return normalized.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static let checksumTable: [UInt32] = (UInt32(0)...255).map { initial in
        var value = initial
        for _ in 0..<8 {
            value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xEDB8_8320
        }
        return value
    }

    private static func crc32(_ data: Data, deadline: DocumentExtractionDeadline) throws -> UInt32 {
        var result: UInt32 = 0xFFFF_FFFF
        for (index, byte) in data.enumerated() {
            if index.isMultiple(of: 4096) { try deadline.check() }
            result = checksumTable[Int((result ^ UInt32(byte)) & 0xFF)] ^ (result >> 8)
        }
        return result ^ 0xFFFF_FFFF
    }
}

private final class DrawingMLTextExtractor: NSObject, XMLParserDelegate {
    private let deadline: DocumentExtractionDeadline
    private var text = ""
    private var textRunDepth = 0
    private var failure: DocumentExtractionError?

    private init(deadline: DocumentExtractionDeadline) {
        self.deadline = deadline
    }

    static func extract(_ bytes: Data, deadline: DocumentExtractionDeadline) throws -> String {
        try deadline.check()
        guard bytes.count < DocumentExtraction.maximumXMLBytes,
              let raw = String(data: bytes, encoding: .utf8)
        else {
            throw DocumentExtractionError.invalid("PowerPoint slide XML is invalid or oversized")
        }
        let folded = raw.lowercased()
        guard !folded.contains("<!doctype"), !folded.contains("<!entity") else {
            throw DocumentExtractionError.invalid("PowerPoint slide XML contains a forbidden entity declaration")
        }
        let delegate = DrawingMLTextExtractor(deadline: deadline)
        let parser = XMLParser(data: bytes)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else {
            if let failure = delegate.failure { throw failure }
            throw DocumentExtractionError.invalid("PowerPoint slide XML is malformed")
        }
        return delegate.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard check(parser) else { return }
        if Self.localName(elementName, qualifiedName: qName) == "t" {
            textRunDepth += 1
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard check(parser) else { return }
        switch Self.localName(elementName, qualifiedName: qName) {
        case "t":
            textRunDepth = max(0, textRunDepth - 1)
        case "p" where !text.isEmpty && !text.hasSuffix("\n"):
            text.append("\n")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard textRunDepth > 0, check(parser) else { return }
        text += string
        if text.utf8.count > defaultToolOutputBytes * 4 {
            failure = .limit("PowerPoint extracted text exceeds its output limit")
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        failure = .invalid("External XML entities are forbidden in PowerPoint documents")
        parser.abortParsing()
        return nil
    }

    private func check(_ parser: XMLParser) -> Bool {
        do {
            try deadline.check()
            return true
        } catch let error as DocumentExtractionError {
            failure = error
            parser.abortParsing()
            return false
        } catch {
            failure = .invalid("PowerPoint XML parsing failed")
            parser.abortParsing()
            return false
        }
    }

    private static func localName(_ elementName: String, qualifiedName: String?) -> String {
        let value = qualifiedName ?? elementName
        return value.split(separator: ":").last.map(String.init) ?? value
    }
}
