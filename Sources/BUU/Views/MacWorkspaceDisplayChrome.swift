import AppKit
import SwiftUI
import VirtualMacKit
import VirtualMacCore

struct MacVMBar: View {
    var vmName: String
    var state: String
    var startedAt: Date?
    var machine: Machine?
    var runState: MacRunState
    var condition: MacGuestCondition
    var errorCount: Int
    var consoleExpanded: Bool
    var consoleAvailable: Bool = true
    var onStart: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onStop: () -> Void
    var onOpenWindow: () -> Void
    var onToggleConsole: () -> Void

    private var stateLabel: String {
        switch runState {
        case .running: return "Running"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .idle: return state.capitalized
        }
    }

    private var stateColor: Color {
        switch runState {
        case .running: return condition == .ready ? .green : .orange
        case .paused: return .orange
        case .finished: return .green
        case .failed: return .red
        case .idle:
            if state == "stopped" { return .secondary }
            switch condition {
            case .error: return .red
            case .ready: return .green
            default: return .orange
            }
        }
    }

    private var resources: String {
        guard let machine else { return "" }
        return "CPU \(machine.cpu) · RAM \(machine.memoryGiB) GB · Disk \(machine.diskGiB) GB"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            Text("\(stateLabel) · \(vmName)\(uptimeSuffix)")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !resources.isEmpty {
                Text(resources)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
            if state == "stopped" {
                Button("Start", action: onStart).controlSize(.small).buttonStyle(.bordered)
            } else if state == "paused" {
                Button("Resume", action: onResume).controlSize(.small).buttonStyle(.bordered)
                Button("Stop", role: .destructive, action: onStop).controlSize(.small).buttonStyle(.bordered).tint(.red)
            } else if state == "running" {
                Button("Pause", action: onPause).controlSize(.small).buttonStyle(.bordered)
                Button("Stop", role: .destructive, action: onStop).controlSize(.small).buttonStyle(.bordered).tint(.red)
            }
            if state == "running" || state == "paused" {
                Button(action: onOpenWindow) {
                    Image(systemName: "macwindow")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help("Open in Window")
                .accessibilityLabel("Open in Window")
            }
            Button(action: onToggleConsole) {
                HStack(spacing: 4) {
                    Label("Console", systemImage: "terminal")
                    if errorCount > 0 {
                        Text("\(errorCount)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .background(Color.red.opacity(0.15), in: Capsule())
                    }
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(!consoleAvailable)
            .help(consoleAvailable ? "Show VM console (⌘L)" : "The pane is too short for the console drawer")
            .accessibilityLabel("VM console, \(errorCount) errors")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var uptimeSuffix: String {
        guard let startedAt else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        if seconds < 60 { return " · Up \(seconds)s" }
        if seconds < 3600 { return " · Up \(seconds / 60)m" }
        return " · Up \(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

enum MacConsoleSection: String, CaseIterable, Identifiable {
    case vmLog = "VM log"
    case errors = "Errors"
    var id: String { rawValue }
}

struct MacConsoleDrawer: View {
    var vmName: String
    let vmLog: [String]
    let errorLog: [String]
    @Binding var section: MacConsoleSection
    var onCopy: ([String]) -> Void
    var onClear: (MacConsoleSection) -> Void

    private var lines: [String] {
        section == .vmLog ? vmLog : errorLog
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Console", selection: $section) {
                    ForEach(MacConsoleSection.allCases) { section in
                        if section == .errors {
                            Text("Errors \(errorLog.count)")
                                .tag(section)
                        } else {
                            Text(section.rawValue).tag(section)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                Spacer()
                Button("Copy") { onCopy(lines) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(lines.isEmpty)
                Button("Clear", role: .destructive) { onClear(section) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(lines.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(lines.suffix(400).joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("console-bottom")
                }
                .onChange(of: lines.count) { _, _ in
                    proxy.scrollTo("console-bottom", anchor: .bottom)
                }
            }
        }
        .background(DesignTokens.Surface.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("VM console")
    }
}

#Preview("VM bar – running") {
    MacVMBar(
        vmName: "NMac-vm",
        state: "running",
        startedAt: Date().addingTimeInterval(-540),
        machine: Machine(name: "NMac-vm", cpu: 6, memoryGiB: 8, diskGiB: 64, installed: true),
        runState: .running,
        condition: .ready,
        errorCount: 2,
        consoleExpanded: false,
        onStart: {}, onPause: {}, onResume: {}, onStop: {}, onOpenWindow: {}, onToggleConsole: {}
    )
    .frame(width: 720)
    .preferredColorScheme(.dark)
}

#Preview("VM bar – stopped") {
    MacVMBar(
        vmName: "NMac-vm",
        state: "stopped",
        startedAt: nil,
        machine: Machine(name: "NMac-vm", cpu: 6, memoryGiB: 8, diskGiB: 64, installed: true),
        runState: .idle,
        condition: .stopped,
        errorCount: 0,
        consoleExpanded: false,
        onStart: {}, onPause: {}, onResume: {}, onStop: {}, onOpenWindow: {}, onToggleConsole: {}
    )
    .frame(width: 720)
    .preferredColorScheme(.light)
}

#Preview("Console drawer – errors") {
    MacConsoleDrawer(
        vmName: "NMac-vm",
        vmLog: ["VM started", "Guest helper connected", "Round 32 started"],
        errorLog: ["Guest helper timed out", "Accessibility permission missing"],
        section: Binding.constant(MacConsoleSection.errors),
        onCopy: { _ in },
        onClear: { _ in }
    )
    .frame(width: 720, height: 220)
    .preferredColorScheme(.dark)
}
