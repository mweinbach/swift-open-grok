// MermaidConfig.swift
//
// Open Grok — Swift port of `mermaid_to_svg::config`
// (third_party/mermaid-to-svg/src/config.rs, W8-S2).
//
// Mermaid sources may open with a `---` YAML frontmatter block carrying a title
// and a render config. Deviation from upstream: rather than pull in a general
// YAML parser, this reads the small indentation-based subset frontmatter
// actually uses — nested mappings of scalar values, two levels deep. Sequences,
// anchors, multi-line scalars, and flow style are not supported and are ignored
// rather than treated as errors, so an exotic frontmatter block degrades to
// default settings instead of failing the render.

import Foundation

/// Flowchart-specific frontmatter settings.
public struct FlowchartConfig: Equatable, Sendable {
    /// `basis` (default) or `linear` edge curves.
    public var curve: String?
    /// Horizontal gap between nodes on a rank.
    public var nodeSpacing: Int?
    /// Gap between ranks.
    public var rankSpacing: Int?
    /// Padding between a label and its node outline.
    public var padding: Int?
    /// Width at which labels wrap.
    public var wrappingWidth: Int?

    // Accepted for Mermaid compatibility; this port does not act on them.
    public var htmlLabels: Bool?
    public var diagramPadding: Int?
    public var useMaxWidth: Bool?
    public var defaultRenderer: String?

    public init() {}
}

/// Everything under the frontmatter's `config:` key.
public struct RenderConfig: Equatable, Sendable {
    public var theme: MermaidThemePreset?
    public var themeVariables = MermaidThemeVariables()
    public var fontFamily: String?
    public var fontSize: String?
    public var flowchart = FlowchartConfig()

    // Accepted for Mermaid compatibility; this port does not act on them.
    public var layout: String?
    public var look: String?
    public var securityLevel: String?

    public init() {}

    /// The theme this config asks for, or nil when it asks for none.
    public func mermaidTheme() -> MermaidTheme? {
        guard theme != nil || !themeVariables.isEmpty else { return nil }
        return themeVariables.applied(to: (theme ?? .default).theme)
    }

