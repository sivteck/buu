import Foundation
import SwiftUI
import BUUKit

struct EndpointEditorView: View {
    @Environment(AppState.self) private var appState
    let endpointID: UUID

    private var endpoint: ProviderEndpoint? {
        appState.settings.endpoints.first { $0.id == endpointID }
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: binding(\.name, default: ""))
                TextField("Base URL", text: binding(\.baseURL, default: ""))
                Picker("Protocol", selection: binding(\.apiStyle, default: .openAI)) {
                    ForEach(APIStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Picker("Authentication", selection: binding(\.authStyle, default: .bearer)) {
                    ForEach(AuthStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                if endpoint?.authStyle == .header {
                    TextField("Header name", text: binding(\.apiKeyHeader, default: "x-api-key"))
                }
                if endpoint?.authStyle == .query {
                    TextField("Query parameter", text: binding(\.apiKeyQueryParameter, default: "key"))
                }
                SecureField("API key", text: apiKeyBinding)
                Toggle("Send anthropic-version header", isOn: binding(\.sendsAnthropicVersion, default: true))
            }

            Section("Model") {
                TextField("Default model", text: binding(\.defaultModel, default: ""))
                Toggle("Supports images", isOn: binding(\.supportsImages, default: true))
                Toggle("Ask the server for its model list", isOn: binding(\.listsModels, default: true))
            }

            Section("Generation") {
                Toggle("Send a system prompt", isOn: Binding(
                    get: { appState.settings.sendSystemPrompt },
                    set: { newValue in
                        appState.settings.sendSystemPrompt = newValue
                        appState.saveSettings()
                    }
                ))
                TextField("System prompt", text: binding(\.systemPrompt, default: ""), axis: .vertical)
                    .lineLimit(3...6)
                HStack {
                    Text("Temperature")
                    Slider(value: Binding(
                        get: { endpoint?.temperature ?? 0.7 },
                        set: { newValue in commitValue(\.temperature, newValue) }
                    ), in: 0...2)
                    Text(String(format: "%.2f", endpoint?.temperature ?? 0.7))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                Stepper(
                    "Max tokens: \(endpoint?.maxTokens ?? 0)",
                    value: Binding(
                        get: { endpoint?.maxTokens ?? 4096 },
                        set: { newValue in commitValue(\.maxTokens, newValue) }
                    ),
                    in: 0...100000,
                    step: 256
                )
            }

            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { appState.settings.appearance },
                    set: { newValue in
                        appState.settings.appearance = newValue
                        appState.saveSettings()
                    }
                )) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                Toggle("Show reasoning blocks", isOn: Binding(
                    get: { appState.settings.showReasoning },
                    set: { newValue in
                        appState.settings.showReasoning = newValue
                        appState.saveSettings()
                    }
                ))
            }

            Section {
                HStack {
                    Button("Test connection") {
                        guard let endpoint else { return }
                        Task { await appState.testConnection(to: endpoint) }
                    }
                    Button("Refresh models") {
                        guard endpoint != nil else { return }
                        Task { await appState.refreshModels() }
                    }
                    Spacer()
                    if let status = appState.endpointStatus[endpointID] {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<ProviderEndpoint, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: {
                guard let endpoint = appState.settings.endpoints.first(where: { $0.id == endpointID }) else {
                    return defaultValue
                }
                return endpoint[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = appState.settings.endpoints.firstIndex(where: { $0.id == endpointID }) else { return }
                appState.settings.endpoints[index][keyPath: keyPath] = newValue
                appState.saveSettings()
            }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: {
                guard let endpoint else { return "" }
                return appState.apiKey(for: endpoint)
            },
            set: { newValue in
                guard let endpoint else { return }
                appState.setAPIKey(newValue, for: endpoint)
            }
        )
    }

    private func commitValue<Value>(_ keyPath: WritableKeyPath<ProviderEndpoint, Value>, _ value: Value) {
        guard let index = appState.settings.endpoints.firstIndex(where: { $0.id == endpointID }) else { return }
        appState.settings.endpoints[index][keyPath: keyPath] = value
        appState.saveSettings()
    }
}
