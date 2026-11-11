import AppKit
import SwiftUI
import Virtualization
import VirtualMacKit
import VirtualMacCore
import BUUKit

struct MacDisplaySurface: View {
    let machine: VZVirtualMachine?
    let screenshot: NSImage?
    let aspectRatio: CGFloat
    let state: String
    let isBusy: Bool
    let onStart: () -> Void
    let onOpenWindow: () -> Void

    var body: some View {
        ZStack {
            DesignTokens.Surface.backdrop
            if let machine {
                EmbeddedVirtualMachineView(machine: machine)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(DesignTokens.Space.s)
            } else if let screenshot {
                Image(nsImage: screenshot)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(DesignTokens.Space.s)
                    .overlay(alignment: .bottomTrailing) {
                        Text("External VM")
                            .font(.caption2)
                            .padding(4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                    }
            } else {
                VStack(spacing: DesignTokens.Space.s) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(state == "stopped" ? "Virtual Mac is stopped" : "Starting virtual Mac…")
                        .font(.headline)
                    Text("The guest is a separate macOS instance. Host screen and input are never used.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    HStack(spacing: DesignTokens.Space.xs) {
                        if state == "stopped" {
                            Button("Start", action: onStart)
                                .buttonStyle(.borderedProminent)
                        } else if isBusy {
                            ProgressView().controlSize(.small)
                        }
                        if machine != nil {
                            Button("Open in Window", action: onOpenWindow)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(DesignTokens.Space.l)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            Label("Isolated guest", systemImage: "lock.shield")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .help("Host screen and input are never used. Every guest action goes through the guest helper.")
        }
        .clipped()
    }
}

enum MacGuestCondition: Equatable {
    case ready
    case stopped
    case helperNotResponding
    case screenRecording
    case accessibility
    case error
}

struct MacStatusPill: View {
    var runState: MacRunState
    var vmState: String
    var condition: MacGuestCondition
    var guestReady: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullLabel
            compactLabel
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Run status"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var fullLabel: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var compactLabel: some View {
        Image(systemName: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 24)
            .background(color.opacity(0.13), in: Capsule())
            .accessibilityLabel(Text(text))
    }

    private var text: String {
        switch runState {
        case .running:
            switch condition {
            case .ready: return "Running · Guest ready"
            case .helperNotResponding: return "Running · Waiting for helper"
            case .screenRecording: return "Running · Screen Recording needed"
            case .accessibility: return "Running · Accessibility needed"
            case .error: return "Running · Guest error"
            case .stopped: return "Running · Guest stopped"
            }
        case .paused:
            return condition == .ready ? "Paused · Guest ready" : "Paused · Waiting for helper"
        case .finished:
            return "Finished"
        case .failed:
            return "Failed"
        case .idle:
            switch condition {
            case .error: return "Error"
            case .stopped: return "Stopped"
            case .helperNotResponding: return "Guest waiting"
            case .screenRecording: return "Screen Recording needed"
            case .accessibility: return "Accessibility needed"
            case .ready: return vmState.capitalized
            }
        }
    }

    private var icon: String {
        switch runState {
        case .running: return condition == .ready ? "play.fill" : "exclamationmark.triangle.fill"
        case .paused: return "pause.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle:
            switch condition {
            case .error, .helperNotResponding, .screenRecording, .accessibility: return "exclamationmark.triangle.fill"
            case .ready, .stopped: return "circle.fill"
            }
        }
    }

    private var color: Color {
        switch runState {
        case .running: return condition == .ready ? .green : .orange
        case .paused: return .orange
        case .finished: return .green
        case .failed: return .red
        case .idle:
            switch condition {
            case .error: return .red
            case .helperNotResponding, .screenRecording, .accessibility: return .orange
            case .ready, .stopped: return .secondary
            }
        }
    }

    private var accessibilityValue: String {
        switch runState {
        case .running: return guestReady ? "Running, guest ready" : "Running, waiting for the guest helper"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .idle:
            switch condition {
            case .ready: return "Idle, \(vmState)"
            case .stopped: return "Stopped"
            case .error: return "Error"
            case .helperNotResponding: return "Idle, guest helper not responding"
            case .screenRecording: return "Idle, Screen Recording permission needed"
            case .accessibility: return "Idle, Accessibility permission needed"
            }
        }
    }
}

struct MacBlockingBanner: View {
    var title: String
    var message: String
    var onRetry: () -> Void
    var onViewLog: () -> Void
    var onOpenSetup: () -> Void
    var onDismiss: () -> Void
    var setupButtonTitle: String = "Open guided setup"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Retry connection", action: onRetry).controlSize(.small)
                    Button("View log", action: onViewLog).controlSize(.small)
                    Button(setupButtonTitle, action: onOpenSetup).controlSize(.small)
                }
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss guest warning")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        }
    }
}

struct MacGuestDetailsPopover: View {
    var vmName: String
    var state: String
    var machine: Machine?
    var guest: VirtualMacGuestStatus?
    var condition: MacGuestCondition
    var startedAt: Date?
    var lastUpdated: Date?
    var onRetry: () -> Void
    var onViewLog: () -> Void
    var onOpenSetup: () -> Void
    var setupButtonTitle: String = "Open guided setup"

