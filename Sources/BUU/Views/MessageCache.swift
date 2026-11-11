import AppKit
import SwiftUI
import BUUKit

// MARK: - Prepared (render-ready) model

/// Everything needed to draw one message, computed once and cached.
///
/// Every member is a finished value: paragraphs are already `AttributedString`s,
/// code is already highlighted and table cells are already attributed and
/// measured. A row's `body` is therefore a pure function of this data, so its
/// height is final on the very first layout pass.
struct PreparedMessage: Equatable, Sendable {
    var blocks: [PreparedBlock]
    /// A conservative lower bound used as `minHeight`. It is intentionally
    /// smaller than the real height so it never adds whitespace.
    var minimumHeight: CGFloat
}

struct PreparedBlock: Identifiable, Equatable, Sendable {
    let id: Int
    let content: Content

    enum Content: Equatable, Sendable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case code(language: String, highlighted: AttributedString, source: String, lineCount: Int)
        case table(PreparedTable)
        case list(ordered: Bool, items: [PreparedListItem])
        case quote(AttributedString)
        case rule
    }
}

struct PreparedListItem: Identifiable, Equatable, Sendable {
    let id: Int
    var text: AttributedString
    var blocks: [PreparedBlock]
}

struct PreparedTable: Equatable, Sendable {
    var header: [AttributedString]
    var alignments: [ColumnAlignment]
    var rows: [[AttributedString]]
    /// Column widths when the table may scroll horizontally.
    var naturalWidths: [CGFloat]
    /// Column widths shrunk to fit the conversation column (preferred).
    var fittedWidths: [CGFloat]
    var markdown: String
    var csv: String

    var columnCount: Int { header.count }
}

// MARK: - Inline markdown

enum MarkdownInline {

    /// Builds an attributed string for inline markdown (bold, italic, `code`,
    /// links). Inline code gets a subtle tinted background; very long unbroken
    /// spans are shortened with a middle ellipsis so they cannot widen a row.
    static func attributed(_ text: String, truncateLongCodeSpans: Bool = true) -> AttributedString {
        let source = truncateLongCodeSpans ? shorteningLongCodeSpans(in: text) : text

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        guard var attributed = try? AttributedString(markdown: source, options: options) else {
            return AttributedString(source)
        }

        let codeRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { return nil }
            return run.range
        }

        for range in codeRanges {
            attributed[range].font = .system(size: Theme.Typography.codeSize, design: .monospaced)
            attributed[range].backgroundColor = Theme.Colors.inlineCode
        }

        return attributed
    }

    /// `abcdefghijklmnopqrstuvwxyz0123456789` → `abcdefghijklmnop…0123456789`
    private static func shorteningLongCodeSpans(in text: String) -> String {
        guard text.contains("`") else { return text }

        var output = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "`" else {
                output.append(text[index])
                index = text.index(after: index)
                continue
            }

            var fence = 0
            var cursor = index
            while cursor < text.endIndex, text[cursor] == "`" {
                fence += 1
                cursor = text.index(after: cursor)
            }

            let fenceText = String(repeating: "`", count: fence)
            guard let end = text[cursor...].range(of: fenceText) else {
                output += String(text[index...])
                return output
            }

            let content = String(text[cursor..<end.lowerBound])
            let isUnbroken = !content.isEmpty && !content.contains(where: \.isWhitespace)

            if isUnbroken, content.count > 44 {
                output += fenceText + content.prefix(18) + "…" + content.suffix(10) + fenceText
            } else {
                output += fenceText + content + fenceText
            }

            index = end.upperBound
        }

        return output
    }
}

// MARK: - Preparer (pure, no UI)

enum MessagePreparer {

    /// Width available to a table inside the conversation column.
    static var tableAvailableWidth: CGFloat {
        // `contentColumn()` caps the content at readableWidth, then adds the
        // gutter outside that frame. The table therefore gets the full column.
        Theme.Metrics.readableWidth
    }

    static func prepare(_ turn: ChatTurn) -> PreparedMessage {
        prepare(text: turn.text, isStreaming: turn.isStreaming)
    }

    static func prepare(text: String, isStreaming: Bool) -> PreparedMessage {
        let document = MarkdownDocument(markdown: text, isStreaming: isStreaming)
        let blocks = makeBlocks(document.blocks)
        return PreparedMessage(blocks: blocks, minimumHeight: minimumHeight(of: blocks))
    }

    // MARK: Blocks

    private static func makeBlocks(_ blocks: [MarkdownBlock]) -> [PreparedBlock] {
        blocks.enumerated().map { index, block in
            PreparedBlock(id: index, content: content(for: block))
        }
    }

