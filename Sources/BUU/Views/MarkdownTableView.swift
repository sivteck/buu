import AppKit
import SwiftUI
import BUUKit

/// A GFM table rendered from **already attributed and measured** cells.
///
/// The preferred layout shrinks columns so the whole table fits the conversation
/// column (cells wrap, nothing is clipped, no nested scroll view). Only when the
/// column is narrower than the minimum table width (7 columns × 80pt) does it
/// fall back to a horizontal scroll view via `ViewThatFits`.
struct MarkdownTableView: View, Equatable {
    let table: PreparedTable

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var isHovering = false
    @State private var copied: CopyKind?

    private enum CopyKind {
        case markdown
        case csv
    }

    nonisolated static func == (lhs: MarkdownTableView, rhs: MarkdownTableView) -> Bool {
        lhs.table == rhs.table
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            toolbar

            ViewThatFits(in: .horizontal) {
                grid(widths: table.fittedWidths)
                ScrollView(.horizontal, showsIndicators: true) {
                    grid(widths: table.naturalWidths)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1)
            }
        }
        .onHover { hovering in
            withAnimation(Theme.Motion.standard(reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Spacer(minLength: 0)

            copyButton(kind: .markdown, title: "Copy as Markdown", systemImage: "doc.on.doc")
            copyButton(kind: .csv, title: "Copy as CSV", systemImage: "tablecells")
        }
        .font(.caption2)
        .frame(height: 18)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .accessibilityHidden(!isHovering)
    }

    private func copyButton(kind: CopyKind, title: String, systemImage: String) -> some View {
        Button {
            copy(kind)
        } label: {
            Label(copied == kind ? "Copied" : title, systemImage: copied == kind ? "checkmark" : systemImage)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied == kind ? Color.accentColor : Color.secondary)
        .pointingHandOnHover()
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: - Grid

    private func grid(widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<table.columnCount, id: \.self) { column in
                    cell(
                        column < table.header.count ? table.header[column] : AttributedString(),
                        column: column,
                        width: widths.indices.contains(column) ? widths[column] : Theme.Table.minColumnWidth,
                        isHeader: true
                    )
                }
            }
            .background(Color.secondary.opacity(0.12))
            .overlay(alignment: .bottom) { separator }

            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 0) {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(
                            column < row.count ? row[column] : AttributedString(),
                            column: column,
                            width: widths.indices.contains(column) ? widths[column] : Theme.Table.minColumnWidth,
                            isHeader: false
                        )
                    }
                }
                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                .overlay(alignment: .bottom) { separator }
            }
        }
    }

    private func cell(_ text: AttributedString, column: Int, width: CGFloat, isHeader: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        return Text(text)
            .font(.system(size: Theme.Typography.tableSize, weight: isHeader ? .semibold : .regular))
            .lineSpacing(2)
            .multilineTextAlignment(alignment.textAlignment)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Table.cellPaddingH)
            .padding(.vertical, Theme.Table.cellPaddingV)
            .frame(width: width, alignment: alignment.cellAlignment)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.Colors.separator)
            .frame(height: 1 / max(displayScale, 1))
    }

    // MARK: - Copying

    private func copy(_ kind: CopyKind) {
        let text = kind == .markdown ? table.markdown : table.csv
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        copied = kind
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copied == kind {
                copied = nil
            }
        }
    }
}

// MARK: - Alignment mapping

extension ColumnAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// Cells align horizontally per the delimiter row and top-align vertically
    /// so rows stay readable when one cell wraps.
    var cellAlignment: Alignment {
        switch self {
        case .leading: return Alignment(horizontal: .leading, vertical: .top)
        case .center: return Alignment(horizontal: .center, vertical: .top)
        case .trailing: return Alignment(horizontal: .trailing, vertical: .top)
        }
    }
}

// MARK: - Previews

private let previewTableMarkdown = """
| # | Thumbnail text | Channel | Views | Published | Duration | Notes |
|:--|:--|:--|--:|:--|--:|:-:|
| 1 | How to build a chat client in SwiftUI from scratch | swiftui-dev | 1,204,553 | 2024-11-02 | 18:42 | **Editor's pick** |
| 2 | Parsing GFM tables without a dependency | markdown-weekly | 88,120 | 2024-10-18 | 07:05 | `SSEDecoder` |
| 3 | Engineered Craftsmanship | internal | 12 | 2024-09-30 | 0:58 | [link](https://example.com) |
"""

private func previewTable() -> PreparedTable {
    let message = MessageCache.shared.prepared(text: previewTableMarkdown)
    for block in message.blocks {
        if case .table(let table) = block.content { return table }
    }
    return PreparedTable(
        header: [],
        alignments: [],
        rows: [],
        naturalWidths: [],
        fittedWidths: [],
        markdown: "",
        csv: ""
    )
}

#Preview("Table – dark") {
    ScrollView {
        MarkdownTableView(table: previewTable())
            .padding()
            .frame(maxWidth: Theme.Metrics.readableWidth)
    }
    .background(Theme.Colors.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Table – light") {
    ScrollView {
        MarkdownTableView(table: previewTable())
            .padding()
            .frame(maxWidth: Theme.Metrics.readableWidth)
    }
    .background(Theme.Colors.canvas)
    .preferredColorScheme(.light)
}