    private var helperNeeded: Bool { condition == .helperNotResponding }
    private var screenNeeded: Bool { condition == .screenRecording }
    private var accessibilityNeeded: Bool { condition == .accessibility }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(vmName).font(.headline)
                    Text(state.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let lastUpdated {
                    Text(lastUpdated.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Guest helper", guest?.isReady == true ? "Ready" : "Waiting")
                row("IP", ipText)
                if let startedAt { row("Uptime", uptime(from: startedAt)) }
                if let machine {
                    row("CPU", "\(machine.cpu) cores")
                    row("Memory", "\(machine.memoryGiB) GB")
                    row("Disk", "\(machine.diskGiB) GB")
                }
                row("Screen Recording", guest?.screenRecording == true ? "Allowed" : "Needed")
                row("Accessibility", guest?.accessibility == true ? "Allowed" : "Needed")
            }
            .font(.caption)
            if helperNeeded || screenNeeded || accessibilityNeeded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if helperNeeded {
                        Text("The guest helper is not reporting permissions. Open the helper in the guest and allow access.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if screenNeeded || accessibilityNeeded {
                        Text("Open the guest helper and allow the missing permission.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Retry connection", action: onRetry).controlSize(.small)
                        Button("View log", action: onViewLog).controlSize(.small)
                        Button(setupButtonTitle, action: onOpenSetup).controlSize(.small)
                    }
                }
            }
            Divider()
            Label("Isolated guest: host screen and input are never used.", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Space.s)
        .frame(width: 310)
    }

    private var ipText: String {
        let value = guest?.ip ?? ""
        return value.isEmpty ? "NAT / unavailable" : value
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func uptime(from start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

#Preview("Display surface – dark") {
    MacDisplaySurface(machine: nil, screenshot: nil, aspectRatio: 1.6, state: "stopped", isBusy: false, onStart: {}, onOpenWindow: {})
        .frame(width: 760, height: 480)
        .preferredColorScheme(.dark)
}

#Preview("Toolbar status – light") {
    MacStatusPill(runState: .running, vmState: "running", condition: .ready, guestReady: true)
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Toolbar status – waiting") {
    MacStatusPill(runState: .running, vmState: "running", condition: .helperNotResponding, guestReady: false)
        .padding()
        .preferredColorScheme(.dark)
}

#Preview("Toolbar status – stopped") {
    MacStatusPill(runState: .idle, vmState: "stopped", condition: .stopped, guestReady: false)
        .padding()
        .preferredColorScheme(.light)
}

#Preview("Guest details – healthy") {
    MacGuestDetailsPopover(
        vmName: "NMac",
        state: "running",
        machine: Machine(name: "NMac", cpu: 6, memoryGiB: 8, diskGiB: 64, installed: true),
        guest: VirtualMacGuestStatus(values: [
            "screenRecording": "true",
            "accessibility": "true",
            "width": "1280",
            "height": "800",
            "artifactSupport": "true",
            "ip": "192.168.64.2",
        ]),
        condition: .ready,
        startedAt: Date().addingTimeInterval(-420),
        lastUpdated: Date(),
        onRetry: {},
        onViewLog: {},
        onOpenSetup: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Guest details – permissions needed") {
    MacGuestDetailsPopover(
        vmName: "NMac",
        state: "running",
        machine: Machine(name: "NMac", cpu: 6, memoryGiB: 8, diskGiB: 64, installed: true),
        guest: VirtualMacGuestStatus(values: [
            "screenRecording": "false",
            "accessibility": "false",
            "width": "1280",
            "height": "800",
        ]),
        condition: .screenRecording,
        startedAt: Date().addingTimeInterval(-90),
        lastUpdated: Date(),
        onRetry: {},
        onViewLog: {},
        onOpenSetup: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Blocking banner") {
    MacBlockingBanner(
        title: "Accessibility permission is needed",
        message: "Open the guest helper and allow Accessibility. The agent cannot click or type until it is granted.",
        onRetry: {},
        onViewLog: {},
        onOpenSetup: {},
        onDismiss: {}
    )
    .padding()
    .frame(width: 620)
    .preferredColorScheme(.dark)
}

#Preview("Run states") {
    VStack(alignment: .leading, spacing: 8) {
        MacStatusPill(runState: .idle, vmState: "stopped", condition: .stopped, guestReady: false)
        MacStatusPill(runState: .running, vmState: "running", condition: .ready, guestReady: true)
        MacStatusPill(runState: .running, vmState: "running", condition: .helperNotResponding, guestReady: false)
        MacStatusPill(runState: .paused, vmState: "running", condition: .screenRecording, guestReady: false)
        MacStatusPill(runState: .finished, vmState: "running", condition: .ready, guestReady: true)
        MacStatusPill(runState: .failed, vmState: "running", condition: .error, guestReady: true)
    }
    .padding()
    .preferredColorScheme(.dark)
}
