import AppKit
import SwiftUI
import BUUKit

/// Named virtual-Mac recipes used by Mac Tasks.
struct MacTaskSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedID: UUID?
    @State private var restoreImageError: String?
    @State private var confirmingDeleteVM = false

    private var configurations: [MacTaskConfiguration] {
        appState.macTaskConfigurations
    }

    private var selected: MacTaskConfiguration? {
        guard let selectedID else { return nil }
        return configurations.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Picker("Configuration", selection: $selectedID) {
                    ForEach(configurations) { configuration in
                        Text(configuration.name).tag(Optional(configuration.id))
                    }
                }
                .frame(maxWidth: 260)

                Button("Add") {
                    selectedID = appState.addMacTaskConfiguration()
                }

                if let selected {
                    Button("Duplicate") {
                        selectedID = appState.duplicateMacTaskConfiguration(selected.id)
                    }

                    Button("Delete", role: .destructive) {
                        appState.removeMacTaskConfiguration(selected.id)
                        selectedID = appState.settings.activeMacTaskConfigurationID
                            ?? appState.macTaskConfigurations.first?.id
                    }

                    Spacer()

                    if appState.settings.activeMacTaskConfigurationID == selected.id {
                        Label("Default", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.success)
                    } else {
                        Button("Set as default") {
                            appState.selectMacTaskConfiguration(selected.id)
                        }
                    }
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)

            Divider()

            if let selected {
                Form {
                    Section("Mac Task") {
                        TextField("Name", text: stringBinding(selected, \.name, default: ""))
                        TextField("Virtual machine name", text: stringBinding(selected, \.machineName, default: "default"))
                        Text("The VM name is the folder name under Application Support/BUU/VirtualMacs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: Theme.Spacing.s) {
                            TextField("Restore image (.ipsw) or folder", text: restoreImageBinding(selected))
                            Button("Choose…") { chooseRestoreImage(for: selected.id) }
                            if selected.restoreImagePath != nil {
                                Button("Clear") {
                                    update(selected.id) { $0.restoreImagePath = nil }
                                    restoreImageError = nil
                                }
                            }
                        }
                        if let restoreImageError {
                            Text(restoreImageError)
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.danger)
                        } else {
                            Text("Leave empty to download Apple's latest compatible macOS image when this task is first created.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        TextField("Description", text: optionalStringBinding(selected, \.profileDescription), axis: .vertical)
                            .lineLimit(2...4)
                        HStack(spacing: Theme.Spacing.s) {
                            Text("\(selected.macOSVersion ?? "macOS") · \(selected.cpus) CPU · \(selected.memoryGiB) GB RAM · \(selected.diskGiB) GB disk")
                            Spacer()
                            Text("\(appState.macTaskUsageCount(configurationID: selected.id)) task(s)")
                            if let lastUsed = selected.lastUsedAt {
                                Text("last used \(lastUsed.formatted(date: .abbreviated, time: .shortened))")
                            } else {
                                Text("never used")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Section("Software") {
                        TextField("macOS version", text: optionalStringBinding(selected, \.macOSVersion))
                        Picker("Architecture", selection: optionalStringBinding(selected, \.architecture, default: "arm64")) {
                            Text("Apple Silicon (arm64)").tag("arm64")
                        }
                        Picker("Image type", selection: optionalStringBinding(selected, \.imageType, default: "ipsw")) {
                            Text(".ipsw restore image").tag("ipsw")
                            Text("Image file").tag("image")
                            Text("Folder").tag("folder")
                        }
                        TextField("VM storage location", text: optionalStringBinding(selected, \.storageLocation))
                    }

                    warningsSection(selected)

                    Section("Resources") {
                        Stepper("CPUs: \(selected.cpus)", value: intBinding(selected, \.cpus), in: 1...32)
                        Stepper("Memory: \(selected.memoryGiB) GiB", value: intBinding(selected, \.memoryGiB), in: 2...128, step: 1)
                        Stepper("Disk: \(selected.diskGiB) GiB", value: intBinding(selected, \.diskGiB), in: 32...2048, step: 16)
                        Stepper(
                            "Artifact transfer limit: \(selected.artifactTransferLimitGiB ?? 2) GiB",
                            value: Binding(
                                get: { appState.macTaskConfigurations.first { $0.id == selected.id }?.artifactTransferLimitGiB ?? 2 },
                                set: { value in update(selected.id) { $0.artifactTransferLimitGiB = value } }
                            ),
                            in: 1...16
                        )
                    }

                    Section("Display") {
                        Stepper("Width: \(selected.width) points", value: intBinding(selected, \.width), in: 800...3840, step: 16)
                        Stepper("Height: \(selected.height) points", value: intBinding(selected, \.height), in: 600...2160, step: 16)
                        Picker("Scale", selection: intBinding(selected, \.scale)) {
                            Text("Standard (1x)").tag(1)
                            Text("Retina (2x)").tag(2)
                        }
                    }

                    Section("Network") {
                        Toggle("Guest has network access", isOn: boolBinding(selected, \.network))
                        Toggle("Share host tools folder", isOn: optionalBoolBinding(selected, \.sharedFolderEnabled, default: true))
                        Picker("Graphics", selection: optionalStringBinding(selected, \.graphicsMode, default: "automatic")) {
                            Text("Automatic").tag("automatic")
                            Text("Software").tag("software")
                        }
                        Text("Network is needed for macOS setup and most tasks. Disable it for an offline guest.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Virtual machine files") {
                        let installed = appState.virtualMac.machines.contains { $0.name == selected.machineName }
                        Button("Delete VM files…", role: .destructive) {
                            confirmingDeleteVM = true
                        }
                        .disabled(!installed || appState.virtualMac.vmState != "stopped")
                        Text(installed
                             ? "Deletes the VM disk and hardware files. The configuration profile stays and can create a new VM."
                             : "No VM exists yet for this configuration name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Add a Mac Task configuration to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            appState.virtualMac.refreshMachines()
            if selectedID == nil {
                selectedID = appState.settings.activeMacTaskConfigurationID
                    ?? configurations.first?.id
            }
        }
        .confirmationDialog(
            "Delete virtual machine files?",
            isPresented: $confirmingDeleteVM,
            presenting: selected
        ) { configuration in
            Button("Delete \(configuration.machineName)", role: .destructive) {
                do {
                    try appState.virtualMac.deleteMachine(name: configuration.machineName)
                    restoreImageError = nil
                } catch {
                    restoreImageError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { configuration in
            Text("This permanently deletes \(configuration.machineName)'s disk and hardware files. The configuration remains.")
        }
    }

    @ViewBuilder
    private func warningsSection(_ configuration: MacTaskConfiguration) -> some View {
        let warnings = warnings(for: configuration)
        if !warnings.isEmpty {
            Section("Warnings") {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
        }
    }

    private func warnings(for configuration: MacTaskConfiguration) -> [String] {
        var warnings: [String] = []
        if configuration.cpus > ProcessInfo.processInfo.activeProcessorCount {
            warnings.append("CPU count exceeds this Mac's \(ProcessInfo.processInfo.activeProcessorCount) logical cores.")
        }
        let hostRAM = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        if configuration.memoryGiB > hostRAM {
            warnings.append("Memory exceeds this Mac's installed \(hostRAM) GB.")
        }
        if let path = configuration.restoreImagePath, !path.isEmpty,
           !FileManager.default.fileExists(atPath: path) {
            warnings.append("The restore image path does not exist.")
        }
        if let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            let required = Int64(configuration.diskGiB) * 1_073_741_824
            if free < required {
                warnings.append("Only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free; the disk setting is \(configuration.diskGiB) GB.")
            }
        }
        if configuration.width < 800 || configuration.height < 600 {
            warnings.append("The display is smaller than the recommended 800×600 minimum.")
        }
        return warnings
    }

    private func optionalStringBinding(
        _ configuration: MacTaskConfiguration,
        _ keyPath: WritableKeyPath<MacTaskConfiguration, String?>,
        default defaultValue: String = ""
    ) -> Binding<String> {
        Binding(
            get: {
                appState.macTaskConfigurations.first { $0.id == configuration.id }?[keyPath: keyPath]
                    ?? defaultValue
            },
            set: { value in update(configuration.id) { $0[keyPath: keyPath] = value.isEmpty ? nil : value } }
        )
    }

    private func optionalBoolBinding(
        _ configuration: MacTaskConfiguration,
        _ keyPath: WritableKeyPath<MacTaskConfiguration, Bool?>,
        default defaultValue: Bool
    ) -> Binding<Bool> {
        Binding(
            get: {
                appState.macTaskConfigurations.first { $0.id == configuration.id }?[keyPath: keyPath]
                    ?? defaultValue
            },
            set: { value in update(configuration.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ id: UUID, _ mutate: (inout MacTaskConfiguration) -> Void) {
        guard var configuration = appState.macTaskConfigurations.first(where: { $0.id == id }) else {
            return
        }
        mutate(&configuration)
        appState.updateMacTaskConfiguration(configuration)
    }

    private func stringBinding(
        _ configuration: MacTaskConfiguration,
        _ keyPath: WritableKeyPath<MacTaskConfiguration, String>,
        default defaultValue: String
    ) -> Binding<String> {
        Binding(
            get: {
                appState.macTaskConfigurations.first { $0.id == configuration.id }?[keyPath: keyPath]
                    ?? defaultValue
            },
            set: { value in update(configuration.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func intBinding(
        _ configuration: MacTaskConfiguration,
        _ keyPath: WritableKeyPath<MacTaskConfiguration, Int>
    ) -> Binding<Int> {
        Binding(
            get: {
                appState.macTaskConfigurations.first { $0.id == configuration.id }?[keyPath: keyPath]
                    ?? configuration[keyPath: keyPath]
            },
            set: { value in update(configuration.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func boolBinding(
        _ configuration: MacTaskConfiguration,
        _ keyPath: WritableKeyPath<MacTaskConfiguration, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: {
                appState.macTaskConfigurations.first { $0.id == configuration.id }?[keyPath: keyPath]
                    ?? configuration[keyPath: keyPath]
            },
            set: { value in update(configuration.id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func restoreImageBinding(_ configuration: MacTaskConfiguration) -> Binding<String> {
        Binding(
            get: {
                appState.macTaskConfigurations.first { $0.id == configuration.id }?.restoreImagePath ?? ""
            },
            set: { value in
                update(configuration.id) { $0.restoreImagePath = value.isEmpty ? nil : value }
            }
        )
    }

    private func chooseRestoreImage(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose a macOS restore image or folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        restoreImageError = nil
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )) ?? []
            if let image = contents
                .filter({ $0.pathExtension.lowercased() == "ipsw" })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                .first {
                update(id) { $0.restoreImagePath = image.path }
            } else {
                restoreImageError = "No .ipsw restore image was found in \(url.lastPathComponent)."
            }
        } else {
            update(id) { $0.restoreImagePath = url.path }
        }
    }
}
