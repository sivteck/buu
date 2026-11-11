import AppKit
import SwiftUI
import VirtualMacKit
import VirtualMacCore
import BUUKit

struct MacConfigurationTabView: View {
    @Environment(AppState.self) private var appState
    private var vm: VirtualMacController { appState.virtualMac }
    private var configuration: MacTaskConfiguration? { appState.activeMacTaskConfiguration }
    private var locked: Bool { vm.vmState != "stopped" }

    var body: some View {
        Form {
            if let configuration {
                if locked {
                    Section {
                        Label("Stop the VM to change hardware and display settings.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("General") {
                    LabeledContent("Profile") {
                        HStack(spacing: 6) {
                            Text(configuration.name)
                            Spacer()
                            Button("Edit in VM Profiles") {
                                appState.showSettings = true
                                appState.settingsSectionRequest = .vmProfiles
                            }
                            .controlSize(.small)
                        }
                    }
                    LabeledContent("VM name", value: configuration.machineName)
                    LabeledContent("macOS", value: configuration.macOSVersion ?? "Latest compatible")
                    LabeledContent("Architecture", value: configuration.architecture ?? "arm64")
                    LabeledContent("Image", value: configuration.restoreImagePath ?? "Download from Apple")
                }
                Section("Resources") {
                    LabeledContent("CPU") {
                        valueWithLock("\(configuration.cpus) cores")
                    }
                    LabeledContent("Memory") {
                        valueWithLock("\(configuration.memoryGiB) GB")
                    }
                    LabeledContent("Disk") {
                        valueWithLock("\(configuration.diskGiB) GB")
                    }
                    LabeledContent("Artifact transfer limit") {
                        valueWithLock("\(configuration.artifactTransferLimitGiB ?? 2) GB")
                    }
                }
                Section("Network and sharing") {
                    Toggle("Guest network access", isOn: networkBinding)
                        .disabled(locked)
                    if locked {
                        Text("Stop the VM to change guest network access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Shared folder") {
                        HStack(spacing: 6) {
                            Text((configuration.sharedFolderEnabled ?? true) ? "Enabled" : "Disabled")
                            if let path = vm.sharedFolderPath {
                                Text(path)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(path)
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                Section("Display") {
                    LabeledContent("Resolution") {
                        valueWithLock("\(configuration.width) × \(configuration.height)")
                    }
                    LabeledContent("Scale") {
                        valueWithLock(configuration.scale == 2 ? "Retina 2x" : "Standard 1x")
                    }
                    LabeledContent("Graphics", value: configuration.graphicsMode ?? "automatic")
                }
            } else {
                Text("No VM configuration selected.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .background(DesignTokens.Surface.window)
    }

    private var networkBinding: Binding<Bool> {
        Binding(
            get: { configuration?.network ?? true },
            set: { value in
                guard var configuration = configuration else { return }
                configuration.network = value
                appState.updateMacTaskConfiguration(configuration)
            }
        )
    }

    @ViewBuilder
    private func valueWithLock(_ text: String) -> some View {
        HStack(spacing: 5) {
            if locked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(text)
        }
    }
}

#Preview("Configuration – light") {
    MacConfigurationTabView()
        .environment(AppState())
        .frame(width: 620, height: 600)
        .preferredColorScheme(.light)
}
