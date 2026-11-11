import Foundation
import os
import BUUKit

private let macQueueLogger = Logger(subsystem: "com.buu", category: "mac-queue")

@MainActor
extension AppState {

    // MARK: - Steers

    func macSteers(for taskID: UUID) -> [SteerItem] {
        agenticTasks.first(where: { $0.id == taskID })?.steers ?? []
    }

    func saveMacSteers(_ items: [SteerItem], taskID: UUID) {
        updateMacTaskRecord(taskID: taskID) { $0.steers = SteerPlanner.normalized(items) }
    }

    @discardableResult
    func addMacSteer(
        taskID: UUID,
        text: String,
        attachmentIDs: [UUID],
        state: SteerState = .queued
    ) -> SteerItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var items = macSteers(for: taskID)
        guard SteerPlanner.pending(items).count < SteerPlanner.maxPending else { return nil }
        let item = SteerItem(
            text: String(trimmed.prefix(8000)),
            attachmentIDs: attachmentIDs,
            state: state,
            order: SteerPlanner.nextOrder(items)
        )
        items.append(item)
        saveMacSteers(items, taskID: taskID)
        macQueueLogger.info("steer queued id=\(item.id.uuidString, privacy: .public) order=\(item.order)")
        return item
    }

    func updateMacSteer(taskID: UUID, id: UUID, text: String) -> Bool {
        var items = macSteers(for: taskID)
        guard let index = items.firstIndex(where: { $0.id == id }),
              SteerPlanner.canMutate(items[index]) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        items[index].text = String(trimmed.prefix(8000))
        saveMacSteers(items, taskID: taskID)
        macQueueLogger.info("steer edited id=\(id.uuidString, privacy: .public)")
        return true
    }

    func cancelMacSteer(taskID: UUID, id: UUID) -> SteerItem? {
        var items = macSteers(for: taskID)
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .queued || items[index].state == .failed else { return nil }
        items[index].state = .cancelled
        items[index].appliedAt = Date()
        let original = items[index]
        saveMacSteers(items, taskID: taskID)
        macQueueLogger.info("steer cancelled id=\(id.uuidString, privacy: .public)")
        return original
    }

    func reorderMacSteers(taskID: UUID, ids: [UUID]) {
        var items = macSteers(for: taskID)
        let pendingIDs = Set(items.filter { $0.state == .queued }.map(\.id))
        var ordered = ids.filter { pendingIDs.contains($0) }
        for item in pendingIDs where !ordered.contains(item) { ordered.append(item) }
        var order = 0
        for id in ordered {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].order = order
                order += 1
            }
        }
        saveMacSteers(items, taskID: taskID)
        macQueueLogger.info("steer reordered task=\(taskID.uuidString, privacy: .public)")
    }

    func setMacSteerState(taskID: UUID, id: UUID, state: SteerState, failure: String? = nil) {
        var items = macSteers(for: taskID)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .queued || items[index].state == .applying else { return }
        items[index].state = state
        items[index].failure = failure
        saveMacSteers(items, taskID: taskID)
    }

    func applyMacSteer(taskID: UUID, id: UUID, round: Int) {
        var items = macSteers(for: taskID)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .applied
        items[index].appliedInRound = round
        items[index].appliedAt = Date()
        items[index].failure = nil
        saveMacSteers(items, taskID: taskID)
        macQueueLogger.info("steer applied id=\(id.uuidString, privacy: .public) round=\(round)")
    }

    func retryMacSteer(taskID: UUID, id: UUID) {
        var items = macSteers(for: taskID)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .queued
        items[index].failure = nil
        items[index].appliedAt = nil
        items[index].appliedInRound = nil
        saveMacSteers(items, taskID: taskID)
    }

    func failMacSteer(taskID: UUID, id: UUID, error: String) {
        setMacSteerState(taskID: taskID, id: id, state: .failed, failure: error)
        macQueueLogger.error("steer failed id=\(id.uuidString, privacy: .public): \(error, privacy: .public)")
    }

    func steerAttachmentsReady(_ steer: SteerItem, taskID: UUID) -> Bool {
        attachmentFailure(steer, taskID: taskID) == nil
    }

    func steerAttachmentFailure(_ steer: SteerItem, taskID: UUID) -> String? {
        attachmentFailure(steer, taskID: taskID)
    }

    private func attachmentFailure(_ steer: SteerItem, taskID: UUID) -> String? {
        guard !steer.attachmentIDs.isEmpty else { return nil }
        let artifacts = macArtifacts(for: taskID)
        for id in steer.attachmentIDs {
            guard let artifact = artifacts.first(where: { $0.id == id }) else {
                return "Attached file is missing."
            }
            switch artifact.guestState {
            case .inGuest, .opened, .modified:
                continue
            case .failed:
                return artifact.lastError ?? "Artifact copy failed."
            case .copying, .queued, nil:
                return "Artifact is still copying."
            }
        }
        return nil
    }

    // MARK: - Queued tasks

    func macQueuedTasks(for taskID: UUID) -> [QueuedTask] {
        (agenticTasks.first(where: { $0.id == taskID })?.queuedTasks ?? [])
            .sorted { lhs, rhs in
                lhs.order == rhs.order ? lhs.createdAt < rhs.createdAt : lhs.order < rhs.order
            }
    }

    func saveMacQueuedTasks(_ tasks: [QueuedTask], taskID: UUID) {
        var copy = tasks
        let ordered = copy.indices.sorted { lhs, rhs in
            let left = copy[lhs]
            let right = copy[rhs]
            return left.order == right.order ? left.createdAt < right.createdAt : left.order < right.order
        }
        for (order, index) in ordered.enumerated() { copy[index].order = order }
        updateMacTaskRecord(taskID: taskID) { $0.queuedTasks = copy }
    }

    @discardableResult
    func enqueueMacTask(
        taskID: UUID,
        prompt: String,
        attachmentIDs: [UUID],
        providerID: UUID?,
        model: String?,
        maxRounds: Int?,
        vmStatePolicy: VMStatePolicy = .freshState,
        continueConversation: Bool = false
    ) -> QueuedTask? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var tasks = macQueuedTasks(for: taskID)
        let nextOrder = (tasks.map(\.order).max() ?? -1) + 1
        let queued = QueuedTask(
            prompt: String(trimmed.prefix(8000)),
            attachmentIDs: attachmentIDs,
            providerID: providerID,
            model: model,
            maxRounds: maxRounds,
            vmStatePolicy: vmStatePolicy,
            continueConversation: continueConversation,
            order: nextOrder
        )
        tasks.append(queued)
        saveMacQueuedTasks(tasks, taskID: taskID)
        macQueueLogger.info("task queued id=\(queued.id.uuidString, privacy: .public) task=\(taskID.uuidString, privacy: .public)")
        return queued
    }

    func updateMacQueuedTask(taskID: UUID, id: UUID, mutate: (inout QueuedTask) -> Void) {
        var tasks = macQueuedTasks(for: taskID)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard tasks[index].state == .queued else { return }
        mutate(&tasks[index])
        saveMacQueuedTasks(tasks, taskID: taskID)
    }

    func removeMacQueuedTask(taskID: UUID, id: UUID) {
        var tasks = macQueuedTasks(for: taskID)
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].state == .queued else { return }
        tasks[index].state = .cancelled
        tasks[index].finishedAt = Date()
        saveMacQueuedTasks(tasks, taskID: taskID)
        macQueueLogger.info("task removed id=\(id.uuidString, privacy: .public)")
    }

    func duplicateMacQueuedTask(taskID: UUID, id: UUID) {
        var tasks = macQueuedTasks(for: taskID)
        guard let source = tasks.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.state = .queued
        copy.createdAt = Date()
        copy.startedAt = nil
        copy.finishedAt = nil
        copy.lastError = nil
        copy.order = (tasks.map(\.order).max() ?? -1) + 1
        tasks.append(copy)
        saveMacQueuedTasks(tasks, taskID: taskID)
    }

    func reorderMacQueuedTasks(taskID: UUID, ids: [UUID]) {
        macQueueLogger.info("queue reorder task=\(taskID.uuidString, privacy: .public)")
        var tasks = macQueuedTasks(for: taskID)
        let movable = Set(tasks.filter { $0.state == .queued }.map(\.id))
        var ordered = ids.filter { movable.contains($0) }
        for task in tasks where movable.contains(task.id) && !ordered.contains(task.id) { ordered.append(task.id) }
        var order = 0
        for id in ordered {
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].order = order
                order += 1
            }
        }
        saveMacQueuedTasks(tasks, taskID: taskID)
    }

    func queueStopOnFailure(for taskID: UUID) -> Bool {
        agenticTasks.first(where: { $0.id == taskID })?.queueStopOnFailure ?? true
    }

    func setQueueStopOnFailure(_ value: Bool, taskID: UUID) {
        updateMacTaskRecord(taskID: taskID) { $0.queueStopOnFailure = value }
    }

    func queuePaused(for taskID: UUID) -> Bool {
        agenticTasks.first(where: { $0.id == taskID })?.queuePaused ?? false
    }

    func setQueuePaused(_ value: Bool, taskID: UUID) {
        updateMacTaskRecord(taskID: taskID) { $0.queuePaused = value }
        macQueueLogger.info("queue paused=\(value) task=\(taskID.uuidString, privacy: .public)")
        if value {
            cancelQueueCountdown()
            isWorkspaceQueueRunning = false
            workspaceQueueMessage = "Queue paused. Current run will finish; queued tasks will wait."
        } else {
            workspaceQueueMessage = "Queue resumed."
        }
    }

    // MARK: - Queue runner

    func startWorkspaceQueue(taskID: UUID) {
        macQueueLogger.info("queue start requested task=\(taskID.uuidString, privacy: .public)")
        guard macQueuedTasks(for: taskID).contains(where: { $0.state == .queued }) else {
            workspaceQueueMessage = "No queued tasks."
            return
        }
        setQueuePaused(false, taskID: taskID)
        isWorkspaceQueueRunning = true
        if virtualMacAgent.isRunning {
            workspaceQueueMessage = "Queue will start after the current run finishes."
            return
        }
        scheduleNextQueuedTask(taskID: taskID, fromTitle: activeAgenticTask?.title ?? "Current task", immediate: true)
    }

    func resumeWorkspaceQueue(taskID: UUID) {
        guard macQueuedTasks(for: taskID).contains(where: { $0.state == .queued }) else { return }
        updateMacTaskRecord(taskID: taskID) { $0.queuePaused = false }
        isWorkspaceQueueRunning = true
        if virtualMacAgent.isRunning { return }
        scheduleNextQueuedTask(taskID: taskID, fromTitle: activeAgenticTask?.title ?? "Current task", immediate: false)
    }

    func cancelQueueCountdown() {
        queueCountdownTask?.cancel()
        queueCountdownTask = nil
        queueTransitionDeadline = nil
        queueTransitionNextTaskID = nil
        queueTransitionFromTitle = nil
        queueTransitionToTitle = nil
        queueStartNextImmediately = false
    }

    func cancelQueueTransition(taskID: UUID) {
        cancelQueueCountdown()
        isWorkspaceQueueRunning = false
        workspaceQueueMessage = "Next task cancelled."
    }

    func requestRunNextNow(taskID: UUID) {
        guard let next = QueuedTaskPlanner.next(macQueuedTasks(for: taskID)) else { return }
        macQueueLogger.info("queue run-next-now task=\(taskID.uuidString, privacy: .public)")
        queueStartNextImmediately = true
        if virtualMacAgent.isRunning {
            virtualMacAgent.requestStopAfterCurrentRound()
            workspaceQueueMessage = "Stopping after the current round, then starting “\(next.title)”."
        } else {
            cancelQueueCountdown()
            scheduleNextQueuedTask(taskID: taskID, fromTitle: activeAgenticTask?.title ?? "Current task", immediate: true)
        }
    }

    func scheduleNextQueuedTask(taskID: UUID, fromTitle: String, immediate: Bool) {
        guard let next = QueuedTaskPlanner.next(macQueuedTasks(for: taskID)) else {
            isWorkspaceQueueRunning = false
            workspaceQueueMessage = "Queue finished."
            cancelQueueCountdown()
            return
        }
        let useImmediate = immediate || queueStartNextImmediately
        cancelQueueCountdown()
        let delay = useImmediate ? 0 : 5
        queueTransitionNextTaskID = next.id
        queueTransitionFromTitle = fromTitle
        queueTransitionToTitle = next.title
        queueTransitionDeadline = Date().addingTimeInterval(TimeInterval(delay))
        workspaceQueueMessage = delay == 0
            ? "Starting “\(next.title)”."
            : "\(fromTitle) finished, starting “\(next.title)” in \(delay)s."
        virtualMacAgent.noteSystem("Queue: \(fromTitle) finished, starting \(next.title) in \(delay)s.")
        queueCountdownTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            guard self.queueTransitionNextTaskID == next.id else { return }
            await self.startQueuedTask(taskID: taskID, id: next.id)
        }
    }

    func startQueuedTaskNow(taskID: UUID) {
        guard let id = queueTransitionNextTaskID else { return }
        cancelQueueCountdown()
        Task { await startQueuedTask(taskID: taskID, id: id) }
    }

    func startQueuedTask(taskID: UUID, id: UUID) async {
        guard let queued = macQueuedTasks(for: taskID).first(where: { $0.id == id }),
              queued.state == .queued else { return }
        guard let endpoint = endpointForQueuedTask(taskID: taskID, queued: queued) else {
            failQueuedTask(taskID: taskID, id: id, error: "No provider is configured.")
            return
        }
        let configuredModel = queued.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = configuredModel.isEmpty
            ? (virtualMacAgent.model.isEmpty ? endpoint.defaultModel : virtualMacAgent.model)
            : configuredModel
        guard !model.isEmpty else {
            failQueuedTask(taskID: taskID, id: id, error: "No model is selected.")
            return
        }

        guard virtualMac.vmState == "running" else {
            isWorkspaceQueueRunning = false
            cancelQueueCountdown()
            updateMacTaskRecord(taskID: taskID) { $0.queuePaused = true }
            workspaceQueueMessage = "Start the virtual Mac, then resume the queue."
            return
        }

        cancelQueueCountdown()
        isWorkspaceQueueRunning = true
        activeQueuedTaskID = id
        queueTransitionDeadline = nil
        markQueuedTask(taskID: taskID, id: id) {
            $0.state = .running
            $0.startedAt = Date()
            $0.lastError = nil
        }
        workspaceQueueMessage = "Running “\(queued.title)”."
        virtualMacAgent.noteSystem("Queue: starting “\(queued.title)” with \(model).")

        if queued.vmStatePolicy == .freshState {
            let ready = await prepareFreshVMForQueuedTask()
            guard ready else {
                failQueuedTask(taskID: taskID, id: id, error: "Could not restart the virtual Mac for a fresh state.")
                return
            }
        }
        if !queued.continueConversation {
            virtualMacAgent.beginFreshRunContext()
        } else {
            virtualMacAgent.loadSession(for: activeAgenticTask)
        }

        virtualMacAgent.selectedEndpointID = endpoint.id
        virtualMacAgent.model = model
        virtualMacAgent.instructions = queued.prompt
        updateTaskStatus(taskID: taskID, status: "running")
        virtualMacAgent.start(
            endpoint: endpoint,
            apiKey: apiKey(for: endpoint),
            model: model,
            instructions: queued.prompt,
            vm: virtualMac,
            maxRoundsOverride: queued.maxRounds
        )
    }

    func handleWorkspaceQueueRunFinished(taskID: UUID, status: String) {
        let pendingSteers = virtualMacAgent.pendingSteersAtEnd
        let id = activeQueuedTaskID
        if let id {
            activeQueuedTaskID = nil
            let failed = status == "failed" || status == "cancelled"
            if failed {
                markQueuedTask(taskID: taskID, id: id) {
                    $0.state = .failed
                    $0.finishedAt = Date()
                    $0.lastError = status == "cancelled" ? "Cancelled by user." : "Run failed."
                }
            } else {
                markQueuedTask(taskID: taskID, id: id) {
                    $0.state = .done
                    $0.finishedAt = Date()
                }
            }
        } else if !isWorkspaceQueueRunning {
            return
        }

        if pendingSteers > 0 {
            isWorkspaceQueueRunning = false
            cancelQueueCountdown()
            updateMacTaskRecord(taskID: taskID) { $0.queuePaused = true }
            workspaceQueueMessage = "\(pendingSteers) steer(s) were not applied. Start a follow-up or discard them before resuming the queue."
            virtualMacAgent.noteSystem("Queue: paused because \(pendingSteers) steer(s) were not applied.")
            return
        }

        if status == "paused" {
            if let id {
                markQueuedTask(taskID: taskID, id: id) {
                    $0.state = .queued
                    $0.startedAt = nil
                    $0.finishedAt = nil
                    $0.continueConversation = true
                    $0.lastError = "Paused at its round limit."
                }
            }
            isWorkspaceQueueRunning = false
            cancelQueueCountdown()
            updateMacTaskRecord(taskID: taskID) { $0.queuePaused = true }
            workspaceQueueMessage = "Queue paused because the current task reached its round limit."
            virtualMacAgent.noteSystem("Queue: paused because the current task reached its round limit.")
            return
        }

        let failed = status == "failed" || status == "cancelled"
        if failed, let id, let task = macQueuedTasks(for: taskID).first(where: { $0.id == id }),
           QueuedTaskPlanner.shouldStopOnFailure(task, stopOnFailure: queueStopOnFailure(for: taskID)) {
            isWorkspaceQueueRunning = false
            updateMacTaskRecord(taskID: taskID) { $0.queuePaused = true }
            workspaceQueueMessage = "Queue stopped because “\(task.title)” failed."
            virtualMacAgent.noteSystem("Queue: stopped because “\(task.title)” failed.")
            return
        }
        guard !queuePaused(for: taskID) else {
            isWorkspaceQueueRunning = false
            workspaceQueueMessage = "Queue paused."
            return
        }
        let fromTitle = id.flatMap { id in macQueuedTasks(for: taskID).first(where: { $0.id == id })?.title }
            ?? activeAgenticTask?.title
            ?? "Task"
        scheduleNextQueuedTask(taskID: taskID, fromTitle: fromTitle, immediate: queueStartNextImmediately)
    }

    func failQueuedTask(taskID: UUID, id: UUID, error: String) {
        activeQueuedTaskID = nil
        let title = macQueuedTasks(for: taskID).first(where: { $0.id == id })?.title ?? "Task"
        markQueuedTask(taskID: taskID, id: id) {
            $0.state = .failed
            $0.finishedAt = Date()
            $0.lastError = error
        }
        virtualMacAgent.noteSystem("Queue: \(title) failed before starting: \(error)")
        if queueStopOnFailure(for: taskID) {
            isWorkspaceQueueRunning = false
            updateMacTaskRecord(taskID: taskID) { $0.queuePaused = true }
            workspaceQueueMessage = "Queue stopped: \(error)"
        } else {
            scheduleNextQueuedTask(taskID: taskID, fromTitle: title, immediate: false)
        }
    }

    func markCancelledQueuedTask(taskID: UUID, id: UUID) {
        markQueuedTask(taskID: taskID, id: id) {
            $0.state = .cancelled
            $0.finishedAt = Date()
            $0.lastError = "Cancelled by user."
        }
    }

    private func markQueuedTask(taskID: UUID, id: UUID, mutate: (inout QueuedTask) -> Void) {
        var tasks = macQueuedTasks(for: taskID)
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
        saveMacQueuedTasks(tasks, taskID: taskID)
    }

    private func endpointForQueuedTask(taskID: UUID, queued: QueuedTask) -> ProviderEndpoint? {
        if let id = queued.providerID, let endpoint = settings.endpoints.first(where: { $0.id == id }) {
            return endpoint
        }
        if let id = virtualMacAgent.selectedEndpointID,
           let endpoint = settings.endpoints.first(where: { $0.id == id }) {
            return endpoint
        }
        return settings.endpoints.first
    }

    private func prepareFreshVMForQueuedTask() async -> Bool {
        let name = virtualMac.selectedName
        guard let machine = virtualMac.machines.first(where: { $0.name == name }), machine.installed else { return false }
        guard virtualMac.vmState == "running" || virtualMac.vmState == "paused" else { return true }
        await virtualMac.stop(force: false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        do {
            try await virtualMac.start(name: name, show: false)
            await virtualMac.refreshGuestStatus()
            return true
        } catch {
            workspaceQueueMessage = "Could not restart the VM for a fresh queue task: \(error.localizedDescription)"
            return false
        }
    }

    private func updateMacTaskRecord(taskID: UUID, mutate: (inout AgenticTaskRecord) -> Void) {
        var tasks = agenticTasks
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        mutate(&tasks[index])
        settings.agenticTasks = tasks
        saveSettings()
    }
}
