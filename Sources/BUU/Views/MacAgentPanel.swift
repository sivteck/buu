import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BUUKit

struct MacAgentPanel: View {
    @Environment(AppState.self) private var appState
    @State private var section: MacAgentSection = .trace
    @State private var steerDraft = ""
    @State private var confirmingStop = false
    @State private var confirmingRunNextNow = false
    @State private var errorMessage: String?
    @State private var isDropTargeted = false
    @State private var confirmingClearContext = false
    @State private var pendingClearAction: ClearContextAction?
    @State private var showingRunHistory = false
    @State private var viewingRun: MacRunHistoryEntry?
    @State private var panelHeight: CGFloat = 680
    @FocusState private var composerFocused: Bool

    private enum ClearContextAction {
        case now
        case afterStep
        case andRun
    }

    private var agent: VirtualMacAgentModel { appState.virtualMacAgent }
    private var task: AgenticTaskRecord? { appState.activeAgenticTask }
    private var endpoint: ProviderEndpoint? {
        if let id = agent.selectedEndpointID {
            return appState.settings.endpoints.first { $0.id == id }
        }
        return appState.settings.endpoints.first
    }
    private var maxRounds: Int? {
        guard let id = task?.id, let value = appState.maxAgentRounds(for: id), value > 0 else { return nil }
        return value
    }

