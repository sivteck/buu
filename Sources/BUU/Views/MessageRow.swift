import AppKit
import SwiftUI
import BUUKit

// MARK: - Row

/// One turn. Equatable on purpose: while tokens stream, every other row skips
/// its body entirely, and hover only re-renders the (cached) subtree.
struct MessageRow: View, Equatable {
    let turn: ChatTurn
    let isLastAssistant: Bool
    let showReasoning: Bool

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        guard lhs.turn.id == rhs.turn.id,
              lhs.isLastAssistant == rhs.isLastAssistant,
              lhs.showReasoning == rhs.showReasoning,
              lhs.turn.isStreaming == rhs.turn.isStreaming,
              lhs.turn.contentRevision == rhs.turn.contentRevision else { return false }
        // New turns use a monotonic revision. Legacy persisted turns have no
        // revision, so keep the content comparison for those only.
        guard lhs.turn.contentRevision == nil else { return true }
        return lhs.turn.text == rhs.turn.text
            && lhs.turn.images == rhs.turn.images
            && lhs.turn.reasoning == rhs.turn.reasoning
            && lhs.turn.errorMessage == rhs.turn.errorMessage
            && lhs.turn.stopReason == rhs.turn.stopReason
            && lhs.turn.usage == rhs.turn.usage
            && lhs.turn.metrics == rhs.turn.metrics
    }

    var body: some View {
        // A single-root row keeps ForEach on the fast path inside LazyVStack.
        VStack(alignment: .leading, spacing: 0) {
            switch turn.role {
            case .user:
                UserMessageBubble(turn: turn)
            case .assistant:
                AssistantBody(
                    turn: turn,
                    isLastAssistant: isLastAssistant,
                    showReasoning: showReasoning
                )
            case .system:
                Text(turn.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .tool:
                // Tool results are normally transient, but keep persisted ones
                // readable if a future version stores them.
                Text(turn.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RenderProbeModifier(id: turn.id))
    }
}

// MARK: - Assistant body

/// Hover lives here (a small child), and every heavy child is `.equatable()`,
/// so a hover change never re-renders the markdown.
private struct AssistantBody: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let turn: ChatTurn
    let isLastAssistant: Bool
    let showReasoning: Bool

    @State private var isHovering = false

    private var message: PreparedMessage {
        MessageCache.shared.prepared(for: turn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if showReasoning, !turn.reasoning.isEmpty {
                ThinkingDisclosure(text: turn.reasoning)
            }

            if !turn.text.isEmpty {
                PreparedMarkdownView(message: message)
                    .equatable()
                    .frame(minHeight: message.minimumHeight, alignment: .topLeading)
            } else if turn.isStreaming {
                TypingIndicator()
            }

            if turn.isStreaming, !turn.text.isEmpty {
                StreamingCursor()
            }

            if let error = turn.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            MessageMetadata(
                turn: turn,
                isLastAssistant: isLastAssistant,
                isRowHovered: isHovering
            )
            .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            if hovering != isHovering {
                withAnimation(Theme.Motion.standard(reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
            }
        }
    }
}

// MARK: - User bubble

struct UserMessageBubble: View, Equatable {
    let turn: ChatTurn

    nonisolated static func == (lhs: UserMessageBubble, rhs: UserMessageBubble) -> Bool {
        lhs.turn.id == rhs.turn.id
            && lhs.turn.text == rhs.turn.text
            && lhs.turn.images == rhs.turn.images
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if !turn.images.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(turn.images) { image in
                            AttachedImageThumbnail(attachment: image)
                        }
                    }
                }

                if !turn.text.isEmpty {
                    bubbleText
                }
            }
            .frame(maxWidth: Theme.Metrics.bubbleMaxWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var bubbleText: some View {
        if isPathLike {
            ScrollView(.horizontal, showsIndicators: true) {
                Text(turn.text)
                    .font(.system(size: Theme.Typography.codeSize, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background { bubbleShape }
        } else {
            Text(turn.text)
                .font(.system(size: Theme.Typography.bodySize))
                .lineSpacing(Theme.Typography.bodyLineSpacing)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background { bubbleShape }
        }
    }

    private var bubbleShape: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
            .fill(Theme.Colors.userBubble)
    }

    private var isPathLike: Bool {
        let trimmed = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        return trimmed.contains("/") || trimmed.contains(".")
    }
}

// MARK: - Metadata

private struct MessageMetadata: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let turn: ChatTurn
    let isLastAssistant: Bool
    let isRowHovered: Bool

    @State private var copied = false

    private var isVisible: Bool {
        isRowHovered || isLastAssistant
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let summary = turn.usage?.summary {
                Text(summary)
                    .accessibilityLabel("Token usage: \(summary)")
            }

            if let context = MetricsFormatter.count(turn.usage?.contextTokens) {
                Text("\(context) ctx")
                    .accessibilityLabel("Context: \(context) tokens")
            }

            if turn.isStreaming {
                if let live = MetricsFormatter.tokensPerSecond(liveTokensPerSecond) {
                    Label(live, systemImage: "speedometer")
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("Generating at \(live)")
                }
            } else if let metrics = turn.metrics, !metrics.isEmpty {
                if let ttft = MetricsFormatter.duration(metrics.timeToFirstToken) {
                    Text("\(ttft) first")
                        .accessibilityLabel("Time to first token: \(ttft)")
                }
                if let generation = MetricsFormatter.tokensPerSecond(metrics.generationTokensPerSecond) {
                    Text(generation)
                        .accessibilityLabel("Generation speed: \(generation)")
                }
                if let prefill = MetricsFormatter.tokensPerSecond(metrics.prefillTokensPerSecond) {
                    Text("prefill \(prefill)")
                        .accessibilityLabel("Prefill speed: \(prefill)")
                }
            }

            if let reason = turn.stopReason, reason != .endTurn, reason != .unknown {
                Text(reason.displayName)
            }

            MetadataButton(
                systemImage: copied ? "checkmark" : "doc.on.doc",
                help: copied ? "Copied" : "Copy"
            ) {
                copy()
            }

            if isLastAssistant, appState.canRegenerate {
                MetadataButton(systemImage: "arrow.clockwise", help: "Regenerate") {
                    appState.regenerate()
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .themeAnimation(isVisible, reduceMotion: reduceMotion)
    }

    /// Very cheap live rate: characters received ÷ elapsed time ÷ ~4 chars per
    /// token. No timer — it updates whenever a token arrives.
    private var liveTokensPerSecond: Double? {
        let elapsed = Date().timeIntervalSince(turn.createdAt)
        guard elapsed > 0.25 else { return nil }
        // UTF-8 length is a much cheaper proxy than grapheme-cluster counting
        // and is recomputed on the streaming row for every token.
        let characters = turn.text.utf8.count + turn.reasoning.utf8.count
        guard characters > 8 else { return nil }
        return Double(characters) / 4 / elapsed
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(turn.text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// 14pt glyph in a 24×24 hit target with a hover highlight.
private struct MetadataButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                        .fill(isHovering ? Color.secondary.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Thinking

struct ThinkingDisclosure: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String

    @State private var isExpanded = false

    nonisolated static func == (lhs: ThinkingDisclosure, rhs: ThinkingDisclosure) -> Bool {
        lhs.text == rhs.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                withAnimation(Theme.Motion.standard(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs + 1) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10, alignment: .leading)
                    Text("Thinking")
                        .font(.caption)
                    Text("\(text.count.formatted()) chars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
            .accessibilityLabel("Thinking")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapse reasoning" : "Expand reasoning")

            if isExpanded {
                ScrollView {
                    Text(text)
                        .font(.system(size: Theme.Typography.bodySize - 1.5))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .frame(maxHeight: 240)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.Colors.separator)
                        .frame(width: 2)
                }
                .padding(.leading, Theme.Spacing.xs)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Streaming indicators

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(active: nil)
            } else {
                PhaseAnimator([0, 1, 2]) { phase in
                    dots(active: phase)
                } animation: { _ in
                    .easeInOut(duration: 0.35)
                }
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Assistant is thinking")
    }

    private func dots(active: Int?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 5, height: 5)
                    .opacity(active == index ? 1 : 0.3)
            }
        }
    }
}

struct StreamingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.accentColor.opacity(0.8))
            .frame(width: 8, height: 3)
            .opacity(dimmed ? 0.2 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
                value: dimmed
            )
            .onAppear {
                guard !reduceMotion else { return }
                dimmed = true
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

private func previewTurn(
    role: MessageRole,
    text: String,
    reasoning: String = "",
    usage: TokenUsage? = nil,
    metrics: TurnMetrics? = nil,
    isStreaming: Bool = false
) -> ChatTurn {
    ChatTurn(
        role: role,
        text: text,
        reasoning: reasoning,
        usage: usage,
        isStreaming: isStreaming,
        metrics: metrics ?? TurnMetrics(
            timeToFirstToken: 0.42,
            prefillTokensPerSecond: 312,
            generationTokensPerSecond: 48.3
        )
    )
}

private let previewTableMarkdown = """
| # | Thumbnail text | Channel | Views | Published | Duration | Notes |
|:--|:--|:--|--:|:--|--:|:-:|
| 1 | How to build a chat client in SwiftUI from scratch | swiftui-dev | 1,204,553 | 2024-11-02 | 18:42 | **Editor's pick** |
| 2 | Parsing GFM tables without a dependency | markdown-weekly | 88,120 | 2024-10-18 | 07:05 | `SSEDecoder` |
| 3 | Engineered Craftsmanship | internal | 12 | 2024-09-30 | 0:58 | [link](https://example.com) |
"""

private let previewLongCode = (1...60)
    .map { "let value\($0) = decoder.decode(chunk) // line \($0)" }
    .joined(separator: "\n")

#Preview("Message – dark") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            MessageRow(turn: previewTurn(role: .user, text: "do a table"), isLastAssistant: false, showReasoning: true)
            MessageRow(
                turn: previewTurn(
                    role: .assistant,
                    text: "Sure thing 😄\n\n" + previewTableMarkdown + "\n\n```swift\n" + previewLongCode + "\n```",
                    reasoning: "The user asks for a table, so build a GFM table with seven columns.",
                    usage: TokenUsage(inputTokens: 1970, outputTokens: 1447)
                ),
                isLastAssistant: true,
                showReasoning: true
            )
        }
        .padding()
        .frame(maxWidth: Theme.Metrics.readableWidth)
    }
    .background(Theme.Colors.canvas)
    .environment(AppState())
    .preferredColorScheme(.dark)
}

#Preview("Message – light") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            MessageRow(turn: previewTurn(role: .user, text: "do a table"), isLastAssistant: false, showReasoning: true)
            MessageRow(
                turn: previewTurn(
                    role: .assistant,
                    text: previewTableMarkdown,
                    usage: TokenUsage(inputTokens: 1970, outputTokens: 1447)
                ),
                isLastAssistant: true,
                showReasoning: true
            )
        }
        .padding()
        .frame(maxWidth: Theme.Metrics.readableWidth)
    }
    .background(Theme.Colors.canvas)
    .environment(AppState())
    .preferredColorScheme(.light)
}
