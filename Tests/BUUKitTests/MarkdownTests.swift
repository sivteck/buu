import Foundation
import Testing
@testable import BUUKit

@Suite("Markdown parsing")
struct MarkdownTests {

    @Test("Headings and paragraphs")
    func parsesHeadingsAndParagraphs() {
        let document = MarkdownDocument(markdown: "# Title\n\nSome text\n\n## Sub")
        #expect(document.blocks.count == 3)

        guard case .heading(let level, let text) = document.blocks[0] else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 1)
        #expect(text == "Title")

        guard case .paragraph(let paragraph) = document.blocks[1] else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(paragraph == "Some text")

        guard case .heading(let subLevel, _) = document.blocks[2] else {
            Issue.record("expected a heading")
            return
        }
        #expect(subLevel == 2)
    }

    @Test("Fenced code blocks")
    func parsesFencedCodeBlock() {
        let document = MarkdownDocument(markdown: "```swift\nlet x = 1\nprint(x)\n```")
        guard case .code(let language, let code) = document.blocks[0] else {
            Issue.record("expected a code block")
            return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1\nprint(x)")
    }

    @Test("Unordered lists")
    func parsesUnorderedList() {
        let document = MarkdownDocument(markdown: "- one\n- two\n- three")
        guard case .list(let ordered, let items) = document.blocks[0] else {
            Issue.record("expected a list")
            return
        }
        #expect(ordered == false)
        #expect(items.map(\.text) == ["one", "two", "three"])
    }

    @Test("Ordered lists")
    func parsesOrderedList() {
        let document = MarkdownDocument(markdown: "1. first\n2. second")
        guard case .list(let ordered, let items) = document.blocks[0] else {
            Issue.record("expected a list")
            return
        }
        #expect(ordered == true)
        #expect(items.map(\.text) == ["first", "second"])
    }

    @Test("Block quotes")
    func parsesBlockquote() {
        let document = MarkdownDocument(markdown: "> quoted text")
        guard case .quote(let text) = document.blocks[0] else {
            Issue.record("expected a quote")
            return
        }
        #expect(text == "quoted text")
    }

    @Test("Horizontal rules")
    func parsesHorizontalRule() {
        let document = MarkdownDocument(markdown: "---")
        guard case .rule = document.blocks[0] else {
            Issue.record("expected a rule")
            return
        }
    }

    @Test("Inline formatting is preserved for the renderer")
    func keepsInlineFormattingInText() {
        let document = MarkdownDocument(markdown: "This is **bold** and `code`")
        guard case .paragraph(let text) = document.blocks[0] else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(text == "This is **bold** and `code`")
    }
}

@Suite("Syntax highlighting")
struct CodeHighlighterTests {

    @Test("Swift keywords, strings and comments")
    func swiftKeywordsAndStringsAreDetected() {
        let code = "let greeting = \"hi\" // comment"
        let tokens = CodeHighlighter.tokenize(code, language: "swift")
        let kinds = tokens.map(\.kind)
        #expect(kinds.contains(.keyword))
        #expect(kinds.contains(.string))
        #expect(kinds.contains(.comment))
    }

    @Test("Python uses hash comments")
    func pythonUsesHashComments() {
        let code = "def f():\n    return 1  # note"
        let tokens = CodeHighlighter.tokenize(code, language: "python")
        #expect(tokens.contains { $0.kind == .comment })
        #expect(tokens.contains { $0.kind == .keyword })
    }

    @Test("Token ranges cover the whole source")
    func tokenRangesCoverTheSource() {
        let code = "print(\"hello\")"
        let tokens = CodeHighlighter.tokenize(code, language: "python")
        #expect(!tokens.isEmpty)
        let total = tokens.reduce(0) { $0 + code.distance(from: $1.range.lowerBound, to: $1.range.upperBound) }
        #expect(total == code.count)
    }
}

@Suite("GFM tables")
struct MarkdownTableTests {

    private func table(_ markdown: String, streaming: Bool = false) -> MarkdownTable? {
        let document = MarkdownDocument(markdown: markdown, isStreaming: streaming)
        for block in document.blocks {
            if case .table(let table) = block { return table }
        }
        return nil
    }

