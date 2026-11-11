import AppKit
import Foundation
import Observation
import SwiftUI
import BUUKit
import VirtualMacKit

/// An image the user attached to the message they are about to send.
struct PendingImage: Identifiable {
    var id = UUID()
    var payload: ImagePayload
    var thumbnail: NSImage
}

/// Central state of the application.
@MainActor
@Observable
final class AppState {

    // MARK: - Persisted state

    var settings: AppSettings = AppSettings()
    var conversations: [Conversation] = []

    // MARK: - Transient state

    var activeConversationID: UUID?
    var availableModels: [RemoteModel] = []
    var isRefreshingModels = false
    var isSending = false
    var composerText = ""
    var pendingImages: [PendingImage] = []
    var showSettings = false
    var endpointStatus: [UUID: String] = [:]
    /// Incremented for every streamed delta. Cheap signal for the transcript's
    /// follow-the-stream logic, instead of a string that changes per token.
    var streamTick = 0
    var errorMessage: String?
    /// The attachment currently shown in the full size image preview.
    var previewedImage: ImageAttachment?
    /// Incremented to ask the composer to take focus (⌘K).
    var focusComposerToken = 0
    var sidebarMode: SidebarMode = SidebarMode(rawValue: UserDefaults.standard.string(forKey: "sidebarMode") ?? "") ?? .chats {
        didSet { UserDefaults.standard.set(sidebarMode.rawValue, forKey: "sidebarMode") }
    }
    var settingsSectionRequest: SettingsSection?
    var showNewTaskWizard = false

    // Sequential Mac Task queue. Tasks run one at a time on the same VM profile.
    var isMacQueueRunning = false
    var macQueueMessage: String?
    @ObservationIgnored private var macQueueConfigurationID: UUID?

    // Guest artifact sync state for the active Mac Task.
    var macArtifactFolders: GuestArtifactFolders?
    var macArtifactProgress: [UUID: Double] = [:]
    var macArtifactMessage: String?
    var macTraceAutosaveMessage: String?
    @ObservationIgnored var macOutputPollTask: Task<Void, Never>?

    // Workspace-level steer/queue transition state.
    var isWorkspaceQueueRunning = false
    var workspaceQueueMessage: String?
    var activeQueuedTaskID: UUID?
    var queueTransitionDeadline: Date?
    var queueTransitionNextTaskID: UUID?
    var queueTransitionFromTitle: String?
    var queueTransitionToTitle: String?
    var macPanelSectionRequest: MacAgentSection?
    var macWorkspaceTabRequest: MacWorkspaceTab?
    var focusMacComposerToken = 0
    var focusSidebarSearchToken = 0
    var isLoadingConversations = false
    var layoutDebugEnabled = false
    @ObservationIgnored var queueCountdownTask: Task<Void, Never>?
    @ObservationIgnored var queueStartNextImmediately = false

    /// Embedded virtual Mac runtime and its always-available model loop.
    @ObservationIgnored let virtualMac = VirtualMacController()
    @ObservationIgnored let virtualMacAgent = VirtualMacAgentModel()

    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let conversationStore = ConversationStore()
    @ObservationIgnored let artifactStore = TaskArtifactStore()
    @ObservationIgnored private var apiKeys: [UUID: String] = [:]
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveGeneration: UInt64 = 0
    /// Cached indices for the row currently streaming. Every token used to
    /// re-scan the conversation and its turns; this keeps the hot path O(1).
    @ObservationIgnored private var streamingLocation: (
        conversationID: UUID,
        conversationIndex: Int,
        turnID: UUID,
        turnIndex: Int
    )?
    @ObservationIgnored private var canRegenerateCache: (
        conversationID: UUID,
        turnCount: Int,
        value: Bool
    )?

    // MARK: - Derived state

    var activeEndpoint: ProviderEndpoint? { settings.activeEndpoint }

    var currentModel: String {
        if !settings.selectedModel.isEmpty { return settings.selectedModel }
        if let endpoint = activeEndpoint, !endpoint.defaultModel.isEmpty { return endpoint.defaultModel }
        return availableModels.first?.id ?? ""
    }

    var currentConversation: Conversation? {
        guard let activeConversationID else { return nil }
        return conversations.first { $0.id == activeConversationID }
    }

    // MARK: - Mac task configurations

    var macTaskConfigurations: [MacTaskConfiguration] {
        settings.macTaskConfigurations ?? []
    }

    var activeMacTaskConfiguration: MacTaskConfiguration? {
        if let id = settings.activeMacTaskConfigurationID,
           let match = macTaskConfigurations.first(where: { $0.id == id }) {
            return match
        }
        return macTaskConfigurations.first
    }

    var agenticTasks: [AgenticTaskRecord] {
        settings.agenticTasks ?? []
    }

    var activeAgenticTask: AgenticTaskRecord? {
        if let id = settings.activeAgenticTaskID,
           let match = agenticTasks.first(where: { $0.id == id }) {
            return match
        }
        return agenticTasks.first
    }

    func macConfiguration(id: UUID) -> MacTaskConfiguration? {
        macTaskConfigurations.first { $0.id == id }
    }

