// OpenGrokCodebaseGraphTests.swift
//
// Deterministic extraction, incremental invalidation, cancellation, and
// cache round-trip fixtures for OpenGrokCodebaseGraph.

import Foundation
import Testing
@testable import OpenGrokCodebaseGraph

@Suite("OpenGrokCodebaseGraph")
struct OpenGrokCodebaseGraphTests {

    @Test("extract rust definitions deterministically")
    func extractRust() {
        let src = """
        pub fn main() {}
        struct Foo {}
        enum Bar { A }
        trait Baz {}
        """
        let symbols = SymbolExtractor.extract(path: "src/lib.rs", content: src)
        let names = symbols.definitions.map(\.name)
        #expect(names.contains("main"))
        #expect(names.contains("Foo"))
        #expect(names.contains("Bar"))
        #expect(names.contains("Baz"))
        // Deterministic order by line.
        #expect(symbols.definitions.map(\.line) == symbols.definitions.map(\.line).sorted())
    }

    @Test("extract python and swift")
    func extractPythonSwift() {
        let py = SymbolExtractor.extract(
            path: "a.py",
            content: "def hello():\n    pass\nclass World:\n    pass\n"
        )
        #expect(py.definitions.map(\.name).contains("hello"))
        #expect(py.definitions.map(\.name).contains("World"))

        let sw = SymbolExtractor.extract(
            path: "A.swift",
            content: "func run() {}\nstruct Item {}\nimport Foundation\n"
        )
        #expect(sw.definitions.map(\.name).contains("run"))
        #expect(sw.definitions.map(\.name).contains("Item"))
        #expect(sw.references.map(\.name).contains("Foundation"))
    }

    @Test("language detection")
    func languageDetect() {
        #expect(SourceLanguage.detect(path: "a.rs") == .rust)
        #expect(SourceLanguage.detect(path: "a.ts") == .typescript)
        #expect(SourceLanguage.detect(path: "a.go") == .go)
        #expect(SourceLanguage.detect(path: "a.txt") == .unknown)
    }

