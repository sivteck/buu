import SwiftUI
import BUUKit

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: Theme.Metrics.sidebarMin,
                    ideal: Theme.Metrics.sidebarIdeal,
                    max: Theme.Metrics.sidebarMax
                )
        } detail: {
            ChatView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: Theme.Metrics.windowMinWidth,
            minHeight: Theme.Metrics.windowMinHeight
        )
        .overlay {
            if let attachment = appState.previewedImage {
                ImagePreviewOverlay(attachment: attachment) {
                    appState.dismissImagePreview()
                }
                .transition(.opacity)
            }
        }
        .themeAnimation(appState.previewedImage, reduceMotion: reduceMotion)
        .sheet(isPresented: $appState.showSettings) {
            SettingsView()
                .environment(appState)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            ),
            presenting: appState.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }
}

#Preview("Light") {
    RootView()
        .environment(AppState())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    RootView()
        .environment(AppState())
        .preferredColorScheme(.dark)
}