    var canSend: Bool {
        !isSending && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty)
    }

    /// Tokens currently in the model's context, taken from the most recent
    /// answer's usage (prompt + completion).
    var contextTokenCount: Int? {
        guard let turns = currentConversation?.turns else { return nil }
        for turn in turns.reversed() where turn.role == .assistant {
            guard let usage = turn.usage,
                  let prompt = usage.inputTokens,
                  let completion = usage.outputTokens else { continue }
            return prompt + completion
        }
        return nil
    }

    var canRegenerate: Bool {
        guard !isSending, let conversation = currentConversation else { return false }
        if let cached = canRegenerateCache,
           cached.conversationID == conversation.id,
           cached.turnCount == conversation.turns.count {
            return cached.value
        }
        let value = conversation.turns.contains { $0.role == .user }
        canRegenerateCache = (
            conversationID: conversation.id,
            turnCount: conversation.turns.count,
            value: value
        )
        return value
    }

    func focusComposer() {
        focusComposerToken += 1
    }

    func useSuggestion(_ text: String) {
        composerText = text
        focusComposer()
    }

    // MARK: - Image preview

    func previewImage(_ attachment: ImageAttachment) {
        previewedImage = attachment
        // The composer keeps the responder chain; release it so keystrokes do
        // not reach the text behind the overlay.
        _ = NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func dismissImagePreview() {
        previewedImage = nil
    }


    // MARK: - Lifecycle

    func bootstrap() async {
        virtualMacAgent.appState = self
        virtualMacAgent.onRunFinished = { [weak self] taskID, status in
            guard let self else { return }
            self.handleMacAgentFinished(taskID: taskID, status: status)
        }
        settings = await settingsStore.load()
        let configurationsChanged = migrateMacTaskConfigurations()
        let tasksChanged = migrateAgenticTasks()
        if configurationsChanged || tasksChanged {
            await settingsStore.save(settings)
        }
        isLoadingConversations = true
        conversations = await conversationStore.loadAll()
        isLoadingConversations = false
        var normalizedTasks = agenticTasks
        var normalized = false
        for index in normalizedTasks.indices
        where normalizedTasks[index].kind == .mac && normalizedTasks[index].lastStatus == "running" {
            normalizedTasks[index].lastStatus = "paused"
            normalized = true
        }
        if normalized {
            settings.agenticTasks = normalizedTasks
            await settingsStore.save(settings)
        }
        for endpoint in settings.endpoints {
            if let key = KeychainStore.get(for: endpoint.id.uuidString), !key.isEmpty {
                apiKeys[endpoint.id] = key
            }
        }
        if activeConversationID == nil {
            activeConversationID = conversations.first?.id
        }
        if let activeConversationID {
            markConversationRead(activeConversationID)
        }
        if let task = activeAgenticTask, task.kind == .mac,
           let configuration = macConfiguration(id: task.configurationID) {
            settings.activeMacTaskConfigurationID = configuration.id
            virtualMac.selectedName = configuration.machineName
        }
        virtualMac.selectedName = activeMacTaskConfiguration?.machineName ?? "default"
        await refreshModels(silently: true)
    }

    func saveSettings(immediately: Bool = false) {
        settingsSaveGeneration &+= 1
        let generation = settingsSaveGeneration
        let snapshot = settings
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [settingsStore] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled, generation == self.settingsSaveGeneration else { return }
            await settingsStore.save(snapshot)
        }
    }

    @discardableResult
    func addMacTaskConfiguration() -> UUID {
        let existingMachines = Set(macTaskConfigurations.map(\.machineName))
        var index = 1
        while existingMachines.contains("mac-\(index)") { index += 1 }
        let configuration = MacTaskConfiguration(
            name: "Mac \(index)",
            machineName: "mac-\(index)"
        )
        var configurations = macTaskConfigurations
        configurations.append(configuration)
        settings.macTaskConfigurations = configurations
        settings.activeMacTaskConfigurationID = configuration.id
        virtualMac.selectedName = configuration.machineName
        saveSettings()
        return configuration.id
    }

    func updateMacTaskConfiguration(_ configuration: MacTaskConfiguration) {
        guard let index = macTaskConfigurations.firstIndex(where: { $0.id == configuration.id }) else { return }
        var configurations = macTaskConfigurations
        configurations[index] = configuration
        settings.macTaskConfigurations = configurations
        saveSettings()
        if activeMacTaskConfiguration?.id == configuration.id {
            virtualMac.selectedName = configuration.machineName
        }
    }

    func removeMacTaskConfiguration(_ id: UUID) {
        let wasActive = settings.activeMacTaskConfigurationID == id
        var configurations = macTaskConfigurations
        configurations.removeAll { $0.id == id }
        if configurations.isEmpty {
            configurations = [MacTaskConfiguration(name: "Default", machineName: "default")]
        }
        settings.macTaskConfigurations = configurations
        if wasActive {
            settings.activeMacTaskConfigurationID = configurations.first?.id
            virtualMac.selectedName = configurations.first?.machineName ?? "default"
        }
        if let replacement = settings.activeMacTaskConfigurationID {
            var tasks = agenticTasks
            for index in tasks.indices where tasks[index].kind == .mac && tasks[index].configurationID == id {
                tasks[index].configurationID = replacement
            }
            settings.agenticTasks = tasks
        }
        saveSettings()
    }

    func selectMacTaskConfiguration(_ id: UUID) {
        guard let configuration = macTaskConfigurations.first(where: { $0.id == id }) else { return }
        settings.activeMacTaskConfigurationID = id
        virtualMac.selectedName = configuration.machineName
        if let task = activeAgenticTask, task.kind == .mac {
            updateTaskConfiguration(taskID: task.id, configurationID: id)
        }
        saveSettings()
    }

    // MARK: - Agentic tasks

    @discardableResult
    func createAgenticTask(
        title: String? = nil,
        configurationID requestedConfigurationID: UUID? = nil,
        prompt: String? = nil
    ) -> UUID {
        let configurationID = requestedConfigurationID ?? addMacTaskConfiguration()
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let task = AgenticTaskRecord(
            kind: .mac,
            title: trimmedTitle.isEmpty ? nextAgenticTaskTitle() : trimmedTitle,
            configurationID: configurationID,
            prompt: prompt
        )
        var tasks = agenticTasks
        tasks.append(task)
        settings.agenticTasks = tasks
        settings.activeAgenticTaskID = task.id
        settings.activeMacTaskConfigurationID = configurationID
        if let configuration = macConfiguration(id: configurationID) {
            virtualMac.selectedName = configuration.machineName
        }
        sidebarMode = .agentic
        saveSettings()
        return task.id
    }

    func selectAgenticTask(_ id: UUID) {
        guard let task = agenticTasks.first(where: { $0.id == id }) else { return }
        if activeAgenticTask?.id != id {
            cancelQueueCountdown()
            isWorkspaceQueueRunning = false
            activeQueuedTaskID = nil
            workspaceQueueMessage = nil
        }
        guard task.kind == .mac,
              let configuration = macConfiguration(id: task.configurationID) else { return }
        settings.activeAgenticTaskID = id
        settings.activeMacTaskConfigurationID = configuration.id
        virtualMac.selectedName = configuration.machineName
        sidebarMode = .agentic
        saveSettings()
    }

    var macTraceAutosaveFolderURL: URL? {
        if let data = settings.macTraceAutosaveBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        guard let path = settings.macTraceAutosavePath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func setMacTraceAutosaveFolder(_ url: URL?) {
        if let url {
            settings.macTraceAutosavePath = url.path
            settings.macTraceAutosaveBookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } else {
            settings.macTraceAutosavePath = nil
            settings.macTraceAutosaveBookmark = nil
        }
        saveSettings()
    }

    func autosaveMacTraceForContextClear(taskID: UUID) {
        guard let task = agenticTasks.first(where: { $0.id == taskID }) else { return }
        writeMacTrace(
            task: task,
            status: virtualMacAgent.lastRunStatus ?? "context-cleared",
            log: virtualMacAgent.log,
            screenshots: macTraceScreenshots(for: taskID),
            toolCalls: [],
            startedAt: virtualMacAgent.runStartedAt,
            finishedAt: Date(),
            contextCleared: true
        )
    }

    private func autosaveMacTrace(
        task: AgenticTaskRecord,
        entry: MacRunHistoryEntry,
        contextCleared: Bool
    ) {
        let screenshots = macTraceScreenshots(for: task.id)
            .filter { entry.screenshotIDs.contains($0.id) }
        var archiveTask = task
        archiveTask.title = entry.title.isEmpty ? task.title : entry.title
        archiveTask.prompt = entry.prompt
        writeMacTrace(
            task: archiveTask,
            status: entry.status,
            log: entry.log,
            screenshots: screenshots,
            toolCalls: virtualMacAgent.runToolCalls,
            startedAt: entry.startedAt,
            finishedAt: entry.finishedAt,
            contextCleared: contextCleared
        )
    }

    private func writeMacTrace(
        task: AgenticTaskRecord,
        status: String,
        log: [String],
        screenshots: [TraceScreenshot],
        toolCalls: [ToolCall],
        startedAt: Date?,
        finishedAt: Date,
        contextCleared: Bool
    ) {
        guard let root = macTraceAutosaveFolderURL else { return }
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }
        do {
            let url = try MacTraceArchiver.save(
                rootURL: root,
                task: task,
                status: status,
                log: log,
                screenshots: screenshots,
                toolCalls: toolCalls,
                runStartedAt: startedAt,
                finishedAt: finishedAt,
                contextCleared: contextCleared
            )
            macTraceAutosaveMessage = "Saved trace: \(url.lastPathComponent)"
        } catch {
            macTraceAutosaveMessage = "Trace autosave failed: \(error.localizedDescription)"
        }
    }

    private func recordMacRunHistory(taskID: UUID, status: String) {
        guard let task = agenticTasks.first(where: { $0.id == taskID }) else { return }
        let queued = activeQueuedTaskID.flatMap { id in
            macQueuedTasks(for: taskID).first(where: { $0.id == id })
        }
        let log = virtualMacAgent.log
        let startIndex = log.lastIndex {
            $0.hasPrefix("Queue: starting") || $0 == "Round 1"
        } ?? 0
        let startedAt = queued?.startedAt ?? task.lastRunAt
        let screenshotIDs: [UUID]
        if let startedAt {
            screenshotIDs = macTraceScreenshots(for: taskID)
                .filter { $0.createdAt >= startedAt }
                .map(\.id)
        } else {
            screenshotIDs = []
        }
        let entry = MacRunHistoryEntry(
            title: queued?.title ?? task.title,
            status: status,
            startedAt: startedAt,
            finishedAt: Date(),
            rounds: virtualMacAgent.currentRound,
            prompt: queued?.prompt ?? task.prompt ?? "",
            attachmentIDs: queued?.attachmentIDs ?? (task.artifacts ?? []).map(\.id),
            log: Array(log[startIndex...]),
            screenshotIDs: screenshotIDs
        )
        appendMacRunHistory(taskID: taskID, entry: entry)
        autosaveMacTrace(
            task: task,
            entry: entry,
            contextCleared: virtualMacAgent.didClearContextDuringRun
        )
    }

    func removeAgenticTask(_ id: UUID) {
        if activeAgenticTask?.id == id {
            cancelQueueCountdown()
            isWorkspaceQueueRunning = false
            activeQueuedTaskID = nil
        }
        if let task = agenticTasks.first(where: { $0.id == id }) {
            Task { await cleanupMacGuestArtifacts(task: task) }
        }
        if virtualMacAgent.currentTaskID == id {
            stopMacOutputPolling()
        }
        artifactStore.removeDirectory(for: id)
        let wasActive = settings.activeAgenticTaskID == id
        var tasks = agenticTasks
        tasks.removeAll { $0.id == id }
        settings.agenticTasks = tasks
        if queuedMacTasks.isEmpty { macQueueConfigurationID = nil }
        if wasActive, isMacQueueRunning {
            isMacQueueRunning = false
            macQueueMessage = "Queue stopped: the current task was deleted."
        }
        if wasActive {
            settings.activeAgenticTaskID = tasks.first?.id
            if let next = tasks.first {
                selectAgenticTask(next.id)
            } else {
                saveSettings()
            }
        } else {
            saveSettings()
        }
    }

    func setMacConfigurationForCurrentTask(_ configurationID: UUID) {
        guard let task = activeAgenticTask, task.kind == .mac,
              let configuration = macConfiguration(id: configurationID) else { return }
        updateTaskConfiguration(taskID: task.id, configurationID: configurationID)
        settings.activeMacTaskConfigurationID = configurationID
        virtualMac.selectedName = configuration.machineName
        saveSettings()
    }

    func saveMacAgentLoop(taskID: UUID, messages: [ChatMessage], log: [String]) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].agentLoop = messages.map(AgentLoopMessage.init)
        tasks[index].agentLog = log
        settings.agenticTasks = tasks
        saveSettings()
    }

    func loadMacAgentLoop(taskID: UUID) -> (messages: [ChatMessage], log: [String])? {
        guard let task = agenticTasks.first(where: { $0.id == taskID }) else { return nil }
        let messages = (task.agentLoop ?? []).map(\.chatMessage)
        guard !messages.isEmpty || !(task.agentLog ?? []).isEmpty else { return nil }
        return (messages, task.agentLog ?? [])
    }

    func clearMacAgentLoop(taskID: UUID) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].agentLoop = nil
        tasks[index].agentLog = nil
        settings.agenticTasks = tasks
        saveSettings()
    }

    func macTraceScreenshots(for taskID: UUID) -> [TraceScreenshot] {
        agenticTasks.first(where: { $0.id == taskID })?.traceScreenshots ?? []
    }

    func macRunHistory(for taskID: UUID) -> [MacRunHistoryEntry] {
        agenticTasks.first(where: { $0.id == taskID })?.runHistory ?? []
    }

    func appendMacRunHistory(taskID: UUID, entry: MacRunHistoryEntry) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var history = tasks[index].runHistory ?? []
        history.append(entry)
        if history.count > 20 { history.removeFirst(history.count - 20) }
        tasks[index].runHistory = history
        settings.agenticTasks = tasks
        saveSettings()
    }

    func deleteMacRunHistory(taskID: UUID, entryID: UUID) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].runHistory?.removeAll { $0.id == entryID }
        settings.agenticTasks = tasks
        saveSettings()
    }

    @discardableResult
    func saveMacResultOutput(taskID: UUID, markdown: String) throws -> TaskOutput {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = artifactStore.outputsDirectory(for: taskID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "BUU Result \(Int(Date().timeIntervalSince1970)).md"
        let url = folder.appendingPathComponent(name)
        let data = Data((text + "\n").utf8)
        try data.write(to: url, options: .atomic)
        var hasher = SHA256()
        hasher.update(data)
        let output = TaskOutput(
            name: name,
            guestPath: "~/Desktop/BUU Outputs/\(name)",
            hostFileName: name,
            byteCount: data.count,
            sha256: hasher.finalize()
        )
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return output
        }
        var outputs = tasks[index].outputs ?? []
        outputs.removeAll { $0.hostFileName == name }
        outputs.append(output)
        tasks[index].outputs = outputs
        settings.agenticTasks = tasks
        saveSettings()
        return output
    }

    func appendMacTraceScreenshot(taskID: UUID, round: Int, png: Data) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        var screenshots = tasks[index].traceScreenshots ?? []
        screenshots.append(TraceScreenshot(round: round, png: png))
        if screenshots.count > 60 { screenshots.removeFirst(screenshots.count - 60) }
        tasks[index].traceScreenshots = screenshots
        settings.agenticTasks = tasks
        saveSettings()
    }

    func maxAgentRounds(for taskID: UUID) -> Int? {
        agenticTasks.first(where: { $0.id == taskID })?.maxAgentRounds
    }

    func setMaxAgentRounds(_ value: Int?, for taskID: UUID) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].maxAgentRounds = value
        settings.agenticTasks = tasks
        saveSettings()
    }

    // MARK: - Mac Task queue

    var queuedMacTasks: [AgenticTaskRecord] {
        agenticTasks
            .filter { $0.kind == .mac && $0.queuedAt != nil }
            .sorted { lhs, rhs in
                let left = lhs.queuedAt ?? .distantPast
                let right = rhs.queuedAt ?? .distantPast
                if left == right { return lhs.createdAt < rhs.createdAt }
                return left < right
            }
    }

    func isMacTaskQueued(_ id: UUID) -> Bool {
        agenticTasks.first(where: { $0.id == id })?.queuedAt != nil
    }

    func queueMacTask(_ id: UUID) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].kind == .mac else { return }
        let prompt = (tasks[index].prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            macQueueMessage = "Add a prompt before queueing “\(tasks[index].title)”."
            return
        }
        if let configurationID = macQueueConfigurationID,
           configurationID != tasks[index].configurationID {
            macQueueMessage = "The Mac queue runs one VM profile at a time. This task uses a different profile."
            return
        }
        if macQueueConfigurationID == nil {
            macQueueConfigurationID = tasks[index].configurationID
        }
        if tasks[index].queuedAt == nil {
            tasks[index].queuedAt = Date()
        }
        settings.agenticTasks = tasks
        saveSettings()
        if !isMacQueueRunning {
            macQueueMessage = "Queued “\(tasks[index].title)”."
        }
    }

    func dequeueMacTask(_ id: UUID) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].queuedAt = nil
        settings.agenticTasks = tasks
        if queuedMacTasks.isEmpty && !isMacQueueRunning {
            macQueueConfigurationID = nil
        }
        saveSettings()
    }

    func toggleMacTaskQueue(_ id: UUID) {
        if isMacTaskQueued(id) {
            dequeueMacTask(id)
        } else {
            queueMacTask(id)
        }
    }

    func startMacQueue() {
        guard !isMacQueueRunning else { return }
        let queue = queuedMacTasks
        guard !queue.isEmpty else {
            macQueueMessage = "No Mac tasks are queued."
            return
        }
        macQueueConfigurationID = queue.first?.configurationID
        if let configurationID = macQueueConfigurationID,
           queue.contains(where: { $0.configurationID != configurationID }) {
            macQueueMessage = "The Mac queue can only run tasks from one VM profile at a time."
            return
        }
        isMacQueueRunning = true
        macQueueMessage = "Queue started."
        if virtualMacAgent.isRunning {
            macQueueMessage = "Queue will start after the current run finishes."
            return
        }
        startNextQueuedMacTask()
    }

    func stopMacQueue() {
        guard isMacQueueRunning else { return }
        isMacQueueRunning = false
        if queuedMacTasks.isEmpty { macQueueConfigurationID = nil }
        macQueueMessage = virtualMacAgent.isRunning
            ? "Queue stopped; the current task will finish normally."
            : "Queue stopped."
    }

    func clearMacQueue() {
        isMacQueueRunning = false
        macQueueConfigurationID = nil
        var tasks = agenticTasks
        for index in tasks.indices where tasks[index].queuedAt != nil {
            tasks[index].queuedAt = nil
        }
        settings.agenticTasks = tasks
        saveSettings()
        macQueueMessage = "Queue cleared."
    }

    func handleMacAgentFinished(taskID: UUID, status: String) {
        stopMacOutputPolling()
        recordMacRunHistory(taskID: taskID, status: status)
        handleWorkspaceQueueRunFinished(taskID: taskID, status: status)
        guard isMacQueueRunning else { return }
        let task = agenticTasks.first(where: { $0.id == taskID })
        if status == "completed" {
            if task?.queuedAt != nil { dequeueMacTask(taskID) }
            startNextQueuedMacTask()
            return
        }
        if task?.queuedAt == nil {
            // A manually started task that is not part of the queue should not
            // block the queued work.
            startNextQueuedMacTask()
            return
        }
        let title = task?.title ?? "Task"
        isMacQueueRunning = false
        macQueueMessage = status == "paused"
            ? "Queue paused: “\(title)” reached its round limit or was paused."
            : "Queue stopped: “\(title)” \(status)."
    }

    func handleMacRunCancelled(taskID: UUID) {
        stopMacOutputPolling()
        recordMacRunHistory(taskID: taskID, status: "paused")
        if let id = activeQueuedTaskID {
            activeQueuedTaskID = nil
            markCancelledQueuedTask(taskID: taskID, id: id)
            isWorkspaceQueueRunning = false
            cancelQueueCountdown()
            workspaceQueueMessage = "Queue stopped because the current task was cancelled."
        } else if isWorkspaceQueueRunning {
            isWorkspaceQueueRunning = false
            cancelQueueCountdown()
            workspaceQueueMessage = "Queue stopped because the current run was cancelled."
        }
        guard isMacQueueRunning else { return }
        _ = taskID
        isMacQueueRunning = false
        macQueueMessage = "Queue stopped: the current task was cancelled."
    }

    private func startNextQueuedMacTask() {
        guard isMacQueueRunning, !virtualMacAgent.isRunning else { return }
        while let next = queuedMacTasks.first {
            guard let configurationID = macQueueConfigurationID,
                  next.configurationID == configurationID else {
                isMacQueueRunning = false
                macQueueMessage = "Queue stopped: queued tasks use different VM profiles."
                return
            }
            if virtualMac.vmState == "running",
               let activeConfigurationID = activeMacTaskConfiguration?.id,
               activeConfigurationID != next.configurationID {
                isMacQueueRunning = false
                macQueueMessage = "Queue stopped: stop the current virtual Mac before running tasks from a different VM profile."
                return
            }
            guard macConfiguration(id: next.configurationID) != nil else {
                dequeueMacTask(next.id)
                macQueueMessage = "Skipped “\(next.title)” because its VM profile is missing."
                continue
            }
            let prompt = (next.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                dequeueMacTask(next.id)
                macQueueMessage = "Skipped “\(next.title)” because it has no prompt."
                continue
            }
            guard virtualMac.vmState == "running" else {
                if activeMacTaskConfiguration?.id != next.configurationID {
                    selectAgenticTask(next.id)
                }
                isMacQueueRunning = false
                macQueueMessage = "Start or resume the virtual Mac, then start the queue again."
                return
            }
            guard virtualMac.canAct else {
                isMacQueueRunning = false
                macQueueMessage = "The virtual Mac is running, but its guest helper is not ready. Open the guest helper, allow permissions, then start the queue again."
                return
            }
            guard let endpoint = macQueueEndpoint else {
                isMacQueueRunning = false
                macQueueMessage = "Add a provider before running the Mac queue."
                return
            }
            let model = virtualMacAgent.model.isEmpty ? endpoint.defaultModel : virtualMacAgent.model
            guard !model.isEmpty else {
                isMacQueueRunning = false
                macQueueMessage = "Choose a model before running the Mac queue."
                return
            }
            if virtualMacAgent.selectedEndpointID == nil {
                virtualMacAgent.selectedEndpointID = endpoint.id
            }
            if virtualMacAgent.model.isEmpty {
                virtualMacAgent.model = model
            }
            if let current = activeAgenticTask,
               current.id != next.id,
               virtualMacAgent.currentTaskID == current.id {
                updateTaskPrompt(taskID: current.id, prompt: virtualMacAgent.instructions)
            }

            selectAgenticTask(next.id)
            virtualMacAgent.instructions = prompt
            virtualMacAgent.loadSession(for: next)
            updateTaskStatus(taskID: next.id, status: "running")
            let remaining = queuedMacTasks.count
            macQueueMessage = remaining > 1
                ? "Running “\(next.title)” — \(remaining - 1) queued behind."
                : "Running “\(next.title)”."
            virtualMacAgent.start(
                endpoint: endpoint,
                apiKey: apiKey(for: endpoint),
                model: model,
                instructions: prompt,
                vm: virtualMac
            )
            return
        }
        isMacQueueRunning = false
        macQueueConfigurationID = nil
        macQueueMessage = "Mac task queue finished."
    }

    private var macQueueEndpoint: ProviderEndpoint? {
        if let id = virtualMacAgent.selectedEndpointID,
           let endpoint = settings.endpoints.first(where: { $0.id == id }) {
            return endpoint
        }
        return settings.endpoints.first
    }

    // MARK: - Task artifacts

    func artifactDirectory(for taskID: UUID) -> URL {
        artifactStore.directory(for: taskID)
    }

    func artifactURL(for artifact: TaskArtifact, taskID: UUID) -> URL {
        artifactStore.url(for: artifact, taskID: taskID)
    }

    func artifactContents(for taskID: UUID) -> [URL] {
        artifactStore.contents(for: taskID)
    }

    @discardableResult
    func addMacArtifacts(_ urls: [URL], for taskID: UUID) throws -> [TaskArtifact] {
        guard let index = agenticTasks.firstIndex(where: { $0.id == taskID }) else { return [] }
        var tasks = agenticTasks
        var added: [TaskArtifact] = []
        do {
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                added.append(try artifactStore.copy(url: url, taskID: taskID))
            }
        } catch {
            if !added.isEmpty {
                tasks[index].artifacts = (tasks[index].artifacts ?? []) + added
                settings.agenticTasks = tasks
                saveSettings()
            }
            throw error
        }
        tasks[index].artifacts = (tasks[index].artifacts ?? []) + added
        settings.agenticTasks = tasks
        saveSettings()
        return added
    }

    func removeMacArtifact(_ artifactID: UUID, for taskID: UUID) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }),
              let artifact = tasks[index].artifacts?.first(where: { $0.id == artifactID }) else { return }
        artifactStore.remove(artifact, taskID: taskID)
        tasks[index].artifacts?.removeAll { $0.id == artifactID }
        settings.agenticTasks = tasks
        saveSettings()
    }

    func updateTaskPrompt(taskID: UUID, prompt: String) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].prompt = prompt
        settings.agenticTasks = tasks
        saveSettings()
    }

    func updateTaskStatus(taskID: UUID, status: String, lastRunAt: Date = Date()) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].lastStatus = status
        tasks[index].lastRunAt = lastRunAt
        settings.agenticTasks = tasks
        saveSettings()
    }

    @discardableResult
    func duplicateAgenticTask(_ id: UUID) -> UUID? {
        guard let source = agenticTasks.first(where: { $0.id == id }), source.kind == .mac else { return nil }
        let title = source.title == "Untitled" ? "Untitled copy" : "\(source.title) copy"
        let newID = createAgenticTask(
            title: title,
            configurationID: source.configurationID,
            prompt: source.prompt
        )
        var tasks = agenticTasks
        if let index = tasks.firstIndex(where: { $0.id == newID }) {
            tasks[index].maxAgentRounds = source.maxAgentRounds
            tasks[index].queueStopOnFailure = source.queueStopOnFailure
        }
        settings.agenticTasks = tasks
        saveSettings()
        return newID
    }

    func renameAgenticTask(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].title = trimmed
        settings.agenticTasks = tasks
        saveSettings()
    }

    func markMacConfigurationUsed(_ id: UUID) {
        guard let index = macTaskConfigurations.firstIndex(where: { $0.id == id }) else { return }
        var configurations = macTaskConfigurations
        configurations[index].lastUsedAt = Date()
        settings.macTaskConfigurations = configurations
        saveSettings()
    }

    func macTaskUsageCount(configurationID: UUID) -> Int {
        agenticTasks.filter { $0.kind == .mac && $0.configurationID == configurationID }.count
    }

    @discardableResult
    func duplicateMacTaskConfiguration(_ id: UUID) -> UUID? {
        guard var copy = macConfiguration(id: id) else { return nil }
        copy.id = UUID()
        copy.name = uniqueMacProfileName(base: "\(copy.name) copy")
        let existingMachines = Set(macTaskConfigurations.map(\.machineName))
        var index = 1
        while existingMachines.contains("\(copy.machineName)-copy\(index)") { index += 1 }
        copy.machineName = "\(copy.machineName)-copy\(index)"
        copy.lastUsedAt = nil
        var configurations = macTaskConfigurations
        configurations.append(copy)
        settings.macTaskConfigurations = configurations
        saveSettings()
        return copy.id
    }

    private func uniqueMacProfileName(base: String) -> String {
        let existing = Set(macTaskConfigurations.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func updateTaskConfiguration(taskID: UUID, configurationID: UUID) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].configurationID = configurationID
        settings.agenticTasks = tasks
    }

    private func nextAgenticTaskTitle() -> String {
        let base = "Mac Task"
        let existing = Set(agenticTasks.filter { $0.kind == .mac }.map(\.title))
        var index = 1
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func migrateAgenticTasks() -> Bool {
        var changed = false
        var tasks = settings.agenticTasks ?? []
        let before = tasks.count
        tasks.removeAll { $0.kind != .mac }
        if tasks.count != before {
            settings.agenticTasks = tasks
            changed = true
        }
        if settings.agenticTasks == nil {
            settings.agenticTasks = macTaskConfigurations.map { configuration in
                AgenticTaskRecord(
                    kind: .mac,
                    title: configuration.name,
                    configurationID: configuration.id
                )
            }
            changed = true
        }
        let currentTasks = settings.agenticTasks ?? []
        if let active = settings.activeAgenticTaskID,
           !currentTasks.contains(where: { $0.id == active }) {
            settings.activeAgenticTaskID = currentTasks.first?.id
            changed = true
        } else if settings.activeAgenticTaskID == nil {
            settings.activeAgenticTaskID = currentTasks.first?.id
            changed = true
        }
        return changed
    }

    private func migrateMacTaskConfigurations() -> Bool {
        var changed = false
        if (settings.macTaskConfigurations ?? []).isEmpty {
            let configuration = MacTaskConfiguration(name: "Default", machineName: "default")
            settings.macTaskConfigurations = [configuration]
            settings.activeMacTaskConfigurationID = configuration.id
            changed = true
        }
        let configurations = settings.macTaskConfigurations ?? []
        if let active = settings.activeMacTaskConfigurationID,
           !configurations.contains(where: { $0.id == active }) {
            settings.activeMacTaskConfigurationID = configurations.first?.id
            changed = true
        } else if settings.activeMacTaskConfigurationID == nil {
            settings.activeMacTaskConfigurationID = configurations.first?.id
            changed = true
        }
        if var configurations = settings.macTaskConfigurations {
            var bumped = false
            for index in configurations.indices where configurations[index].diskGiB < 32 {
                configurations[index].diskGiB = 64
                bumped = true
            }
            if bumped {
                settings.macTaskConfigurations = configurations
                changed = true
            }
        }
        return changed
    }

    // MARK: - Conversations

    func newConversation() {
        let endpoint = activeEndpoint
        let conversation = Conversation(
            endpointID: endpoint?.id ?? UUID(),
            endpointName: endpoint?.name ?? "",
            model: currentModel
        )
        conversations.insert(conversation, at: 0)
        activeConversationID = conversation.id
        composerText = ""
        pendingImages = []
        Task { await conversationStore.save(conversation) }
    }

    func selectConversation(_ id: UUID) {
        activeConversationID = id
        markConversationRead(id)
    }

    func markConversationRead(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].isUnread == true else { return }
        conversations[index].isUnread = false
        Task { await conversationStore.save(conversations[index]) }
    }

    func setConversationPinned(_ conversation: Conversation, pinned: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].isPinned = pinned
        Task { await conversationStore.save(conversations[index]) }
    }

    func toggleConversationPin(_ conversation: Conversation) {
        setConversationPinned(conversation, pinned: !(conversation.isPinned ?? false))
    }

    func performPrimarySidebarAction() {
        switch sidebarMode {
        case .chats:
            newConversation()
        case .agentic:
            showNewTaskWizard = true
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        if activeConversationID == conversation.id {
            activeConversationID = conversations.first?.id
        }
        Task { await conversationStore.delete(conversation) }
    }

    func renameConversation(_ conversation: Conversation, to title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].title = title
        Task { await conversationStore.save(conversations[index]) }
    }

    func duplicate(_ conversation: Conversation) {
        var copy = conversation
        copy.id = UUID()
        copy.title = conversation.title + " copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.turns = conversation.turns
        conversations.insert(copy, at: 0)
        activeConversationID = copy.id
        Task { await conversationStore.save(copy) }
    }

    // MARK: - Endpoints

    func addEndpoint(_ endpoint: ProviderEndpoint) {
        settings.endpoints.append(endpoint)
        settings.activeEndpointID = endpoint.id
        saveSettings()
    }

    func removeEndpoint(_ endpoint: ProviderEndpoint) {
        settings.endpoints.removeAll { $0.id == endpoint.id }
        if settings.activeEndpointID == endpoint.id {
            settings.activeEndpointID = settings.endpoints.first?.id
        }
        apiKeys[endpoint.id] = nil
        saveSettings()
    }

    func selectEndpoint(_ endpoint: ProviderEndpoint) {
        settings.activeEndpointID = endpoint.id
        settings.selectedModel = ""
        saveSettings()
        Task { await refreshModels() }
    }

    func apiKey(for endpoint: ProviderEndpoint) -> String {
        apiKeys[endpoint.id] ?? ""
    }

    func setAPIKey(_ value: String, for endpoint: ProviderEndpoint) {
        apiKeys[endpoint.id] = value
        try? KeychainStore.set(value, for: endpoint.id.uuidString)
    }

    func refreshModels(silently: Bool = false) async {
        guard let endpoint = activeEndpoint else { return }

        // Some servers do not implement /models – respect the setting instead of
        // showing an error for a perfectly usable endpoint.
        guard endpoint.listsModels else {
            availableModels = endpoint.defaultModel.isEmpty
                ? []
                : [RemoteModel(id: endpoint.defaultModel)]
            endpointStatus[endpoint.id] = "Using the configured model"
            return
        }

        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            let client = try ProviderClient(endpoint: endpoint, apiKey: apiKeys[endpoint.id])
            let models = try await client.listModels()
            availableModels = models
            endpointStatus[endpoint.id] = "\(models.count) model\(models.count == 1 ? "" : "s") available"
        } catch {
            availableModels = []
            endpointStatus[endpoint.id] = error.localizedDescription
            if !silently {
                errorMessage = error.localizedDescription
            }
        }
    }

    func testConnection(to endpoint: ProviderEndpoint) async {
        do {
            let configuration = try ProviderConfiguration.make(endpoint: endpoint, apiKey: apiKeys[endpoint.id])
            let (data, head) = try await HTTPTransport.perform(
                RequestBuilderForTesting.makeRequest(for: configuration)
            )
            endpointStatus[endpoint.id] = head.isSuccess
                ? "Connected (\(head.statusCode))"
                : "HTTP \(head.statusCode): \(String(decoding: data, as: UTF8.self).prefix(120))"
        } catch {
            endpointStatus[endpoint.id] = error.localizedDescription
        }
    }

    // MARK: - Attachments

    func addImages(at urls: [URL]) async {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "Could not read \(url.lastPathComponent)"
                continue
            }
            addImageData(data)
        }
    }

    func addImageData(_ data: Data) {
        do {
            let payload = try ImageProcessor.prepare(data: data)
            let thumbnail = NSImage(data: payload.data) ?? NSImage(size: NSSize(width: 64, height: 64))
            pendingImages.append(PendingImage(payload: payload, thumbnail: thumbnail))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pasteImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else {
            errorMessage = "The clipboard does not contain an image"
            return
        }
        addImageData(data)
    }

    func removeImage(_ image: PendingImage) {
        pendingImages.removeAll { $0.id == image.id }
    }

    func clearPendingImages() {
        pendingImages.removeAll()
    }

    // MARK: - Model

    func selectModel(_ id: String) {
        settings.selectedModel = id
        saveSettings()
    }

    // MARK: - Sending

    func send() {
        guard canSend else { return }
        guard let endpoint = activeEndpoint else {
            errorMessage = "Configure a server in Settings first."
            showSettings = true
            return
        }
        let model = currentModel
        guard !model.isEmpty else {
            errorMessage = "Select a model first."
            return
        }

        let text = composerText
        let images = pendingImages
        composerText = ""
        pendingImages = []
        isSending = true

        streamTask = Task { [weak self] in
            await self?.streamReply(
                endpoint: endpoint,
                model: model,
                newUserMessage: (text: text, images: images)
            )
        }
    }

    /// Drops the answer to the last question and asks again.
    func regenerate() {
        guard !isSending, let endpoint = activeEndpoint, var conversation = currentConversation else { return }
        guard let lastUserIndex = conversation.turns.lastIndex(where: { $0.role == .user }) else { return }
        let model = conversation.model.isEmpty ? currentModel : conversation.model
        guard !model.isEmpty else {
            errorMessage = "Select a model first."
            return
        }

        if lastUserIndex + 1 < conversation.turns.count {
            conversation.turns.removeSubrange((lastUserIndex + 1)..<conversation.turns.count)
        }
        conversation.updatedAt = Date()
        update(conversation)
        isSending = true

        streamTask = Task { [weak self] in
            await self?.streamReply(endpoint: endpoint, model: model, newUserMessage: nil)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
    }

    private func streamReply(
        endpoint: ProviderEndpoint,
        model: String,
        newUserMessage: (text: String, images: [PendingImage])?
    ) async {
        defer { isSending = false }

        // Timings: measured client side, overridden by server values if reported.
        let startedAt = Date()
        var firstTokenAt: Date?
        var serverTimings: ServerTimings?

        var conversation = currentConversation ?? makeConversation(endpoint: endpoint, model: model)
        if currentConversation == nil {
            conversations.insert(conversation, at: 0)
            activeConversationID = conversation.id
        }
        let conversationID = conversation.id

        if let newUserMessage {
            var attachments: [ImageAttachment] = []
            for image in newUserMessage.images {
                if let attachment = try? await conversationStore.storeAttachment(
                    data: image.payload.data,
                    mimeType: image.payload.mimeType
                ) {
                    attachments.append(attachment)
                }
            }
            conversation.turns.append(
                ChatTurn(role: .user, text: newUserMessage.text, images: attachments)
            )
        }

        // Snapshot the messages before the live assistant placeholder. The tool
        // loop adds its own transient assistant/tool-result messages on top.
        let requestTurns = conversation.turns

        let assistantTurn = ChatTurn(role: .assistant, isStreaming: true)
        conversation.turns.append(assistantTurn)
        conversation.model = model
        conversation.endpointID = endpoint.id
        conversation.endpointName = endpoint.name
        conversation.updatedAt = Date()
        if conversation.title == "New chat", let text = newUserMessage?.text, !text.isEmpty {
            conversation.title = Conversation.makeTitle(from: text)
        }
        update(conversation)

        // Load the binary payload of every referenced image.
        var payloads: [UUID: Data] = [:]
        for turn in conversation.turns {
            for attachment in turn.images {
                if let data = await conversationStore.loadAttachmentData(attachment) {
                    payloads[attachment.id] = data
                }
            }
        }

        let system = settings.sendSystemPrompt ? endpoint.systemPrompt : nil
        let request = ChatRequestBuilder.build(
            turns: requestTurns,
            attachments: payloads,
            system: system,
            model: model,
            temperature: endpoint.temperature,
            topP: endpoint.topP,
            maxTokens: endpoint.maxTokens
        )

        do {
            let client = try ProviderClient(endpoint: endpoint, apiKey: apiKeys[endpoint.id])
            for try await event in client.stream(request: request) {
                if Task.isCancelled { break }

                switch event {
                case .text, .reasoning:
                    if firstTokenAt == nil { firstTokenAt = Date() }
                case .timings(let timings):
                    serverTimings = timings
                default:
                    break
                }

                apply(event: event, to: assistantTurn.id, in: conversationID)
            }
        } catch {
            if Task.isCancelled {
                apply(event: .finished(reason: .cancelled, usage: nil), to: assistantTurn.id, in: conversationID)
            } else {
                apply(event: .failed(error.localizedDescription), to: assistantTurn.id, in: conversationID)
            }
        }

        // Latency / throughput for this answer.
        let finishedAt = Date()
        if let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
           let turnIndex = conversations[conversationIndex].turns.firstIndex(where: { $0.id == assistantTurn.id }) {
            let usage = conversations[conversationIndex].turns[turnIndex].usage
            conversations[conversationIndex].turns[turnIndex].contentRevision = (conversations[conversationIndex].turns[turnIndex].contentRevision ?? 0) &+ 1
            conversations[conversationIndex].turns[turnIndex].metrics = TurnMetricsCalculator.compute(
                startedAt: startedAt,
                firstTokenAt: firstTokenAt,
                finishedAt: finishedAt,
                usage: usage,
                timings: serverTimings
            )
        }

        // Make sure the assistant turn never stays in the "streaming" state.
        if let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
           let turnIndex = conversations[conversationIndex].turns.firstIndex(where: { $0.id == assistantTurn.id }),
           conversations[conversationIndex].turns[turnIndex].isStreaming {
            conversations[conversationIndex].turns[turnIndex].isStreaming = false
            if conversations[conversationIndex].turns[turnIndex].stopReason == nil {
                conversations[conversationIndex].turns[turnIndex].stopReason = .cancelled
            }
            conversations[conversationIndex].turns[turnIndex].contentRevision = (conversations[conversationIndex].turns[turnIndex].contentRevision ?? 0) &+ 1
            if conversationID != activeConversationID {
                conversations[conversationIndex].isUnread = true
                Task { await conversationStore.save(conversations[conversationIndex]) }
            }
        }

        // Save the conversation that actually streamed, even if the user moved
        // to another conversation (or deleted it) meanwhile.
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].updatedAt = Date()
            await conversationStore.save(conversations[index])
        }
        streamingLocation = nil
    }

    private func makeConversation(endpoint: ProviderEndpoint, model: String) -> Conversation {
        Conversation(
            endpointID: endpoint.id,
            endpointName: endpoint.name,
            model: model
        )
    }

    private func update(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
    }

    /// Resolve the live row's indices, reusing the previous location when it
    /// still points at the same conversation and turn. Array mutations (new
    /// chats, deletions) invalidate it, in which case we fall back to a scan.
    private func streamingIndices(
        conversationID: UUID,
        turnID: UUID
    ) -> (conversationIndex: Int, turnIndex: Int)? {
        if let cached = streamingLocation,
           cached.conversationID == conversationID,
           cached.turnID == turnID,
           cached.conversationIndex < conversations.count,
           conversations[cached.conversationIndex].id == conversationID,
           cached.turnIndex < conversations[cached.conversationIndex].turns.count,
           conversations[cached.conversationIndex].turns[cached.turnIndex].id == turnID {
            return (cached.conversationIndex, cached.turnIndex)
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let turnIndex = conversations[conversationIndex].turns.firstIndex(where: { $0.id == turnID }) else {
            streamingLocation = nil
            return nil
        }

        streamingLocation = (
            conversationID: conversationID,
            conversationIndex: conversationIndex,
            turnID: turnID,
            turnIndex: turnIndex
        )
        return (conversationIndex, turnIndex)
    }

    private func apply(event: StreamEvent, to turnID: UUID, in conversationID: UUID) {
        guard let (conversationIndex, turnIndex) = streamingIndices(
            conversationID: conversationID,
            turnID: turnID
        ) else { return }

        switch event {
        case .started:
            break
        case .text(let chunk):
            conversations[conversationIndex].turns[turnIndex].text += chunk
            conversations[conversationIndex].turns[turnIndex].contentRevision = (conversations[conversationIndex].turns[turnIndex].contentRevision ?? 0) &+ 1
            if conversationID == activeConversationID { streamTick &+= 1 }
        case .reasoning(let chunk):
            conversations[conversationIndex].turns[turnIndex].reasoning += chunk
            conversations[conversationIndex].turns[turnIndex].contentRevision = (conversations[conversationIndex].turns[turnIndex].contentRevision ?? 0) &+ 1
            if conversationID == activeConversationID { streamTick &+= 1 }
        case .toolCall(_, let name, let arguments):
            conversations[conversationIndex].turns[turnIndex].text += "\n\n**Tool call:** `\(name)(\(arguments))`\n"
            conversations[conversationIndex].turns[turnIndex].contentRevision = (conversations[conversationIndex].turns[turnIndex].contentRevision ?? 0) &+ 1
            if conversationID == activeConversationID { streamTick &+= 1 }
        case .finished(let reason, let usage):
            conversations[conversationIndex].turns[turnIndex].stopReason = reason
            conversations[conversationIndex].turns[turnIndex].usage = usage
            conversations[conversationIndex].turns[turnIndex].isStreaming = false
            conversations[conversationIndex].turns[turnIndex].contentRevision = (conversations[conversationIndex].turns[turnIndex].contentRevision ?? 0) &+ 1
        case .timings:
            break
        case .failed(let message):
            conversations[conversationIndex].turns[turnIndex].errorMessage = message
            conversations[conversationIndex].turns[turnIndex].isStreaming = false
            conversations[conversationIndex].turns[turnIndex].contentRevision = (conversations[conversationIndex].turns[turnIndex].contentRevision ?? 0) &+ 1
            if conversationID != activeConversationID {
                conversations[conversationIndex].isUnread = true
                Task { await conversationStore.save(conversations[conversationIndex]) }
            }
        }
    }
}

/// Small helper that turns a provider configuration into a request the test
/// connection button can use.
enum RequestBuilderForTesting {
    static func makeRequest(for configuration: ProviderConfiguration) -> URLRequest {
        var request = URLRequest(url: configuration.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (key, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}
