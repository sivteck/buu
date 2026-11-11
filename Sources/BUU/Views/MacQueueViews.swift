import SwiftUI
import UniformTypeIdentifiers
import BUUKit

struct QueueTrayView: View {
    @Binding var expanded: Bool
    var tasks: [QueuedTask]
    var artifacts: [TaskArtifact]
    var endpoints: [ProviderEndpoint]
    var defaultModel: String
    var runningID: UUID?
    var paused: Bool
    var stopOnFailure: Bool
    var transitionDeadline: Date?
    var transitionFrom: String?
    var transitionTo: String?
    var transitionNextID: UUID?
    var message: String? = nil
    var onPauseResume: (Bool) -> Void
    var onStartQueue: () -> Void
    var onRunNextNow: () -> Void
    var onStartNow: () -> Void
    var onCancelTransition: () -> Void
    var onEdit: (QueuedTask) -> Void
    var onDuplicate: (UUID) -> Void
    var onRemove: (UUID) -> Void
    var onReorder: ([UUID]) -> Void
    var onStopOnFailure: @MainActor @Sendable (Bool) -> Void
    var onQueueCurrent: () -> Void

    private var queued: [QueuedTask] {
        tasks.filter { $0.state == .queued }.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.createdAt < rhs.createdAt : lhs.order < rhs.order
        }
    }

    private var running: QueuedTask? {
        tasks.first { $0.id == runningID || $0.state == .running }
    }

    private var failedOrDone: [QueuedTask] {
        tasks.filter { $0.state == .failed || $0.state == .done || $0.state == .cancelled }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label("Queue", systemImage: "list.number")
                            .font(.callout.weight(.semibold))
                        if !queued.isEmpty {
                            Text("\(queued.count)")
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if !queued.isEmpty {
                    Button(paused ? "Resume queue" : "Pause queue") {
                        onPauseResume(!paused)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    Button("Run next now", action: onRunNextNow)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }

            if expanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack(spacing: Theme.Spacing.s) {
                        Button("Queue current prompt", action: onQueueCurrent)
                            .font(.caption)
                        if paused {
                            Button("Resume queue", action: { onPauseResume(false) })
                                .font(.caption)
                        } else if !queued.isEmpty {
                            Button("Start queue", action: onStartQueue)
                                .font(.caption)
                        }
                        Spacer()
                        Toggle(
                            "Stop on failure",
                            isOn: Binding(
                                get: { stopOnFailure },
                                set: { value in
                                    Task { @MainActor in onStopOnFailure(value) }
                                }
                            )
                        )
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.caption)
                            .help("Stop the queue when a queued task fails.")
                    }

                    if let transitionDeadline, let transitionTo {
                        QueueTransitionBannerView(
                            deadline: transitionDeadline,
                            from: transitionFrom ?? "Task",
                            to: transitionTo,
                            onCancel: onCancelTransition,
                            onStartNow: onStartNow
                        )
                    }

                    if let running {
                        QueuedTaskRowView(
                            task: running,
                            artifacts: artifacts,
                            providerLabel: providerLabel(running),
                            modelLabel: running.model ?? defaultModel,
                            isRunning: true,
                            isFirst: true,
                            isLast: false,
                            reduceMotion: reduceMotion,
                            onEdit: { onEdit(running) },
                            onDuplicate: { onDuplicate(running.id) },
                            onRemove: { onRemove(running.id) },
                            onMoveUp: {},
                            onMoveDown: {},
                            onDropBefore: { _ in }
                        )
                    }

                    ForEach(Array(queued.enumerated()), id: \.element.id) { index, task in
                        queuedRow(task, index: index)
                    }

                    if queued.isEmpty && running == nil {
                        QueueEmptyView()
                    }

                    if !failedOrDone.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(failedOrDone) { task in
                                HStack(spacing: 6) {
                                    Image(systemName: icon(for: task.state))
                                        .font(.caption2)
                                        .foregroundStyle(color(for: task.state))
                                    Text(task.title).font(.caption2).lineLimit(1)
                                    Spacer()
                                    Text(task.state.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.s)
                .transition(.opacity.combined(with: reduceMotion ? .identity : .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .background(Theme.Colors.control.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: tasks.map(\.id))
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func queuedRow(_ task: QueuedTask, index: Int) -> some View {
        QueuedTaskRowView(
            task: task,
            artifacts: artifacts,
            providerLabel: providerLabel(task),
            modelLabel: task.model ?? defaultModel,
            isRunning: false,
            isFirst: index == 0,
            isLast: index == queued.count - 1,
            reduceMotion: reduceMotion,
            onEdit: { onEdit(task) },
            onDuplicate: { onDuplicate(task.id) },
            onRemove: { onRemove(task.id) },
            onMoveUp: { move(task, offset: -1) },
            onMoveDown: { move(task, offset: 1) },
            onDropBefore: { draggedID in
                guard let draggedID,
                      let draggedUUID = UUID(uuidString: draggedID),
                      draggedUUID != task.id else { return }
                var ids = queued.map(\.id)
                guard let from = ids.firstIndex(of: draggedUUID),
                      let to = ids.firstIndex(of: task.id) else { return }
                let dragged = ids.remove(at: from)
                ids.insert(dragged, at: to)
                onReorder(ids)
            }
        )
    }

    private func providerLabel(_ task: QueuedTask) -> String {
        guard let id = task.providerID else { return endpoints.first?.name ?? "Default provider" }
        return endpoints.first(where: { $0.id == id })?.name ?? "Missing provider"
    }

    private func move(_ task: QueuedTask, offset: Int) {
        var ids = queued.map(\.id)
        guard let index = ids.firstIndex(of: task.id) else { return }
        let target = index + offset
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        onReorder(ids)
    }

    private func icon(for state: QueuedTaskState) -> String {
        switch state {
        case .queued: return "clock"
        case .running: return "play.circle"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(for state: QueuedTaskState) -> Color {
        switch state {
        case .queued: return .secondary
        case .running: return Color.accentColor
        case .done: return Theme.Colors.success
        case .failed: return Theme.Colors.danger
        case .cancelled: return .secondary
        }
    }
}

struct QueueTransitionBannerView: View {
    var deadline: Date
    var from: String
    var to: String
    var onCancel: () -> Void
    var onStartNow: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(Color.accentColor)
                Text("\(from) finished, starting \(to) in \(remaining)s")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("Cancel", action: onCancel).font(.caption)
                Button("Start now", action: onStartNow).font(.caption)
            }
            .padding(Theme.Spacing.s)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.s))
        }
    }
}

struct QueuedTaskRowView: View {
    var task: QueuedTask
    var artifacts: [TaskArtifact]
    var providerLabel: String
    var modelLabel: String
    var isRunning: Bool
    var isFirst: Bool
    var isLast: Bool
    var reduceMotion: Bool
    var onEdit: () -> Void
    var onDuplicate: () -> Void
    var onRemove: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDropBefore: (String?) -> Void

    @State private var dropTargeted = false

    private var attachments: [TaskArtifact] {
        artifacts.filter { task.attachmentIDs.contains($0.id) }
    }

    private var budget: String {
        task.maxRounds.map { "\($0) rounds" } ?? "Workspace budget"
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            if !isRunning {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .draggable(task.id.uuidString)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small).frame(width: 12)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title).font(.callout.weight(.medium)).lineLimit(1)
                    if isRunning {
                        MacStatusChip(text: "Running", color: Color.accentColor, systemImage: "play.fill")
                    } else {
                        MacStatusChip(text: task.state.rawValue.capitalized, color: .secondary, systemImage: "clock")
                    }
                }
                HStack(spacing: 8) {
                    Label(providerLabel, systemImage: "network")
                    Text(modelLabel)
                    Text(budget)
                    Label(task.vmStatePolicy == .freshState ? "Fresh VM" : "Keep VM", systemImage: task.vmStatePolicy == .freshState ? "arrow.clockwise" : "pause.circle")
                        .help(task.vmStatePolicy.detail)
                    if task.continueConversation {
                        Label("Continue conversation", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if !attachments.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(attachments.prefix(4)) { artifact in
                            Label(artifact.name, systemImage: "paperclip")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.Colors.control, in: Capsule())
                                .lineLimit(1)
                        }
                    }
                }
                if let error = task.lastError, !error.isEmpty {
                    Text(error).font(.caption2).foregroundStyle(Theme.Colors.danger).lineLimit(2)
                }
            }
            Spacer()
            Menu {
                Button("Edit", action: onEdit).disabled(task.state != .queued)
                Button("Duplicate", action: onDuplicate).disabled(task.state != .queued)
                Divider()
                Button("Remove", role: .destructive, action: onRemove).disabled(task.state != .queued)
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Task actions")
            .accessibilityAction(named: "Edit") { onEdit() }
            .accessibilityAction(named: "Duplicate") { onDuplicate() }
            .accessibilityAction(named: "Remove") { onRemove() }
            .accessibilityAction(named: "Move up") { onMoveUp() }
            .accessibilityAction(named: "Move down") { onMoveDown() }
        }
        .padding(Theme.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .fill(isRunning ? Color.accentColor.opacity(0.08) : Theme.Colors.control)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Theme.Colors.separator, lineWidth: dropTargeted ? 2 : 1)
        }
        .opacity(task.state == .cancelled ? 0.55 : 1)
        .dropDestination(for: String.self) { items, _ in
            guard !isRunning, let id = items.first else { return false }
            onDropBefore(id)
            return true
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .focusable()
        .onKeyPress(.upArrow, phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            onMoveUp()
            return .handled
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            onMoveDown()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued task \(task.title)")
        .accessibilityValue("\(task.state.rawValue), \(providerLabel), \(modelLabel), \(budget)")
    }
}