    private static func content(for block: MarkdownBlock) -> PreparedBlock.Content {
        switch block {
        case .heading(let level, let text):
            return .heading(level: level, text: MarkdownInline.attributed(text))

        case .paragraph(let text):
            return .paragraph(MarkdownInline.attributed(text))

        case .code(let language, let code):
            return .code(
                language: language?.lowercased() ?? "",
                highlighted: highlight(code: code, language: language),
                source: code,
                lineCount: lineCount(of: code)
            )

        case .table(let table):
            return .table(prepare(table))

        case .list(let ordered, let items):
            let preparedItems = items.enumerated().map { index, item in
                PreparedListItem(
                    id: index,
                    text: MarkdownInline.attributed(item.text),
                    blocks: makeBlocks(item.blocks)
                )
            }
            return .list(ordered: ordered, items: preparedItems)

        case .quote(let text):
            return .quote(MarkdownInline.attributed(text))

        case .rule:
            return .rule
        }
    }

    // MARK: Code

    private static func highlight(code: String, language: String?) -> AttributedString {
        var result = AttributedString()
        var cursor = code.startIndex

        for token in CodeHighlighter.tokenize(code, language: language) {
            if token.range.lowerBound > cursor {
                result += AttributedString(String(code[cursor..<token.range.lowerBound]))
            }
            var piece = AttributedString(String(code[token.range]))
            piece.foregroundColor = SyntaxPalette.shared.color(for: token.kind)
            result += piece
            cursor = token.range.upperBound
        }

        if cursor < code.endIndex {
            result += AttributedString(String(code[cursor...]))
        }

        result.font = Theme.Typography.code
        return result
    }

    private static func lineCount(of code: String) -> Int {
        guard !code.isEmpty else { return 1 }
        return code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // MARK: Tables

    private static func prepare(_ table: MarkdownTable) -> PreparedTable {
        let header = table.header.map { MarkdownInline.attributed($0) }
        let rows = table.rows.map { row in row.map { MarkdownInline.attributed($0) } }

        let natural = naturalWidths(header: table.header, rows: table.rows)
        let fitted = fittedWidths(natural, available: tableAvailableWidth - 1)

        return PreparedTable(
            header: header,
            alignments: (0..<table.columnCount).map(table.alignment(at:)),
            rows: rows,
            naturalWidths: natural,
            fittedWidths: fitted,
            markdown: table.markdown,
            csv: table.csv
        )
    }

    private static func naturalWidths(header: [String], rows: [[String]]) -> [CGFloat] {
        (0..<header.count).map { column in
            var widest = Theme.Table.minColumnWidth

            func measure(_ raw: String) {
                let text = MarkdownTable.plainInline(raw)
                let longestWord = text.split(separator: " ").map(\.count).max() ?? 0
                let sample = max(longestWord, min(text.count, 44))
                let width = CGFloat(sample) * Theme.Table.characterWidth
                    + Theme.Table.cellPaddingH * 2
                widest = max(widest, width)
            }

            measure(header[column])
            for row in rows where column < row.count {
                measure(row[column])
            }

            return min(widest, Theme.Table.maxColumnWidth)
        }
    }

    /// Shrinks columns proportionally so the whole table fits the column. Cells
    /// wrap instead of the right edge being clipped.
    private static func fittedWidths(_ natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard total > available else { return natural }

        let minimum = Theme.Table.minColumnWidth
        let minimumTotal = minimum * CGFloat(natural.count)
        guard minimumTotal < available else {
            return natural.map { _ in minimum }
        }

        let slack = available - minimumTotal
        let surplus = natural.map { max($0 - minimum, 0) }
        let surplusTotal = surplus.reduce(0, +)
        guard surplusTotal > 0 else { return natural.map { _ in minimum } }

        return surplus.map { extra in
            minimum + extra / surplusTotal * slack
        }
    }

    // MARK: Height estimate

    /// Deliberately conservative: underestimating never adds blank space.
    private static func minimumHeight(of blocks: [PreparedBlock]) -> CGFloat {
        var total: CGFloat = 0

        for block in blocks {
            switch block.content {
            case .heading:
                total += 26
            case .paragraph(let text):
                total += lineEstimate(for: text) * 20
            case .quote(let text):
                total += lineEstimate(for: text) * 20
            case .list(_, let items):
                total += CGFloat(items.count) * 22
            case .code(_, _, _, let lines):
                total += CGFloat(min(lines, Theme.Metrics.collapsedCodeLines)) * 18 + 36
            case .table(let table):
                total += CGFloat(table.rows.count + 1) * 32 + 24
            case .rule:
                total += 12
            }
        }

        // Headroom for inter-block spacing, then take 60% so it stays a floor.
        total += CGFloat(max(blocks.count - 1, 0)) * Theme.Typography.paragraphSpacing
        return total * 0.6
    }

    private static func lineEstimate(for text: AttributedString) -> CGFloat {
        let characters = max(text.characters.count, 1)
        return CGFloat(max(1, Int(ceil(Double(characters) / 72.0))))
    }
}

// MARK: - Cache

/// A process-wide, non-observable cache of prepared messages.
///
/// It is deliberately **not** an `@Observable` type: reading it from a row body
/// must not subscribe that row to cache writes, otherwise every prepared
/// message would invalidate every row.
final class MessageCache: @unchecked Sendable {
    static let shared = MessageCache()

    private struct Entry {
        var text: String
        var textLength: Int
        var reasoning: String
        var isStreaming: Bool
        var preparedAt: Date
        var message: PreparedMessage
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var textEntries: [String: PreparedMessage] = [:]