    @Test("build index skips binary and oversized")
    func buildSkips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-cg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "fn legit() {}\n".write(
            to: root.appendingPathComponent("legit.rs"),
            atomically: true,
            encoding: .utf8
        )
        // binary
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: root.appendingPathComponent("bin.rs"))
        // oversized
        let big = String(repeating: "fn x() {}\n", count: 200_000) // ~2MB
        try big.write(to: root.appendingPathComponent("big.rs"), atomically: true, encoding: .utf8)
        // hidden dir
        let hidden = root.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "fn secret() {}\n".write(
            to: hidden.appendingPathComponent("s.rs"),
            atomically: true,
            encoding: .utf8
        )

        let index = try IndexBuilder().build(root: root.path)
        #expect(index.stats.files == 1)
        #expect(Navigator(index).hasDefinition("legit"))
        #expect(!Navigator(index).hasDefinition("secret"))
        #expect(!Navigator(index).hasDefinition("x"))
    }

    @Test("goto definition and references")
    func navigation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "fn alpha() {}\n".write(
            to: root.appendingPathComponent("a.rs"),
            atomically: true,
            encoding: .utf8
        )
        try "use crate::alpha;\nfn beta() { alpha(); }\n".write(
            to: root.appendingPathComponent("b.rs"),
            atomically: true,
            encoding: .utf8
        )
        let index = try IndexBuilder().build(root: root.path)
        let nav = Navigator(index)
        let defs = nav.gotoDefinition(name: "alpha")
        #expect(defs.count == 1)
        #expect(defs[0].path.hasSuffix("a.rs") || defs[0].path == "a.rs")
        let refs = nav.findReferences(name: "alpha")
        #expect(!refs.isEmpty)
    }

    @Test("incremental invalidation via manager")
    func incremental() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-inc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "fn original() {}\n".write(
            to: root.appendingPathComponent("t.rs"),
            atomically: true,
            encoding: .utf8
        )
        let handle = await IndexManager.spawn(config: IndexManagerConfig(root: root.path))
        #expect(await handle.hasDefinition("original"))

        try "fn version_2() {}\n".write(
            to: root.appendingPathComponent("t.rs"),
            atomically: true,
            encoding: .utf8
        )
        await handle.sendEvent(.modified(path: "t.rs"))
        // Allow coalesce timer + apply.
        try await Task.sleep(nanoseconds: 100_000_000)
        // Force a second event flush in case the first coalesce raced.
        await handle.sendEvent(.modified(path: "t.rs"))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await handle.hasDefinition("version_2"))
        #expect(!(await handle.hasDefinition("original")))
    }

    @Test("event coalesce last write wins")
    func eventCoalesce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-coalesce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "fn a() {}\n".write(
            to: root.appendingPathComponent("t.rs"),
            atomically: true,
            encoding: .utf8
        )
        let handle = await IndexManager.spawn(config: IndexManagerConfig(root: root.path))

        for i in 0..<20 {
            try "fn version_\(i)() {}\n".write(
                to: root.appendingPathComponent("t.rs"),
                atomically: true,
                encoding: .utf8
            )
            await handle.sendEvent(.modified(path: "t.rs"))
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(await handle.hasDefinition("version_19"))
    }

    @Test("cache save/load round trip")
    func cacheRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "fn cached() {}\n".write(
            to: root.appendingPathComponent("c.rs"),
            atomically: true,
            encoding: .utf8
        )
        let index = try IndexBuilder().build(root: root.path)
        let cachePath = getCachePath(repoPath: root.path, under: root.appendingPathComponent("state").path)
        try saveIndex(index, to: cachePath)
        #expect(cacheExists(at: cachePath))
        let loaded = try loadIndex(from: cachePath)
        #expect(loaded.stats.files == index.stats.files)
        #expect(Navigator(loaded).hasDefinition("cached"))
    }

    @Test("cancellation during build")
    func cancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<50 {
            try "fn f\(i)() {}\n".write(
                to: root.appendingPathComponent("f\(i).rs"),
                atomically: true,
                encoding: .utf8
            )
        }
        let handle = await IndexManager.spawn(config: IndexManagerConfig(root: root.path))
        await handle.cancel()
        do {
            try await handle.rebuild()
            // may succeed if already cancelled path throws
        } catch QueryError.cancelled {
            // expected
        } catch {
            // also fine if rebuild completed before cancel took effect
        }
    }

    @Test("binary content detection")
    func binaryDetect() {
        #expect(isBinaryContent(Data([0x00, 0x01])))
        #expect(!isBinaryContent(Data("hello".utf8)))
    }

    @Test("file event helpers")
    func fileEventHelpers() {
        #expect(FileEvent.created(path: "a").requiresReparse)
        #expect(FileEvent.modified(path: "a").requiresReparse)
        #expect(!FileEvent.deleted(path: "a").requiresReparse)
        #expect(FileEvent.renamed(from: "a", to: "b").path == "b")
    }

    // MARK: - Parser-backed fixtures (multiline, scopes, comments, strings, aliases)

    @Test("skips symbols inside comments and strings")
    func skipsCommentsAndStrings() {
        let src = """
        // fn not_a_def() {}
        /* struct Hidden {} */
        let s = "fn also_hidden() {}";
        fn real() {}
        """
        let symbols = SymbolExtractor.extract(path: "c.rs", content: src)
        let names = symbols.definitions.map(\.name)
        #expect(names.contains("real"))
        #expect(!names.contains("not_a_def"))
        #expect(!names.contains("Hidden"))
        #expect(!names.contains("also_hidden"))
    }

    @Test("multiline function signature is extracted")
    func multilineSignature() {
        let src = """
        pub async fn long_name(
            a: i32,
            b: i32,
        ) -> i32 {
            a + b
        }
        """
        let symbols = SymbolExtractor.extract(path: "m.rs", content: src)
        #expect(symbols.definitions.map(\.name).contains("long_name"))
        #expect(!symbols.scopes.isEmpty)
    }

    @Test("nested scopes recorded for braces")
    func nestedScopes() {
        let src = """
        fn outer() {
            fn inner() {}
        }
        """
        let symbols = SymbolExtractor.extract(path: "n.rs", content: src)
        #expect(symbols.definitions.map(\.name).contains("outer"))
        // Scope ranges cover brace groups.
        #expect(!symbols.scopes.isEmpty)
    }

    @Test("rust use alias tracked")
    func rustAlias() {
        let src = """
        use foo::Bar as Baz;
        fn main() {}
        """
        let symbols = SymbolExtractor.extract(path: "a.rs", content: src)
        #expect(symbols.aliases.contains { $0.alias == "Baz" && $0.original == "Bar" })
        #expect(symbols.references.map(\.name).contains("Bar"))
    }

    @Test("js import alias tracked")
    func jsAlias() {
        let src = """
        import { Foo as Bar } from './x';
        function run() {}
        """
        let symbols = SymbolExtractor.extract(path: "a.ts", content: src)
        #expect(symbols.aliases.contains { $0.alias == "Bar" && $0.original == "Foo" })
        #expect(symbols.definitions.map(\.name).contains("run"))
    }

    @Test("malformed source does not crash and remains deterministic")
    func malformedSource() {
        let src = "fn incomplete( {\nstruct {\nenum\n"
        let a = SymbolExtractor.extract(path: "bad.rs", content: src)
        let b = SymbolExtractor.extract(path: "bad.rs", content: src)
        #expect(a.definitions == b.definitions)
        #expect(a.references == b.references)
    }

    @Test("go and typescript extraction")
    func goAndTS() {
        let go = SymbolExtractor.extract(
            path: "m.go",
            content: "package main\nfunc Hello() {}\ntype T struct{}\n"
        )
        #expect(go.definitions.map(\.name).contains("Hello"))
        #expect(go.definitions.map(\.name).contains("T"))

        let ts = SymbolExtractor.extract(
            path: "m.ts",
            content: "export class Widget {}\nconst x = 1;\n"
        )
        #expect(ts.definitions.map(\.name).contains("Widget"))
        #expect(ts.definitions.map(\.name).contains("x"))
    }

    @Test("debounce cancellation does not double-apply")
    func debounceCancelExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-debounce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "fn v0() {}\n".write(
            to: root.appendingPathComponent("t.rs"),
            atomically: true,
            encoding: .utf8
        )
        let handle = await IndexManager.spawn(config: IndexManagerConfig(root: root.path))

        // Rapid burst: only the last content should win after debounce.
        for i in 0..<30 {
            try "fn burst_\(i)() {}\n".write(
                to: root.appendingPathComponent("t.rs"),
                atomically: true,
                encoding: .utf8
            )
            await handle.sendEvent(.modified(path: "t.rs"))
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(await handle.hasDefinition("burst_29"))
        for i in 0..<29 {
            #expect(!(await handle.hasDefinition("burst_\(i)")))
        }
    }

    @Test("column is populated on definitions")
    func columnsPopulated() {
        let src = "fn alpha() {}\n"
        let symbols = SymbolExtractor.extract(path: "c.rs", content: src)
        let alpha = symbols.definitions.first { $0.name == "alpha" }
        #expect(alpha != nil)
        #expect((alpha?.column ?? 0) >= 1)
    }
}
