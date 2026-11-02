import Foundation

/// A parsed markdown document.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock] = []) {
        self.blocks = blocks
    }

    public init(markdown: String, isStreaming: Bool = false) {
        var parser = MarkdownParser(text: markdown, streaming: isStreaming)
        self.blocks = parser.parse()
    }

    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n\n")
    }
}

/// A block level element of a markdown document.
public enum MarkdownBlock: Sendable, Equatable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case list(ordered: Bool, items: [MarkdownListItem])
    case quote(String)
    case rule
    case table(MarkdownTable)

    public var id: String {
        switch self {
        case .heading(let level, let text): return "h\(level)-\(text.hashValue)"
        case .paragraph(let text): return "p-\(text.hashValue)"
        case .code(let language, let code): return "code-\(language ?? "")-\(code.hashValue)"
        case .list(let ordered, let items): return "list-\(ordered)-\(items.count)"
        case .quote(let text): return "quote-\(text.hashValue)"
        case .rule: return "rule"
        case .table(let table): return "table-\(table.header.joined(separator: "|").hashValue)"
        }
    }

    public var plainText: String {
        switch self {
        case .heading(_, let text): return text
        case .paragraph(let text): return text
        case .code(_, let code): return code
        case .list(_, let items): return items.map(\.plainText).joined(separator: "\n")
        case .quote(let text): return text
        case .rule: return ""
        case .table(let table): return table.plainText
        }
    }
}

