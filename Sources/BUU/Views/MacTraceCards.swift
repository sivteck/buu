import AppKit
import SwiftUI
import BUUKit

enum MacTraceStatus: Equatable {
    case ok
    case warning
    case error

    var icon: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct MacTraceChip: Identifiable, Equatable {
    var id: String { text }
    let text: String
    let isError: Bool
}

struct MacTraceAction: Identifiable, Equatable {
    let id: String
    let tool: String
    let summary: String
    let icon: String
    var result: String
    var durationMs: Int?
    var isError: Bool
    var chips: [MacTraceChip]
    var screenshotID: UUID?
    var marker: CGPoint?
}

struct MacTraceRound: Identifiable, Equatable {
    let id: String
    let number: Int
    var assistant: String
    var actions: [MacTraceAction]
    var steers: [String]
    var notes: [String]
    var errors: [String]
    var contextClearedBefore: Bool
    var isSynthetic: Bool

    var durationMs: Int {
        actions.compactMap(\.durationMs).reduce(0, +)
    }

    var status: MacTraceStatus {
        if !errors.isEmpty || actions.contains(where: { $0.isError }) { return .error }
        if notes.contains(where: {
            $0.localizedCaseInsensitiveContains("interrupt")
                || $0.localizedCaseInsensitiveContains("paused")
                || $0.localizedCaseInsensitiveContains("stopped")
        }) { return .warning }
        return .ok
    }

    var summary: String {
        let actionSummary = actions.prefix(2).map(\.summary).joined(separator: " · ")
        let pieces = [actionSummary, durationText(durationMs)].filter { !$0.isEmpty }
        return pieces.isEmpty ? (assistant.isEmpty ? "Round activity" : String(assistant.prefix(100))) : pieces.joined(separator: " · ")
    }
}

struct MacTraceResult: Identifiable, Equatable {
    let id: String
    let text: String
    let status: MacTraceStatus
    let finishedAt: Date?
    let rounds: Int
    let durationMs: Int
}

struct MacTraceParseResult: Equatable {
    var rounds: [MacTraceRound] = []
    var trailingDivider = false
    var screenshotsByID: [UUID: TraceScreenshot] = [:]
    var result: MacTraceResult?

    static let empty = MacTraceParseResult()
}

enum MacTraceParser {
    private struct ClickArgs: Decodable { var x: Int; var y: Int; var button: String?; var clicks: Int? }
    private struct PointArgs: Decodable { var x: Int; var y: Int }
    private struct DragArgs: Decodable { var x: Int; var y: Int; var toX: Int; var toY: Int }
    private struct ScrollArgs: Decodable { var x: Int; var y: Int; var dy: Int; var dx: Int? }
    private struct TypeArgs: Decodable { var text: String }
    private struct KeyArgs: Decodable { var key: String }

