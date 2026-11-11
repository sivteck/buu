import SwiftUI
import BUUKit

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var layoutFrames: [String: CGRect] = [:]

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
            if appState.sidebarMode == .chats {
                ChatView()
            } else if let task = appState.activeAgenticTask, task.kind == .mac {
                VirtualMacView()
            } else {
                VStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("No Agentic task selected")
                        .font(.title3)
                    Text("Use New task in the sidebar to create a Mac Task.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.canvas)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.layoutDebugEnabled, appState.layoutDebugEnabled)
        .onPreferenceChange(LayoutRegionFramesKey.self) { frames in
            layoutFrames = frames
        }
        .frame(
            minWidth: Theme.Metrics.windowMinWidth,
            minHeight: Theme.Metrics.windowMinHeight
        )
        .coordinateSpace(.named("WindowContent"))
        .background {
            WindowConfigurator(
                minContentSize: CGSize(
                    width: Theme.Metrics.windowMinWidth,
                    height: Theme.Metrics.windowMinHeight
                )
            )
            .frame(width: 0, height: 0)
        }
        .overlay {
            LayoutDebugOverlay(frames: layoutFrames)
        }
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
        .sheet(isPresented: $appState.showNewTaskWizard) {
            NewAgentTaskWizard()
                .environment(appState)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                appState.saveSettings(immediately: true)
            }
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

#if DEBUG
#Preview("Layout – minimum 1120×720") {
    RootView()
        .environment(AppState())
        .frame(width: Theme.Metrics.windowMinWidth, height: Theme.Metrics.windowMinHeight)
}

#Preview("Layout – 1200×720") {
    RootView()
        .environment(AppState())
        .frame(width: 1200, height: 720)
}

#Preview("Layout – 1600×1000") {
    RootView()
        .environment(AppState())
        .frame(width: 1600, height: 1000)
}
#endif
