import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BUUKit

struct MacArtifactsTabView: View {
    @Environment(AppState.self) private var appState
    var taskID: UUID
    @State private var showingInfo = false
    @State private var error: String?

    private var task: AgenticTaskRecord? { appState.activeAgenticTask }
    private var artifacts: [TaskArtifact] { appState.macArtifacts(for: taskID) }
    private var guestRoot: String { appState.macArtifactFolders?.artifactsRoot ?? "~/Desktop/BUU Artifacts" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Add files…", action: addFiles)
                    .controlSize(.small)
                Button {
                    showingInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingInfo) {
                    Text("Files are copied into the guest's \(guestRoot). The host keeps its own copy; the guest never gets write access to the host original.")
                        .font(.callout)
                        .padding(12)
                        .frame(width: 300)
                }
                Spacer()
                if !artifacts.isEmpty {
                    Text("\(artifacts.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if artifacts.isEmpty {
                Text("Drop files here or use Add files to make them available inside the guest.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(artifacts) { artifact in
                            artifactRow(artifact)
                        }
                    }
                    .padding(8)
                }
            }
            if !artifacts.isEmpty {
                Divider()
                Text("In VM: \(guestRoot)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red).padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            add(urls)
            return true
        }
    }

    private func artifactRow(_ artifact: TaskArtifact) -> some View {
        let hostURL = appState.artifactURL(for: artifact, taskID: taskID)
        let progress = appState.macArtifactProgress[artifact.id] ?? artifact.guestProgress
        return HStack(spacing: 8) {
            Image(systemName: icon(for: artifact.name)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name).font(.callout).lineLimit(1)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file))
                        .font(.caption2).foregroundStyle(.tertiary)
                    stateChip(artifact, progress: progress)
                }
            }
            Spacer()
            if artifact.guestState == .failed {
                Button("Retry") {
                    Task { await appState.syncMacArtifact(taskID: taskID, artifactID: artifact.id, announce: false) }
                }
                .controlSize(.small)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([hostURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(hostURL.path)
            Button {
                Task { await appState.removeMacArtifactEverywhere(artifact.id, for: taskID) }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from host and guest")
        }
        .padding(8)
        .background(DesignTokens.Surface.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stateChip(_ artifact: TaskArtifact, progress: Double?) -> some View {
        switch artifact.guestState ?? .queued {
        case .queued:
            MacStatusChip(text: "Queued", color: .secondary, systemImage: "clock")
        case .copying:
            MacStatusChip(text: "Copying \(Int((progress ?? 0) * 100))%", color: .orange, systemImage: "arrow.up.circle")
        case .inGuest:
            MacStatusChip(text: "In VM", color: .green, systemImage: "checkmark.circle")
        case .opened:
            MacStatusChip(text: "Opened", color: .green, systemImage: "macwindow")
        case .modified:
            MacStatusChip(text: "Modified", color: .orange, systemImage: "pencil")
        case .failed:
            MacStatusChip(text: "Failed", color: .red, systemImage: "exclamationmark.triangle")
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach files to this Mac Task"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        Task {
            do {
                try await appState.addMacArtifactsAndSync(urls, for: taskID)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func icon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "tif", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "swift", "py", "js", "ts", "sh": return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz": return "archivebox"
        default: return "doc"
        }
    }
}

struct MacOutputsTabView: View {
    @Environment(AppState.self) private var appState
    var taskID: UUID
    @State private var error: String?

    private var outputs: [TaskOutput] { appState.macOutputs(for: taskID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files saved in the guest's BUU Outputs folder appear here live.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await appState.refreshMacOutputs(taskID: taskID) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh outputs")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if outputs.isEmpty {
                Text("No outputs yet. Files saved in the VM's BUU Outputs folder show up here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(outputs) { output in
                            outputRow(output)
                        }
                    }
                    .padding(8)
                }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red).padding(8)
            }
        }
    }

    private func outputRow(_ output: TaskOutput) -> some View {
        let hostURL = appState.artifactStore.outputsDirectory(for: taskID).appendingPathComponent(output.hostFileName)
        return HStack(spacing: 8) {
            Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(output.name).font(.callout).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(output.byteCount), countStyle: .file))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                QuickLookPresenter.shared.present(hostURL)
            } label: { Image(systemName: "eye") }
                .buttonStyle(.borderless).help("Quick Look")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([hostURL])
            } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Reveal on host")
            Button("Export") { export(output, hostURL: hostURL) }
                .controlSize(.small)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output.guestPath, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy guest path")
        }
        .padding(8)
        .background(DesignTokens.Surface.card, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.medium))
    }

    private func export(_ output: TaskOutput, hostURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = output.hostFileName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: hostURL, to: destination)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview("Artifacts tab – dark") {
    MacArtifactsTabView(taskID: UUID())
        .environment(AppState())
        .frame(width: 460, height: 380)
        .preferredColorScheme(.dark)
}

#Preview("Outputs tab – light") {
    MacOutputsTabView(taskID: UUID())
        .environment(AppState())
        .frame(width: 460, height: 380)
        .preferredColorScheme(.light)
}
