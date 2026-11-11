import SwiftUI
import UniformTypeIdentifiers
import BUUKit

enum SteerDisplayStatus: Equatable {
    case queuedUntilResume
    case applying
    case appliesAfter(Int)
    case copying
    case applied(Int)
    case cancelled
    case failed

    var title: String {
        switch self {
        case .queuedUntilResume: return "Queued until resume"
        case .applying: return "Applying…"
        case .appliesAfter(let round): return "Applies after round \(round)"
        case .copying: return "Copying, then queued"
        case .applied(let round): return "Applied in round \(round)"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .queuedUntilResume, .appliesAfter: return .secondary
        case .applying, .copying: return Theme.Colors.warning
        case .applied: return Theme.Colors.success
        case .cancelled: return .secondary
        case .failed: return Theme.Colors.danger
        }
    }

    var icon: String {
        switch self {
        case .queuedUntilResume, .appliesAfter: return "clock"
        case .applying: return "arrow.triangle.2.circlepath"
        case .copying: return "paperclip"
        case .applied: return "checkmark.circle"
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

struct MacStatusChip: View {
    var text: String
    var color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text).font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityLabel(Text(text))
    }
}

struct SteerStripView: View {
    var items: [SteerItem]
    var artifacts: [TaskArtifact]
    var snapshot: MacLoopSnapshot
    var isRunning: Bool
    var isPaused: Bool
    var onEdit: (UUID, String) -> Bool
    var onDelete: (UUID) -> Void
    var onSendNow: (UUID) -> Void
    var onReorder: ([UUID]) -> Void
    var onRetrySteer: (SteerItem) -> Void
    var onClearAll: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pending: [SteerItem] {
        SteerPlanner.pending(items)
    }

    var body: some View {
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Text(pending.count == 1 ? "1 pending steer" : "\(pending.count) pending steers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if pending.count > 2 {
                        Button("Clear all", role: .destructive, action: onClearAll)
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Theme.Spacing.s) {
                        ForEach(Array(pending.enumerated()), id: \.element.id) { index, item in
                            SteerCardView(
                                item: item,
                                position: index,
                                attachments: artifacts.filter { item.attachmentIDs.contains($0.id) },
                                status: status(for: item),
                                onEdit: { onEdit(item.id, $0) },
                                onDelete: { onDelete(item.id) },
                                onSendNow: { onSendNow(item.id) },
                                onMoveUp: { move(item, offset: -1) },
                                onMoveDown: { move(item, offset: 1) },
                                onDropBefore: { draggedID in
                                    guard let draggedID,
                                          let draggedUUID = UUID(uuidString: draggedID),
                                          draggedUUID != item.id else { return }
                                    var ids = pending.map(\.id)
                                    guard let from = ids.firstIndex(of: draggedUUID),
                                          let to = ids.firstIndex(of: item.id) else { return }
                                    let dragged = ids.remove(at: from)
                                    ids.insert(dragged, at: to)
                                    onReorder(ids)
                                },
                                onRetry: { onRetrySteer(item) }
                            )
                            .frame(width: 292)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: pending.map { "\($0.id)-\($0.state.rawValue)" })
            }
        }
    }

    private func status(for item: SteerItem) -> SteerDisplayStatus {
        if item.state == .applying { return .applying }
        if item.state == .applied { return .applied(item.appliedInRound ?? 0) }
        if item.state == .cancelled { return .cancelled }
        if item.state == .failed { return .failed }
        let attachments = artifacts.filter { item.attachmentIDs.contains($0.id) }
        if attachments.contains(where: { $0.guestState == .failed }) { return .failed }
        if attachments.contains(where: { $0.guestState == .copying || $0.guestState == .queued || $0.guestState == nil }) {
            return .copying
        }
        if isPaused || !isRunning { return .queuedUntilResume }
        return .appliesAfter(max(1, snapshot.nextSafeBoundaryRound ?? snapshot.round))
    }

