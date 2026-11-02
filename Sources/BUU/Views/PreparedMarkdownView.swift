import AppKit
import SwiftUI
import BUUKit

/// Renders a prepared message. Pure: every piece of text is already parsed,
/// highlighted and attributed, so the size is final on the first layout pass.
struct PreparedMarkdownView: View, Equatable {
    let message: PreparedMessage

    nonisolated static func == (lhs: PreparedMarkdownView, rhs: PreparedMarkdownView) -> Bool {
        lhs.message == rhs.message
    }

    var body: some View {
        PreparedBlocksView(blocks: message.blocks)
    }
}

struct PreparedBlocksView: View, Equatable {
    let blocks: [PreparedBlock]

    nonisolated static func == (lhs: PreparedBlocksView, rhs: PreparedBlocksView) -> Bool {
        lhs.blocks == rhs.blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Typography.paragraphSpacing) {
            ForEach(blocks) { block in
                PreparedBlockView(block: block)
                    .equatable()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PreparedBlockView: View, Equatable {
    let block: PreparedBlock

    nonisolated static func == (lhs: PreparedBlockView, rhs: PreparedBlockView) -> Bool {
        lhs.block == rhs.block
    }

    var body: some View {
        switch block.content {
        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level: level))
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.xs)

        case .paragraph(let text):
            Text(text)
                .font(.system(size: Theme.Typography.bodySize))
                .lineSpacing(Theme.Typography.bodyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let language, let highlighted, let source, let lineCount):
            CodeBlockView(
                language: language,
                highlighted: highlighted,
                source: source,
                lineCount: lineCount
            )
            .equatable()

        case .table(let table):
            MarkdownTableView(table: table)
                .equatable()

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Text(ordered ? "\(item.id + 1)." : "•")
                            .font(.system(size: Theme.Typography.bodySize))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)

                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            if item.text.characters.count > 0 {
                                Text(item.text)
                                    .font(.system(size: Theme.Typography.bodySize))
                                    .lineSpacing(Theme.Typography.bodyLineSpacing)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !item.blocks.isEmpty {
                                PreparedBlocksView(blocks: item.blocks)
                                    .equatable()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(width: 2)
                Text(text)
                    .font(.system(size: Theme.Typography.bodySize))
                    .lineSpacing(Theme.Typography.bodyLineSpacing)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .rule:
            Divider()
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title3
        case 2: return .headline
        default: return .subheadline
        }
    }
}

// MARK: - Convenience wrapper

/// Convenience wrapper for previews and one-off markdown: prepares synchronously
/// (memoised by text) and renders.
struct MarkdownView: View {
    let text: String

    private var message: PreparedMessage {
        MessageCache.shared.prepared(text: text)
    }

    var body: some View {
        PreparedMarkdownView(message: message)
    }
}

// MARK: - Previews

private let previewMarkdown = """
## Comparison

Here is the overview — note the `inline code` and a [link](https://example.com).

| # | Thumbnail text | Channel | Views | Published | Duration | Notes |
|:--|:--|:--|--:|:--|--:|:-:|
| 1 | How to build a chat client in SwiftUI from scratch | swiftui-dev | 1,204,553 | 2024-11-02 | 18:42 | **Editor's pick** |
| 2 | Parsing GFM tables without a dependency | markdown-weekly | 88,120 | 2024-10-18 | 07:05 | `SSEDecoder` |
| 3 | Long unbroken identifier `5GXs6gX8ppcugUJHEgYbIYvVurx3Q` | internal | 12 | 2024-09-30 | 0:58 | [link](https://example.com) |

1. Completed rows render immediately
2. The partial row is held back

```swift
struct SSEDecoder { var buffer = Data() }
```

> Blockquotes are muted.
"""

#Preview("Markdown – dark") {
    ScrollView {
        MarkdownView(text: previewMarkdown)
            .padding()
            .frame(maxWidth: Theme.Metrics.readableWidth)
    }
    .background(Theme.Colors.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Markdown – light") {
    ScrollView {
        MarkdownView(text: previewMarkdown)
            .padding()
            .frame(maxWidth: Theme.Metrics.readableWidth)
    }
    .background(Theme.Colors.canvas)
    .preferredColorScheme(.light)
}
