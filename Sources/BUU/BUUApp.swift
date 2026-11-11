import SwiftUI
import BUUKit

@main
struct BUUApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(appState.settings.appearance.colorScheme)
                .task {
                    await appState.bootstrap()
                }
        }
        .defaultSize(width: 1280, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(appState.sidebarMode == .chats ? "New Chat" : "New Task") {
                    Task { @MainActor in appState.performPrimarySidebarAction() }
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Search Sidebar") {
                    Task { @MainActor in appState.focusSidebarSearchToken += 1 }
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("Chats") {
                    Task { @MainActor in appState.sidebarMode = .chats }
                }
                .keyboardShortcut("1", modifiers: .control)
                Button("Agentic") {
                    Task { @MainActor in appState.sidebarMode = .agentic }
                }
                .keyboardShortcut("2", modifiers: .control)

                #if DEBUG
                Button("Debug: Load Test Thread (200 messages)") {
                    Task { @MainActor in appState.loadTestThread() }
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                #endif
            }

            CommandGroup(after: .textEditing) {
                Button("Focus Composer") {
                    Task { @MainActor in appState.focusComposer() }
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Stop Generating") {
                    Task { @MainActor in appState.stop() }
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!appState.isSending)

                Button("Regenerate Answer") {
                    Task { @MainActor in appState.regenerate() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!appState.canRegenerate)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    Task { @MainActor in appState.showSettings = true }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

    }
}

extension AppSettings.Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
