import AppKit
import SwiftUI
import BUUKit

private enum MacTraceFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "All"
    case actions = "Actions"
    case errors = "Errors"
    case steers = "Steers"
    var id: String { rawValue }
}

struct MacTraceTabView: View {
    var log: [String]
    var screenshots: [TraceScreenshot] = []
    var toolCalls: [ToolCall] = []
    var onSuggestion: (String) -> Void = { _ in }
    var showSuggestions: Bool = true
    var compact: Bool = false
    var runState: MacRunState = .idle
    var runStartedAt: Date? = nil
    var finishedAt: Date? = nil
    var liveScreenshot: NSImage? = nil
    var taskID: UUID? = nil
    var onFollowUp: () -> Void = {}

    @State private var filter: MacTraceFilter = .all
    @State private var search = ""
    @State private var autoScroll = true
    @State private var parsed = MacTraceParseResult.empty
    @State private var visibleRounds: [MacTraceRound] = []
    @State private var roundIndexByID: [String: Int] = [:]
    @State private var expandedRoundIDs: Set<String> = []
    @State private var collapsedRoundIDs: Set<String> = []
    @State private var selectedRoundID: String?
    @State private var viewingScreenshot: TraceScreenshot?
    @State private var didInitialScroll = false
    @FocusState private var traceFocused: Bool

    private let bottomID = "trace-bottom"

    private var traceScrollKey: String {
        let lastRound = parsed.rounds.last
        return "\(log.count)|\(log.last?.hashValue ?? 0)|\(screenshots.count)|\(lastRound?.actions.count ?? 0)|\(lastRound?.assistant.count ?? 0)"
    }

