import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BUUKit

struct NewAgentTaskWizard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var configurationID: UUID?
    @State private var prompt = ""
    @State private var artifactURLs: [URL] = []
    @State private var artifactError: String?
    @State private var createdTaskID: UUID?

    private var configurationOptions: [(id: UUID, name: String)] {
        appState.macTaskConfigurations.map { ($0.id, $0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Configure Mac Task")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(Theme.Spacing.l)

            Divider()

            ScrollView {
                taskForm()
                    .padding(Theme.Spacing.xl)
            }

            Divider()

            HStack {
                Spacer()
                Button("Add to queue instead of running") { enqueueInstead() }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Add this prompt and its files to the current Mac workspace queue")
                Button("Create Task") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.l)
        }
        .frame(width: 620, height: 560)
    }

    private func taskForm() -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Label("macOS Virtual Machine", systemImage: "macwindow.on.rectangle")
            .font(.headline)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Task name")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Task name", text: $title)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Configuration profile")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: Theme.Spacing.s) {
                    Picker("Configuration", selection: $configurationID) {
                        ForEach(configurationOptions, id: \.id) { option in
                            Text(option.name).tag(Optional(option.id))
                        }
                    }
                    .labelsHidden()

                    Button("Create new profile") {
                        configurationID = appState.addMacTaskConfiguration()
                    }
                }
                Text("The profile supplies the VM image, hardware and display settings. You can change it later in the task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Task prompt")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .padding(Theme.Spacing.s)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                            .fill(Theme.Colors.control)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                            .strokeBorder(Theme.Colors.separator, lineWidth: 1)
                    }
                Text("Optional. You can also write or edit the prompt in the task workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            wizardArtifacts
            Text("Use Add to queue instead of running to append this prompt and its files to the current Mac workspace queue.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var wizardArtifacts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Artifacts")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add files…") { chooseWizardArtifacts() }
                    .font(.caption)
            }
            if artifactURLs.isEmpty {
                Text("Optional files copied into the task's model-visible artifact workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(artifactURLs.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            artifactURLs.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let artifactError {
                Text(artifactError)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            let collector = DroppedURLCollector()
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = Self.fileURL(from: item) { collector.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let urls = collector.snapshot()
                Task { @MainActor in
                    let existing = Set(artifactURLs.map(\.standardizedFileURL))
                    artifactURLs.append(contentsOf: urls.filter { !existing.contains($0.standardizedFileURL) })
                    artifactError = nil
                }
            }
            return true
        }
    }

    private func chooseWizardArtifacts() {
        let panel = NSOpenPanel()
        panel.title = "Attach artifacts to this Mac Task"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let existing = Set(artifactURLs.map(\.standardizedFileURL))
        artifactURLs.append(contentsOf: panel.urls.filter { !existing.contains($0.standardizedFileURL) })
        artifactError = nil
    }

    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }

    private func enqueueInstead() {
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptText.isEmpty else {
            artifactError = "Add a prompt before queueing."
            return
        }
        guard let workspace = appState.activeAgenticTask, workspace.kind == .mac else {
            artifactError = "Select a Mac workspace first, or create a new task."
            return
        }
        if let configurationID, configurationID != workspace.configurationID {
            artifactError = "The workspace queue runs in the current Mac workspace. Select its configuration or create a new task."
            return
        }
        do {
            let added: [TaskArtifact]
            if artifactURLs.isEmpty {
                added = []
            } else {
                added = try appState.addMacArtifacts(artifactURLs, for: workspace.id)
            }
            guard appState.enqueueMacTask(
                taskID: workspace.id,
                prompt: promptText,
                attachmentIDs: added.map(\.id),
                providerID: appState.virtualMacAgent.selectedEndpointID,
                model: appState.virtualMacAgent.model.isEmpty ? nil : appState.virtualMacAgent.model,
                maxRounds: appState.maxAgentRounds(for: workspace.id),
                vmStatePolicy: .freshState,
                continueConversation: false
            ) != nil else {
                artifactError = "Could not add the task to the workspace queue."
                return
            }
            if !added.isEmpty {
                Task {
                    for artifact in added {
                        await appState.syncMacArtifact(taskID: workspace.id, artifactID: artifact.id, announce: false)
                    }
                }
            }
            dismiss()
        } catch {
            artifactError = error.localizedDescription
        }
    }

    private func create() {
        let taskID: UUID
        if let createdTaskID {
            taskID = createdTaskID
        } else {
            let configuration = configurationID ?? appState.activeMacTaskConfiguration?.id
            let id = appState.createAgenticTask(
                title: title,
                configurationID: configuration,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
            )
            createdTaskID = id
            taskID = id
        }

        if !artifactURLs.isEmpty {
            do {
                try appState.addMacArtifacts(artifactURLs, for: taskID)
            } catch {
                appState.errorMessage = "The task was created, but an artifact could not be copied: \(error.localizedDescription)"
                dismiss()
                return
            }
        }
        dismiss()
    }
}
