import SwiftUI
import BUUKit

struct MacQueueTabView: View {
    @Environment(AppState.self) private var appState
    var taskID: UUID
    var onQueueCurrent: () -> Void
    var onRunNextNow: () -> Void
    @State private var editingTask: QueuedTask?

    private var tasks: [QueuedTask] { appState.macQueuedTasks(for: taskID) }
    private var queued: [QueuedTask] { tasks.filter { $0.state == .queued } }
    private var running: QueuedTask? {
        if let id = appState.activeQueuedTaskID {
            return tasks.first { $0.id == id }
        }
        return tasks.first { $0.state == .running }
    }
    private var paused: Bool { appState.queuePaused(for: taskID) }
    private var stopOnFailure: Bool { appState.queueStopOnFailure(for: taskID) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let deadline = appState.queueTransitionDeadline, let to = appState.queueTransitionToTitle {
                QueueTransitionBannerView(
                    deadline: deadline,
                    from: appState.queueTransitionFromTitle ?? "Task",
                    to: to,
                    onCancel: { appState.cancelQueueTransition(taskID: taskID) },
                    onStartNow: { appState.startQueuedTaskNow(taskID: taskID) }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            Divider()
            if let running {
                MacQueueRow(
                    task: running,
                    running: true,
                    onEdit: nil,
                    onDuplicate: nil,
                    onRemove: nil
                )
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            if queued.isEmpty {
                Text("Queue another task here. A queued task keeps its own prompt, files, model and VM policy.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                List {
                    ForEach(queued) { task in
                        MacQueueRow(
                            task: task,
                            running: false,
                            onEdit: { editingTask = task },
                            onDuplicate: { appState.duplicateMacQueuedTask(taskID: taskID, id: task.id) },
                            onRemove: { appState.removeMacQueuedTask(taskID: taskID, id: task.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                    .onMove { source, destination in
                        var ids = queued.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        appState.reorderMacQueuedTasks(taskID: taskID, ids: ids)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $editingTask) { task in
            QueuedTaskEditorView(
                task: task,
                endpoints: appState.settings.endpoints,
                defaultModel: appState.virtualMacAgent.model
            ) { updated in
                appState.updateMacQueuedTask(taskID: taskID, id: updated.id) { $0 = updated }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(paused ? "Resume queue" : "Pause queue") {
                    if paused {
                        appState.setQueuePaused(false, taskID: taskID)
                        appState.resumeWorkspaceQueue(taskID: taskID)
                    } else {
                        appState.setQueuePaused(true, taskID: taskID)
                    }
                }
                .controlSize(.small)
                Button("Run next now", action: onRunNextNow)
                    .controlSize(.small)
                    .disabled(queued.isEmpty)
                Spacer()
                Button("Queue current prompt", action: onQueueCurrent)
                    .controlSize(.small)
            }
            HStack {
                Toggle("Stop on failure", isOn: Binding(
                    get: { stopOnFailure },
                    set: { value in
                        Task { @MainActor in appState.setQueueStopOnFailure(value, taskID: taskID) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()
                if !queued.isEmpty {
                    Text("\(queued.count) queued")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let message = appState.workspaceQueueMessage, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

private struct MacQueueRow: View {
    var task: QueuedTask
    var running: Bool
    var onEdit: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if running {
                ProgressView().controlSize(.small).frame(width: 16)
            } else {
                Image(systemName: "line.3.horizontal").font(.caption2).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title).font(.callout.weight(.medium)).lineLimit(1)
                    MacStatusChip(
                        text: running ? "Running" : task.state.rawValue.capitalized,
                        color: running ? .accentColor : (task.state == .failed ? .red : .secondary),
                        systemImage: running ? "play.fill" : "clock"
                    )
                }
                Text("\(task.model ?? "Workspace model") · \(task.vmStatePolicy == .freshState ? "Fresh VM" : "Keep VM") · \(task.maxRounds.map { "\($0) rounds" } ?? "Workspace rounds")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !task.attachmentIDs.isEmpty {
                    Text("\(task.attachmentIDs.count) file(s)").font(.caption2).foregroundStyle(.tertiary)
                }
                if let error = task.lastError, !error.isEmpty {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            if !running {
                Menu {
                    Button("Edit") { onEdit?() }
                    Button("Duplicate") { onDuplicate?() }
                    Divider()
                    Button("Remove", role: .destructive) { onRemove?() }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.medium)
                .fill(running ? Color.accentColor.opacity(0.08) : DesignTokens.Surface.card)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit") { onEdit?() }
        .accessibilityAction(named: "Duplicate") { onDuplicate?() }
        .accessibilityAction(named: "Remove") { onRemove?() }
    }
}

#Preview("Queue tab – light") {
    MacQueueTabView(taskID: UUID(), onQueueCurrent: {}, onRunNextNow: {})
        .environment(AppState())
        .frame(width: 460, height: 420)
        .preferredColorScheme(.light)
}
