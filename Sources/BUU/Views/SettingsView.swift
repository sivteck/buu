import SwiftUI
import BUUKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedEndpointID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                endpointList
                    .frame(width: 220)
                Divider()
                detail
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
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
        }
    }

    private var endpointList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedEndpointID) {
                ForEach(appState.settings.endpoints) { endpoint in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.name)
                        Text(endpoint.baseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(endpoint.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            appState.removeEndpoint(endpoint)
                            selectedEndpointID = appState.settings.endpoints.first?.id
                        }
                    }
                }
            }
            .listStyle(.sidebar)

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

    @ViewBuilder
    private var detail: some View {
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
    }
}
