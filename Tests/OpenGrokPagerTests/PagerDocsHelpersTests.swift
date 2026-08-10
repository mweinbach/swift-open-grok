import Foundation
@testable import OpenGrokPager
import Testing

@Suite("Pager docs helpers")
struct PagerDocsHelpersTests {
    @Test("getHowtoDoc resolves every pinned title and both tables")
    func getHowtoDocResolvesTitles() throws {
        for doc in PagerDocs.all {
            #expect(PagerDocs.getHowtoDoc(title: doc.title) == doc.content)
            #expect(PagerDocs.getHowtoDoc(title: asciiUppercased(doc.title)) == doc.content)
        }
        #expect(PagerDocs.getHowtoDoc(title: "no such doc") == nil)
        #expect(PagerDocs.getHowtoDoc(title: "howto") == nil)
        #expect(PagerDocs.getHowtoDoc(title: "guides") == nil)
    }

    @Test("extraction writes the exact embedded user-guide bytes")
    func extractionWritesExactCorpusBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("docs/user-guide", isDirectory: true)

        let result = try PagerDocs.extractUserGuideDocs(to: destination)
        #expect(result == .extracted(version: PagerDocs.userGuideCorpusVersion))

        for doc in PagerDocs.userGuide {
            let bytes = try Data(contentsOf: destination.appendingPathComponent(doc.filename))
            #expect(bytes == Data(doc.content.utf8), "extracted bytes drifted for \(doc.filename)")
        }
        let extractedNames = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(Set(extractedNames) == Set(
            PagerDocs.userGuide.map(\.filename) + [PagerDocs.extractionVersionFileName]
        ))
        let installedVersion = try String(
            contentsOf: destination.appendingPathComponent(PagerDocs.extractionVersionFileName),
            encoding: .utf8
        )
        #expect(installedVersion == "\(PagerDocs.userGuideCorpusVersion)\n")
    }

    @Test("matching versions are idempotent and stale versions refresh atomically")
    func extractionIsVersionedAndIdempotent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("guides", isDirectory: true)

        let first = try PagerDocs.extractUserGuideDocs(to: destination)
        #expect(first == .extracted(version: PagerDocs.userGuideCorpusVersion))
        let note = destination.appendingPathComponent("notes.md")
        try Data("user notes".utf8).write(to: note)

        let second = try PagerDocs.extractUserGuideDocs(to: destination)
        #expect(second == .unchanged(version: PagerDocs.userGuideCorpusVersion))
        #expect(try Data(contentsOf: note) == Data("user notes".utf8))

        try Data("old-version\n".utf8).write(
            to: destination.appendingPathComponent(PagerDocs.extractionVersionFileName)
        )
        try Data("stale".utf8).write(
            to: destination.appendingPathComponent("99-removed.md")
        )
        let refreshed = try PagerDocs.extractUserGuideDocs(to: destination)
        #expect(refreshed == .extracted(version: PagerDocs.userGuideCorpusVersion))
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("99-removed.md").path
        ))
        #expect(try Data(contentsOf: note) == Data("user notes".utf8))
    }

    @Test("a staging failure leaves the installed corpus byte-exact")
    func stagingFailureDoesNotPublish() throws {
        struct InjectedFailure: Error {}

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("guides", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old bytes".utf8).write(
            to: destination.appendingPathComponent("01-getting-started.md")
        )
        try Data("old-version\n".utf8).write(
            to: destination.appendingPathComponent(PagerDocs.extractionVersionFileName)
        )
        try Data("user notes".utf8).write(to: destination.appendingPathComponent("notes.md"))
        let before = try directorySnapshot(destination)

        #expect(throws: InjectedFailure.self) {
            try PagerDocs.extractUserGuideDocs(to: destination) { _, index in
                if index == 1 { throw InjectedFailure() }
            }
        }

        #expect(try directorySnapshot(destination) == before)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!siblings.contains { $0.hasSuffix(".staging") })
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-pager-docs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func asciiUppercased(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
        (0x61...0x7A).contains(scalar.value)
            ? Unicode.Scalar(scalar.value - 0x20)!
            : scalar
    }))
}

private func directorySnapshot(_ directory: URL) throws -> [String: Data] {
    var snapshot: [String: Data] = [:]
    for item in try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey]
    ) {
        let values = try item.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            for (name, data) in try directorySnapshot(item) {
                snapshot["\(item.lastPathComponent)/\(name)"] = data
            }
        } else {
            snapshot[item.lastPathComponent] = try Data(contentsOf: item)
        }
    }
    return snapshot
}