struct QueueEmptyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Queue another task for this workspace")
                .font(.callout.weight(.medium))
            Text("Example: run “Open the PDF and summarize it”, then “Save the summary to BUU Outputs”. Each queued task keeps its own prompt, files, provider, model and round budget.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.control, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }
}

struct QueuedTaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: QueuedTask
    var endpoints: [ProviderEndpoint]
    var defaultModel: String
    var onSave: (QueuedTask) -> Void

    init(task: QueuedTask, endpoints: [ProviderEndpoint], defaultModel: String, onSave: @escaping (QueuedTask) -> Void) {
        _draft = State(initialValue: task)
        self.endpoints = endpoints
        self.defaultModel = defaultModel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Edit queued task").font(.title3.weight(.semibold))
            TextEditor(text: $draft.prompt)
                .font(.body)
                .frame(minHeight: 120)
                .padding(6)
                .background(Theme.Colors.control, in: RoundedRectangle(cornerRadius: 8))
            Picker("Provider", selection: Binding(
                get: { draft.providerID },
                set: { draft.providerID = $0 }
            )) {
                Text("Workspace default").tag(Optional<UUID>.none)
                ForEach(endpoints) { endpoint in
                    Text(endpoint.name).tag(Optional(endpoint.id))
                }
            }
            TextField("Model", text: Binding(
                get: { draft.model ?? "" },
                set: { draft.model = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            Stepper("Max rounds: \(draft.maxRounds.map(String.init) ?? "Workspace default")", value: Binding(
                get: { draft.maxRounds ?? 0 },
                set: { draft.maxRounds = $0 == 0 ? nil : $0 }
            ), in: 0...500)
            Picker("VM state", selection: $draft.vmStatePolicy) {
                ForEach(VMStatePolicy.allCases, id: \.self) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Toggle("Continue conversation", isOn: $draft.continueConversation)
                .help("Off means a fresh model context for this queued task.")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 560)
    }
}

#Preview("Queue tray – light") {
    QueueTrayView(
        expanded: .constant(true),
        tasks: [
            QueuedTask(prompt: "Open the PDF and summarize page 2.", state: .running, order: 0, startedAt: Date()),
            QueuedTask(prompt: "Save the summary to BUU Outputs.", order: 1),
            QueuedTask(prompt: "Open the summary in TextEdit.", vmStatePolicy: .keepState, order: 2),
            QueuedTask(prompt: "Take a final screenshot.", order: 3),
        ],
        artifacts: [],
        endpoints: [],
        defaultModel: "deepseek-v4.1-flash",
        runningID: nil,
        paused: false,
        stopOnFailure: true,
        transitionDeadline: Date().addingTimeInterval(5),
        transitionFrom: "Task 1",
        transitionTo: "Task 2",
        transitionNextID: nil,
        onPauseResume: { _ in },
        onStartQueue: {},
        onRunNextNow: {},
        onStartNow: {},
        onCancelTransition: {},
        onEdit: { _ in },
        onDuplicate: { _ in },
        onRemove: { _ in },
        onReorder: { _ in },
        onStopOnFailure: { _ in },
        onQueueCurrent: {}
    )
    .padding()
    .frame(width: 760)
    .preferredColorScheme(.light)
}

#Preview("Queue tray – dark") {
    QueueTrayView(
        expanded: .constant(true),
        tasks: [
            QueuedTask(prompt: "Open the PDF and summarize page 2.", order: 0),
            QueuedTask(prompt: "Save the summary to BUU Outputs.", order: 1),
        ],
        artifacts: [],
        endpoints: [],
        defaultModel: "model",
        runningID: nil,
        paused: true,
        stopOnFailure: true,
        transitionDeadline: nil,
        transitionFrom: nil,
        transitionTo: nil,
        transitionNextID: nil,
        onPauseResume: { _ in },
        onStartQueue: {},
        onRunNextNow: {},
        onStartNow: {},
        onCancelTransition: {},
        onEdit: { _ in },
        onDuplicate: { _ in },
        onRemove: { _ in },
        onReorder: { _ in },
        onStopOnFailure: { _ in },
        onQueueCurrent: {}
    )
    .padding()
    .frame(width: 760)
    .preferredColorScheme(.dark)
}

#Preview("Queue empty") {
    QueueEmptyView()
        .padding()
        .frame(width: 520)
}

#Preview("Queue empty – dark") {
    QueueEmptyView()
        .padding()
        .frame(width: 520)
        .preferredColorScheme(.dark)
}
