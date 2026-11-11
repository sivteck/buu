import AppKit
import SwiftUI
import BUUKit

struct MacTraceSettingsView: View {
    @Environment(AppState.self) private var appState

    private var folderPath: String {
        appState.macTraceAutosaveFolderURL?.path ?? "Not configured"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Trace Autosave")
                        .font(.title2.weight(.semibold))
                    Text("Archive every Mac Task trace into outcome folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
            .background(.bar)

            Divider()

            Form {
                Section("Destination") {
                    LabeledContent("Folder") {
                        Text(folderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: Theme.Spacing.s) {
                        Button("Choose Folder…") { chooseFolder() }
                        if appState.macTraceAutosaveFolderURL != nil {
                            Button("Reveal in Finder") {
                                if let url = appState.macTraceAutosaveFolderURL {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                            Button("Stop Autosaving", role: .destructive) {
                                appState.setMacTraceAutosaveFolder(nil)
                            }
                        }
                    }
                    Text("Each run is saved as Markdown, JSON, and screenshot PNGs. Manual Clear context also archives the trace before clearing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Folders") {
                    ForEach(MacTraceOutcome.allCases, id: \.self) { outcome in
                        LabeledContent(outcome.rawValue) {
                            Text(outcomeDetail(outcome))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let message = appState.macTraceAutosaveMessage {
                    Section("Last Archive") {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .background(Theme.Colors.canvas)
    }

    private func outcomeDetail(_ outcome: MacTraceOutcome) -> String {
        switch outcome {
        case .fullySuccessful: return "Completed with no errors in the run tail."
        case .partialSuccess: return "Completed, but the run reported errors or unfinished steering."
        case .failure: return "The run ended with a failure."
        case .stoppedMidway: return "Paused, cancelled, or stopped before completion."
        case .contextCleared: return "The user manually cleared the model context."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Mac trace autosave folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.setMacTraceAutosaveFolder(url)
    }
}
