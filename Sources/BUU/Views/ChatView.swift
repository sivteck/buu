import SwiftUI
import BUUKit

/// The detail pane: a header bar that shares the conversation column, the
/// scrolling transcript and the composer (attached by `MessageListView` as a
/// bottom safe-area inset, so nothing is ever drawn over it).
struct ChatView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderBar()
            Divider()
            MessageListView()
        }
        .background(Theme.Colors.canvas)
        .onExitCommand {
            if appState.isSending { appState.stop() }
        }
    }
}

// MARK: - Header

/// One unified header: title (editable on double-click) with the provider as a
/// subtitle on the leading edge, the model pill on the trailing edge. Both sit
/// in the same 760pt column as the messages and the composer.
struct ChatHeaderBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            ChatTitleView()
            Spacer(minLength: Theme.Spacing.m)

            if let context = MetricsFormatter.compactCount(appState.contextTokenCount) {
                Label(context, systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help("Tokens currently in the model's context (prompt + completion of the last answer)")
                    .accessibilityLabel("Context size: \(context)")
            }

            ModelPickerMenu()
        }
        .padding(.vertical, Theme.Spacing.s)
        .contentColumn()
        .background(.bar)
    }
}

struct ChatTitleView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var conversation: Conversation? { appState.currentConversation }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if isEditing {
                TextField("Chat title", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .focused($isFocused)
                    .onAppear { isFocused = true }
                    .onSubmit(commit)
                    .onChange(of: isFocused) {
                        if !isFocused { commit() }
                    }
                    .onExitCommand { isEditing = false }
                    .frame(maxWidth: 320, alignment: .leading)
            } else {
                Text(conversation?.title ?? "New chat")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginEditing() }
                    .help("Double-click to rename")
            }

            if let endpoint = appState.activeEndpoint {
                Text(endpoint.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .themeAnimation(isEditing, reduceMotion: reduceMotion)
    }

    private func beginEditing() {
        guard conversation != nil else { return }
        draft = conversation?.title ?? ""
        isEditing = true
    }

    private func commit() {
        defer { isEditing = false }
        guard let conversation else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != conversation.title else { return }
        appState.renameConversation(conversation, to: trimmed)
    }
}



// MARK: - Model pill

/// A single compact pill: model name, then a trailing chevron.
struct ModelPickerMenu: View {
    @Environment(AppState.self) private var appState

    private var title: String {
        let model = appState.currentModel
        return model.isEmpty ? "Select Model" : model
    }

    var body: some View {
        Menu {
            if appState.availableModels.isEmpty {
                Text("No models listed")
            } else {
                ForEach(appState.availableModels) { model in
                    Button {
                        appState.selectModel(model.id)
                    } label: {
                        if appState.currentModel == model.id {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }

            Divider()

            Button("Refresh Model List") {
                Task { await appState.refreshModels() }
            }
            Button("Server Settings…") {
                appState.showSettings = true
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, Theme.Spacing.s + 2)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandOnHover()
        .help("Choose a model")
        .accessibilityLabel("Model: \(title)")
    }
}

#Preview("Header – dark") {
    VStack(spacing: 0) {
        ChatHeaderBar()
        Divider()
        Spacer()
    }
    .frame(width: 1000, height: 160)
    .background(Theme.Colors.canvas)
    .environment(AppState())
    .preferredColorScheme(.dark)
}

#Preview("Header – light") {
    VStack(spacing: 0) {
        ChatHeaderBar()
        Divider()
        Spacer()
    }
    .frame(width: 1000, height: 160)
    .background(Theme.Colors.canvas)
    .environment(AppState())
    .preferredColorScheme(.light)
}
