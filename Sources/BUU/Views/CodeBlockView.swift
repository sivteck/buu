import AppKit
import SwiftUI
import BUUKit

/// A fenced code block rendered from **already highlighted** text.
///
/// - One `Text` for the whole block (never one per line or per token).
/// - Wrapping is on by default, so long lines are never clipped and no nested
///   horizontal scroll view sits inside the transcript.
/// - Very tall blocks collapse to ``Theme/Metrics/collapsedCodeLines`` lines with
///   a "Show all N lines" button — never an inner vertical scroll view.
struct CodeBlockView: View, Equatable {
    let language: String
    let highlighted: AttributedString
    let source: String
    let lineCount: Int

    @State private var wrapLines = true
    @State private var isExpanded = false
    @State private var copied = false

    nonisolated static func == (lhs: CodeBlockView, rhs: CodeBlockView) -> Bool {
        lhs.language == rhs.language
            && lhs.source == rhs.source
            && lhs.lineCount == rhs.lineCount
    }

    private var displayLanguage: String {
        language.isEmpty ? "text" : language
    }

    private var isCollapsible: Bool {
        lineCount > Theme.Metrics.collapsedCodeLines
    }

    private var visibleLineLimit: Int? {
        guard isCollapsible, !isExpanded else { return nil }
        return Theme.Metrics.collapsedCodeLines
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            codeBody

            if isCollapsible {
                Divider()
                expandButton
            }
        }
        .background(
            Theme.Colors.codeSurface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(displayLanguage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: Theme.Spacing.s)

            Button {
                wrapLines.toggle()
            } label: {
                Image(systemName: wrapLines ? "text.alignleft" : "arrow.left.and.right")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(wrapLines ? Color.accentColor : Color.secondary)
            .iconHitTarget(22)
            .pointingHandOnHover()
            .help(wrapLines ? "Turn wrapping off" : "Wrap long lines")
            .accessibilityLabel(wrapLines ? "Turn line wrapping off" : "Wrap long lines")

            Button {
                copy()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .iconHitTarget(22)
            .pointingHandOnHover()
            .help("Copy code")
            .accessibilityLabel(copied ? "Copied" : "Copy code")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Body

    @ViewBuilder
    private var codeBody: some View {
        if wrapLines {
            Text(highlighted)
                .font(Theme.Typography.code)
                .lineSpacing(2)
                .textSelection(.enabled)
                .lineLimit(visibleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.m)
        } else {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(highlighted)
                    .font(Theme.Typography.code)
                    .textSelection(.enabled)
                    .lineLimit(visibleLineLimit)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(Theme.Spacing.m)
            }
        }
    }

    private var expandButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(isExpanded
                     ? "Show less"
                     : "Show all \(lineCount.formatted()) lines")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .help(isExpanded ? "Collapse code" : "Show the whole block")
        .accessibilityLabel(isExpanded ? "Show less" : "Show all \(lineCount) lines")
    }

    // MARK: - Copy

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }
}

// MARK: - Syntax colours

/// Token colours built from **dynamic** system colours, so a prepared message
/// can be cached across light/dark appearance changes.
struct SyntaxPalette {
    static let shared = SyntaxPalette()

    func color(for kind: CodeTokenKind) -> Color {
        switch kind {
        case .keyword: return Color(nsColor: .systemPurple)
        case .type: return Color(nsColor: .systemBlue)
        case .string: return Color(nsColor: .systemOrange)
        case .number: return Color(nsColor: .systemGreen)
        case .comment: return Color(nsColor: .secondaryLabelColor)
        case .function: return Color(nsColor: .systemTeal)
        case .punctuation: return Color(nsColor: .secondaryLabelColor)
        case .attribute: return Color(nsColor: .systemPink)
        case .plain: return Color(nsColor: .labelColor)
        }
    }
}

// MARK: - Previews

private let previewCode = (1...28)
    .map { "let value\($0) = decoder.decode(chunk) // line \($0) with a fairly long trailing comment" }
    .joined(separator: "\n")

#Preview("Code – dark") {
    ScrollView {
        VStack(spacing: Theme.Spacing.l) {
            CodeBlockView(
                language: "swift",
                highlighted: MessageCache.shared.prepared(text: "```swift\nstruct SSEDecoder { var buffer = Data() }\n```").blocks.compactMap {
                    if case .code(_, let highlighted, _, _) = $0.content { return highlighted }
                    return nil
                }.first ?? AttributedString(),
                source: "struct SSEDecoder { var buffer = Data() }",
                lineCount: 1
            )

            CodeBlockView(
                language: "swift",
                highlighted: MessageCache.shared.prepared(text: "```swift\n\(previewCode)\n```").blocks.compactMap {
                    if case .code(_, let highlighted, _, _) = $0.content { return highlighted }
                    return nil
                }.first ?? AttributedString(),
                source: previewCode,
                lineCount: 28
            )
        }
        .padding()
        .frame(maxWidth: Theme.Metrics.readableWidth)
    }
    .background(Theme.Colors.canvas)
    .preferredColorScheme(.dark)
}

#Preview("Code – light") {
    ScrollView {
        CodeBlockView(
            language: "",
            highlighted: MessageCache.shared.prepared(text: "```\nplain text block with no language\n```").blocks.compactMap {
                if case .code(_, let highlighted, _, _) = $0.content { return highlighted }
                return nil
            }.first ?? AttributedString(),
            source: "plain text block with no language",
            lineCount: 1
        )
        .padding()
        .frame(maxWidth: Theme.Metrics.readableWidth)
    }
    .background(Theme.Colors.canvas)
    .preferredColorScheme(.light)
}
