import SwiftUI
import BUUKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case providers
    case vmProfiles
    case vmInstances
    case macTraces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providers: return "Providers"
        case .vmProfiles: return "VM Profiles"
        case .vmInstances: return "VM Instances"
        case .macTraces: return "Mac Traces"
        }
    }

    var systemImage: String {
        switch self {
        case .providers: return "server.rack"
        case .vmProfiles: return "square.stack.3d.up"
        case .vmInstances: return "macwindow.on.rectangle"
        case .macTraces: return "doc.text.magnifyingglass"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var section: SettingsSection = .providers
    @State private var selectedEndpointID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                settingsSidebar
                    .frame(width: 220)
                Divider()
                detail
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    appState.saveSettings(immediately: true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 860, height: 580)
        .onAppear {
            if selectedEndpointID == nil {
                selectedEndpointID = appState.settings.activeEndpointID ?? appState.settings.endpoints.first?.id
            }
            if let request = appState.settingsSectionRequest {
                section = request
                appState.settingsSectionRequest = nil
            }
        }
        .onChange(of: appState.settingsSectionRequest) { _, request in
            guard let request else { return }
            section = request
            appState.settingsSectionRequest = nil
        }
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            List {
                Section("Settings") {
                    ForEach(SettingsSection.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            section == item
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                    }
                }

                if section == .providers {
                    Section("Servers") {
                        ForEach(appState.settings.endpoints) { endpoint in
                            Button {
                                section = .providers
                                selectedEndpointID = endpoint.id
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(endpoint.name)
                                    Text(endpoint.baseURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                selectedEndpointID == endpoint.id
                                    ? Color.accentColor.opacity(0.14)
                                    : Color.clear
                            )
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    appState.removeEndpoint(endpoint)
                                    selectedEndpointID = appState.settings.endpoints.first?.id
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if section == .providers {
                Divider()
                HStack(spacing: 6) {
                    Menu {
                        ForEach(EndpointPresets.all) { preset in
                            Button(preset.name) {
                                appState.addEndpoint(preset)
                                selectedEndpointID = appState.settings.activeEndpointID
                            }
                        }
                    } label: {
                        Label("Add server", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .providers:
            if let selectedEndpointID,
               appState.settings.endpoints.contains(where: { $0.id == selectedEndpointID }) {
                EndpointEditorView(endpointID: selectedEndpointID)
            } else {
                VStack(spacing: 10) {
                    Text("No server selected")
                        .font(.title3)
                    Text("Add a server to start chatting. Local servers usually speak the OpenAI protocol on http://localhost:<port>/v1.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .vmProfiles:
            VMProfilesView()
        case .vmInstances:
            VMInstancesView()
        case .macTraces:
            MacTraceSettingsView()
        }
    }
}
