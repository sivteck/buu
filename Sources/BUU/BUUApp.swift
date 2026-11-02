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
        .defaultSize(width: 1100, height: 760)
        // Seamless window: there is no window toolbar, because the chat header
        // is real content in the detail pane. Nothing can overlap the messages.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    Task { @MainActor in appState.newConversation() }
                }
                .keyboardShortcut("n", modifiers: .command)

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
