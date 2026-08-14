// FuzzyMatcherTests.swift
//
// Unit tests for FuzzyMatcher, FuzzyFileMatcher, and FuzzyFileMatcherDaemon.

import Foundation
import Testing
@testable import OpenGrokWorkspace

@Suite("FuzzyMatcherTests")
struct FuzzyMatcherTests {

    // MARK: - 1. FuzzyMatchResult & Codable

    @Test("FuzzyMatchResult Codable, Hashable, Equatable and defaults")
    func testFuzzyMatchResultModel() throws {
        let res = FuzzyMatchResult(
            path: "Sources/OpenGrokWorkspace/FuzzyMatcher.swift",
            score: 120,
            indices: [0, 5, 12],
            isDir: false
        )

        #expect(res.name == "FuzzyMatcher.swift")
        #expect(res.score == 120)
        #expect(res.indices == [0, 5, 12])
        #expect(!res.isDir)

        let encoder = JSONEncoder()
        let data = try encoder.encode(res)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FuzzyMatchResult.self, from: data)

        #expect(decoded == res)
        #expect(decoded.name == "FuzzyMatcher.swift")
        #expect(decoded.score == 120)
        #expect(decoded.indices == [0, 5, 12])
        #expect(!decoded.isDir)
    }

    // MARK: - 2. Exact Match

    @Test("Exact match on full string and exact basename match")
    func testExactMatch() {
        let matcher = FuzzyMatcher()

        let fullMatch = matcher.match(pattern: "hello", candidate: "hello")
        #expect(fullMatch != nil)
        #expect(fullMatch?.indices == [0, 1, 2, 3, 4])
        #expect(fullMatch!.score > 0)

        // Exact basename match on full path
        let path = "Sources/OpenGrokWorkspace/FuzzyMatcher.swift"
        let basenameMatch = matcher.match(pattern: "FuzzyMatcher.swift", candidate: path)
        #expect(basenameMatch != nil)
        #expect(basenameMatch?.name == "FuzzyMatcher.swift")

        // Exact basename without extension
        let basenameNoExtMatch = matcher.match(pattern: "FuzzyMatcher", candidate: path)
        #expect(basenameNoExtMatch != nil)

        // Compare score with non-exact match
        let partialMatch = matcher.match(pattern: "Fuzz", candidate: path)
        #expect(basenameMatch!.score > partialMatch!.score)
    }

    // MARK: - 3. Subsequence Match

    @Test("Subsequence matching and non-matching behavior")
    func testSubsequenceMatch() {
        let matcher = FuzzyMatcher()
        let candidate = "Sources/OpenGrokWorkspace/FuzzyMatcher.swift"

        // Valid subsequence
        let match1 = matcher.match(pattern: "fms", candidate: candidate)
        #expect(match1 != nil)
        #expect(match1!.indices.count == 3)

        // Non-subsequence should return nil
        let nonMatch = matcher.match(pattern: "xyz", candidate: candidate)
        #expect(nonMatch == nil)

        // Empty pattern matches with score 0
        let emptyMatch = matcher.match(pattern: "", candidate: candidate)
        #expect(emptyMatch != nil)
        #expect(emptyMatch?.score == 0)
        #expect(emptyMatch?.indices == [])

        // Pattern longer than candidate
        let tooLong = matcher.match(pattern: "abcdefghijklmnopqrstuvwxyz", candidate: "abc")
        #expect(tooLong == nil)

        // Empty candidate
        let emptyCand = matcher.match(pattern: "abc", candidate: "")
        #expect(emptyCand == nil)
    }

    // MARK: - 4. Bonus Scores

    @Test("Prefix match bonus")
    func testPrefixBonus() {
        let matcher = FuzzyMatcher()

        let prefixMatch = matcher.match(pattern: "Fuzzy", candidate: "FuzzyMatcher.swift")
        let middleMatch = matcher.match(pattern: "Fuzzy", candidate: "MyFuzzyMatcher.swift")

        #expect(prefixMatch != nil)
        #expect(middleMatch != nil)
        #expect(prefixMatch!.score > middleMatch!.score)
    }

    @Test("Consecutive character match bonus")
    func testConsecutiveBonus() {
        let matcher = FuzzyMatcher()

        let consecutive = matcher.match(pattern: "abc", candidate: "abcdef")
        let scattered = matcher.match(pattern: "abc", candidate: "a_b_c_d_e_f")

        #expect(consecutive != nil)
        #expect(scattered != nil)
        #expect(consecutive!.score > scattered!.score)
    }

    @Test("Word boundary bonuses for '/', '_', '-', '.'")
    func testWordBoundaryBonuses() {
        let matcher = FuzzyMatcher()

        // Match after '_'
        let afterUnderscore = matcher.match(pattern: "fb", candidate: "foo_bar")
        let inWord = matcher.match(pattern: "fb", candidate: "foob_ar")
        #expect(afterUnderscore != nil)
        #expect(inWord != nil)
        #expect(afterUnderscore!.score > inWord!.score)

        // Match after '/'
        let afterSlash = matcher.match(pattern: "fb", candidate: "foo/bar")
        #expect(afterSlash != nil)
        #expect(afterSlash!.score > inWord!.score)

        // Match after '-' and '.'
        let afterDash = matcher.match(pattern: "fb", candidate: "foo-bar")
        let afterDot = matcher.match(pattern: "fb", candidate: "foo.bar")
        #expect(afterDash != nil)
        #expect(afterDot != nil)
        #expect(afterDash!.score > inWord!.score)
        #expect(afterDot!.score > inWord!.score)
    }

    @Test("camelCase transition bonus")
    func testCamelCaseBonus() {
        let matcher = FuzzyMatcher()

        let camelMatch = matcher.match(pattern: "md", candidate: "makeDirectory")
        let plainMatch = matcher.match(pattern: "md", candidate: "makedirectory")

        #expect(camelMatch != nil)
        #expect(plainMatch != nil)
        #expect(camelMatch!.score > plainMatch!.score)
    }

    // MARK: - 5. Index Highlights

    @Test("Matched indices accurately highlight pattern characters")
    func testIndexHighlights() {
        let matcher = FuzzyMatcher()
        let candidate = "Sources/OpenGrokWorkspace/FuzzyMatcher.swift"
        let pattern = "OGWFM"

        let match = matcher.match(pattern: pattern, candidate: candidate)
        #expect(match != nil)
        guard let match else { return }

        #expect(match.indices.count == pattern.count)

        // Verify each index points to the expected character (case-insensitive)
        let candidateChars = Array(candidate)
        let patternChars = Array(pattern)
        for (i, idx) in match.indices.enumerated() {
            let c = candidateChars[Int(idx)]
            let p = patternChars[i]
            #expect(c.lowercased() == p.lowercased())
        }

        // Verify indices are strictly increasing
        for i in 1..<match.indices.count {
            #expect(match.indices[i] > match.indices[i - 1])
        }
    }

    // MARK: - 6. Case Sensitivity

    @Test("Case-insensitivity by default and case-sensitive option")
    func testCaseSensitivity() {
        let caseInsensitiveMatcher = FuzzyMatcher(caseSensitive: false)
        let caseSensitiveMatcher = FuzzyMatcher(caseSensitive: true)

        #expect(caseInsensitiveMatcher.match(pattern: "fuzzy", candidate: "FUZZY") != nil)
        #expect(caseInsensitiveMatcher.match(pattern: "FUZZY", candidate: "fuzzy") != nil)

        #expect(caseSensitiveMatcher.match(pattern: "fuzzy", candidate: "FUZZY") == nil)
        #expect(caseSensitiveMatcher.match(pattern: "fuzzy", candidate: "fuzzy") != nil)
    }

    // MARK: - 7. Ranking

    @Test("Ranking candidates by score and brevity")
    func testRanking() {
        let matcher = FuzzyMatcher()
        let paths = [
            "src/other/path/file.txt",
            "file.txt",
            "src/file.txt",
            "random/unrelated.md"
        ]

        let results = matcher.rank(pattern: "file", paths: paths)
        #expect(results.count == 3)
        // "file.txt" should be ranked #1 due to prefix/exact basename match and shortest length
        #expect(results[0].path == "file.txt")
        #expect(results[1].path == "src/file.txt")
        #expect(results[2].path == "src/other/path/file.txt")
    }

    // MARK: - 8. Gitignore & Directory Tree Walker

    @Test("FuzzyFileTreeWalker respects .gitignore and hidden flags")
    func testTreeWalkerAndGitignore() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Setup directory structure
        // tempDir/
        //   ├── .git/ (should be ignored)
        //   │   └── config
        //   ├── .hidden_file (hidden)
        //   ├── .gitignore (ignores *.ignored and build/)
        //   ├── root.txt
        //   ├── test.ignored (ignored)
        //   ├── build/ (ignored dir)
        //   │   └── output.bin
        //   └── src/
        //       ├── app.swift
        //       └── util.swift

        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "gitconfig".write(to: tempDir.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        try "hidden".write(to: tempDir.appendingPathComponent(".hidden_file"), atomically: true, encoding: .utf8)
        try "*.ignored\nbuild/\n".write(to: tempDir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "root".write(to: tempDir.appendingPathComponent("root.txt"), atomically: true, encoding: .utf8)
        try "ignored".write(to: tempDir.appendingPathComponent("test.ignored"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("build"), withIntermediateDirectories: true)
        try "bin".write(to: tempDir.appendingPathComponent("build/output.bin"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "swift".write(to: tempDir.appendingPathComponent("src/app.swift"), atomically: true, encoding: .utf8)
        try "swift".write(to: tempDir.appendingPathComponent("src/util.swift"), atomically: true, encoding: .utf8)

        // 1. Normal walk (hidden: false, respectGitignore: true)
        let normalEntries = FuzzyFileTreeWalker.walk(root: tempDir, hidden: false, respectGitignore: true)
        let normalPaths = Set(normalEntries.map(\.relativePath))

        #expect(normalPaths.contains("root.txt"))
        #expect(normalPaths.contains("src"))
        #expect(normalPaths.contains("src/app.swift"))
        #expect(normalPaths.contains("src/util.swift"))

        // Should NOT contain .git, .hidden_file, test.ignored, build
        #expect(!normalPaths.contains(".git"))
        #expect(!normalPaths.contains(".hidden_file"))
        #expect(!normalPaths.contains("test.ignored"))
        #expect(!normalPaths.contains("build"))
        #expect(!normalPaths.contains("build/output.bin"))

        // 2. Hidden walk (hidden: true)
        let hiddenEntries = FuzzyFileTreeWalker.walk(root: tempDir, hidden: true, respectGitignore: true)
        let hiddenPaths = Set(hiddenEntries.map(\.relativePath))
        #expect(hiddenPaths.contains(".hidden_file"))
        #expect(hiddenPaths.contains(".gitignore"))
        #expect(!hiddenPaths.contains(".git")) // .git directory is always omitted
    }

    // MARK: - 9. FuzzyFileMatcherDaemon

    @Test("FuzzyFileMatcherDaemon querying, directory filtering, and generation updates")
    func testFuzzyFileMatcherDaemon() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("Sources/MyModule"), withIntermediateDirectories: true)
        try "swift".write(to: tempDir.appendingPathComponent("Sources/MyModule/MyClass.swift"), atomically: true, encoding: .utf8)
        try "swift".write(to: tempDir.appendingPathComponent("Sources/MyModule/Helper.swift"), atomically: true, encoding: .utf8)
        try "md".write(to: tempDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "dot".write(to: tempDir.appendingPathComponent(".secret.txt"), atomically: true, encoding: .utf8)

        let daemon = FuzzyFileMatcherDaemon(root: tempDir, maxTopK: 10)

        // Initial query: empty query lists all non-hidden items
        let initialResults = await daemon.query("", isDir: false, hidden: false)
        #expect(initialResults.totalMatches > 0)
        #expect(initialResults.generation > 0)
        #expect(initialResults.topk.allSatisfy { $0.score == 0 })

        // Query specific file
        let fileResults = await daemon.query("MyClass", isDir: false, hidden: false)
        #expect(fileResults.totalMatches >= 1)
        #expect(fileResults.topk.first?.name == "MyClass.swift")
        #expect(fileResults.topk.first!.score > 0)
        #expect(!fileResults.topk.first!.indices.isEmpty)

        // Query with isDir = true
        let dirResults = await daemon.query("Sources", isDir: true, hidden: false)
        #expect(dirResults.totalMatches >= 1)
        #expect(dirResults.topk.allSatisfy { $0.isDir })

        // Query hidden file with hidden = false vs hidden = true
        let noHidden = await daemon.query("secret", isDir: false, hidden: false)
        #expect(noHidden.totalMatches == 0)

        let withHidden = await daemon.query("secret", isDir: false, hidden: true)
        #expect(withHidden.totalMatches == 1)
        #expect(withHidden.topk.first?.name == ".secret.txt")

        // Generation increment on walk restart
        let genBefore = await daemon.generation
        await daemon.restartWalk(hidden: false, respectGitignore: true)
        let genAfter = await daemon.generation
        #expect(genAfter > genBefore)
    }
}