    @Test("Parses a table with outer pipes")
    func parsesBasicTable() throws {
        let parsed = try #require(table("""
        | # | Name |
        |---|---|
        | 1 | One |
        | 2 | Two |
        """))
        #expect(parsed.header == ["#", "Name"])
        #expect(parsed.rows == [["1", "One"], ["2", "Two"]])
        #expect(parsed.columnCount == 2)
    }

    @Test("Tolerates missing outer pipes")
    func toleratesMissingOuterPipes() throws {
        let parsed = try #require(table("""
        ID | Name
        --- | ---
        1 | One
        """))
        #expect(parsed.header == ["ID", "Name"])
        #expect(parsed.rows == [["1", "One"]])
    }

    @Test("Reads column alignment from the delimiter row")
    func readsAlignment() throws {
        let parsed = try #require(table("""
        | a | b | c |
        |:---|:---:|---:|
        | 1 | 2 | 3 |
        """))
        #expect(parsed.alignments == [.leading, .center, .trailing])
        #expect(parsed.alignment(at: 0) == .leading)
        #expect(parsed.alignment(at: 1) == .center)
        #expect(parsed.alignment(at: 2) == .trailing)
    }

    @Test("A table directly after a paragraph is still detected")
    func tableWithoutLeadingBlankLine() throws {
        let document = MarkdownDocument(markdown: """
        Here is the comparison:
        | a | b |
        |---|---|
        | 1 | 2 |
        """)
        guard case .paragraph(let intro) = document.blocks.first else {
            Issue.record("expected a paragraph first")
            return
        }
        #expect(intro == "Here is the comparison:")
        #expect(document.blocks.count == 2)
        guard case .table(let parsed) = document.blocks[1] else {
            Issue.record("expected a table second")
            return
        }
        #expect(parsed.rows == [["1", "2"]])
    }

    @Test("Ragged rows are padded and truncated to the header width")
    func padsRaggedRows() throws {
        let parsed = try #require(table("""
        | a | b | c |
        |---|---|---|
        | 1 |
        | 1 | 2 | 3 | 4 |
        """))
        #expect(parsed.rows[0] == ["1", "", ""])
        #expect(parsed.rows[1] == ["1", "2", "3"])
    }

    @Test("Streaming holds back a half written trailing row")
    func streamingDropsPartialRow() throws {
        let complete = try #require(table("""
        | a | b |
        |---|---|
        | 1 | 2 |
        | 3 |
        """, streaming: true))
        #expect(complete.rows == [["1", "2"]])

        let finished = try #require(table("""
        | a | b |
        |---|---|
        | 1 | 2 |
        | 3 |
        """, streaming: false))
        #expect(finished.rows == [["1", "2"], ["3", ""]])
    }

    @Test("A row with an empty middle cell counts as complete while streaming")
    func emptyMiddleCellIsComplete() throws {
        let parsed = try #require(table("""
        | a | b | c |
        |---|---|---|
        | 1 |  | 3 |
        """, streaming: true))
        #expect(parsed.rows == [["1", "", "3"]])
    }

    @Test("Escaped pipes stay inside a cell")
    func escapedPipe() throws {
        let parsed = try #require(table("""
        | a | b |
        |---|---|
        | x \\| y | z |
        """))
        #expect(parsed.rows[0][0] == "x | y")
    }

    @Test("Serialises back to markdown")
    func serialisesMarkdown() throws {
        let parsed = try #require(table("""
        | a | b |
        |:---|---:|
        | 1 | 2 |
        """))
        #expect(parsed.markdown == """
        | a | b |
        | :--- | ---: |
        | 1 | 2 |
        """)
    }

    @Test("Serialises to CSV with quoting and plain text")
    func serialisesCSV() throws {
        let parsed = try #require(table("""
        | name | note |
        |---|---|
        | **bold** | has, comma |
        """))
        #expect(parsed.csv == """
        name,note
        bold,"has, comma"
        """)
    }

    @Test("Plain text strips inline markers")
    func plainText() throws {
        let parsed = try #require(table("""
        | a |
        |---|
        | **bold** `code` [link](https://example.com) |
        """))
        #expect(parsed.plainText.contains("bold code link"))
    }

    @Test("Code fences are not swallowed by a table")
    func tableStopsAtFence() throws {
        let document = MarkdownDocument(markdown: """
        | a | b |
        |---|---|
        | 1 | 2 |

        ```swift
        let x = 1
        ```
        """)
        #expect(document.blocks.count == 2)
        guard case .code(_, let code) = document.blocks[1] else {
            Issue.record("expected a code block")
            return
        }
        #expect(code == "let x = 1")
    }
}