    private func move(_ item: SteerItem, offset: Int) {
        var ids = pending.map(\.id)
        guard let index = ids.firstIndex(of: item.id) else { return }
        let target = index + offset
        guard ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        onReorder(ids)
    }
}

struct SteerCardView: View {
    var item: SteerItem
    var position: Int
    var attachments: [TaskArtifact]
    var status: SteerDisplayStatus
    var onEdit: (String) -> Bool
    var onDelete: () -> Void
    var onSendNow: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDropBefore: (String?) -> Void
    var onRetry: () -> Void

    @State private var expanded = false
    @State private var editing = false
    @State private var draft = ""
    @State private var dropTargeted = false

    private var canMutate: Bool { item.state == .queued }
    private var canDelete: Bool { item.state == .queued || item.state == .failed }
    private var hasFailedAttachment: Bool { attachments.contains { $0.guestState == .failed } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header
            content
            attachmentsView
            retryView
        }
        .padding(Theme.Spacing.s)
        .background(Theme.Colors.control, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Theme.Colors.separator, lineWidth: dropTargeted ? 2 : 1)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first else { return false }
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
        .accessibilityLabel("Queued steer \(position + 1): \(item.text)")
        .accessibilityValue(status.title)
        .accessibilityAction(named: "Edit") { beginEditing() }
        .accessibilityAction(named: "Delete") { if canDelete { onDelete() } }
        .accessibilityAction(named: "Send now") { sendNowIfPossible() }
        .accessibilityAction(named: "Move up") { onMoveUp() }
        .accessibilityAction(named: "Move down") { onMoveDown() }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                .draggable(item.id.uuidString)
            Text("#\(position + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            MacStatusChip(text: status.title, color: status.color, systemImage: status.icon)
            actionsMenu
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button("Edit", action: beginEditing)
                .disabled(!canMutate)
            Button("Send now", action: sendNowIfPossible)
                .disabled(!canMutate || status == .copying || status == .queuedUntilResume)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
                .disabled(!canDelete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Steer actions")
    }

    @ViewBuilder
    private var content: some View {
        if editing {
            TextEditor(text: $draft)
                .font(.callout)
                .frame(minHeight: 54, maxHeight: 90)
                .padding(4)
                .background(Theme.Colors.control, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                Button("Save") {
                    if onEdit(draft) { editing = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.caption)
        } else {
            Text(item.text)
                .font(.callout)
                .lineLimit(expanded ? nil : 2)
                .textSelection(.enabled)
                .onTapGesture { expanded.toggle() }
                .accessibilityHint("Tap to expand or collapse")
        }
    }

    @ViewBuilder
    private var attachmentsView: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(attachments) { artifact in
                        HStack(spacing: 3) {
                            Image(systemName: artifact.guestState == .failed ? "exclamationmark.triangle" : "paperclip")
                            Text(artifact.name).lineLimit(1)
                        }
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.control, in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var retryView: some View {
        if item.state == .failed || hasFailedAttachment {
            HStack {
                Text(item.failure ?? attachments.compactMap(\.lastError).first ?? "Attachment copy failed.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Colors.danger)
                    .lineLimit(2)
                Spacer()
                Button("Retry", action: onRetry)
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
    }

    private func sendNowIfPossible() {
        guard canMutate, status != .copying, status != .queuedUntilResume else { return }
        onSendNow()
    }

    private func beginEditing() {
        guard canMutate else { return }
        draft = item.text
        editing = true
    }
}

struct SteerComposerView: View {
    @Binding var text: String
    var isEnabled: Bool
    var disabledReason: String?
    var isPaused: Bool
    var attachmentNames: [String]
    var onAttach: () -> Void
    var onSteer: () -> Void
    var onInterrupt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .disabled(!isEnabled)
                .help("Attach files to this steer")
                .accessibilityLabel("Attach files")

                TextField(
                    isPaused ? "Steer the agent. Applied when you resume." : "Steer the agent. Applied after the current step.",
                    text: $text,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Theme.Colors.control, in: RoundedRectangle(cornerRadius: 8))
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if press.modifiers.contains(.option) {
                        onInterrupt()
                    } else {
                        onSteer()
                    }
                    return .handled
                }
                .disabled(!isEnabled)
                .help(isEnabled ? "" : (disabledReason ?? "Steering is unavailable"))

                Button("Steer", action: onSteer)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Queues this steer for the next safe boundary")

                Menu {
                    Button("Interrupt and steer", action: onInterrupt)
                        .disabled(!isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More steer actions")
                .accessibilityLabel("More steer actions")
            }

            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("Return queues for the next step. Option-Return interrupts and applies now. Shift-Return adds a line.")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)

            if !attachmentNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(attachmentNames, id: \.self) { name in
                            Label(name, systemImage: "paperclip")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.Colors.control, in: Capsule())
                        }
                    }
                }
            }
            if let disabledReason, !isEnabled {
                Text(disabledReason)
                    .font(.caption2)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }
        .padding(Theme.Spacing.s)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct SteerTraceRow: View {
    var line: String

    var body: some View {
        if line.hasPrefix("You steered") {
            Label(line, systemImage: "text.bubble")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 1)
                .accessibilityLabel("You steered. \(line)")
        } else if line.hasPrefix("System: Interrupt") || line.hasPrefix("Interrupt") {
            Label(line, systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(Theme.Colors.warning)
                .padding(.vertical, 1)
        } else if line.hasPrefix("System:") {
            Label(line, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 1)
        } else {
            Text(line)
                .font(Theme.Typography.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("Steer strip – light") {
    SteerStripView(
        items: [
            SteerItem(text: "Open the PDF and summarize page 2.", order: 0),
            SteerItem(text: "Also check the chart on page 4.", order: 1),
            SteerItem(text: "Save the summary as summary.txt.", order: 2),
        ],
        artifacts: [],
        snapshot: MacLoopSnapshot(round: 33, phase: .modelThinking, nextSafeBoundaryRound: 33, pendingSteerCount: 3, interruptRequested: false),
        isRunning: true,
        isPaused: false,
        onEdit: { _, _ in true },
        onDelete: { _ in },
        onSendNow: { _ in },
        onReorder: { _ in },
        onRetrySteer: { _ in },
        onClearAll: {}
    )
    .padding()
    .frame(width: 720)
    .preferredColorScheme(.light)
}

#Preview("Steer strip – dark") {
    SteerStripView(
        items: [
            SteerItem(text: "Open the PDF and summarize page 2.", order: 0),
            SteerItem(text: "Also check the chart on page 4.", order: 1),
            SteerItem(text: "Save the summary as summary.txt.", order: 2),
        ],
        artifacts: [],
        snapshot: MacLoopSnapshot(round: 33, phase: .betweenRounds, nextSafeBoundaryRound: 33, pendingSteerCount: 3, interruptRequested: false),
        isRunning: true,
        isPaused: false,
        onEdit: { _, _ in true },
        onDelete: { _ in },
        onSendNow: { _ in },
        onReorder: { _ in },
        onRetrySteer: { _ in },
        onClearAll: {}
    )
    .padding()
    .frame(width: 720)
    .preferredColorScheme(.dark)
}

#Preview("Applied steer row") {
    SteerTraceRow(line: "You steered (round 34, 10:42:11): Use Preview and summarize page 2.")
        .padding()
        .frame(width: 640)
}

#Preview("Empty steer strip") {
    VStack(alignment: .leading) {
        Text("No pending steers")
            .font(.callout)
        Text("Steers appear here while a run is active or paused.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 420)
}

#Preview("Applied steer row – dark") {
    SteerTraceRow(line: "You steered (round 34, 10:42:11): Use Preview and summarize page 2.")
        .padding()
        .frame(width: 640)
        .preferredColorScheme(.dark)
}

#Preview("Empty steer strip – dark") {
    VStack(alignment: .leading) {
        Text("No pending steers")
            .font(.callout)
        Text("Steers appear here while a run is active or paused.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding()
    .frame(width: 420)
    .preferredColorScheme(.dark)
}
