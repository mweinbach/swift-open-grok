import Foundation
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokToolRuntime
import Testing
@testable import OpenGrokFileTools

@Suite("Read-file PDF and PowerPoint document parity", .serialized)
struct DocumentExtractionParityTests {
    @Test("PDF pages accept inclusive, open-ended, deduplicated ranges")
    func pdfPageRangeGrammar() throws {
        #expect(try DocumentExtraction.parsePageRange("3, 1-2, 2", pageCount: 8) == [0, 1, 2])
        #expect(try DocumentExtraction.parsePageRange("7-", pageCount: 8) == [6, 7])
        #expect(try DocumentExtraction.parsePageRange("7-999", pageCount: 8) == [6, 7])
        #expect(throws: DocumentExtractionError.self) {
            try DocumentExtraction.parsePageRange("0", pageCount: 8)
        }
        #expect(throws: DocumentExtractionError.self) {
            try DocumentExtraction.parsePageRange("4-2", pageCount: 8)
        }
        #expect(throws: DocumentExtractionError.self) {
            try DocumentExtraction.parsePageRange(", ,", pageCount: 8)
        }
        #expect(throws: DocumentExtractionError.self) {
            try DocumentExtraction.parsePageRange("1-21", pageCount: 30)
        }
    }

    @Test("real PDF text extraction respects page selection and normal line windows")
    func pdfTextExtractionUsesLiveReadTool() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try fixture.pdf(["Alpha", "Beta", "Gamma"]).write(to: fixture.path("report.pdf"))

        let output = try await fixture.read("report.pdf", pages: "2-3", format: "text")
        let content = try fixture.content(output)
        #expect(content.contains("--- Page 2 ---"))
        #expect(content.contains("Beta"))
        #expect(content.contains("--- Page 3 ---"))
        #expect(content.contains("Gamma"))
        #expect(!content.contains("Alpha"))
        #expect(content.hasPrefix("1→"))
    }

    @Test("PDF magic identifies documents without a PDF extension")
    func pdfMagicDetection() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try fixture.pdf(["Hidden PDF"]).write(to: fixture.path("report.bin"))
        let content = try fixture.content(await fixture.read("report.bin", format: "text"))
        #expect(content.contains("Hidden PDF"))
    }

    @Test("PDF text streams support FlateDecode")
    func compressedPDFText() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try fixture.pdf(["Compressed page"], compressed: true).write(to: fixture.path("flate.pdf"))
        let content = try fixture.content(await fixture.read("flate.pdf", format: "text"))
        #expect(content.contains("Compressed page"))
    }

    @Test("PDF documents above ten pages require explicit page selection")
    func largePDFRequiresPages() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try fixture.pdf((1...11).map { "Page \($0)" }).write(to: fixture.path("large.pdf"))

        let result = await fixture.result("large.pdf", format: "text")
        guard case .failure(let error) = result else {
            Issue.record("large PDF must require explicit pages")
            return
        }
        #expect(error.detail.contains("10 page auto-read limit"))

        let selected = try await fixture.read("large.pdf", pages: "11", format: "text")
        #expect(try fixture.content(selected).contains("Page 11"))
    }

    @Test("unsupported PDF formats fail without exposing document contents")
    func unsupportedPDFFormatFailsClosed() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try fixture.pdf(["private-document-secret"]).write(to: fixture.path("secret.pdf"))
        let result = await fixture.result("secret.pdf", format: "html")
        guard case .failure(let error) = result else {
            Issue.record("unsupported PDF format should fail")
            return
        }
        #expect(error.detail.contains("Invalid format"))
        #expect(!error.detail.contains("private-document-secret"))
    }

    @Test("default PDF image mode emits genuine JPEG pages when supported")
    func pdfImageModeIsTruthful() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try fixture.pdf(["Visible page"]).write(to: fixture.path("visible.pdf"))

        #if canImport(CoreGraphics) && canImport(ImageIO)
        let result = try await fixture.read("visible.pdf")
        guard case .object(let value) = result.value,
              value["type"] == .string("pdf_page_images"),
              let first = result.modelOutput.first,
              case .image(let mime, let encoded, _, _, _, _) = first,
              let bytes = Data(base64Encoded: encoded)
        else {
            Issue.record("PDF image mode did not return multimodal image output")
            return
        }
        #expect(mime == "image/jpeg")
        #expect(bytes.starts(with: [0xFF, 0xD8, 0xFF]))
        #else
        let text = try await fixture.read("visible.pdf")
        #expect(try fixture.content(text).contains("Visible page"))
        let image = await fixture.result("visible.pdf", format: "image")
        guard case .failure(let error) = image else {
            Issue.record("unsupported PDF image mode must fail")
            return
        }
        #expect(error.detail.contains("unavailable"))
        #endif
    }

    @Test("PowerPoint orders slides numerically and attaches matching speaker notes")
    func powerpointSlidesAndNotes() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        let archive = fixture.zip([
            ("ppt/slides/slide10.xml", fixture.slide(["Tenth"]), false),
            ("ppt/slides/slide2.xml", fixture.slide(["Sec", "ond &amp; slide"]), false),
            ("ppt/slides/slide1.xml", fixture.slide(["First"]), false),
            ("ppt/notesSlides/notesSlide2.xml", fixture.slide(["Second notes"]), false),
        ])
        try archive.write(to: fixture.path("deck.pptx"))

        let output = try fixture.content(await fixture.read("deck.pptx"))
        let first = try #require(output.range(of: "Slide 1"))
        let second = try #require(output.range(of: "Slide 2"))
        let tenth = try #require(output.range(of: "Slide 10"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < tenth.lowerBound)
        #expect(output.contains("ond & slide"))
        #expect(output.contains("Speaker Notes:"))
        #expect(output.contains("Second notes"))
    }

    @Test("PowerPoint reads ordinary DEFLATE-compressed XML entries")
    func deflatedPowerPoint() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        let archive = fixture.zip([
            ("ppt/slides/slide1.xml", fixture.slide(["Compressed PowerPoint"]), true),
        ])
        try archive.write(to: fixture.path("compressed.pptx"))

        #if os(Windows)
        let result = await fixture.result("compressed.pptx")
        if case .failure(let error) = result {
            #expect(error.detail.contains("Windows zlib"))
        }
        #else
        #expect(try fixture.content(await fixture.read("compressed.pptx")).contains("Compressed PowerPoint"))
        #endif
    }

    @Test("DrawingML concatenates split text runs and ignores text outside runs")
    func drawingMLTextRuns() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        let xml = """
        <p:sld xmlns:p="urn:p" xmlns:a="urn:a"><a:p><a:r><a:t>Hel</a:t></a:r>
        ignored<a:r><a:t>lo &amp; bye</a:t></a:r></a:p></p:sld>
        """
        try fixture.zip([("ppt/slides/slide1.xml", xml, false)]).write(to: fixture.path("runs.pptx"))
        let output = try fixture.content(await fixture.read("runs.pptx"))
        #expect(output.contains("Hello & bye"))
        #expect(!output.contains("ignored"))
    }

    @Test("PowerPoint external entities and document declarations are rejected")
    func powerpointXXEFailsClosed() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        let xml = """
        <!DOCTYPE p:sld [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
        <p:sld xmlns:p="urn:p" xmlns:a="urn:a"><a:p><a:t>&secret;</a:t></a:p></p:sld>
        """
        try fixture.zip([("ppt/slides/slide1.xml", xml, false)]).write(to: fixture.path("unsafe.pptx"))
        let result = await fixture.result("unsafe.pptx")
        guard case .failure(let error) = result else {
            Issue.record("external entities must be rejected")
            return
        }
        #expect(error.detail.contains("forbidden entity"))
        #expect(!error.detail.contains("root:"))
    }

    @Test("PowerPoint archive traversal and invalid integrity are rejected")
    func unsafeZipEntriesFailClosed() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        let traversal = fixture.zip([
            ("ppt/slides/../../secret.xml", fixture.slide(["secret"]), false),
            ("ppt/slides/slide1.xml", fixture.slide(["safe"]), false),
        ])
        try traversal.write(to: fixture.path("traversal.pptx"))
        guard case .failure = await fixture.result("traversal.pptx") else {
            Issue.record("archive traversal must be rejected")
            return
        }

        var corrupt = fixture.zip([("ppt/slides/slide1.xml", fixture.slide(["hello"]), false)])
        let nameLength = "ppt/slides/slide1.xml".utf8.count
        corrupt[30 + nameLength] ^= 0x01
        try corrupt.write(to: fixture.path("corrupt.pptx"))
        guard case .failure(let error) = await fixture.result("corrupt.pptx") else {
            Issue.record("corrupt archive entry must fail integrity checks")
            return
        }
        #expect(error.detail.contains("integrity"))
    }

    @Test("PowerPoint decompression bombs are rejected from trusted ZIP metadata")
    func zipBombFailsBeforeInflation() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        var archive = fixture.zip([
            ("ppt/slides/slide1.xml", fixture.slide(["small"]), true),
        ])
        let end = archive.count - 22
        let directory = Int(archive[end + 16])
            | Int(archive[end + 17]) << 8
            | Int(archive[end + 18]) << 16
            | Int(archive[end + 19]) << 24
        archive[directory + 24] = 0
        archive[directory + 25] = 0
        archive[directory + 26] = 0
        archive[directory + 27] = 4
        try archive.write(to: fixture.path("bomb.pptx"))

        guard case .failure(let error) = await fixture.result("bomb.pptx") else {
            Issue.record("declared 64 MiB XML entry must be rejected")
            return
        }
        #expect(error.detail.contains("unsafe") || error.detail.contains("limit"))
    }

    @Test("malformed PDF and workspace escapes never reveal document payloads")
    func malformedPDFAndWorkspaceEscapeFailClosed() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try Data("%PDF-1.4\nprivate-document-payload".utf8)
            .write(to: fixture.path("malformed.pdf"))
        guard case .failure(let invalid) = await fixture.result("malformed.pdf", format: "text") else {
            Issue.record("malformed PDF must fail")
            return
        }
        #expect(!invalid.detail.contains("private-document-payload"))

        guard case .failure = await fixture.result("../outside.pdf", format: "text") else {
            Issue.record("workspace traversal must fail before opening a PDF")
            return
        }
    }

    @Test("PowerPoint archives without slides fail safely")
    func emptyPresentationFails() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try fixture.zip([("[Content_Types].xml", "<Types/>", false)])
            .write(to: fixture.path("empty.pptx"))
        guard case .failure(let error) = await fixture.result("empty.pptx") else {
            Issue.record("presentation without slides must fail")
            return
        }
        #expect(error.detail.contains("No slides"))
    }

    @Test("ignored and oversized documents fail before extraction")
    func securityGatesRunBeforeExtraction() async throws {
        let fixture = try DocumentFixture()
        defer { fixture.dispose() }
        try "secret.pdf\n".write(to: fixture.path(".gitignore"), atomically: true, encoding: .utf8)
        try fixture.pdf(["private-secret"]).write(to: fixture.path("secret.pdf"))
        fixture.resources.extras.insert(GitIgnoreAccessPolicy(enabled: true))
        guard case .failure(let ignored) = await fixture.result("secret.pdf", format: "text") else {
            Issue.record("ignored PDFs must not be extracted")
            return
        }
        #expect(ignored.detail.contains("ignored"))
        #expect(!ignored.detail.contains("private-secret"))

        let large = fixture.path("large.pptx")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(DocumentExtraction.maximumDocumentBytes + 1))
        try handle.close()
        guard case .failure(let size) = await fixture.result("large.pptx") else {
            Issue.record("oversized presentations must fail before reading")
            return
        }
        #expect(size.detail.contains("50 MB"))
    }
}