    private func recomputeVisible() {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        visibleRounds = parsed.rounds.filter { round in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .actions:
                matchesFilter = !round.actions.isEmpty
            case .errors:
                matchesFilter = round.status == .error
            case .steers:
                matchesFilter = !round.steers.isEmpty
            }
            guard matchesFilter else { return false }
            guard !needle.isEmpty else { return true }
            if round.assistant.lowercased().contains(needle) { return true }
            if round.steers.contains(where: { $0.lowercased().contains(needle) }) { return true }
            if round.notes.contains(where: { $0.lowercased().contains(needle) }) { return true }
            return round.actions.contains {
                $0.summary.lowercased().contains(needle)
                    || $0.result.lowercased().contains(needle)
                    || $0.chips.contains(where: { $0.text.lowercased().contains(needle) })
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if log.isEmpty {
                emptyState
            } else {
                if !compact {
                    controls
                    Divider()
                }
                traceBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: log, initial: true) { _, _ in rebuild() }
        .onChange(of: toolCalls) { _, _ in rebuild() }
        .onChange(of: screenshots) { _, _ in rebuild() }
        .onChange(of: runState) { _, _ in rebuild() }
        .onChange(of: finishedAt) { _, _ in rebuild() }
        .onChange(of: filter) { _, _ in recomputeVisible() }
        .onChange(of: search) { _, _ in recomputeVisible() }
        .sheet(item: $viewingScreenshot) { screenshot in
            MacTraceScreenshotViewer(screenshot: screenshot, liveScreenshot: liveScreenshot)
        }
    }

    private var traceBody: some View {
        ScrollViewReader { proxy in
            Group {
                if #available(macOS 15.0, *) {
                    scrollBody
                        .defaultScrollAnchor(.bottom)
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
                        } action: { _, nearBottom in
                            guard didInitialScroll else { return }
                            if autoScroll != nearBottom { autoScroll = nearBottom }
                        }
                } else {
                    scrollBody
                }
            }
            .onAppear {
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(bottomID, anchor: .bottom)
                    didInitialScroll = true
                }
            }
            .onChange(of: traceScrollKey) { _, _ in
                guard autoScroll else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: visibleRounds.count) { _, _ in
                guard autoScroll else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: search) { _, _ in
                autoScroll = true
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: filter) { _, _ in
                autoScroll = true
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if !autoScroll {
                    Button("Jump to latest") {
                        autoScroll = true
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .padding(10)
                }
            }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(visibleRounds) { round in
                    if round.contextClearedBefore {
                        MacTraceContextDivider()
                            .id("divider-\(round.id)")
                    }
                    MacRoundCard(
                        round: round,
                        isExpanded: isExpanded(round),
                        isSelected: selectedRoundID == round.id,
                        screenshotsByID: parsed.screenshotsByID,
                        onToggle: { toggle(round) },
                        onSelect: {
                            selectedRoundID = round.id
                            traceFocused = true
                        },
                        onOpenScreenshot: { viewingScreenshot = $0 }
                    )
                    .equatable()
                    .id(round.id)
                }
                if parsed.trailingDivider {
                    MacTraceContextDivider()
                        .id("trailing-divider")
                }
                if filter == .all, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let result = parsed.result {
                    MacTraceResultCard(
                        result: result,
                        taskID: taskID,
                        onFollowUp: onFollowUp
                    )
                    .padding(.top, 8)
                    .id(result.id)
                }
                Color.clear.frame(height: 1).id(bottomID)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(minHeight: 80, maxHeight: .infinity)
        .clipped()
        .focusable()
        .focused($traceFocused)
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(KeyEquivalent(" ")) {
            if let selectedRoundID, let round = parsed.rounds.first(where: { $0.id == selectedRoundID }) {
                toggle(round)
            }
            return .handled
        }
        .layoutRegion("Trace")
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(MacTraceFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        if filter == item {
                            Label(item.rawValue, systemImage: "checkmark")
                        } else {
                            Text(item.rawValue)
                        }
                    }
                }
                Divider()
                Button("Collapse all") { collapseAll() }
                Button("Expand all") { expandAll() }
            } label: {
                Label(filter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter trace")

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search trace", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(DesignTokens.Surface.input, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .layoutPriority(2)
        .layoutRegion("TraceFilters")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No activity yet").font(.callout.weight(.medium))
            Text("Describe a task below, or start with one of these.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if showSuggestions {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], spacing: 6) {
                    ForEach(["Summarize the attached PDF", "Open Safari and find today's weather", "Rename the files in BUU Artifacts"], id: \.self) { suggestion in
                        Button(suggestion) { onSuggestion(suggestion) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func rebuild() {
        parsed = MacTraceParser.parse(
            log: log,
            toolCalls: toolCalls,
            screenshots: screenshots,
            runState: runState,
            runStartedAt: runStartedAt,
            finishedAt: finishedAt
        )
        roundIndexByID = Dictionary(uniqueKeysWithValues: parsed.rounds.enumerated().map { ($0.element.id, $0.offset) })
        recomputeVisible()
        if let last = parsed.rounds.last, selectedRoundID == nil {
            selectedRoundID = last.id
        }
    }

    private func isExpanded(_ round: MacTraceRound) -> Bool {
        if collapsedRoundIDs.contains(round.id) { return false }
        if expandedRoundIDs.contains(round.id) { return true }
        guard let index = roundIndexByID[round.id] else { return true }
        return index >= parsed.rounds.count - 3
    }

    private func toggle(_ round: MacTraceRound) {
        if isExpanded(round) {
            expandedRoundIDs.remove(round.id)
            collapsedRoundIDs.insert(round.id)
        } else {
            collapsedRoundIDs.remove(round.id)
            expandedRoundIDs.insert(round.id)
        }
    }

    private func collapseAll() {
        collapsedRoundIDs = Set(parsed.rounds.map(\.id))
        expandedRoundIDs = []
    }

    private func expandAll() {
        expandedRoundIDs = Set(parsed.rounds.map(\.id))
        collapsedRoundIDs = []
    }

    private func moveSelection(_ offset: Int) {
        let rounds = visibleRounds
        guard !rounds.isEmpty else { return }
        let current = selectedRoundID.flatMap { id in rounds.firstIndex(where: { $0.id == id }) }
        let next = min(max((current ?? rounds.count - 1) + offset, 0), rounds.count - 1)
        selectedRoundID = rounds[next].id
        autoScroll = true
    }
}

private struct MacTraceContextDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Divider()
            Text("Context cleared")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            Divider()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Trace – round cards") {
    MacTraceTabView(
        log: [
            "Round 1",
            "Assistant: Opening the report. **What happened:** I checked the PDF.",
            "→ vm_status",
            "  vm=running\nready=true\nscreenRecording=true\naccessibility=true\nscreen=1280x800 [120 ms]",
            "→ vm_click",
            "  Clicked 63,244. [364 ms]",
            "→ vm_screenshot",
            "  Screenshot captured (1280x800). [88 ms]",
            "Round 2",
            "Assistant: The table is visible.",
            "→ vm_type",
            "  Typed 60 characters. [240 ms]",
            "Error: Could not open the next page.",
        ],
        screenshots: [],
        runState: .finished,
        runStartedAt: Date().addingTimeInterval(-12),
        finishedAt: Date(),
        taskID: nil
    )
    .frame(width: 460, height: 520)
    .environment(AppState())
    .preferredColorScheme(.dark)
}
#endif

#if DEBUG
#Preview("Trace – deduped context clears") {
    MacTraceTabView(
        log: [
            "Round 1",
            "Assistant: First round.",
            "Context cleared",
            "Context cleared",
            "Round 2",
            "Assistant: Second round after one deduped divider.",
            "Context cleared",
        ],
        runState: .finished,
        runStartedAt: Date().addingTimeInterval(-5),
        finishedAt: Date(),
        taskID: nil
    )
    .frame(width: 460, height: 360)
    .environment(AppState())
    .preferredColorScheme(.light)
}
#endif