    static func parse(
        log: [String],
        toolCalls: [ToolCall] = [],
        screenshots: [TraceScreenshot] = [],
        runState: MacRunState = .idle,
        runStartedAt: Date? = nil,
        finishedAt: Date? = nil
    ) -> MacTraceParseResult {
        var result = MacTraceParseResult()
        result.screenshotsByID = Dictionary(uniqueKeysWithValues: screenshots.map { ($0.id, $0) })
        var current: MacTraceRound?
        var dividerPending = false
        var hasContentSinceDivider = false
        var callCursor = 0
        var screenshotCursor = 0
        var lastClick: CGPoint?
        var screenSize = CGSize(width: 1280, height: 800)

        func flush() {
            if let current, !current.isSynthetic || !current.notes.isEmpty || !current.assistant.isEmpty {
                result.rounds.append(current)
            }
            current = nil
            lastClick = nil
        }

        for line in log {
            if line == "Context cleared" {
                if hasContentSinceDivider && !dividerPending {
                    dividerPending = true
                    hasContentSinceDivider = false
                }
                continue
            }

            if line.hasPrefix("Round "), let number = Int(line.dropFirst(6)) {
                flush()
                current = MacTraceRound(
                    id: "round-\(number)-\(result.rounds.count)",
                    number: number,
                    assistant: "",
                    actions: [],
                    steers: [],
                    notes: [],
                    errors: [],
                    contextClearedBefore: dividerPending,
                    isSynthetic: false
                )
                dividerPending = false
                hasContentSinceDivider = true
                continue
            }

            if current == nil {
                current = MacTraceRound(
                    id: "activity-\(result.rounds.count)",
                    number: 0,
                    assistant: "",
                    actions: [],
                    steers: [],
                    notes: [],
                    errors: [],
                    contextClearedBefore: dividerPending,
                    isSynthetic: true
                )
                dividerPending = false
            }

            if line.hasPrefix("Context:") {
                continue
            }

            if line.hasPrefix("Assistant: ") {
                let text = String(line.dropFirst("Assistant: ".count))
                if current?.assistant.isEmpty == true {
                    current?.assistant = text
                } else {
                    current?.assistant += "\n" + text
                }
                hasContentSinceDivider = true
                continue
            }

            if line.hasPrefix("→ ") {
                let tool = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                var call: ToolCall?
                if callCursor < toolCalls.count, toolCalls[callCursor].name == tool {
                    call = toolCalls[callCursor]
                    callCursor += 1
                } else if let match = toolCalls.dropFirst(callCursor).firstIndex(where: { $0.name == tool }) {
                    call = toolCalls[match]
                    callCursor = match + 1
                }
                let action = makeAction(
                    tool: tool,
                    call: call,
                    round: current?.number ?? 0,
                    index: current?.actions.count ?? 0,
                    lastClick: &lastClick,
                    screenSize: &screenSize,
                    screenshot: screenshotCursor < screenshots.count ? screenshots[screenshotCursor] : nil
                )
                if action.tool == "vm_screenshot", screenshotCursor < screenshots.count {
                    screenshotCursor += 1
                }
                current?.actions.append(action)
                hasContentSinceDivider = true
                continue
            }

            if line.hasPrefix("  error: ") || line.hasPrefix("  ") {
                let isError = line.hasPrefix("  error: ")
                let raw = isError
                    ? String(line.dropFirst("  error: ".count))
                    : String(line.dropFirst(2))
                let parsed = splitDuration(raw)
                if var actions = current?.actions, !actions.isEmpty {
                    let index = actions.count - 1
                    actions[index].result = parsed.text
                    actions[index].durationMs = parsed.ms
                    actions[index].isError = isError
                    if actions[index].tool == "vm_status", !isError {
                        actions[index].chips = statusChips(from: parsed.text)
                    }
                    if actions[index].tool == "vm_status", let size = parseScreenSize(from: parsed.text) {
                        screenSize = size
                    }
                    current?.actions = actions
                } else if isError {
                    current?.errors.append(parsed.text)
                } else {
                    current?.notes.append(parsed.text)
                }
                continue
            }

            if line.hasPrefix("You steered") {
                current?.steers.append(line)
                hasContentSinceDivider = true
                continue
            }

            if line.hasPrefix("System: ") {
                let text = String(line.dropFirst("System: ".count))
                current?.notes.append(text)
                if text.localizedCaseInsensitiveContains("error") {
                    current?.errors.append(text)
                }
                hasContentSinceDivider = true
                continue
            }

            if line.hasPrefix("Error: ") {
                let text = String(line.dropFirst("Error: ".count))
                current?.errors.append(text)
                hasContentSinceDivider = true
                continue
            }

            if line.hasPrefix("Preparing guest artifacts") || line.hasPrefix("Artifacts:") || line.hasPrefix("No input artifacts") {
                current?.notes.append(line)
                hasContentSinceDivider = true
                continue
            }

            if !line.isEmpty {
                if current?.assistant.isEmpty == false {
                    current?.assistant += "\n" + line
                } else {
                    current?.notes.append(line)
                }
            }
        }

        flush()
        result.trailingDivider = dividerPending

        if runState == .finished || runState == .failed {
            let lastAssistant = result.rounds.reversed().first(where: { !$0.assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let duration: Int
            if let runStartedAt, let finishedAt {
                duration = max(0, Int(finishedAt.timeIntervalSince(runStartedAt) * 1000))
            } else {
                duration = result.rounds.map(\.durationMs).reduce(0, +)
            }
            if let lastAssistant {
                result.result = MacTraceResult(
                    id: "result",
                    text: lastAssistant.assistant,
                    status: runState == .failed ? .error : lastAssistant.status,
                    finishedAt: finishedAt,
                    rounds: result.rounds.filter { !$0.isSynthetic }.count,
                    durationMs: duration
                )
            }
        }
        return result
    }

    static func exportLines(_ parsed: MacTraceParseResult) -> [String] {
        guard !parsed.rounds.isEmpty || parsed.result != nil else { return [] }
        var lines: [String] = []
        for round in parsed.rounds {
            if round.contextClearedBefore { lines.append("Context cleared") }
            let title = round.isSynthetic ? "Activity" : "Round \(round.number)"
            lines.append("\(title) [\(round.status == .error ? "error" : round.status == .warning ? "warning" : "ok")] \(durationText(round.durationMs))")
            if !round.assistant.isEmpty {
                lines.append(round.assistant)
            }
            for action in round.actions {
                let duration = action.durationMs.map { " [\($0) ms]" } ?? ""
                lines.append("  \(action.summary)\(duration)")
                if !action.result.isEmpty, action.chips.isEmpty {
                    lines.append("    \(action.result)")
                }
                if !action.chips.isEmpty {
                    lines.append("    " + action.chips.map(\.text).joined(separator: " · "))
                }
            }
            for steer in round.steers { lines.append("  \(steer)") }
            for note in round.notes { lines.append("  System: \(note)") }
            for error in round.errors { lines.append("  Error: \(error)") }
        }
        if parsed.trailingDivider { lines.append("Context cleared") }
        if let result = parsed.result {
            lines.append("")
            lines.append("Result [\(result.rounds) rounds, \(durationText(result.durationMs))]")
            lines.append(result.text)
        }
        return lines
    }

    private static func makeAction(
        tool: String,
        call: ToolCall?,
        round: Int,
        index: Int,
        lastClick: inout CGPoint?,
        screenSize: inout CGSize,
        screenshot: TraceScreenshot?
    ) -> MacTraceAction {
        let summary = actionSummary(tool: tool, call: call, screenSize: screenSize)
        var marker: CGPoint?
        if let click = clickPoint(call) {
            lastClick = click
        }
        if tool == "vm_screenshot", let lastClick {
            marker = CGPoint(
                x: min(1, max(0, lastClick.x / max(1, screenSize.width))),
                y: min(1, max(0, lastClick.y / max(1, screenSize.height)))
            )
        }
        return MacTraceAction(
            id: "round-\(round)-action-\(index)-\(tool)",
            tool: tool,
            summary: summary,
            icon: actionIcon(tool),
            result: "",
            durationMs: nil,
            isError: false,
            chips: [],
            screenshotID: screenshot?.id,
            marker: marker
        )
    }

    private static func actionSummary(tool: String, call: ToolCall?, screenSize: CGSize) -> String {
        guard let call, let data = call.arguments.data(using: .utf8) else {
            return humanize(tool)
        }
        let decoder = JSONDecoder()
        switch tool {
        case "vm_click":
            if let args = try? decoder.decode(ClickArgs.self, from: data) {
                let prefix = args.clicks == 2 ? "Double-click" : args.clicks == 3 ? "Triple-click" : args.button == "right" ? "Right-click" : "Click"
                return "\(prefix) (\(args.x), \(args.y))"
            }
        case "vm_move":
            if let args = try? decoder.decode(PointArgs.self, from: data) {
                return "Move to (\(args.x), \(args.y))"
            }
        case "vm_drag":
            if let args = try? decoder.decode(DragArgs.self, from: data) {
                return "Drag (\(args.x), \(args.y)) → (\(args.toX), \(args.toY))"
            }
        case "vm_scroll":
            if let args = try? decoder.decode(ScrollArgs.self, from: data) {
                return "Scroll \(args.dy)"
            }
        case "vm_type":
            if let args = try? decoder.decode(TypeArgs.self, from: data) {
                return "Type \(args.text.count) character\(args.text.count == 1 ? "" : "s")"
            }
        case "vm_key":
            if let args = try? decoder.decode(KeyArgs.self, from: data) {
                return "Press \(prettyKey(args.key))"
            }
        default:
            break
        }
        return humanize(tool)
    }

    private static func clickPoint(_ call: ToolCall?) -> CGPoint? {
        guard let call, call.name == "vm_click", let data = call.arguments.data(using: .utf8),
              let args = try? JSONDecoder().decode(ClickArgs.self, from: data) else { return nil }
        return CGPoint(x: args.x, y: args.y)
    }

    private static func actionIcon(_ tool: String) -> String {
        switch tool {
        case "vm_screenshot": return "camera"
        case "vm_click", "vm_move", "vm_drag": return "cursorarrow"
        case "vm_scroll": return "arrow.up.and.down"
        case "vm_type": return "keyboard"
        case "vm_key": return "return"
        case "list_artifacts", "read_artifact", "write_artifact": return "paperclip"
        case "open_artifact", "reveal_artifact": return "macwindow"
        case "vm_status": return "info.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    private static func humanize(_ tool: String) -> String {
        let words = tool.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + String(words.dropFirst())
    }

    private static func prettyKey(_ key: String) -> String {
        key.replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "option", with: "⌥")
            .replacingOccurrences(of: "control", with: "⌃")
            .replacingOccurrences(of: "+", with: "")
            .capitalized
    }

    private static func splitDuration(_ text: String) -> (text: String, ms: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(" ms]"), let open = trimmed.lastIndex(of: "[") else {
            return (trimmed, nil)
        }
        let numberStart = trimmed.index(after: open)
        let number = trimmed[numberStart...].dropLast(4)
        return (String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines), Int(number))
    }

    private static func parseScreenSize(from status: String) -> CGSize? {
        for line in status.split(separator: "\n") {
            guard line.hasPrefix("screen=") else { continue }
            let value = line.dropFirst("screen=".count)
            let parts = value.split(separator: "x")
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0 else { continue }
            return CGSize(width: width, height: height)
        }
        return nil
    }

    private static func statusChips(from status: String) -> [MacTraceChip] {
        var chips: [MacTraceChip] = []
        for line in status.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1]
            switch key {
            case "vm":
                chips.append(MacTraceChip(text: "VM \(value)", isError: value != "running"))
            case "ready":
                chips.append(MacTraceChip(text: value == "true" ? "Ready" : "Not ready", isError: value != "true"))
            case "screenRecording":
                chips.append(MacTraceChip(text: value == "true" ? "Screen recording on" : "Screen recording off", isError: value != "true"))
            case "accessibility":
                chips.append(MacTraceChip(text: value == "true" ? "Accessibility on" : "Accessibility off", isError: value != "true"))
            case "screen":
                let display = value.replacingOccurrences(of: "x", with: "×")
                chips.append(MacTraceChip(text: display, isError: value == "0x0"))
            default:
                chips.append(MacTraceChip(text: "\(key) \(value)", isError: false))
            }
        }
        return chips
    }
}

