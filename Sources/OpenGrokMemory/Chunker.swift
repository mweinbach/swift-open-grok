import Foundation
import OpenGrokConfigTypes
import OpenGrokFileUtils

public func chunkHash(_ text: String) -> String {
    FileChecksum.sha256Hex(text)
}

public func chunkMarkdown(_ content: String, config: MemoryIndexConfig = MemoryIndexConfig()) -> [MemoryChunk] {
    guard !content.isEmpty else { return [] }

    let maxChars = max(1, config.maxChunkChars)
    let overlapChars = max(0, config.chunkOverlapChars)
    let lines = markdownLines(content)
    guard !lines.isEmpty else { return [] }

    if content.utf8.count <= maxChars {
        return [MemoryChunk(text: content, startLine: 0, endLine: lines.count)]
    }

    let sections = splitByHeaders(lines)
    var chunks: [MemoryChunk] = []
    for section in sections {
        let sectionText = section.lines.joined(separator: "\n")
        if sectionText.utf8.count <= maxChars {
            chunks.append(
                MemoryChunk(
                    text: addHeaderContext(section.headerContext, sectionText),
                    startLine: section.startLine,
                    endLine: section.startLine + section.lines.count
                )
            )
        } else {
            chunks.append(contentsOf: splitSectionByParagraphs(section, maxChars: maxChars, overlapChars: overlapChars))
        }
    }
    return chunks
}

public func markdownHeaderLevel(_ line: String) -> Int? {
    let trimmed = String(line.drop(while: { $0.isWhitespace }))
    guard trimmed.first == "#" else { return nil }

    var level = 0
    for character in trimmed {
        guard character == "#" else { break }
        level += 1
    }

    let remainder = String(trimmed.dropFirst(level))
    guard remainder.isEmpty || remainder.first == " " else { return nil }
    return level
}

private struct MarkdownSection {
    let lines: [String]
    let startLine: Int
    let headerContext: String
}

private func markdownLines(_ content: String) -> [String] {
    var lines = content.components(separatedBy: .newlines)
    if content.last?.isNewline == true {
        _ = lines.popLast()
    }
    return lines
}

private func splitByHeaders(_ lines: [String]) -> [MarkdownSection] {
    var sections: [MarkdownSection] = []
    var currentLines: [String] = []
    var currentStart = 0
    var headerStack: [(level: Int, text: String)] = []

    for (index, line) in lines.enumerated() {
        if let level = markdownHeaderLevel(line) {
            if !currentLines.isEmpty {
                sections.append(
                    MarkdownSection(
                        lines: currentLines,
                        startLine: currentStart,
                        headerContext: formatHeaderContext(headerStack)
                    )
                )
                currentLines.removeAll(keepingCapacity: true)
            }
            currentStart = index
            while headerStack.last?.level ?? 0 >= level {
                _ = headerStack.popLast()
            }
            headerStack.append((level: level, text: line))
        }
        currentLines.append(line)
    }

    if !currentLines.isEmpty {
        sections.append(
            MarkdownSection(
                lines: currentLines,
                startLine: currentStart,
                headerContext: formatHeaderContext(headerStack)
            )
        )
    }
    return sections
}

private func splitSectionByParagraphs(
    _ section: MarkdownSection,
    maxChars: Int,
    overlapChars: Int
) -> [MemoryChunk] {
    var chunks: [MemoryChunk] = []
    var currentText = ""
    var currentStart = section.startLine
    var lineOffset = 0

    for (index, line) in section.lines.enumerated() {
        let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBlank && !currentText.isEmpty && currentText.utf8.count + line.utf8.count > maxChars {
            let flushed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            chunks.append(
                MemoryChunk(
                    text: addHeaderContext(section.headerContext, flushed),
                    startLine: currentStart,
                    endLine: section.startLine + index
                )
            )
            currentText = overlapChars > 0 ? String(flushed.suffix(overlapChars)) : ""
            currentStart = section.startLine + index + 1
            lineOffset = index + 1
            continue
        }

        if !currentText.isEmpty {
            currentText.append("\n")
        }
        currentText.append(contentsOf: line)

        if currentText.utf8.count > maxChars && index > lineOffset {
            if let splitIndex = currentText.lastIndex(of: "\n") {
                let keep = String(currentText[..<splitIndex])
                let remainderStart = currentText.index(after: splitIndex)
                let remainder = String(currentText[remainderStart...])
                chunks.append(
                    MemoryChunk(
                        text: addHeaderContext(section.headerContext, keep.trimmingCharacters(in: .whitespacesAndNewlines)),
                        startLine: currentStart,
                        endLine: section.startLine + index
                    )
                )
                currentText = remainder
                currentStart = section.startLine + index
                lineOffset = index
            } else {
                chunks.append(
                    MemoryChunk(
                        text: addHeaderContext(section.headerContext, currentText.trimmingCharacters(in: .whitespacesAndNewlines)),
                        startLine: currentStart,
                        endLine: section.startLine + index
                    )
                )
                currentText = ""
                currentStart = section.startLine + index
                lineOffset = index
            }
        }
    }

    if !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        chunks.append(
            MemoryChunk(
                text: addHeaderContext(section.headerContext, currentText.trimmingCharacters(in: .whitespacesAndNewlines)),
                startLine: currentStart,
                endLine: section.startLine + section.lines.count
            )
        )
    }
    return chunks
}

private func formatHeaderContext(_ stack: [(level: Int, text: String)]) -> String {
    guard stack.count > 1 else { return "" }
    return stack.dropLast().map(\.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " > ")
}

private func addHeaderContext(_ context: String, _ text: String) -> String {
    context.isEmpty ? text : "[Context: \(context)]\n\n\(text)"
}