/// An entry of a markdown list.
public struct MarkdownListItem: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Inline content of the item (first paragraph).
    public var text: String
    /// Additional blocks belonging to the item (nested lists, code, …).
    public var blocks: [MarkdownBlock]

    public init(id: UUID = UUID(), text: String = "", blocks: [MarkdownBlock] = []) {
        self.id = id
        self.text = text
        self.blocks = blocks
    }

    public var plainText: String {
        ([text] + blocks.map(\.plainText))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// A pragmatic markdown block parser (headings, paragraphs, lists, quotes,
/// fenced code and horizontal rules).
// MARK: - Tables (GFM)

/// Horizontal alignment of a table column, taken from the `:---` separator row.
public enum ColumnAlignment: String, Sendable, Equatable {
    case leading
    case center
    case trailing
}

/// A GFM table: a header row, per-column alignment and body rows of raw inline
/// markdown.
public struct MarkdownTable: Sendable, Equatable {
    public var header: [String]
    public var alignments: [ColumnAlignment]
    public var rows: [[String]]

    public init(header: [String], alignments: [ColumnAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    public var columnCount: Int { header.count }

    public func alignment(at index: Int) -> ColumnAlignment {
        guard index >= 0, index < alignments.count else { return .leading }
        return alignments[index]
    }

    public var plainText: String {
        var lines = [header.map(Self.plainInline).joined(separator: " | ")]
        for row in rows {
            lines.append(row.map(Self.plainInline).joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    /// The table re-serialised as GFM markdown (used by "Copy as Markdown").
    public var markdown: String {
        var lines: [String] = []
        lines.append(Self.row(header))
        let delimiters = (0..<columnCount).map { index -> String in
            switch alignment(at: index) {
            case .leading: return ":---"
            case .center: return ":---:"
            case .trailing: return "---:"
            }
        }
        lines.append(Self.row(delimiters))
        for row in rows {
            lines.append(Self.row(row))
        }
        return lines.joined(separator: "\n")
    }

    /// The table as CSV with inline markdown stripped (used by "Copy as CSV").
    public var csv: String {
        func field(_ raw: String) -> String {
            let text = Self.plainInline(raw)
            if text.contains(",") || text.contains("\"") || text.contains("\n") {
                return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return text
        }

        var lines: [String] = [header.map(field).joined(separator: ",")]
        for row in rows {
            lines.append(row.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func row(_ cells: [String]) -> String {
        "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
    }

    /// Removes inline markdown markers so a cell can be copied as plain text,
    /// and so the UI can estimate how wide a column needs to be.
    public static func plainInline(_ text: String) -> String {
        var result = text
        // Links: [label](target) -> label
        if result.contains("](") {
            var output = ""
            var index = result.startIndex
            while index < result.endIndex {
                if result[index] == "[",
                   let close = result[index...].firstIndex(of: "]"),
                   close < result.endIndex,
                   result.index(after: close) < result.endIndex,
                   result[result.index(after: close)] == "(",
                   let end = result[result.index(after: close)...].firstIndex(of: ")") {
                    output += String(result[result.index(after: index)..<close])
                    index = result.index(after: end)
                    continue
                }
                output.append(result[index])
                index = result.index(after: index)
            }
            result = output
        }

        for marker in ["**", "__", "~~", "`", "*", "_"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        return result
    }
}

// MARK: - Parser

struct MarkdownParser {
    private let lines: [String]
    /// While a reply is still streaming the last table row may be half written.
    private let streaming: Bool
    private let endsWithNewline: Bool
    private var index = 0

    init(text: String, streaming: Bool = false) {
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        self.lines = normalised
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        self.streaming = streaming
        self.endsWithNewline = normalised.hasSuffix("\n")
    }

    mutating func parse() -> [MarkdownBlock] {
        parseBlocks()
    }

    // MARK: - Blocks

    private mutating func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []

        while index < lines.count {
            let line = lines[index]

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = fenceInfo(for: line) {
                blocks.append(parseCodeBlock(fence: fence))
                continue
            }

            if let heading = parseHeading(line) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isHorizontalRule(line) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if line.hasPrefix(">") {
                blocks.append(parseQuote())
                continue
            }

            if listMarker(for: line) != nil {
                blocks.append(parseList())
                continue
            }

            if isTableStart(at: index) {
                blocks.append(parseTable())
                continue
            }

            blocks.append(parseParagraph())
        }

        return blocks
    }

    // MARK: - Code

    private struct FenceInfo {
        var language: String?
        var marker: String
    }

    private func fenceInfo(for line: String) -> FenceInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        let marker = String(trimmed.prefix(3))
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return FenceInfo(language: language.isEmpty ? nil : language, marker: marker)
    }

    private mutating func parseCodeBlock(fence: FenceInfo) -> MarkdownBlock {
        index += 1
        var code: [String] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence.marker) {
                index += 1
                break
            }
            code.append(line)
            index += 1
        }
        return .code(language: fence.language, code: code.joined(separator: "\n"))
    }

    // MARK: - Headings

    private func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        for marker in ["-", "*", "_"] {
            if trimmed.allSatisfy({ $0 == Character(marker) }) { return true }
        }
        return false
    }

    // MARK: - Quote

    private mutating func parseQuote() -> MarkdownBlock {
        var parts: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix(">") {
                var content = String(line.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                parts.append(content)
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            } else {
                parts.append(line)
                index += 1
            }
        }
        return .quote(parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Paragraph

    private mutating func parseParagraph() -> MarkdownBlock {
        var parts: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if fenceInfo(for: line) != nil { break }
            if parseHeading(line) != nil { break }
            if isHorizontalRule(line) { break }
            if line.hasPrefix(">") { break }
            if listMarker(for: line) != nil { break }
            if isTableStart(at: index) { break }
            parts.append(line)
            index += 1
        }
        return .paragraph(parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Tables

    /// A table starts when a row containing a pipe is followed by a delimiter
    /// row (`|---|---|`, `:---:`, `---:`). Outer pipes are optional, and the
    /// blank line GFM requires before a table is tolerated but not required.
    private func isTableStart(at lineIndex: Int) -> Bool {
        guard lineIndex + 1 < lines.count else { return false }
        guard lines[lineIndex].contains("|") else { return false }

        let header = splitRow(lines[lineIndex]) ?? []
        guard !header.isEmpty, header.contains(where: { !$0.isEmpty }) else { return false }

        guard let delimiters = splitRow(lines[lineIndex + 1]) else { return false }
        guard delimiters.count == header.count, !delimiters.isEmpty else { return false }
        return delimiters.allSatisfy(isDelimiterCell)
    }

    private func isDelimiterCell(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let body = trimmed.hasPrefix(":") ? String(trimmed.dropFirst()) : trimmed
        let withoutTail = body.hasSuffix(":") ? String(body.dropLast()) : body
        guard !withoutTail.isEmpty else { return false }
        return withoutTail.allSatisfy { $0 == "-" }
    }

    private func alignment(forDelimiter cell: String) -> ColumnAlignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let leading = trimmed.hasPrefix(":")
        let trailing = trimmed.hasSuffix(":")
        switch (leading, trailing) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }

    private mutating func parseTable() -> MarkdownBlock {
        let header = splitRow(lines[index]) ?? []
        let delimiting = splitRow(lines[index + 1]) ?? []
        let alignments = delimiting.map(alignment(forDelimiter:))

        index += 2

        var rows: [[String]] = []
        var rawCellCounts: [Int] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            if fenceInfo(for: line) != nil { break }
            if line.hasPrefix(">") { break }
            if parseHeading(line) != nil { break }
            guard line.contains("|"), let cells = splitRow(line) else { break }
            rawCellCounts.append(cells.count)
            rows.append(normalised(cells, to: header.count))
            index += 1
        }

        // Streaming: the final line of the document may still be arriving.
        // Drop that row so the table does not flicker between shapes.
        if streaming, !endsWithNewline, index == lines.count,
           let lastCount = rawCellCounts.last, lastCount != header.count {
            rows.removeLast()
        }

        return .table(MarkdownTable(header: header, alignments: alignments, rows: rows))
    }

    private func normalised(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: "", count: count - cells.count)
    }

    /// Splits a table row on unescaped pipes, tolerating missing outer pipes.
    private func splitRow(_ line: String) -> [String]? {
        var content = line.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }

        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false

        for character in content {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }

        if escaped {
            current.append("\\")
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Lists

    private struct Marker {
        var ordered: Bool
        var content: String
        var width: Int
    }

    private func listMarker(for line: String) -> Marker? {
        let indent = indentation(of: line)
        let content = String(line.dropFirst(indent))
        guard let first = content.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            let rest = content.dropFirst()
            guard rest.first == " " || rest.isEmpty else { return nil }
            let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
            return Marker(ordered: false, content: text, width: indent + 2)
        }

        // ordered: "1. " or "1) "
        var digits = ""
        var scanner = content.startIndex
        while scanner < content.endIndex, content[scanner].isNumber {
            digits.append(content[scanner])
            scanner = content.index(after: scanner)
        }
        guard !digits.isEmpty, scanner < content.endIndex else { return nil }
        let delimiter = content[scanner]
        guard delimiter == "." || delimiter == ")" else { return nil }
        let afterDelimiter = content.index(after: scanner)
        guard afterDelimiter < content.endIndex, content[afterDelimiter] == " " else { return nil }
        let text = String(content[content.index(after: afterDelimiter)...]).trimmingCharacters(in: .whitespaces)
        return Marker(ordered: true, content: text, width: indent + digits.count + 2)
    }

    private func indentation(of line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private mutating func parseList() -> MarkdownBlock {
        var items: [MarkdownListItem] = []
        var ordered = false
        var baseIndent = 0
        var first = true

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line ends the list unless the next line continues it.
                let next = index + 1
                if next < lines.count, listMarker(for: lines[next]) != nil {
                    index += 1
                    continue
                }
                break
            }

            let indent = indentation(of: line)
            guard let marker = listMarker(for: line) else {
                if indent > baseIndent, var last = items.popLast() {
                    // Continuation of the previous item.
                    var content = last.text
                    if !content.isEmpty { content += "\n" }
                    content += line.trimmingCharacters(in: .whitespaces)
                    last.text = content
                    items.append(last)
                    index += 1
                    continue
                }
                break
            }

            if first {
                baseIndent = indent
                ordered = marker.ordered
                first = false
            } else if marker.ordered != ordered || indent != baseIndent {
                break
            }

            var contentLines = [marker.content]
            index += 1

            // Collect the continuation / nested lines of this item.
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty {
                    let lookahead = index + 1
                    if lookahead < lines.count {
                        let candidate = lines[lookahead]
                        if indentation(of: candidate) > baseIndent || listMarker(for: candidate) != nil {
                            contentLines.append("")
                            index += 1
                            continue
                        }
                    }
                    break
                }
                let nextIndent = indentation(of: next)
                if nextIndent > baseIndent {
                    contentLines.append(String(next.dropFirst(min(nextIndent, marker.width))))
                    index += 1
                    continue
                }
                if listMarker(for: next) != nil { break }
                contentLines.append(next.trimmingCharacters(in: .whitespaces))
                index += 1
            }

            var itemParser = MarkdownParser(text: contentLines.joined(separator: "\n"))
            let blocks = itemParser.parse()
            var text = ""
            var rest: [MarkdownBlock] = []
            for (offset, block) in blocks.enumerated() {
                if offset == 0, case .paragraph(let paragraph) = block {
                    text = paragraph
                } else {
                    rest.append(block)
                }
            }
            items.append(MarkdownListItem(text: text, blocks: rest))
        }

        return .list(ordered: ordered, items: items)
    }
}