private struct DocumentFixture {
    let root: URL
    let resources: ToolResources

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-grok-document-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        resources = ToolResources(cwd: root.path, sessionFolder: root.path, allowedRoots: [root.path])
    }

    func dispose() { try? FileManager.default.removeItem(at: root) }
    func path(_ name: String) -> URL { root.appendingPathComponent(name) }

    func result(_ name: String, pages: String? = nil, format: String? = nil) async -> Result<TypedToolOutput, ToolError> {
        var args: [String: JSONValue] = ["target_file": .string(name)]
        if let pages { args["pages"] = .string(pages) }
        if let format { args["format"] = .string(format) }
        return await ReadFileTool.run(args: .object(args), resources: resources)
    }

    func read(_ name: String, pages: String? = nil, format: String? = nil) async throws -> TypedToolOutput {
        try await result(name, pages: pages, format: format).get()
    }

    func content(_ output: TypedToolOutput) throws -> String {
        guard case .object(let value) = output.value,
              case .string(let text)? = value["content"]
        else { throw DocumentExtractionError.invalid("expected document text output") }
        return text
    }

    func slide(_ paragraphs: [String]) -> String {
        let content = paragraphs.map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
        return "<p:sld xmlns:p=\"urn:p\" xmlns:a=\"urn:a\">\(content)</p:sld>"
    }

    func pdf(_ pages: [String], compressed: Bool = false) -> Data {
        var output = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func append(_ string: String) { output.append(Data(string.utf8)) }
        offsets.append(output.count)
        append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        offsets.append(output.count)
        let children = pages.indices.map { "\(3 + $0 * 3) 0 R" }.joined(separator: " ")
        append("2 0 obj\n<< /Type /Pages /Kids [\(children)] /Count \(pages.count) >>\nendobj\n")
        for (index, text) in pages.enumerated() {
            let page = 3 + index * 3
            let content = page + 1
            let font = page + 2
            offsets.append(output.count)
            append("\(page) 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(content) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>\nendobj\n")
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
            let raw = Data("BT /F1 12 Tf 72 720 Td (\(escaped)) Tj ET".utf8)
            let stream = compressed ? zlibStored(raw) : raw
            offsets.append(output.count)
            append("\(content) 0 obj\n<< /Length \(stream.count)\(compressed ? " /Filter /FlateDecode" : "") >>\nstream\n")
            output.append(stream)
            append("\nendstream\nendobj\n")
            offsets.append(output.count)
            append("\(font) 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n")
        }
        let xref = output.count
        append("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n")
        for offset in offsets {
            append(String(format: "%010d 00000 n \n", offset))
        }
        append("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        return output
    }

    func zip(_ entries: [(String, String, Bool)]) -> Data {
        var local = Data()
        var central = Data()
        for (name, string, compressed) in entries {
            let nameBytes = Data(name.utf8)
            let original = Data(string.utf8)
            let payload = compressed ? rawStoredDeflate(original) : original
            let checksum = crc32(original)
            let offset = local.count

            local.appendLittle(UInt32(0x0403_4B50))
            local.appendLittle(UInt16(20))
            local.appendLittle(UInt16(0))
            local.appendLittle(UInt16(compressed ? 8 : 0))
            local.appendLittle(UInt16(0))
            local.appendLittle(UInt16(0))
            local.appendLittle(checksum)
            local.appendLittle(UInt32(payload.count))
            local.appendLittle(UInt32(original.count))
            local.appendLittle(UInt16(nameBytes.count))
            local.appendLittle(UInt16(0))
            local.append(nameBytes)
            local.append(payload)

            central.appendLittle(UInt32(0x0201_4B50))
            central.appendLittle(UInt16(20))
            central.appendLittle(UInt16(20))
            central.appendLittle(UInt16(0))
            central.appendLittle(UInt16(compressed ? 8 : 0))
            central.appendLittle(UInt16(0))
            central.appendLittle(UInt16(0))
            central.appendLittle(checksum)
            central.appendLittle(UInt32(payload.count))
            central.appendLittle(UInt32(original.count))
            central.appendLittle(UInt16(nameBytes.count))
            central.appendLittle(UInt16(0))
            central.appendLittle(UInt16(0))
            central.appendLittle(UInt16(0))
            central.appendLittle(UInt16(0))
            central.appendLittle(UInt32(0))
            central.appendLittle(UInt32(offset))
            central.append(nameBytes)
        }
        let centralOffset = local.count
        local.append(central)
        local.appendLittle(UInt32(0x0605_4B50))
        local.appendLittle(UInt16(0))
        local.appendLittle(UInt16(0))
        local.appendLittle(UInt16(entries.count))
        local.appendLittle(UInt16(entries.count))
        local.appendLittle(UInt32(central.count))
        local.appendLittle(UInt32(centralOffset))
        local.appendLittle(UInt16(0))
        return local
    }

    private func rawStoredDeflate(_ value: Data) -> Data {
        precondition(value.count <= Int(UInt16.max))
        var result = Data([0x01])
        let count = UInt16(value.count)
        result.appendLittle(count)
        result.appendLittle(~count)
        result.append(value)
        return result
    }

    private func zlibStored(_ value: Data) -> Data {
        var result = Data([0x78, 0x01])
        result.append(rawStoredDeflate(value))
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in value {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let checksum = (b << 16) | a
        result.append(UInt8((checksum >> 24) & 0xFF))
        result.append(UInt8((checksum >> 16) & 0xFF))
        result.append(UInt8((checksum >> 8) & 0xFF))
        result.append(UInt8(checksum & 0xFF))
        return result
    }

    private func crc32(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xFFFF_FFFF
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 {
                result = result & 1 == 0 ? result >> 1 : (result >> 1) ^ 0xEDB8_8320
            }
        }
        return result ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittle(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittle(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
