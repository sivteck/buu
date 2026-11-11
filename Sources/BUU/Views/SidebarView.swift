import AppKit
import SwiftUI
import BUUKit

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var searchScope: ChatSearchScope = .all
    @State private var searchResults: [ChatSearchHit] = []
    @State private var editingConversationID: UUID?
    @State private var renameDraft = ""
    @State private var renamingTask: AgenticTaskRecord?
    @State private var renameTaskText = ""
    @State private var pendingDeleteChat: Conversation?
    @State private var collapsedSections: Set<ChatSectionKind> = []

    private let listRowInsets = EdgeInsets(
        top: 2,
        leading: Theme.Metrics.rowInset,
        bottom: 2,
        trailing: Theme.Metrics.rowInset
    )

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchKey: String {
        "\(appState.sidebarMode.rawValue)|\(searchScope.rawValue)|\(searchText)|\(appState.conversations.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            primaryAction
            searchField

            Group {
                switch appState.sidebarMode {
                case .chats:
                    chatList
                case .agentic:
                    agenticList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SidebarFooter(showsProvider: appState.sidebarMode == .chats)
        }
        .background(Theme.Colors.canvas)
        .layoutRegion("Sidebar")
        .onChange(of: appState.focusSidebarSearchToken) { _, _ in
            searchFocused = true
        }
        .onChange(of: appState.activeConversationID) { _, _ in
            if editingConversationID != nil {
                commitRename()
            }
        }
        .task(id: searchKey) {
            await updateSearch()
        }
        .background {
            Button("Delete Chat") {
                if appState.sidebarMode == .chats, !searchFocused,
                   let id = appState.activeConversationID,
                   let chat = appState.conversations.first(where: { $0.id == id }) {
                    pendingDeleteChat = chat
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .hidden()
        }
        .sheet(item: $renamingTask) { task in
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Rename task").font(.headline)
                TextField("Task name", text: $renameTaskText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { renamingTask = nil }
                    Button("Rename") {
                        appState.renameAgenticTask(task.id, title: renameTaskText)
                        renamingTask = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(Theme.Spacing.l)
            .frame(width: 340)
        }
        .confirmationDialog(
            "Delete chat?",
            isPresented: Binding(
                get: { pendingDeleteChat != nil },
                set: { if !$0 { pendingDeleteChat = nil } }
            ),
            presenting: pendingDeleteChat
        ) { chat in
            Button("Delete \(chat.title)", role: .destructive) {
                appState.deleteConversation(chat)
                pendingDeleteChat = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteChat = nil }
        } message: { _ in
            Text("This permanently deletes the conversation.")
        }
    }

    private var modePicker: some View {
        Picker("Section", selection: Binding(
            get: { appState.sidebarMode },
            set: { appState.sidebarMode = $0 }
        )) {
            ForEach(SidebarMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var primaryAction: some View {
        Button {
            appState.performPrimarySidebarAction()
            if appState.sidebarMode == .chats {
                searchText = ""
                editingConversationID = nil
            }
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Label(primaryActionTitle, systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: Theme.Spacing.s)
                Text("⌘N")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
        .accessibilityLabel(primaryActionTitle)
        .accessibilityHint("Command N")
    }

    private var primaryActionTitle: String {
        switch appState.sidebarMode {
        case .chats: return "New Chat"
        case .agentic: return "New Task"
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    searchText = ""
                    searchFocused = false
                    return .handled
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            if appState.sidebarMode == .chats {
                Menu {
                    ForEach(ChatSearchScope.allCases) { scope in
                        Button {
                            searchScope = scope
                        } label: {
                            if searchScope == scope {
                                Label(scope.title, systemImage: "checkmark")
                            } else {
                                Text(scope.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Search scope")
                .accessibilityLabel("Search scope, \(searchScope.title)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.Colors.control, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search sidebar")
    }

    // MARK: - Chats

    @ViewBuilder
    private var chatList: some View {
        if appState.isLoadingConversations && appState.conversations.isEmpty {
            VStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { _ in SidebarSkeletonRow() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        } else if isSearching {
            chatSearchList
        } else {
            groupedChatList
        }
    }

    private var groupedChatList: some View {
        let groups = ChatSectionKind.groups(appState.conversations)
        return List(selection: Binding(
            get: { appState.activeConversationID },
            set: { appState.activeConversationID = $0 }
        )) {
            if groups.isEmpty {
                SidebarEmptyChats { appState.performPrimarySidebarAction() }
                    .listRowInsets(listRowInsets)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            ForEach(groups) { group in
                Section {
                    if !collapsedSections.contains(group.kind) {
                        ForEach(group.conversations) { conversation in
                            chatRow(conversation, subtitle: ChatSectionKind.subtitle(for: conversation))
                        }
                    }
                } header: {
                    ChatSectionHeader(
                        title: group.kind.title,
                        isCollapsed: collapsedSections.contains(group.kind),
                        onToggle: { toggleSection(group.kind) }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: Theme.Spacing.m, bottom: 4, trailing: Theme.Spacing.m))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var chatSearchList: some View {
        List(selection: Binding(
            get: { appState.activeConversationID },
            set: { appState.activeConversationID = $0 }
        )) {
            if searchResults.isEmpty {
                VStack(spacing: Theme.Spacing.s) {
                    Text("No results for “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Clear search") { searchText = "" }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(Theme.Spacing.l)
                .listRowInsets(listRowInsets)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            } else {
                ForEach(searchResults) { hit in
                    chatRow(
                        hit.conversation,
                        subtitle: hit.snippet,
                        isSearchResult: true
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func chatRow(_ conversation: Conversation, subtitle: AttributedString, isSearchResult: Bool = false) -> some View {
        if editingConversationID == conversation.id {
            SidebarInlineRenameRow(
                title: conversation.title,
                draft: $renameDraft,
                onSubmit: commitRename,
                onCancel: cancelRename
            )
            .tag(conversation.id)
            .listRowInsets(listRowInsets)
            .listRowSeparator(.hidden)
        } else {
            SidebarRow(
                title: conversation.title,
                subtitle: subtitle,
                subtitleString: isSearchResult ? String(subtitle.characters) : ChatSectionKind.subtitleText(for: conversation),
                detailTooltip: "\(conversation.endpointName) · \(conversation.model)",
                icon: nil,
                isSelected: appState.activeConversationID == conversation.id,
                showsSelectionBackground: false,
                isGenerating: conversation.turns.contains { $0.isStreaming },
                isUnread: conversation.isUnread == true,
                isPinned: conversation.isPinned == true,
                statusColor: nil,
                actions: chatActions(conversation)
            )
            .equatable()
            .onTapGesture {
                appState.selectConversation(conversation.id)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(conversation) })
            .tag(conversation.id)
            .listRowInsets(listRowInsets)
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    pendingDeleteChat = conversation
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    appState.toggleConversationPin(conversation)
                } label: {
                    Label(conversation.isPinned == true ? "Unpin" : "Pin", systemImage: conversation.isPinned == true ? "pin.slash" : "pin")
                }
            }
        }
    }

    private func chatActions(_ conversation: Conversation) -> SidebarRowActions {
        let id = conversation.id
        return SidebarRowActions(
            rename: {
                if let current = appState.conversations.first(where: { $0.id == id }) { startRename(current) }
            },
            togglePin: {
                if let current = appState.conversations.first(where: { $0.id == id }) {
                    appState.toggleConversationPin(current)
                }
            },
            duplicate: {
                if let current = appState.conversations.first(where: { $0.id == id }) {
                    appState.duplicate(current)
                }
            },
            export: {
                if let current = appState.conversations.first(where: { $0.id == id }) {
                    exportConversation(current)
                }
            },
            delete: {
                if let current = appState.conversations.first(where: { $0.id == id }) {
                    pendingDeleteChat = current
                }
            }
        )
    }

    // MARK: - Agentic

    private var agenticList: some View {
        let activeID = appState.activeAgenticTask?.id
        let macConfigIDs = Set(appState.macTaskConfigurations.map(\.id))
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tasks = appState.agenticTasks.filter { $0.kind == .mac }.filter { task in
            guard !needle.isEmpty else { return true }
            return task.title.lowercased().contains(needle)
                || taskSubtitle(task, activeID: activeID, macConfigIDs: macConfigIDs).lowercased().contains(needle)
        }

        return List {
            if tasks.isEmpty {
                Text(needle.isEmpty ? "No Mac tasks yet. Use New task." : "No results")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.l)
                    .listRowInsets(listRowInsets)
                    .listRowSeparator(.hidden)
            }
            if !tasks.isEmpty {
                Section("Mac Tasks") {
                    ForEach(tasks) { task in
                        taskRow(task, activeID: activeID, macConfigIDs: macConfigIDs)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func taskRow(
        _ task: AgenticTaskRecord,
        activeID: UUID?,
        macConfigIDs: Set<UUID>
    ) -> some View {
        let isActive = activeID == task.id
        let status = taskStatus(task, activeID: activeID)
        SidebarRow(
            title: task.title,
            subtitle: AttributedString(taskSubtitle(task, activeID: activeID, macConfigIDs: macConfigIDs)),
            subtitleString: taskSubtitle(task, activeID: activeID, macConfigIDs: macConfigIDs),
            icon: "macwindow.on.rectangle",
            isSelected: isActive,
            showsSelectionBackground: true,
            isGenerating: status.running,
            isUnread: false,
            isPinned: false,
            statusColor: status.color,
            actions: SidebarRowActions(
                rename: {
                    if let current = appState.agenticTasks.first(where: { $0.id == task.id }) {
                        renameTaskText = current.title
                        renamingTask = current
                    }
                },
                duplicate: { _ = appState.duplicateAgenticTask(task.id) },
                delete: { appState.removeAgenticTask(task.id) }
            )
        )
        .equatable()
        .onTapGesture { appState.selectAgenticTask(task.id) }
        .listRowInsets(listRowInsets)
        .listRowSeparator(.hidden)
    }

    // MARK: - Helpers

    private func taskSubtitle(
        _ task: AgenticTaskRecord,
        activeID: UUID?,
        macConfigIDs: Set<UUID>
    ) -> String {
        let status: String
        if activeID == task.id {
            status = appState.virtualMacAgent.runState.rawValue
        } else {
            status = task.lastStatus ?? appState.virtualMac.vmState
        }
        guard macConfigIDs.contains(task.configurationID) else { return "Missing configuration" }
        return "NMac · \(status)"
    }

    private func taskStatus(_ task: AgenticTaskRecord, activeID: UUID?) -> (color: Color, running: Bool) {
        if activeID == task.id {
            switch appState.virtualMacAgent.runState {
            case .running: return (.green, true)
            case .paused: return (.orange, false)
            case .failed: return (.red, false)
            case .finished: return (.green, false)
            case .idle: return (.secondary, false)
            }
        }
        if task.lastStatus == "failed" { return (.red, false) }
        if task.lastStatus == "completed" { return (.green, false) }
        if task.lastStatus == "running" { return (.green, true) }
        return (.secondary, false)
    }

    private func toggleSection(_ kind: ChatSectionKind) {
        if collapsedSections.contains(kind) {
            collapsedSections.remove(kind)
        } else {
            collapsedSections.insert(kind)
        }
    }

    private func startRename(_ conversation: Conversation) {
        renameDraft = conversation.title
        editingConversationID = conversation.id
        searchText = ""
    }

    private func commitRename() {
        guard let id = editingConversationID,
              let conversation = appState.conversations.first(where: { $0.id == id }) else {
            cancelRename()
            return
        }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            appState.renameConversation(conversation, to: title)
        }
        cancelRename()
    }

    private func cancelRename() {
        editingConversationID = nil
        renameDraft = ""
    }

    private func exportConversation(_ conversation: Conversation) {
        let panel = NSSavePanel()
        panel.title = "Export chat"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(conversation.title).md"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "# \(conversation.title)\n\n"
        for turn in conversation.turns {
            text += "## \(turn.role.rawValue.capitalized)\n\n\(turn.text)\n\n"
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func updateSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appState.sidebarMode == .chats, !query.isEmpty else {
            if !searchResults.isEmpty { searchResults = [] }
            return
        }
        let snapshot = appState.conversations
        let scope = searchScope
        let activeModel = appState.currentConversation?.model ?? ""
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let hits = await Task.detached(priority: .userInitiated) {
            ChatSearchIndex.search(conversations: snapshot, query: query, scope: scope, activeModel: activeModel)
        }.value
        guard !Task.isCancelled else { return }
        searchResults = hits
    }
}

// MARK: - Shared row

struct SidebarRowActions {
    var rename: (() -> Void)?
    var togglePin: (() -> Void)?
    var duplicate: (() -> Void)?
    var export: (() -> Void)?
    var delete: (() -> Void)?

    var isEmpty: Bool {
        rename == nil && togglePin == nil && duplicate == nil && export == nil && delete == nil
    }
}

struct SidebarRow: View, Equatable {
    let title: String
    let subtitle: AttributedString
    let subtitleString: String
    var detailTooltip: String? = nil
    let icon: String?
    let isSelected: Bool
    let showsSelectionBackground: Bool
    let isGenerating: Bool
    let isUnread: Bool
    let isPinned: Bool
    let statusColor: Color?
    let actions: SidebarRowActions?

    @State private var isHovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.subtitleString == rhs.subtitleString
            && lhs.detailTooltip == rhs.detailTooltip
            && lhs.icon == rhs.icon
            && lhs.isSelected == rhs.isSelected
            && lhs.showsSelectionBackground == rhs.showsSelectionBackground
            && lhs.isGenerating == rhs.isGenerating
            && lhs.isUnread == rhs.isUnread
            && lhs.isPinned == rhs.isPinned
            && lhs.statusColor == rhs.statusColor
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .frame(width: 24, alignment: .trailing)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, Theme.Spacing.xs)
        .background {
            if showsSelectionBackground && isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            } else if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            menuItems
        }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Rename") {
            if let rename = actions?.rename { rename() }
        }
        .accessibilityAction(named: isPinned ? "Unpin" : "Pin") {
            if let togglePin = actions?.togglePin { togglePin() }
        }
        .accessibilityAction(named: "Delete") {
            if let delete = actions?.delete { delete() }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isHovering, let actions, !actions.isEmpty {
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        } else {
            HStack(spacing: 3) {
                if isGenerating {
                    ProgressView().controlSize(.mini)
                } else {
                    if isUnread {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    if let statusColor {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let actions {
            if let rename = actions.rename {
                Button("Rename…", action: rename)
            }
            if let togglePin = actions.togglePin {
                Button(isPinned ? "Unpin" : "Pin", action: togglePin)
            }
            if let duplicate = actions.duplicate {
                Button("Duplicate", action: duplicate)
            }
            if let export = actions.export {
                Button("Export…", action: export)
            }
            if actions.delete != nil {
                Divider()
                Button("Delete", role: .destructive) { actions.delete?() }
            }
        }
    }

    private var tooltip: String {
        let detail = detailTooltip ?? subtitleString
        return detail.isEmpty ? title : "\(title)\n\(detail)"
    }

    private var accessibilityLabel: String {
        var pieces = [title, subtitleString]
        if isGenerating { pieces.append("Generating") }
        else if isUnread { pieces.append("Unread") }
        else if isPinned { pieces.append("Pinned") }
        return pieces.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct SidebarInlineRenameRow: View {
    let title: String
    @Binding var draft: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            TextField("Chat title", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($focused)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onCancel)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, Theme.Spacing.xs)
        .background(Theme.Colors.control, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .onAppear {
            draft = title
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                onSubmit()
            }
        }
    }
}

struct ChatSectionHeader: View {
    let title: String
    let isCollapsed: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if isHovering {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}

struct SidebarEmptyChats: View {
    var onCreate: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No chats yet")
                .font(.callout.weight(.medium))
            Text("Start a new chat to see it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("New Chat", action: onCreate)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }
}

struct SidebarSkeletonRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.10)).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)).frame(height: 11).frame(maxWidth: 150)
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.08)).frame(height: 9).frame(maxWidth: 100)
            }
            Spacer()
        }
        .frame(height: 48)
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Search

enum ChatSearchScope: String, CaseIterable, Identifiable {
    case all
    case thisModel
    case pinned

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .thisModel: return "This model"
        case .pinned: return "Pinned"
        }
    }
}

struct ChatSearchHit: Identifiable, Sendable {
    var id: UUID { conversation.id }
    let conversation: Conversation
    let snippet: AttributedString
}

enum ChatSearchIndex {
    static func search(
        conversations: [Conversation],
        query: String,
        scope: ChatSearchScope,
        activeModel: String
    ) -> [ChatSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let eligible = conversations.filter { conversation in
            switch scope {
            case .all: return true
            case .thisModel: return conversation.model == activeModel
            case .pinned: return conversation.isPinned == true
            }
        }
        return eligible.compactMap { conversation in
            if let range = conversation.title.range(of: needle, options: .caseInsensitive) {
                let snippet = highlight(conversation.title, range: range)
                return ChatSearchHit(conversation: conversation, snippet: snippet)
            }
            for turn in conversation.turns.reversed() {
                guard let range = turn.text.range(of: needle, options: .caseInsensitive) else { continue }
                let snippetText = snippet(turn.text, around: range)
                return ChatSearchHit(conversation: conversation, snippet: highlight(snippetText, needle: needle))
            }
            return nil
        }
        .sorted {
            if $0.conversation.updatedAt != $1.conversation.updatedAt {
                return $0.conversation.updatedAt > $1.conversation.updatedAt
            }
            return $0.conversation.id.uuidString < $1.conversation.id.uuidString
        }
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = flattened.range(of: String(text[range]), options: .caseInsensitive) else {
            return String(flattened.prefix(120))
        }
        let start = flattened.index(match.lowerBound, offsetBy: -30, limitedBy: flattened.startIndex) ?? flattened.startIndex
        let end = flattened.index(match.upperBound, offsetBy: 60, limitedBy: flattened.endIndex) ?? flattened.endIndex
        return String(flattened[start..<end])
    }

    private static func highlight(_ text: String, needle: String) -> AttributedString {
        guard let range = text.range(of: needle, options: .caseInsensitive) else {
            return AttributedString(text)
        }
        return highlight(text, range: range)
    }

    private static func highlight(_ text: String, range: Range<String.Index>) -> AttributedString {
        var output = AttributedString(String(text[..<range.lowerBound]))
        var match = AttributedString(String(text[range]))
        match.inlinePresentationIntent = .stronglyEmphasized
        output += match
        output += AttributedString(String(text[range.upperBound...]))
        return output
    }
}

// MARK: - Grouping

enum ChatSectionKind: String, CaseIterable, Identifiable {
    case pinned
    case today
    case yesterday
    case previous7
    case older

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pinned: return "Pinned"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7: return "Previous 7 Days"
        case .older: return "Older"
        }
    }

    static func groups(_ conversations: [Conversation], calendar: Calendar = .current) -> [ChatSectionGroup] {
        let sorted = conversations.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let pinned = sorted.filter { $0.isPinned == true }
        let unpinned = sorted.filter { $0.isPinned != true }
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        var buckets: [ChatSectionKind: [Conversation]] = [:]
        for conversation in unpinned {
            let day = calendar.startOfDay(for: conversation.updatedAt)
            let kind: ChatSectionKind
            if day >= today {
                kind = .today
            } else if day >= yesterday {
                kind = .yesterday
            } else if day >= weekAgo {
                kind = .previous7
            } else {
                kind = .older
            }
            buckets[kind, default: []].append(conversation)
        }
        var groups: [ChatSectionGroup] = []
        if !pinned.isEmpty {
            groups.append(ChatSectionGroup(kind: .pinned, conversations: pinned))
        }
        for kind in [ChatSectionKind.today, .yesterday, .previous7, .older] {
            if let items = buckets[kind], !items.isEmpty {
                groups.append(ChatSectionGroup(kind: kind, conversations: items))
            }
        }
        return groups
    }

    static func subtitle(for conversation: Conversation) -> AttributedString {
        AttributedString(subtitleText(for: conversation))
    }

    static func subtitleText(for conversation: Conversation) -> String {
        let time = relativeTime(conversation.updatedAt)
        let model = conversation.model.isEmpty ? conversation.endpointName : conversation.model
        return model.isEmpty ? time : "\(time) · \(model)"
    }

    static func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        let start = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: start).day ?? 0
        if days == 1 { return "Yesterday" }
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct ChatSectionGroup: Identifiable {
    var id: ChatSectionKind { kind }
    let kind: ChatSectionKind
    let conversations: [Conversation]
}

// MARK: - Footer

struct SidebarFooter: View {
    @Environment(AppState.self) private var appState
    var showsProvider = true

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if showsProvider {
                providerMenu
            }
            Spacer(minLength: Theme.Spacing.xs)
            settingsButton
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
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
            Button("Server Settings…") { appState.showSettings = true }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "server.rack").font(.system(size: 10))
                Text(appState.activeEndpoint?.name ?? "No server")
                    .font(.system(size: 11))
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

#if DEBUG
#Preview("Sidebar – dark") {
    SidebarView()
        .environment(AppState())
        .frame(width: Theme.Metrics.sidebarIdeal, height: 700)
        .preferredColorScheme(.dark)
}

#Preview("Sidebar – light – narrow") {
    SidebarView()
        .environment(AppState())
        .frame(width: Theme.Metrics.sidebarMin, height: 700)
        .preferredColorScheme(.light)
}

#Preview("Sidebar – wide") {
    SidebarView()
        .environment(AppState())
        .frame(width: Theme.Metrics.sidebarMax, height: 700)
        .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Sidebar rows – states") {
    VStack(alignment: .leading, spacing: 2) {
        SidebarRow(
            title: "Normal chat",
            subtitle: AttributedString("2h · llama-3.3-70b"),
            subtitleString: "2h · llama-3.3-70b",
            icon: nil,
            isSelected: false,
            showsSelectionBackground: false,
            isGenerating: false,
            isUnread: false,
            isPinned: false,
            statusColor: nil,
            actions: nil
        )
        SidebarRow(
            title: "Selected chat",
            subtitle: AttributedString("Yesterday · qwen2.5-coder"),
            subtitleString: "Yesterday · qwen2.5-coder",
            icon: nil,
            isSelected: true,
            showsSelectionBackground: true,
            isGenerating: false,
            isUnread: false,
            isPinned: false,
            statusColor: nil,
            actions: nil
        )
        SidebarRow(
            title: "A very long chat title that should truncate at the tail",
            subtitle: AttributedString("Mon · deepseek-reasoner-2025-01"),
            subtitleString: "Mon · deepseek-reasoner-2025-01",
            icon: nil,
            isSelected: false,
            showsSelectionBackground: false,
            isGenerating: false,
            isUnread: false,
            isPinned: false,
            statusColor: nil,
            actions: nil
        )
        SidebarRow(
            title: "Generating",
            subtitle: AttributedString("now · qwen2.5-coder"),
            subtitleString: "now · qwen2.5-coder",
            icon: nil,
            isSelected: false,
            showsSelectionBackground: false,
            isGenerating: true,
            isUnread: false,
            isPinned: false,
            statusColor: nil,
            actions: nil
        )
        SidebarRow(
            title: "Unread",
            subtitle: AttributedString("Yesterday · llama-3.3-70b"),
            subtitleString: "Yesterday · llama-3.3-70b",
            icon: nil,
            isSelected: false,
            showsSelectionBackground: false,
            isGenerating: false,
            isUnread: true,
            isPinned: false,
            statusColor: nil,
            actions: nil
        )
        SidebarRow(
            title: "Pinned",
            subtitle: AttributedString("Friday · qwen2.5-coder"),
            subtitleString: "Friday · qwen2.5-coder",
            icon: nil,
            isSelected: false,
            showsSelectionBackground: false,
            isGenerating: false,
            isUnread: false,
            isPinned: true,
            statusColor: nil,
            actions: nil
        )
    }
    .padding(8)
    .frame(width: 250)
    .preferredColorScheme(.dark)
}

private func sidebarPreviewSearchSnippet() -> AttributedString {
    var snippet = AttributedString("Yesterday · ")
    var match = AttributedString("quarterly report")
    match.inlinePresentationIntent = .stronglyEmphasized
    snippet += match
    snippet += AttributedString(" · qwen2.5-coder")
    return snippet
}

#Preview("Sidebar search result – highlighted") {
    SidebarRow(
        title: "Report review",
        subtitle: sidebarPreviewSearchSnippet(),
        subtitleString: "Yesterday · quarterly report · qwen2.5-coder",
        icon: nil,
        isSelected: false,
        showsSelectionBackground: false,
        isGenerating: false,
        isUnread: false,
        isPinned: false,
        statusColor: nil,
        actions: nil
    )
    .padding(8)
    .frame(width: 250)
    .preferredColorScheme(.light)
}
#endif
