import AppKit
import SwiftUI
import BUUKit

struct MessageListView: View {
    @Environment(AppState.self) private var appState

    @State private var scroller = TranscriptScroller()

    private static let bottomSentinelID = "buu.transcript.bottom"

    private var turns: [ChatTurn] { appState.currentConversation?.turns ?? [] }
    private var showReasoning: Bool { appState.settings.showReasoning }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if turns.isEmpty {
                        EmptyChatView()
                    }

                    ForEach(turns) { turn in
                        MessageRow(
                            turn: turn,
                            isLastAssistant: isLast(turn),
                            showReasoning: showReasoning
                        )
                        // Skips this row's body entirely when `==` says nothing
                        // relevant changed (all rows except the streaming one).
                        // Must come before `.id()`: `.id()` erases the type.
                        .equatable()
                        .id(turn.id)
                    }

                    // ONE sentinel decides whether we may follow the stream.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomSentinelID)
                        .onAppear { scroller.bottomSentinelAppeared() }
                        .onDisappear { scroller.bottomSentinelDisappeared() }
                }
                .padding(.top, Theme.Spacing.l)
                .padding(.bottom, Theme.Metrics.transcriptBottomInset)
                .contentColumn()
                .background {
                    // Reports live scrolling from this scroll view only.
                    TranscriptScrollTracking {
                        scroller.userScrolledVertically()
                    }
                    .frame(width: 0, height: 0)
                }
            }
            // A fresh ScrollView per conversation is deliberate: it prevents
            // the previous conversation's (possibly out-of-range) offset from
            // leaving the new transcript blank before its lazy rows exist.
            .id(appState.activeConversationID)
            // Nothing may draw over the header or the composer.
            .clipped()
            .overlay(alignment: .bottom) {
                scrollToLatestButton(proxy: proxy)
            }
            .onChange(of: appState.streamTick) {
                scroller.followIfNeeded(proxy: proxy, lastID: turns.last?.id)
            }
            .task(id: appState.activeConversationID) {
                await loadConversation(proxy: proxy)
            }
            .onChange(of: turns.count) {
                MessageCache.shared.warm(turns)

                // A new message was appended (sending, or the assistant
                // placeholder). If the user was at the bottom, keep them there:
                // the append pushed the bottom sentinel off screen, and without
                // this jump the sentinel would never come back.
                if scroller.isFollowing {
                    scroller.jumpToBottom(proxy: proxy, lastID: turns.last?.id, animated: false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerView()
            }
        }
    }

    /// Resets the follow state for a conversation, starts its cache warm-up,
    /// and scrolls to the newest message only after SwiftUI has installed the
    /// new lazy content.
    @MainActor
    private func loadConversation(proxy: ScrollViewProxy) async {
        scroller.reset()
        MessageCache.shared.warm(turns)

        guard let lastID = turns.last?.id else { return }

        await Task.yield()
        guard !Task.isCancelled else { return }
        scroller.jumpToBottom(proxy: proxy, lastID: lastID, animated: false)

        // Lazy rows can finish their first layout one run-loop later. One
        // correction pass makes sure a tall last row is fully accounted for.
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled, scroller.isFollowing else { return }
        scroller.jumpToBottom(proxy: proxy, lastID: turns.last?.id ?? lastID, animated: false)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func scrollToLatestButton(proxy: ScrollViewProxy) -> some View {
        if scroller.showsScrollToLatest, !turns.isEmpty {
            Button {
                scroller.jumpToBottom(proxy: proxy, lastID: turns.last?.id, animated: true)
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, Theme.Spacing.s + 2)
                    .padding(.vertical, Theme.Spacing.s)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.Colors.separator, lineWidth: 1) }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .pointingHandOnHover()
            .help("Scroll to latest message")
            .accessibilityLabel("Scroll to latest message")
            // Bottom-centre, 16pt above the composer divider.
            .padding(.bottom, Theme.Spacing.l)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: scroller.showsScrollToLatest)
        }
    }

    private func isLast(_ turn: ChatTurn) -> Bool {
        turns.last?.id == turn.id && turn.role == .assistant
    }
}

// MARK: - Empty state

struct EmptyChatView: View {
    @Environment(AppState.self) private var appState

    private static let suggestions = [
        "Summarise this document",
        "Explain this Swift error",
        "Build a 7-column comparison table",
        "Compare two approaches"
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text("BUU")
                .font(.title3.weight(.semibold))

            Text("Chat with any OpenAI or Anthropic compatible server.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: Theme.Spacing.s) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        appState.useSuggestion(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.callout)
                            .padding(.horizontal, Theme.Spacing.m)
                            .padding(.vertical, Theme.Spacing.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .accessibilityLabel(suggestion)
                }
            }
            .frame(maxWidth: 360)
            .padding(.top, Theme.Spacing.s)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.bottom, Theme.Spacing.xl)
    }
}

// MARK: - Previews

#Preview("Transcript – light") {
    MessageListView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 900, height: 640)
}

#Preview("Transcript – dark") {
    MessageListView()
        .environment(AppState())
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 640)
}

#Preview("Load test thread – dark") {
    MessageListView()
        .environment(AppState.debugPreviewState(messageCount: 120))
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 720)
}