    var body: some View {
        // The inspector can measure its content with an unbounded/ideal height.
        // A long trace makes ScrollView report its content height in that pass,
        // which grows this VStack and puts the composer below the visible clip.
        // GeometryReader supplies the actual inspector height, so the trace is
        // forced to shrink and the composer always stays inside the panel.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                topBar
                    .layoutPriority(2)
                    .layoutRegion("InspectorHeader")
                Divider()
                tabs
                    .frame(maxHeight: .infinity)
                composer
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
                    .layoutRegion("Composer")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(DesignTokens.Surface.panel)
            .onAppear {
                if abs(panelHeight - proxy.size.height) > 0.5 { panelHeight = proxy.size.height }
            }
            .onChange(of: proxy.size.height) { _, value in
                if abs(panelHeight - value) > 0.5 { panelHeight = value }
            }
        }
        .layoutRegion("Inspector")
        .onChange(of: appState.macPanelSectionRequest) { _, request in
            guard let request else { return }
            section = request
            appState.macPanelSectionRequest = nil
        }
        .onChange(of: appState.focusMacComposerToken) { _, _ in
            composerFocused = true
        }
        .onAppear {
            if let request = appState.macPanelSectionRequest {
                section = request
                appState.macPanelSectionRequest = nil
            }
        }
        .onChange(of: appState.activeAgenticTask?.id) { _, _ in
            section = .trace
            viewingRun = nil
        }
        .confirmationDialog("Stop the current run?", isPresented: $confirmingStop) {
            Button("Stop", role: .destructive) { stopRun() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The model loop stops immediately. Finished rounds and pending steers stay saved.")
        }
        .confirmationDialog("Run the next queued task now?", isPresented: $confirmingRunNextNow) {
            Button("Stop after current round and start next") {
                if let task { appState.requestRunNextNow(taskID: task.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current run stops at its next safe boundary, then the queue advances.")
        }
        .confirmationDialog("Clear the model's conversation context?", isPresented: $confirmingClearContext) {
            Button("Clear context", role: .destructive) { performClearContext() }
            Button("Cancel", role: .cancel) { pendingClearAction = nil }
        } message: {
            Text("VM state, files, outputs and the trace stay. Only the model's conversation context is reset.")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(runStateColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(runStateLabel)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    MacAgentActionText(agent: agent, task: task)
                }
                Spacer()
                headerControls
                Menu {
                    Button(agent.isRunning ? "Clear context (pause or stop first)" : "Clear context") {
                        requestClearContext(.now)
                    }
                    .disabled(agent.isRunning || !agent.hasModelContext)
                    if agent.isRunning {
                        Button("Clear after current step") {
                            requestClearContext(.afterStep)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More run actions")
                .accessibilityLabel("More run actions")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    runSwitcherButton
                    Text(summaryLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                    Spacer(minLength: 4)
                    budgetMeter
                }
                HStack(spacing: 8) {
                    runSwitcherButton
                    Spacer(minLength: 4)
                    Text(compactBudgetText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DesignTokens.Surface.panel)
    }

    private var runSwitcherButton: some View {
        Button {
            showingRunHistory = true
        } label: {
            HStack(spacing: 3) {
                Text(runSwitcherLabel)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Run history")
        .accessibilityLabel("Run history, \(runSwitcherLabel)")
        .popover(isPresented: $showingRunHistory, arrowEdge: .bottom) {
            MacRunHistoryPopover(
                entries: task.map { appState.macRunHistory(for: $0.id) } ?? [],
                currentRunState: agent.runState,
                currentRounds: agent.currentRound,
                onCurrent: {
                    viewingRun = nil
                    section = .trace
                    showingRunHistory = false
                },
                onOpen: { entry in
                    viewingRun = entry
                    section = .trace
                    showingRunHistory = false
                },
                onRerun: rerunHistory,
                onExport: exportHistory,
                onDelete: { entry in
                    if let task { appState.deleteMacRunHistory(taskID: task.id, entryID: entry.id) }
                }
            )
        }
    }

    private var compactBudgetText: String {
        let rounds = maxRounds.map { "\(agent.currentRound)/\($0)" } ?? "\(agent.currentRound) rounds"
        if let started = agent.runStartedAt {
            return "\(rounds) · \(elapsed(from: started))"
        }
        return rounds
    }

    @ViewBuilder
    private var headerControls: some View {
        switch agent.runState {
        case .running:
            Button("Pause") { pauseRun() }
                .controlSize(.small)
                .buttonStyle(.bordered)
            Button("Stop", role: .destructive) { confirmingStop = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: EventModifiers())
        case .paused:
            Button("Resume") { startRun() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canStart)
            Button("Stop", role: .destructive) { confirmingStop = true }
                .controlSize(.small)
                .buttonStyle(.bordered)
        case .idle, .finished, .failed:
            EmptyView()
        }
    }

    private var budgetMeter: some View {
        HStack(spacing: 8) {
            if let maxRounds {
                ProgressView(value: Double(min(agent.currentRound, maxRounds)), total: Double(maxRounds))
                    .frame(maxWidth: 80)
                Text("Round \(agent.currentRound) / \(maxRounds)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Round \(agent.currentRound)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let started = agent.runStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(elapsed(from: started))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var runStateLabel: String {
        switch agent.runState {
        case .idle: return "Idle"
        case .running: return "Running"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Failed"
        }
    }

    private var runStateColor: Color {
        switch agent.runState {
        case .idle: return .secondary
        case .running: return .green
        case .paused: return .orange
        case .finished: return .green
        case .failed: return .red
        }
    }

    private var runSwitcherLabel: String {
        let history = task.map { appState.macRunHistory(for: $0.id) } ?? []
        if let viewingRun, let index = history.firstIndex(where: { $0.id == viewingRun.id }) {
            return "Run \(index + 1) · \(viewingRun.rounds) rounds"
        }
        return "Run \(history.count + 1) · \(agent.currentRound) rounds"
    }

    private var summaryLine: String {
        let model = agent.model.isEmpty ? "No model" : agent.model
        let provider = endpoint?.name ?? "No provider"
        let rounds = maxRounds.map { "\($0) rounds" } ?? "unlimited rounds"
        return "\(model) · \(provider) · \(rounds)"
    }

    private var canStart: Bool {
        appState.virtualMac.canAct
            && endpoint != nil
            && !agent.model.isEmpty
            && !agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Tabs

    private var tabs: some View {
        VStack(spacing: 0) {
            sectionPicker
            Divider()
            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutRegion("InspectorContent")
        }
    }

    private var sectionPicker: some View {
        MacAgentSectionPicker(taskID: task?.id, selection: $section)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .layoutPriority(2)
            .layoutRegion("InspectorTabStrip")
    }

    @ViewBuilder
    private var sectionContent: some View {
        if let task {
            switch section {
            case .trace:
                MacTraceSectionView(taskID: task.id, viewingRun: $viewingRun, compact: panelHeight < 560)
            case .artifacts:
                MacArtifactsTabView(taskID: task.id)
            case .outputs:
                MacOutputsTabView(taskID: task.id)
            case .queue:
                MacQueueTabView(
                    taskID: task.id,
                    onQueueCurrent: queueCurrentPrompt,
                    onRunNextNow: { confirmingRunNextNow = true }
                )
            }
        } else {
            Text("Select a task to see its trace.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func exportHistory(_ entry: MacRunHistoryEntry) {
        let sections: [(String, [String])] = [
            ("Run", [
                "title: \(entry.title)",
                "status: \(entry.status)",
                "rounds: \(entry.rounds)",
                "prompt: \(entry.prompt)",
            ]),
            ("Log", entry.log),
        ]
        if let error = LogExporter.export(
            title: "BUU Mac Run",
            suggestedName: "BUU-MacRun.log",
            sections: sections
        ) {
            errorMessage = error
        }
    }

    private func rerunHistory(_ entry: MacRunHistoryEntry) {
        guard let task, !entry.prompt.isEmpty else { return }
        _ = appState.enqueueMacTask(
            taskID: task.id,
            prompt: entry.prompt,
            attachmentIDs: entry.attachmentIDs,
            providerID: agent.selectedEndpointID,
            model: agent.model,
            maxRounds: appState.maxAgentRounds(for: task.id),
            vmStatePolicy: .freshState,
            continueConversation: false
        )
        section = .queue
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let task {
                SteerStripView(
                    items: agent.steerItems,
                    artifacts: appState.macArtifacts(for: task.id),
                    snapshot: agent.snapshot,
                    isRunning: agent.isRunning,
                    isPaused: agent.runState == .paused,
                    onEdit: { id, text in agent.editSteer(id: id, text: text) },
                    onDelete: { id in _ = agent.deleteSteer(id: id) },
                    onSendNow: { id in _ = agent.interruptSteer(id: id) },
                    onReorder: { ids in agent.reorderSteers(ids: ids) },
                    onRetrySteer: { item in
                        _ = agent.retrySteer(id: item.id)
                        Task {
                            for id in item.attachmentIDs {
                                await appState.syncMacArtifact(taskID: task.id, artifactID: id, announce: false)
                            }
                        }
                    },
                    onClearAll: {
                        for item in SteerPlanner.pending(agent.steerItems) where item.state == .queued || item.state == .failed {
                            _ = agent.deleteSteer(id: item.id)
                        }
                    }
                )
            }

            if let sendDisabledReason {
                Text(sendDisabledReason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MacComposerStatusLine(agent: agent, compact: panelHeight < 500) {
                requestClearContext(.now)
            }
            .layoutRegion("StatusLine")

            VStack(alignment: .leading, spacing: 8) {
                if !composerArtifacts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(composerArtifacts) { artifact in
                                attachmentChip(artifact)
                            }
                        }
                    }
                }

                TextField(placeholder, text: composerBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(2...8)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 40, maxHeight: composerTextMaxHeight, alignment: .topLeading)
                    .focused($composerFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if press.modifiers.contains(.option), agent.runState == .running {
                            sendSteer(interrupt: true)
                        } else if press.modifiers.contains(.option) {
                            primarySend()
                        } else if press.modifiers.contains(.command) {
                            primarySend()
                        } else {
                            primarySend()
                        }
                        return .handled
                    }
                    .onKeyPress(.escape, phases: .down) { _ in
                        guard agent.isRunning else { return .ignored }
                        confirmingStop = true
                        return .handled
                    }

                HStack(spacing: 8) {
                    attachMenu
                    MacModelChip()
                    Spacer(minLength: 4)
                    sendControl
                }
            }
            .padding(12)
            .background(DesignTokens.Surface.elevated, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(composerFocused ? 0.6 : 0), lineWidth: 1)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                addAttachments(urls)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .onPasteCommand(of: [.fileURL, .png, .tiff]) { providers in
                handlePaste(providers)
            }
            .help(sendDisabledReason ?? "")

            if composerFocused {
                Text(agent.runState == .running
                     ? "Return to send · Shift-Return for a new line · ⌥Return to interrupt"
                     : "Return to send · Shift-Return for a new line")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 2)
            }
        }
        .padding(12)
    }

    private var composerTextMaxHeight: CGFloat {
        min(260, max(80, panelHeight * 0.4 - 80))
    }

    private var composerArtifacts: [TaskArtifact] {
        guard let task else { return [] }
        return appState.macArtifacts(for: task.id)
    }

    private var guestRoot: String {
        appState.macArtifactFolders?.artifactsRoot ?? "~/Desktop/BUU Artifacts"
    }

    private func attachmentChip(_ artifact: TaskArtifact) -> some View {
        HStack(spacing: 4) {
            Image(systemName: artifact.guestState == .failed ? "exclamationmark.triangle" : "paperclip")
            Text(artifact.name).lineLimit(1)
            Text(attachmentStateLabel(artifact))
                .font(.caption2)
                .foregroundStyle(attachmentStateColor(artifact))
            Button {
                guard let task else { return }
                Task { await appState.removeMacArtifactEverywhere(artifact.id, for: task.id) }
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(artifact.name)")
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(DesignTokens.Surface.input, in: Capsule())
        .help(artifact.guestPath ?? guestRoot)
    }

    private func attachmentStateLabel(_ artifact: TaskArtifact) -> String {
        switch artifact.guestState ?? .queued {
        case .queued: return "Queued"
        case .copying: return "Copying"
        case .inGuest: return "In VM"
        case .opened: return "In VM"
        case .modified: return "Modified"
        case .failed: return "Failed"
        }
    }

    private func attachmentStateColor(_ artifact: TaskArtifact) -> Color {
        switch artifact.guestState ?? .queued {
        case .queued, .copying: return .orange
        case .inGuest, .opened: return .green
        case .modified: return .orange
        case .failed: return .red
        }
    }

    private var attachMenu: some View {
        Menu {
            Button("Add files…") { chooseFiles() }
            Button("Add folder…") { chooseFolder() }
            Button("Paste image") { pasteImage() }
            if !composerArtifacts.isEmpty {
                Divider()
                Button("In VM: \(guestRoot)") {}
                    .disabled(true)
            }
        } label: {
            Image(systemName: "paperclip")
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Attach files")
        .accessibilityLabel("Attach files")
    }

    @ViewBuilder
    private var sendControl: some View {
        if agent.runState == .running,
           steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                confirmingStop = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
            .background(Color.red, in: Capsule())
            .help("Stop the current run")
            .accessibilityLabel("Stop the current run")
        } else {
            HStack(spacing: 0) {
                Button(action: primarySend) {
                    Text(sendLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.borderless)
                .disabled(!sendEnabled)
                .help(sendDisabledReason ?? sendLabel)
                .accessibilityLabel(sendLabel)

                Rectangle()
                    .fill(Color.white.opacity(sendEnabled ? 0.28 : 0.18))
                    .frame(width: 1, height: 18)

                Menu {
                    composerMenuItems
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(minWidth: 28, minHeight: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Send options")
                .accessibilityLabel("Send options")
            }
            .foregroundStyle(sendEnabled ? Color.white : Color.primary.opacity(0.78))
            .background(sendEnabled ? Color.accentColor : Color.accentColor.opacity(0.35), in: Capsule())
            .fixedSize()
            .help(sendDisabledReason ?? "")
        }
    }

    @ViewBuilder
    private var composerMenuItems: some View {
        switch agent.runState {
        case .running:
            Button("Steer after current step") { sendSteer(interrupt: false) }
                .disabled(steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Interrupt and steer") { sendSteer(interrupt: true) }
                .keyboardShortcut(.return, modifiers: [.option])
                .disabled(steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Button("Add to queue") { queueCurrentPrompt() }
            Button("Clear context after current step") { requestClearContext(.afterStep) }
        case .paused:
            Button("Send and resume") { primarySend() }
                .disabled(!sendEnabled)
            Button("Add to queue") { queueCurrentPrompt() }
            Divider()
            Button("Clear context and run") { requestClearContext(.andRun) }
                .disabled(!sendEnabled)
        case .idle, .finished, .failed:
            Button("Run now") { primarySend() }
                .disabled(!sendEnabled)
            Button("Add to queue") { queueCurrentPrompt() }
            Divider()
            Button("Clear context and run") { requestClearContext(.andRun) }
                .disabled(!sendEnabled)
        }
    }

    private var sendLabel: String {
        switch agent.runState {
        case .running: return "Steer"
        case .paused: return steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Resume" : "Send & resume"
        case .idle, .finished, .failed: return "Run"
        }
    }

    private var sendEnabled: Bool {
        guard appState.virtualMac.canAct else { return false }
        switch agent.runState {
        case .running:
            return !steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .paused:
            return canStart || !steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .idle, .finished, .failed:
            return canStart
        }
    }

    private var sendDisabledReason: String? {
        if !appState.virtualMac.canAct {
            return "The guest helper is not ready. Open BUUVirtualMacGuest and allow Screen Recording and Accessibility."
        }
        if agent.runState == .running, steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        if agent.runState != .running, endpoint == nil || agent.model.isEmpty {
            return "Choose a model."
        }
        return nil
    }

    private var composerBinding: Binding<String> {
        if agent.runState == .running || agent.runState == .paused {
            return $steerDraft
        }
        return Binding(
            get: { agent.instructions },
            set: { agent.instructions = String($0.prefix(8000)) }
        )
    }

    private var placeholder: String {
        switch agent.runState {
        case .running: return "Steer the agent. Applied after the current step."
        case .paused: return "Add instructions and resume…"
        case .idle, .finished, .failed: return "Follow up on this run or start a new task…"
        }
    }

    // MARK: - Actions

    private func startRun() {
        guard let endpoint, canStart else { return }
        if let task {
            appState.updateTaskPrompt(taskID: task.id, prompt: agent.instructions)
            appState.updateTaskStatus(taskID: task.id, status: "running")
        }
        steerDraft = ""
        agent.start(
            endpoint: endpoint,
            apiKey: appState.apiKey(for: endpoint),
            model: agent.model,
            instructions: agent.instructions,
            vm: appState.virtualMac
        )
    }

    private func stopRun() {
        agent.cancel(markPaused: false)
        if let task {
            appState.updateTaskStatus(taskID: task.id, status: "stopped")
            appState.handleMacRunCancelled(taskID: task.id)
        }
    }

    private func pauseRun() {
        agent.cancel(markPaused: true)
        if let task { appState.updateTaskStatus(taskID: task.id, status: "paused") }
    }

    private func sendSteer(interrupt: Bool) {
        let text = steerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard agent.enqueueSteer(text: text, interrupt: interrupt) != nil else { return }
        steerDraft = ""
    }

    private func primarySend() {
        switch agent.runState {
        case .running:
            sendSteer(interrupt: false)
        case .paused:
            if !steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sendSteer(interrupt: false)
            }
            startRun()
        case .idle, .finished, .failed:
            startRun()
        }
    }

    private func requestClearContext(_ action: ClearContextAction) {
        guard agent.hasModelContext || action == .andRun else { return }
        pendingClearAction = action
        confirmingClearContext = true
    }

    private func performClearContext() {
        guard let action = pendingClearAction else { return }
        pendingClearAction = nil
        switch action {
        case .now:
            agent.resetSession()
        case .afterStep:
            agent.requestClearContextAfterRound()
        case .andRun:
            agent.resetSession()
            startRun()
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Attach files from a folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true {
                urls.append(url)
                if urls.count >= 50 { break }
            }
        }
        addAttachments(urls)
    }

    private func pasteImage() {
        let pasteboard = NSPasteboard.general
        let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        guard let data else {
            errorMessage = "The clipboard does not contain an image."
            return
        }
        let extensionName = pasteboard.data(forType: .png) != nil ? "png" : "tiff"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted-\(UUID().uuidString).\(extensionName)")
        do {
            try data.write(to: temp, options: .atomic)
            addAttachments([temp])
            try? FileManager.default.removeItem(at: temp)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let collector = DroppedURLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = Self.fileURL(from: item) { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.snapshot()
            if urls.isEmpty {
                pasteImage()
            } else {
                addAttachments(urls)
            }
        }
    }

    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }

    private func addAttachments(_ urls: [URL]) {
        guard let task, !urls.isEmpty else { return }
        do {
            let added = try appState.addMacArtifacts(urls, for: task.id)
            if agent.runState == .running || agent.runState == .paused {
                let text = steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Use the attached file(s)."
                    : steerDraft
                if agent.enqueueSteer(text: text, attachmentIDs: added.map(\.id)) != nil {
                    steerDraft = ""
                }
            }
            Task {
                for artifact in added {
                    await appState.syncMacArtifact(taskID: task.id, artifactID: artifact.id, announce: false)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func queueCurrentPrompt() {
        guard let task else { return }
        let prompt = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            errorMessage = "Add a prompt before queueing."
            return
        }
        appState.updateTaskPrompt(taskID: task.id, prompt: prompt)
        guard appState.enqueueMacTask(
            taskID: task.id,
            prompt: prompt,
            attachmentIDs: (task.artifacts ?? []).map(\.id),
            providerID: agent.selectedEndpointID,
            model: agent.model,
            maxRounds: appState.maxAgentRounds(for: task.id),
            vmStatePolicy: .freshState,
            continueConversation: false
        ) != nil else {
            errorMessage = "Could not add the task to the queue."
            return
        }
        section = .queue
    }

    private func elapsed(from start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

#Preview("Agent panel – idle") {
    MacAgentPanel()
        .environment(AppState())
        .frame(width: 460, height: 680)
        .preferredColorScheme(.dark)
}

private struct MacRunHistoryPopover: View {
    var entries: [MacRunHistoryEntry]
    var currentRunState: MacRunState
    var currentRounds: Int
    var onCurrent: () -> Void
    var onOpen: (MacRunHistoryEntry) -> Void
    var onRerun: (MacRunHistoryEntry) -> Void
    var onExport: (MacRunHistoryEntry) -> Void
    var onDelete: (MacRunHistoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run history").font(.headline)
            Button(action: onCurrent) {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Current run").font(.callout)
                        Text("\(currentRunState.rawValue.capitalized) · \(currentRounds) rounds")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))

            if entries.isEmpty {
                Text("Completed runs appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(entries.reversed())) { entry in
                            row(entry)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(12)
        .frame(width: 380)
    }

    private func row(_ entry: MacRunHistoryEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: entry.status))
                .foregroundStyle(color(for: entry.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.callout).lineLimit(1)
                Text(detail(entry)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button("Open trace") { onOpen(entry) }
                Button("Re-run") { onRerun(entry) }
                Button("Export") { onExport(entry) }
                Divider()
                Button("Delete", role: .destructive) { onDelete(entry) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(6)
        .background(DesignTokens.Surface.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
    }

    private func detail(_ entry: MacRunHistoryEntry) -> String {
        let duration: String
        if let value = entry.duration {
            duration = value < 60 ? "\(Int(value))s" : "\(Int(value / 60))m"
        } else {
            duration = "—"
        }
        return "\(entry.status.capitalized) · \(duration) · \(entry.rounds) rounds · \(entry.finishedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle"
        case "failed": return "exclamationmark.triangle"
        case "paused": return "pause.circle"
        default: return "clock"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed": return .green
        case "failed": return .red
        case "paused": return .orange
        default: return .secondary
        }
    }
}

#Preview("Agent panel – 340") {
    MacAgentPanel()
        .environment(AppState())
        .frame(width: 340, height: 680)
        .preferredColorScheme(.dark)
}

#Preview("Agent panel – 420") {
    MacAgentPanel()
        .environment(AppState())
        .frame(width: 420, height: 680)
        .preferredColorScheme(.light)
}

#Preview("Agent panel – 640") {
    MacAgentPanel()
        .environment(AppState())
        .frame(width: 640, height: 760)
        .preferredColorScheme(.dark)
}

private struct MacAgentSectionPicker: View {
    @Environment(AppState.self) private var appState
    var taskID: UUID?
    @Binding var selection: MacAgentSection

    var body: some View {
        Picker("Panel", selection: $selection) {
            ForEach(MacAgentSection.allCases) { section in
                Text(label(for: section)).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    private func label(for section: MacAgentSection) -> String {
        guard let taskID else { return section.rawValue }
        switch section {
        case .trace:
            return "Trace"
        case .artifacts:
            return "Artifacts \(appState.macArtifacts(for: taskID).count)"
        case .outputs:
            return "Outputs \(appState.macOutputs(for: taskID).count)"
        case .queue:
            let count = appState.macQueuedTasks(for: taskID).filter { $0.state == .queued }.count
            return count == 0 ? "Queue" : "Queue \(count)"
        }
    }
}

private struct MacAgentActionText: View {
    var agent: VirtualMacAgentModel
    var task: AgenticTaskRecord?

    var body: some View {
        Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var detail: String {
        if agent.runState == .finished, let task {
            return task.lastRunAt.map { "Finished \($0.formatted(date: .omitted, time: .shortened))" } ?? "Finished"
        }
        if agent.runState == .failed, let error = agent.errorMessage {
            return error
        }
        if let last = agent.log.reversed().first(where: { $0.hasPrefix("→ ") }) {
            return "Round \(agent.currentRound) · \(last.replacingOccurrences(of: "→ ", with: ""))"
        }
        return agent.currentRound > 0 ? "Round \(agent.currentRound)" : "Ready when you are"
    }
}

private struct MacComposerStatusLine: View {
    var agent: VirtualMacAgentModel
    var compact: Bool = false
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(stateColor).frame(width: 6, height: 6)
            Text(stateLabel)
            if !compact {
                Text("·").foregroundStyle(.tertiary)
                Text(contextSummary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 6)
            Button("Clear context", action: onClear)
                .buttonStyle(.borderless)
                .disabled(!agent.hasModelContext || agent.isRunning)
                .help(!agent.hasModelContext ? "No model context to clear" : (agent.isRunning ? "Pause or stop first" : "Clear the model's conversation context"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private var contextLine: String {
        for line in agent.log.reversed() {
            if line.hasPrefix("Context:") { return line }
            if line == "Context cleared" { return "" }
        }
        return ""
    }

    private var contextSummary: String {
        guard agent.hasModelContext else { return "Context empty" }
        let numbers = contextLine.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if numbers.count >= 2 { return "Context \(numbers[0]) messages · \(numbers[1]) reasoning" }
        if numbers.count == 1 { return "Context \(numbers[0]) messages" }
        return "Context empty"
    }

    private var stateLabel: String {
        switch agent.runState {
        case .idle: return "Idle"
        case .running: return "Running"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Failed"
        }
    }

    private var stateColor: Color {
        switch agent.runState {
        case .idle: return .secondary
        case .running: return .green
        case .paused: return .orange
        case .finished: return .green
        case .failed: return .red
        }
    }
}

private struct MacTraceSectionView: View {
    @Environment(AppState.self) private var appState
    var taskID: UUID
    @Binding var viewingRun: MacRunHistoryEntry?
    var compact: Bool = false

    private var agent: VirtualMacAgentModel { appState.virtualMacAgent }

    var body: some View {
        if let viewingRun {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        self.viewingRun = nil
                    } label: {
                        Label("Back to current", systemImage: "chevron.left")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    Text("Viewing \(viewingRun.title) · \(viewingRun.status.capitalized) · \(viewingRun.rounds) rounds")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Export") { export(viewingRun) }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.06))
                Divider()
                MacTraceTabView(
                    log: viewingRun.log,
                    screenshots: appState.macTraceScreenshots(for: taskID)
                        .filter { viewingRun.screenshotIDs.contains($0.id) },
                    showSuggestions: false,
                    compact: compact,
                    runState: .finished,
                    runStartedAt: viewingRun.startedAt,
                    finishedAt: viewingRun.finishedAt,
                    liveScreenshot: appState.virtualMac.screenshotImage,
                    taskID: taskID,
                    onFollowUp: { appState.focusMacComposerToken += 1 }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MacTraceTabView(
                log: agent.log,
                screenshots: appState.macTraceScreenshots(for: taskID),
                toolCalls: agent.traceMessages.flatMap(\.toolCalls),
                onSuggestion: { suggestion in
                    agent.instructions = suggestion
                    appState.focusMacComposerToken += 1
                },
                compact: compact,
                runState: agent.runState,
                runStartedAt: agent.runStartedAt,
                finishedAt: appState.activeAgenticTask?.lastRunAt,
                liveScreenshot: appState.virtualMac.screenshotImage,
                taskID: taskID,
                onFollowUp: { appState.focusMacComposerToken += 1 }
            )
        }
    }

    private func export(_ entry: MacRunHistoryEntry) {
        let parsed = MacTraceParser.parse(
            log: entry.log,
            screenshots: appState.macTraceScreenshots(for: taskID)
                .filter { entry.screenshotIDs.contains($0.id) },
            runState: .finished,
            runStartedAt: entry.startedAt,
            finishedAt: entry.finishedAt
        )
        let sections: [(String, [String])] = [
            ("Run", [
                "title: \(entry.title)",
                "status: \(entry.status)",
                "rounds: \(entry.rounds)",
                "prompt: \(entry.prompt)",
            ]),
            ("Rounds", MacTraceParser.exportLines(parsed)),
            ("Log", entry.log),
        ]
        _ = LogExporter.export(
            title: "BUU Mac Run",
            suggestedName: "BUU-MacRun.log",
            sections: sections
        )
    }
}
