import SwiftUI
import BUUKit

struct SidebarView: View {
    @Environment(AppState.self) private var appState

    @State private var renamingConversation: Conversation?
    @State private var renameText = ""

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: 2,
            leading: Theme.Metrics.rowInset,
            bottom: 2,
            trailing: Theme.Metrics.rowInset
        )
    }

    var body: some View {
        @Bindable var appState = appState

        List(selection: $appState.activeConversationID) {
            header

            ForEach(appState.conversations) { conversation in
                SidebarChatRow(
                    conversation: conversation,
                    isSelected: appState.activeConversationID == conversation.id
                )
                    .tag(conversation.id)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
                    .contextMenu {
                        Button("Rename…") {
                            renameText = conversation.title
                            renamingConversation = conversation
                        }
                        Button("Duplicate") {
                            appState.duplicate(conversation)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            appState.deleteConversation(conversation)
                        }
                    }
            }

            if appState.conversations.isEmpty {
                Text("No chats yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Metrics.rowInnerInset)
                    .padding(.vertical, Theme.Spacing.s)
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
        .alert("Rename chat", isPresented: isRenaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingConversation = nil }
            Button("Rename") {
                if let conversation = renamingConversation {
                    let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    appState.renameConversation(conversation, to: title.isEmpty ? conversation.title : title)
                }
                renamingConversation = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("Chats")
                .font(.headline)
            Spacer(minLength: Theme.Spacing.xs)
            Button {
                appState.newConversation()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .iconHitTarget(24)
            .help("New chat (⌘N)")
            .accessibilityLabel("New chat")
        }
        .padding(.horizontal, Theme.Metrics.rowInnerInset)
        .padding(.vertical, Theme.Spacing.xs)
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        )
    }
}

// MARK: - Row

struct SidebarChatRow: View {
    let conversation: Conversation
    var isSelected = false

    @State private var isHovering = false

    private var subtitle: String {
        if conversation.model.isEmpty { return conversation.endpointName }
        return "\(conversation.endpointName) · \(conversation.model)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(conversation.title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Metrics.rowInnerInset)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                .fill(isHovering && !isSelected ? Color.secondary.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Footer

struct SidebarFooter: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: Theme.Spacing.xs) {
                providerMenu
                Spacer(minLength: Theme.Spacing.xs)
                settingsButton
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
        }
        .background(.bar)
    }

    private var providerMenu: some View {
        Menu {
            ForEach(appState.settings.endpoints) { endpoint in
                Button {
                    appState.selectEndpoint(endpoint)
                } label: {
                    if endpoint.id == appState.settings.activeEndpointID {
                        Label(endpoint.name, systemImage: "checkmark")
                    } else {
                        Text(endpoint.name)
                    }
                }
            }

            Divider()

            Button("Server Settings…") {
                appState.showSettings = true
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10))
                Text(appState.activeEndpoint?.name ?? "No server")
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandOnHover()
        .help("Active server")
        .accessibilityLabel("Active server: \(appState.activeEndpoint?.name ?? "none")")
    }

    private var settingsButton: some View {
        Button {
            appState.showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .iconHitTarget()
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }
}

#Preview("Sidebar – dark") {
    SidebarView()
        .environment(AppState())
        .preferredColorScheme(.dark)
        .frame(width: 260, height: 520)
}

#Preview("Sidebar – light") {
    SidebarView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 260, height: 520)
}