    /// The newest warm pass that owns each turn. A background pass may only
    /// commit while it still owns the turn, so a slow pass can never overwrite
    /// fresher work started later.
    private var warmGenerations: [UUID: UInt64] = [:]
    private var nextWarmGeneration: UInt64 = 0

    /// Synchronous, memoised. Cheap on a hit, ~1 ms on a miss for a normal
    /// message — which keeps the first layout of a row correct and stable.
    func prepared(for turn: ChatTurn) -> PreparedMessage {
        lock.lock()
        if let entry = entries[turn.id],
           entry.textLength == turn.text.utf8.count,
           entry.text == turn.text,
           entry.reasoning == turn.reasoning,
           entry.isStreaming == turn.isStreaming {
            // The state on screen already owns this turn. Invalidate any older
            // background pass so it cannot replace this entry afterwards.
            warmGenerations.removeValue(forKey: turn.id)
            lock.unlock()
            return entry.message
        }

        // Streaming: reuse the previous render until enough new text arrived
        // *and* a short interval has passed. Keeps the streaming row at roughly
        // one parse per 50 ms instead of one parse per token. Comparing the
        // cached byte length avoids rescanning the whole message on every token.
        if let entry = entries[turn.id],
           entry.isStreaming, turn.isStreaming,
           entry.reasoning == turn.reasoning {
            let added = turn.text.utf8.count - entry.textLength
            let tooSoon = Date().timeIntervalSince(entry.preparedAt) < 0.05
            if added >= 0, (added < 12 || tooSoon) {
                let message = entry.message
                lock.unlock()
                return message
            }
        }
        lock.unlock()

        let message = MessagePreparer.prepare(turn)
        store(message, for: turn)
        return message
    }

    func store(_ message: PreparedMessage, for turn: ChatTurn) {
        lock.lock()
        entries[turn.id] = Entry(
            text: turn.text,
            textLength: turn.text.utf8.count,
            reasoning: turn.reasoning,
            isStreaming: turn.isStreaming,
            preparedAt: Date(),
            message: message
        )
        // A synchronous store came from the state currently on screen, so it
        // always wins over a background preparation still in flight.
        warmGenerations.removeValue(forKey: turn.id)
        lock.unlock()
    }

    /// Memoised preparation for callers that only have a string.
    func prepared(text: String, isStreaming: Bool = false) -> PreparedMessage {
        var hasher = SHA256()
        hasher.update(Data(text.utf8))
        let key = "\(isStreaming)-\(text.count)-\(hasher.finalize())"

        lock.lock()
        if let entry = textEntries[key] {
            lock.unlock()
            return entry
        }
        lock.unlock()

        let message = MessagePreparer.prepare(text: text, isStreaming: isStreaming)

        lock.lock()
        if textEntries.count > 64 {
            textEntries.removeAll(keepingCapacity: true)
        }
        textEntries[key] = message
        lock.unlock()

        return message
    }

    func forget(_ id: UUID) {
        lock.lock()
        entries.removeValue(forKey: id)
        lock.unlock()
    }

    /// Warms the cache off the main thread so scrolling never pays for parsing
    /// or highlighting. Safe to call repeatedly.
    func warm(_ turns: [ChatTurn]) {
        guard !turns.isEmpty else { return }

        lock.lock()
        let pending = turns.filter { turn in
            // Only assistant turns are rendered from prepared markdown; user
            // and system turns use plain Text, so preparing them is wasted work.
            guard turn.role == .assistant else { return false }
            guard let entry = entries[turn.id] else { return true }
            // Length first: a streaming append almost always differs in length,
            // which avoids scanning the whole message just to discover that.
            return entry.textLength != turn.text.utf8.count
                || entry.text != turn.text
                || entry.reasoning != turn.reasoning
                || entry.isStreaming != turn.isStreaming
        }
        guard !pending.isEmpty else {
            lock.unlock()
            return
        }

        nextWarmGeneration &+= 1
        let generation = nextWarmGeneration
        for turn in pending {
            warmGenerations[turn.id] = generation
        }
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.finishWarm(pending, generation: generation) }

            for turn in pending {
                if Task.isCancelled { return }
                let message = MessagePreparer.prepare(turn)
                self.storeInBackground(message, for: turn, generation: generation)
            }
        }
    }

    /// Commits a background result only if no newer request or synchronous
    /// store has taken ownership of the turn since this pass started.
    private func storeInBackground(
        _ message: PreparedMessage,
        for turn: ChatTurn,
        generation: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard warmGenerations[turn.id] == generation else { return }

        entries[turn.id] = Entry(
            text: turn.text,
            textLength: turn.text.utf8.count,
            reasoning: turn.reasoning,
            isStreaming: turn.isStreaming,
            preparedAt: Date(),
            message: message
        )
        warmGenerations.removeValue(forKey: turn.id)
    }

    private func finishWarm(_ turns: [ChatTurn], generation: UInt64) {
        lock.lock()
        for turn in turns where warmGenerations[turn.id] == generation {
            warmGenerations.removeValue(forKey: turn.id)
        }
        lock.unlock()
    }
}
