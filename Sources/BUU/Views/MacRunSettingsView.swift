import SwiftUI
import BUUKit

struct MacModelChip: View {
    @Environment(AppState.self) private var appState
    @State private var showingSettings = false

    private var agent: VirtualMacAgentModel { appState.virtualMacAgent }
    private var endpoint: ProviderEndpoint? {
        if let id = agent.selectedEndpointID {
            return appState.settings.endpoints.first { $0.id == id }
        }
        return appState.settings.endpoints.first
    }
    private var missingModel: Bool {
        endpoint == nil || agent.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var modelLabel: String { missingModel ? "Choose a model" : agent.model }

    var body: some View {
        Button {
            showingSettings.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.caption2)
                    .foregroundStyle(missingModel ? Color.orange : Color.secondary)
                Text(modelLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(missingModel ? Color.orange : Color.primary)
                    .frame(minWidth: 120, alignment: .leading)
                if agent.isLoadingModels {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 180, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .fill(missingModel ? Color.orange.opacity(0.12) : DesignTokens.Surface.input)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.small, style: .continuous)
                    .strokeBorder(missingModel ? Color.orange.opacity(0.45) : Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(endpoint?.name ?? "No provider") · \(missingModel ? "No model selected" : agent.model)")
        .accessibilityLabel("Model")
        .accessibilityValue("\(modelLabel), \(endpoint?.name ?? "No provider")")
        .popover(
            isPresented: $showingSettings,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            MacRunSettingsView()
                .environment(appState)
        }
    }
}

struct MacRunSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var modelSearch = ""
    @State private var customRounds = "25"
    @State private var showingCustomRounds = false
    @State private var showingManageProviders = false
    @FocusState private var searchFocused: Bool

    private var agent: VirtualMacAgentModel { appState.virtualMacAgent }
    private var endpoint: ProviderEndpoint? {
        if let id = agent.selectedEndpointID {
            return appState.settings.endpoints.first { $0.id == id }
        }
        return appState.settings.endpoints.first
    }

    private var dedupedModels: [RemoteModel] {
        var seen = Set<String>()
        return agent.availableModels.filter { model in
            seen.insert(model.id.lowercased()).inserted
        }
    }

    private var selectedModel: RemoteModel? {
        if let match = dedupedModels.first(where: { $0.id == agent.model }) { return match }
        guard !agent.model.isEmpty else { return nil }
        return RemoteModel(id: agent.model)
    }

    private var availableModels: [RemoteModel] {
        let needle = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return dedupedModels.filter { model in
            guard model.id != agent.model else { return false }
            guard !needle.isEmpty else { return true }
            return model.id.lowercased().contains(needle) || model.displayName.lowercased().contains(needle)
        }
    }

    private var networkOn: Bool { appState.activeMacTaskConfiguration?.network ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerMenu
            modelSection
            roundsMenu
            Divider()
            networkLine
            Text("Applies to the next run.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
        .controlSize(.small)
        .background(DesignTokens.Surface.panel)
        .onAppear {
            Task { @MainActor in searchFocused = true }
        }
        .task {
            if let endpoint {
                await agent.loadModels(endpoint: endpoint, apiKey: appState.apiKey(for: endpoint))
            }
        }
        .alert("Custom max rounds", isPresented: $showingCustomRounds) {
            TextField("Rounds", text: $customRounds)
            Button("Cancel", role: .cancel) {}
            Button("Set") { setRounds(Int(customRounds)) }
        } message: {
            Text("Use a positive whole number.")
        }
        .sheet(isPresented: $showingManageProviders) {
            SettingsView()
                .environment(appState)
        }
    }

    private var providerMenu: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Provider").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Menu {
                ForEach(appState.settings.endpoints) { item in
                    let status = providerStatus(item)
                    Button {
                        selectProvider(item)
                    } label: {
                        Label {
                            Text(item.name)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(status.color)
                        }
                    }
                }
                Divider()
                Button("Manage providers…") { showingManageProviders = true }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(providerStatus(endpoint).color).frame(width: 7, height: 7)
                    Text(endpoint?.name ?? "No provider")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(DesignTokens.Surface.input, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            }
            .menuStyle(.borderlessButton)
            .help(endpoint?.baseURL ?? "No provider")
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Model").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if agent.isLoadingModels {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    refreshModels()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh models")
                .accessibilityLabel("Refresh models")
            }

            TextField("Search models", text: $modelSearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($searchFocused)
                .foregroundStyle(.primary)

            if let error = agent.modelError {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Spacer(minLength: 4)
                    Button("Retry") { refreshModels() }
                        .controlSize(.small)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let selectedModel {
                        modelRow(selectedModel, selected: true)
                        Divider().padding(.vertical, 2)
                    }
                    ForEach(availableModels) { model in
                        modelRow(model, selected: false)
                    }
                    if availableModels.isEmpty, !agent.isLoadingModels, agent.modelError == nil {
                        Text("No matching models.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 160)

            TextField("Enter model ID manually", text: Binding(
                get: { agent.model },
                set: { agent.model = String($0.prefix(200)) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }

    private func modelRow(_ model: RemoteModel, selected: Bool) -> some View {
        Button {
            agent.model = model.id
        } label: {
            HStack(spacing: 6) {
                Text(model.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if selected {
                    Text("Selected").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.id)
        .accessibilityLabel(model.displayName)
        .accessibilityValue(selected ? "Selected" : "Available")
    }

    private var roundsMenu: some View {
        HStack(spacing: 8) {
            Text("Max rounds").foregroundStyle(.secondary)
            Spacer()
            Menu(roundsLabel) {
                Button("Unlimited") { setRounds(nil) }
                Button("10") { setRounds(10) }
                Button("25") { setRounds(25) }
                Button("50") { setRounds(50) }
                Button("100") { setRounds(100) }
                Divider()
                Button("Custom…") {
                    customRounds = String(effectiveRounds ?? 25)
                    showingCustomRounds = true
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var networkLine: some View {
        HStack(spacing: 6) {
            Text("Guest network:")
                .foregroundStyle(.secondary)
            Text(networkOn ? "On" : "Off")
            Spacer(minLength: 4)
            Button("Change in Configuration") {
                dismiss()
                appState.macWorkspaceTabRequest = .configuration
                appState.macPanelSectionRequest = nil
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
        }
        .font(.caption)
    }

    private var effectiveRounds: Int? {
        guard let id = appState.activeAgenticTask?.id,
              let value = appState.maxAgentRounds(for: id), value > 0 else { return nil }
        return value
    }

    private var roundsLabel: String {
        effectiveRounds.map { "\($0)" } ?? "Unlimited"
    }

    private func selectProvider(_ item: ProviderEndpoint) {
        agent.selectedEndpointID = item.id
        agent.model = item.defaultModel
        Task { await agent.loadModels(endpoint: item, apiKey: appState.apiKey(for: item)) }
    }

    private func refreshModels() {
        guard let endpoint else { return }
        Task { await agent.loadModels(endpoint: endpoint, apiKey: appState.apiKey(for: endpoint)) }
    }

    private func setRounds(_ value: Int?) {
        guard let id = appState.activeAgenticTask?.id else { return }
        if let value, value <= 0 { return }
        appState.setMaxAgentRounds(value, for: id)
    }

    private func providerStatus(_ endpoint: ProviderEndpoint?) -> (color: Color, label: String) {
        guard let endpoint else { return (.secondary, "No provider") }
        if endpoint.authStyle != .none, appState.apiKey(for: endpoint).isEmpty {
            return (.orange, "Missing API key")
        }
        if let status = appState.endpointStatus[endpoint.id], !status.isEmpty {
            if status.localizedCaseInsensitiveContains("error")
                || status.localizedCaseInsensitiveContains("failed")
                || status.hasPrefix("HTTP ") {
                return (.red, status)
            }
            return (.green, status)
        }
        return (.secondary, "Not checked")
    }
}

#if DEBUG
private struct MacRunSettingsPreviewHost: View {
    @State private var appState = AppState()
    let configure: (AppState) -> Void

    var body: some View {
        MacRunSettingsView()
            .environment(appState)
            .onAppear { configure(appState) }
    }
}

private struct MacModelChipPreviewHost: View {
    @State private var appState = AppState()
    let configure: (AppState) -> Void

    var body: some View {
        MacModelChip()
            .environment(appState)
            .padding()
            .onAppear { configure(appState) }
    }
}

#Preview("Model chip – missing model") {
    MacModelChipPreviewHost { app in
        app.virtualMacAgent.model = ""
    }
    .preferredColorScheme(.dark)
}

#Preview("Model chip – normal") {
    MacModelChipPreviewHost { app in
        app.virtualMacAgent.model = "qwen2.5-coder-32b-instruct"
    }
    .preferredColorScheme(.light)
}

#Preview("Model chip – truncated") {
    MacModelChipPreviewHost { app in
        app.virtualMacAgent.model = "deepseek-reasoner-2025-01-very-long-model-identifier"
    }
    .preferredColorScheme(.dark)
}

#Preview("Model chip – loading") {
    MacModelChipPreviewHost { app in
        app.virtualMacAgent.model = ""
        app.virtualMacAgent.isLoadingModels = true
    }
    .preferredColorScheme(.dark)
}

#Preview("Run settings – loaded") {
    MacRunSettingsPreviewHost { app in
        app.virtualMacAgent.model = "qwen2.5-coder-32b-instruct"
        app.virtualMacAgent.availableModels = [
            RemoteModel(id: "qwen2.5-coder-32b-instruct", displayName: "Qwen 2.5 Coder 32B"),
            RemoteModel(id: "qwen2.5-coder-32b-instruct", displayName: "Qwen 2.5 Coder 32B duplicate"),
            RemoteModel(id: "llama-3.3-70b", displayName: "Llama 3.3 70B"),
        ]
    }
    .preferredColorScheme(.dark)
}

#Preview("Run settings – loading") {
    MacRunSettingsPreviewHost { app in
        app.virtualMacAgent.isLoadingModels = true
    }
    .preferredColorScheme(.light)
}

#Preview("Run settings – error") {
    MacRunSettingsPreviewHost { app in
        app.virtualMacAgent.modelError = "The server did not respond. Check the provider URL and API key."
    }
    .preferredColorScheme(.dark)
}

#Preview("Run settings – manual entry") {
    MacRunSettingsPreviewHost { app in
        app.virtualMacAgent.model = ""
        app.virtualMacAgent.availableModels = []
    }
    .preferredColorScheme(.light)
}
#endif