@MainActor
enum MacTraceThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
        return cache
    }()

    static func image(for screenshot: TraceScreenshot) -> NSImage? {
        let key = screenshot.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: screenshot.png) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct MacTraceThumbnail: View {
    let screenshot: TraceScreenshot
    var marker: CGPoint?
    var width: CGFloat = 160
    var height: CGFloat = 100

    var body: some View {
        if let image = MacTraceThumbnailCache.image(for: screenshot) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .overlay {
                    if let marker {
                        GeometryReader { proxy in
                            Circle()
                                .strokeBorder(Color.red, lineWidth: 2)
                                .background(Circle().fill(Color.red.opacity(0.22)))
                                .frame(width: 14, height: 14)
                                .position(x: marker.x * proxy.size.width, y: marker.y * proxy.size.height)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .accessibilityLabel("Trace screenshot")
                .accessibilityValue("Round \(screenshot.round)")
        }
    }
}

struct MacRoundCard: View, Equatable {
    let round: MacTraceRound
    let isExpanded: Bool
    let isSelected: Bool
    let screenshotsByID: [UUID: TraceScreenshot]
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onOpenScreenshot: (TraceScreenshot) -> Void

    @State private var showFullText = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.round.id == rhs.round.id
            && lhs.round.assistant == rhs.round.assistant
            && lhs.round.actions == rhs.round.actions
            && lhs.round.notes == rhs.round.notes
            && lhs.round.errors == rhs.round.errors
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color(nsColor: .separatorColor))
                .frame(width: 2)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 8) {
                header
                if isExpanded {
                    if !round.assistant.isEmpty {
                        assistantText
                    }
                    ForEach(round.actions) { action in
                        actionRow(action)
                    }
                    ForEach(round.steers, id: \.self) { steer in
                        Label(steer, systemImage: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    if round.errors.isEmpty {
                        ForEach(round.notes, id: \.self) { note in
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(round.errors, id: \.self) { error in
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text(round.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Round \(round.number)")
        .accessibilityValue(round.status == .error ? "Error" : round.status == .warning ? "Warning" : "Complete")
    }

    private var header: some View {
        Button {
            onSelect()
            onToggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: round.status.icon)
                    .font(.caption)
                    .foregroundStyle(round.status.color)
                Text(round.isSynthetic ? "Activity" : "Round \(round.number)")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                if round.durationMs > 0 {
                    Text(durationText(round.durationMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Round \(round.number)")
        .accessibilityHint(isExpanded ? "Collapse round" : "Expand round")
    }

    private var assistantText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(macMarkdown(round.assistant))
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(showFullText ? nil : 4)
            if round.assistant.count > 240 {
                Button(showFullText ? "Show less" : "Show more") {
                    showFullText.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
    }

    private func actionRow(_ action: MacTraceAction) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: action.isError ? "exclamationmark.triangle.fill" : action.icon)
                .font(.caption2)
                .foregroundStyle(action.isError ? Color.red : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(action.summary)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let ms = action.durationMs {
                        Text("\(ms) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if !action.chips.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 4)], alignment: .leading, spacing: 4) {
                        ForEach(action.chips) { chip in
                            Text(chip.text)
                                .font(.caption2)
                                .foregroundStyle(chip.isError ? Color.red : Color.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(chip.isError ? Color.red.opacity(0.10) : Color.secondary.opacity(0.10))
                                )
                        }
                    }
                }
                if action.isError, !action.result.isEmpty {
                    Text(action.result)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let id = action.screenshotID, let screenshot = screenshotsByID[id] {
                    Button {
                        onOpenScreenshot(screenshot)
                    } label: {
                        MacTraceThumbnail(screenshot: screenshot, marker: action.marker)
                    }
                    .buttonStyle(.plain)
                    .help("Open screenshot")
                    .accessibilityLabel("Open screenshot")
                    .accessibilityValue("Round \(round.number)")
                }
            }
        }
    }

}

struct MacTraceResultCard: View {
    @Environment(AppState.self) private var appState
    let result: MacTraceResult
    var taskID: UUID?
    var onFollowUp: () -> Void

    @State private var savedMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: result.status.icon)
                        .font(.caption)
                        .foregroundStyle(result.status.color)
                    Text("Result")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(statusLine)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(macMarkdown(result.text))
                    .font(.callout)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.text, forType: .string)
                    }
                    Button("Save as output") {
                        guard let taskID else { return }
                        do {
                            _ = try appState.saveMacResultOutput(taskID: taskID, markdown: result.text)
                            savedMessage = "Saved to BUU Outputs"
                        } catch {
                            savedMessage = error.localizedDescription
                        }
                    }
                    .disabled(taskID == nil)
                    Button("Follow up", action: onFollowUp)
                    if let savedMessage {
                        Text(savedMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Run result")
    }

    private var statusLine: String {
        let finish = result.finishedAt?.formatted(date: .omitted, time: .shortened) ?? "just now"
        return [
            "\(result.status == .error ? "Failed" : "Finished") \(finish)",
            "\(result.rounds) rounds",
            durationText(result.durationMs),
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }

}

struct MacTraceScreenshotViewer: View {
    @Environment(\.dismiss) private var dismiss
    let screenshot: TraceScreenshot
    var liveScreenshot: NSImage?

    @State private var showingLive = false

    private var image: NSImage? {
        showingLive ? liveScreenshot : MacTraceThumbnailCache.image(for: screenshot)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(showingLive ? "Live display · read-only" : "Screenshot · round \(screenshot.round)")
                    .font(.headline)
                Spacer()
                if liveScreenshot != nil {
                    Button(showingLive ? "Show historical" : "Return to live") {
                        showingLive.toggle()
                    }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 900, maxHeight: 620)
            } else {
                Text("Screenshot unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .background(DesignTokens.Surface.panel)
    }
}

func durationText(_ milliseconds: Int) -> String {
    guard milliseconds > 0 else { return "" }
    if milliseconds < 1000 { return "\(milliseconds) ms" }
    return String(format: "%.1f s", Double(milliseconds) / 1000)
}

func macMarkdown(_ text: String) -> AttributedString {
    if let parsed = try? AttributedString(markdown: text) { return parsed }
    let plain = text
        .replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "__", with: "")
        .replacingOccurrences(of: "`", with: "")
    return AttributedString(plain)
}

#if DEBUG
private func previewRound(status: MacTraceStatus = .ok, withScreenshot: Bool = false) -> MacTraceRound {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()
    var actions: [MacTraceAction] = [
        MacTraceAction(
            id: "preview-click",
            tool: "vm_click",
            summary: "Click (63, 244)",
            icon: "cursorarrow",
            result: "",
            durationMs: 364,
            isError: false,
            chips: [],
            screenshotID: nil,
            marker: nil
        ),
        MacTraceAction(
            id: "preview-type",
            tool: "vm_type",
            summary: "Type 60 characters",
            icon: "keyboard",
            result: "",
            durationMs: 240,
            isError: false,
            chips: [],
            screenshotID: nil,
            marker: nil
        ),
    ]
    if withScreenshot {
        let id = UUID()
        actions.append(MacTraceAction(
            id: "preview-shot",
            tool: "vm_screenshot",
            summary: "Screenshot",
            icon: "camera",
            result: "",
            durationMs: 88,
            isError: false,
            chips: [],
            screenshotID: id,
            marker: CGPoint(x: 0.05, y: 0.3)
        ))
        _ = png
    }
    return MacTraceRound(
        id: "preview-round",
        number: 4,
        assistant: "**What happened:** I opened the report and checked page 4. The table is visible and the totals match.",
        actions: actions,
        steers: [],
        notes: [],
        errors: status == .error ? ["Could not open the next page."] : [],
        contextClearedBefore: false,
        isSynthetic: false
    )
}

#Preview("Round card – actions") {
    ScrollView {
        MacRoundCard(
            round: previewRound(),
            isExpanded: true,
            isSelected: false,
            screenshotsByID: [:],
            onToggle: {},
            onSelect: {},
            onOpenScreenshot: { _ in }
        )
        .environment(AppState())
    }
    .frame(width: 460, height: 420)
    .preferredColorScheme(.dark)
}

#Preview("Round card – error") {
    MacRoundCard(
        round: previewRound(status: .error),
        isExpanded: true,
        isSelected: true,
        screenshotsByID: [:],
        onToggle: {},
        onSelect: {},
        onOpenScreenshot: { _ in }
    )
    .environment(AppState())
    .frame(width: 460)
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Round card – collapsed") {
    MacRoundCard(
        round: previewRound(),
        isExpanded: false,
        isSelected: false,
        screenshotsByID: [:],
        onToggle: {},
        onSelect: {},
        onOpenScreenshot: { _ in }
    )
    .environment(AppState())
    .frame(width: 460)
    .padding()
    .preferredColorScheme(.dark)
}

#Preview("Result – long markdown") {
    ScrollView {
        MacTraceResultCard(
            result: MacTraceResult(
                id: "preview-result",
                text: """
                ## What happened

                I opened **report.pdf** in Preview and checked page 4.

                - The totals match.
                - The table is legible.
                - No follow-up action is needed.

                `Done.`
                """,
                status: .ok,
                finishedAt: Date(),
                rounds: 7,
                durationMs: 8200
            ),
            taskID: nil,
            onFollowUp: {}
        )
        .environment(AppState())
        .padding()
    }
    .frame(width: 480, height: 520)
    .preferredColorScheme(.light)
}
#endif

#if DEBUG
#Preview("Round card – screenshot") {
    let id = UUID()
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=") ?? Data()
    let screenshot = TraceScreenshot(id: id, round: 4, png: png)
    let round = MacTraceRound(
        id: "preview-screenshot",
        number: 4,
        assistant: "Captured the current screen.",
        actions: [
            MacTraceAction(
                id: "preview-shot",
                tool: "vm_screenshot",
                summary: "Screenshot",
                icon: "camera",
                result: "",
                durationMs: 88,
                isError: false,
                chips: [],
                screenshotID: id,
                marker: CGPoint(x: 0.3, y: 0.4)
            )
        ],
        steers: [],
        notes: [],
        errors: [],
        contextClearedBefore: false,
        isSynthetic: false
    )
    MacRoundCard(
        round: round,
        isExpanded: true,
        isSelected: false,
        screenshotsByID: [id: screenshot],
        onToggle: {},
        onSelect: {},
        onOpenScreenshot: { _ in }
    )
    .environment(AppState())
    .frame(width: 460)
    .padding()
    .preferredColorScheme(.dark)
}
#endif