    /// `fontSize` in points, accepting a bare number or a `px` suffix.
    public func fontSizePixels() -> Double? {
        guard let fontSize else { return nil }
        var numeric = fontSize.trimmingCharacters(in: .whitespaces)
        if numeric.hasSuffix("px") {
            numeric = String(numeric.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        guard let value = Double(numeric), value.isFinite, value > 0 else { return nil }
        return value
    }
}

/// The frontmatter's own metadata.
public struct MermaidFrontmatter: Equatable, Sendable {
    public var title: String?

    public init(title: String? = nil) {
        self.title = title
    }
}

/// A Mermaid source split into its frontmatter and its diagram body.
public struct ParsedMermaidSource: Equatable, Sendable {
    /// The diagram source with any frontmatter removed.
    public var body: String
    /// nil when the source had no frontmatter block at all.
    public var frontmatter: MermaidFrontmatter?
    public var config: RenderConfig

    public init(body: String, frontmatter: MermaidFrontmatter? = nil, config: RenderConfig = RenderConfig()) {
        self.body = body
        self.frontmatter = frontmatter
        self.config = config
    }
}

/// Splits a leading `--- ... ---` frontmatter block off `source` and reads the
/// settings it carries. Sources without frontmatter come back unchanged.
public func parseMermaidFrontmatter(_ source: String) -> ParsedMermaidSource {
    guard let bounds = frontmatterBounds(source) else {
        return ParsedMermaidSource(body: source)
    }

    let body = String(source[bounds.bodyStart...])
    let yaml = String(source[bounds.yamlStart..<bounds.yamlEnd])
    let root = MiniYAML.parseMapping(yaml)

    let frontmatter = MermaidFrontmatter(title: root["title"]?.scalar)
    var config = RenderConfig()
    if let configNode = root["config"]?.mapping {
        config = parseRenderConfig(configNode)
    }

    return ParsedMermaidSource(body: body, frontmatter: frontmatter, config: config)
}

private func parseRenderConfig(_ mapping: [String: MiniYAML.Node]) -> RenderConfig {
    var config = RenderConfig()
    config.theme = mapping["theme"]?.scalar.flatMap(MermaidThemePreset.init(rawValue:))
    config.layout = mapping["layout"]?.scalar
    config.look = mapping["look"]?.scalar
    config.securityLevel = mapping["securityLevel"]?.scalar
    config.fontFamily = mapping["fontFamily"]?.scalar
    config.fontSize = mapping["fontSize"]?.scalar

    if let variables = mapping["themeVariables"]?.mapping {
        // Insertion order does not matter: each alias writes a distinct slot,
        // and duplicate keys are already collapsed by the parser.
        for key in variables.keys.sorted() {
            guard let value = variables[key]?.scalar else { continue }
            config.themeVariables.applyMermaidAlias(key: key, value: value)
        }
    }

    if let flowchart = mapping["flowchart"]?.mapping {
        config.flowchart.curve = flowchart["curve"]?.scalar
        config.flowchart.htmlLabels = flowchart["htmlLabels"]?.boolean
        config.flowchart.nodeSpacing = flowchart["nodeSpacing"]?.unsignedInteger
        config.flowchart.rankSpacing = flowchart["rankSpacing"]?.unsignedInteger
        config.flowchart.padding = flowchart["padding"]?.unsignedInteger
        config.flowchart.diagramPadding = flowchart["diagramPadding"]?.unsignedInteger
        config.flowchart.wrappingWidth = flowchart["wrappingWidth"]?.unsignedInteger
        config.flowchart.useMaxWidth = flowchart["useMaxWidth"]?.boolean
        config.flowchart.defaultRenderer = flowchart["defaultRenderer"]?.scalar
    }

    return config
}

/// Byte offsets of the YAML block and the body that follows it.
private func frontmatterBounds(
    _ source: String
) -> (yamlStart: String.Index, yamlEnd: String.Index, bodyStart: String.Index)? {
    var cursor = source.startIndex
    while cursor < source.endIndex {
        let end = nextLineEnd(source, from: cursor)
        let line = source[cursor..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            cursor = end
            continue
        }
        guard line == "---" else { return nil }

        let yamlStart = end
        var scan = end
        while scan < source.endIndex {
            let scanEnd = nextLineEnd(source, from: scan)
            if source[scan..<scanEnd].trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                return (yamlStart, scan, scanEnd)
            }
            scan = scanEnd
        }
        // An unterminated block is not frontmatter.
        return nil
    }
    return nil
}

private func nextLineEnd(_ source: String, from start: String.Index) -> String.Index {
    guard let newline = source[start...].firstIndex(of: "\n") else { return source.endIndex }
    return source.index(after: newline)
}

/// The indentation-based YAML subset Mermaid frontmatter is written in.
enum MiniYAML {
    indirect enum Node: Equatable {
        case scalar(String)
        case mapping([String: Node])

        var scalar: String? {
            if case let .scalar(value) = self { return value }
            return nil
        }

        var mapping: [String: Node]? {
            if case let .mapping(value) = self { return value }
            return nil
        }

        var boolean: Bool? {
            switch scalar {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }

        /// A non-negative integer, accepting a quoted or bare number.
        var unsignedInteger: Int? {
            guard let value = scalar.flatMap(Int.init), value >= 0 else { return nil }
            return value
        }
    }

    /// Parses a block mapping. Later duplicate keys win, matching YAML.
    static func parseMapping(_ yaml: String) -> [String: Node] {
        var lines: [(indent: Int, key: String, value: String)] = []
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Sequences, comments, and document markers are outside the subset.
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("-") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            lines.append((indent, unquote(key), value))
        }

        var index = 0
        return parseBlock(lines, &index, indent: lines.first?.indent ?? 0)
    }

    private static func parseBlock(
        _ lines: [(indent: Int, key: String, value: String)],
        _ index: inout Int,
        indent: Int
    ) -> [String: Node] {
        var mapping: [String: Node] = [:]
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            if line.indent > indent {
                // Orphaned deeper line with no parent key; skip it.
                index += 1
                continue
            }

            index += 1
            if line.value.isEmpty {
                let childIndent = index < lines.count ? lines[index].indent : indent
                if childIndent > indent {
                    mapping[line.key] = .mapping(parseBlock(lines, &index, indent: childIndent))
                } else {
                    mapping[line.key] = .scalar("")
                }
            } else {
                mapping[line.key] = .scalar(unquote(line.value))
            }
        }
        return mapping
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
