import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Virtualization
import VirtualMacKit
import VirtualMacCore
import BUUKit

/// A separate macOS guest with manual controls and an always-available model
/// loop. Every action goes through the guest helper; no host input or screen API
/// is used.
struct VirtualMacView: View {
    @Environment(AppState.self) private var appState

    @State private var restoreImageError: String?
    @State private var confirmingDiscard = false
    @State private var confirmingDeleteVM = false
    @State private var selectedTab: MacWorkspaceTab = .workspace
    @AppStorage("macTaskSideBySide") private var sideBySideDisplay = true
    @AppStorage("macTaskInspectorVisible") private var inspectorVisible = true
    @AppStorage("macTaskStackedRatio") private var stackedRatio = 0.58
    @AppStorage("macTaskConsoleExpanded") private var consoleExpanded = false
    @AppStorage("macTaskConsoleRatio") private var consoleRatio = 0.35
    @State private var consoleSection: MacConsoleSection = .vmLog
    @State private var didAutoOpenConsole = false
    @State private var confirmingStopVM = false
    @State private var confirmingClearContext = false
    @State private var steerDraft = ""
    @State private var artifactError: String?
    @State private var queueTrayExpanded = true
    @State private var editingQueuedTask: QueuedTask?
    @State private var confirmingRunNextNow = false
    @State private var showingGuestDetails = false
    @State private var confirmingRestartGuest = false
    @State private var dismissedBlockingBanner = false
    @State private var reportedGuestUnreachable = false

    private var vm: VirtualMacController { appState.virtualMac }
    private var macConfiguration: MacTaskConfiguration? { appState.activeMacTaskConfiguration }

    private var displayAspectRatio: CGFloat {
        guard let configuration = macConfiguration, configuration.height > 0 else { return 16 / 10 }
        return CGFloat(configuration.width) / CGFloat(configuration.height)
    }
    private var configuredMachine: Machine? {
        guard let name = macConfiguration?.machineName else { return nil }
        return vm.machines.first { $0.name == name }
    }
    private var agent: VirtualMacAgentModel { appState.virtualMacAgent }

    var body: some View { workspaceDialogs }

    private var workspaceBase: some View {
        Group {
            switch selectedTab {
            case .workspace:
                displayTab
            case .configuration:
                MacConfigurationTabView()
            }
        }
        .background(DesignTokens.Surface.window)
        .navigationTitle(appState.activeAgenticTask?.title ?? "Mac Task")
        .navigationSubtitle(workspaceSubtitle)
        .toolbar { toolbar }
        .background { workspaceShortcuts }
    }

    private var workspaceLifecycle: some View {
        workspaceBase
            .task { await monitorGuestStatus() }
            .onChange(of: showingGuestDetails) { _, shown in
                guard shown else { return }
                Task { await vm.refreshGuestStatus() }
            }
            .onAppear {
                bootstrapWorkspace()
                if let request = appState.macWorkspaceTabRequest {
                    selectedTab = request
                    appState.macWorkspaceTabRequest = nil
                }
            }
            .onDisappear {
                persistPrompt(for: appState.activeAgenticTask)
            }
            .onChange(of: appState.macWorkspaceTabRequest) { _, request in
                guard let request else { return }
                selectedTab = request
                appState.macWorkspaceTabRequest = nil
            }
            .onChange(of: appState.activeAgenticTask?.id) { oldID, newID in
                if let oldID, agent.currentTaskID == oldID {
                    appState.updateTaskPrompt(taskID: oldID, prompt: agent.instructions)
                }
                loadPrompt(for: appState.agenticTasks.first(where: { $0.id == newID }))
            }
            .onChange(of: vm.errorLog.count) { _, count in
                if count > 0, !didAutoOpenConsole {
                    didAutoOpenConsole = true
                    consoleExpanded = true
                    consoleSection = .errors
                }
            }
            .onChange(of: guestCondition, initial: true) { _, condition in
                if condition == .helperNotResponding {
                    guard !reportedGuestUnreachable else { return }
                    reportedGuestUnreachable = true
                    vm.noteError("Guest is not reachable. The guest may be at the login screen, or BUUVirtualMacGuest may not be running. Sign in or open the helper, then retry.")
                } else {
                    reportedGuestUnreachable = false
                }
            }
            .onChange(of: vm.canAct) { _, ready in
                dismissedBlockingBanner = false
                guard ready, let task = appState.activeAgenticTask else { return }
                Task { await appState.syncQueuedMacArtifacts(taskID: task.id) }
            }
    }

    private var workspaceRunDialogs: some View {
        workspaceLifecycle
            .confirmationDialog("Stop the virtual Mac?", isPresented: $confirmingStopVM) {
                Button("Stop guest", role: .destructive) { Task { await vm.stop(force: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The VM will stop. The agent loop cannot continue until it is started again.")
            }
            .alert("Steers were not applied", isPresented: pendingSteersPresented) {
                Button("Start follow-up") { startFollowUpWithPendingSteers() }
                Button("Discard", role: .destructive) { agent.discardPendingSteers() }
                Button("Keep queued", role: .cancel) { agent.clearSteerEndPrompt() }
            } message: {
                Text("\(agent.pendingSteersAtEnd) steer(s) were not applied. Start a follow-up with them, discard them, or keep them queued.")
            }
            .confirmationDialog("Restart guest?", isPresented: $confirmingRestartGuest) {
                Button("Restart guest", role: .destructive) { Task { await restartGuest() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The virtual Mac will stop and start again. Unsaved work inside the guest may be lost.")
            }
            .confirmationDialog("Start the next queued task now?", isPresented: $confirmingRunNextNow) {
                Button("Stop after current round and start next") {
                    if let task = appState.activeAgenticTask { appState.requestRunNextNow(taskID: task.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The current task stops at the next safe boundary, then the queue advances.")
            }
    }

    private var workspaceDialogs: some View {
        workspaceRunDialogs
            .confirmationDialog("Discard incomplete virtual Mac?", isPresented: $confirmingDiscard) {
                Button("Discard installation", role: .destructive) {
                    guard let name = macConfiguration?.machineName else { return }
                    do { try vm.discardIncompleteMachine(name: name); vm.errorMessage = nil }
                    catch { vm.errorMessage = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the unfinished VM disk and hardware files so the next attempt can use the current settings.")
            }
            .confirmationDialog("Clear agent context?", isPresented: $confirmingClearContext) {
                Button("Clear context", role: .destructive) { agent.resetSession() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the saved agent loop and reasoning for this Mac Task. The task prompt and VM are kept.")
            }
            .confirmationDialog("Delete virtual machine?", isPresented: $confirmingDeleteVM) {
                Button("Delete VM and all its files", role: .destructive) {
                    guard let name = macConfiguration?.machineName else { return }
                    do { try vm.deleteMachine(name: name); vm.errorMessage = nil }
                    catch { vm.errorMessage = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes \(macConfiguration?.machineName ?? "the VM")'s disk and hardware files. The Mac Task configuration is kept.")
            }
    }

    private var workspaceShortcuts: some View {
        Group {
            Button("Workspace") { selectedTab = .workspace }
                .keyboardShortcut("1", modifiers: .command)
            Button("Configuration") { selectedTab = .configuration }
                .keyboardShortcut("2", modifiers: .command)
            Button("Focus composer") { appState.focusMacComposerToken += 1 }
                .keyboardShortcut("k", modifiers: .command)
            Button("Toggle console") { toggleConsole() }
                .keyboardShortcut("l", modifiers: .command)
        }
        .hidden()
    }

    private func monitorGuestStatus() async {
        while !Task.isCancelled {
            if vm.vmState == "running" {
                await vm.refreshGuestStatus()
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func bootstrapWorkspace() {
        vm.refreshMachines()
        loadPrompt(for: appState.activeAgenticTask)
        if let macConfiguration {
            vm.selectedName = macConfiguration.machineName
        }
        if agent.selectedEndpointID == nil {
            agent.selectedEndpointID = appState.settings.endpoints.first?.id
        }
        guard let endpoint = selectedEndpoint else { return }
        if agent.model.isEmpty {
            agent.model = endpoint.defaultModel
        }
        let key = appState.apiKey(for: endpoint)
        Task { await agent.loadModels(endpoint: endpoint, apiKey: key) }
    }

    private var pendingSteersPresented: Binding<Bool> {
        Binding(
            get: { agent.runEndedWithPendingSteers },
            set: { presented in
                if !presented { agent.clearSteerEndPrompt() }
            }
        )
    }

    private var workspaceSubtitle: String {
        let state = agent.isRunning ? "running" : vm.vmState
        return "NMac · \(state)"
    }

    @ViewBuilder
    private var displayTab: some View {
        GeometryReader { proxy in
            if sideBySideDisplay, proxy.size.width >= DesignTokens.inspectorMinWidth + Theme.Metrics.displayPaneMinWidth {
                workspaceDisplay
                    .inspector(isPresented: $inspectorVisible) {
                        MacAgentPanel()
                            .inspectorColumnWidth(
                                min: DesignTokens.inspectorMinWidth,
                                ideal: DesignTokens.inspectorIdealWidth,
                                max: DesignTokens.inspectorMaxWidth
                            )
                    }
            } else if sideBySideDisplay {
                // Auto-collapse the inspector instead of forcing overflow.
                workspaceDisplay
            } else {
                MacSplitView(ratio: Binding(
                    get: { CGFloat(stackedRatio) },
                    set: { stackedRatio = Double($0) }
                )) {
                    workspaceDisplay
                } bottom: {
                    MacAgentPanel()
                }
            }
        }
    }

    private var workspaceDisplay: some View {
        GeometryReader { proxy in
            let consoleAvailable = proxy.size.height >= 420
            let showConsole = consoleExpanded && consoleAvailable
            VStack(spacing: 0) {
                Group {
                    if showConsole {
                        MacSplitView(
                            ratio: consoleTopRatio,
                            minTop: 200,
                            minBottom: 120
                        ) {
                            displaySurfaceWithBanner
                        } bottom: {
                            consoleDrawer
                        }
                    } else {
                        displaySurfaceWithBanner
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .layoutRegion("DisplayArea")
                MacVMBar(
                    vmName: macConfiguration?.machineName ?? vm.selectedName,
                    state: vm.vmState,
                    startedAt: vm.startedAt,
                    machine: configuredMachine,
                    runState: agent.runState,
                    condition: guestCondition,
                    errorCount: vm.errorLog.count,
                    consoleExpanded: showConsole,
                    consoleAvailable: consoleAvailable,
                    onStart: { startConfiguredVM() },
                    onPause: { Task { await vm.pause() } },
                    onResume: { Task { await vm.resume() } },
                    onStop: { confirmingStopVM = true },
                    onOpenWindow: { vm.showWindow() },
                    onToggleConsole: { toggleConsole() }
                )
                .layoutRegion("VMBar")
            }
            .onChange(of: proxy.size.height) { _, height in
                if height < 420, consoleExpanded {
                    consoleExpanded = false
                }
            }
        }
    }

    private var consoleTopRatio: Binding<CGFloat> {
        Binding(
            get: { CGFloat(min(max(1 - consoleRatio, 0.6), 0.8)) },
            set: { topRatio in
                consoleRatio = min(max(1 - Double(topRatio), 0.2), 0.4)
            }
        )
    }

    private var displaySurface: some View {
        MacDisplaySurface(
            machine: vm.virtualMachine,
            screenshot: vm.screenshotImage,
            aspectRatio: displayAspectRatio,
            state: vm.vmState,
            isBusy: vm.isBusy,
            onStart: { startConfiguredVM() },
            onOpenWindow: { vm.showWindow() }
        )
    }

    private var displaySurfaceWithBanner: some View {
        displaySurface
            .safeAreaInset(edge: .top, spacing: 0) {
                if let issue = blockingIssue, !dismissedBlockingBanner {
                    MacBlockingBanner(
                        title: issue.title,
                        message: issue.message,
                        onRetry: {
                            dismissedBlockingBanner = false
                            Task { await vm.refreshGuestStatus() }
                        },
                        onViewLog: { showVMLog() },
                        onOpenSetup: {
                            vm.showWindow()
                            showVMLog()
                        },
                        onDismiss: { dismissedBlockingBanner = true },
                        setupButtonTitle: issue.setupTitle
                    )
                    .padding(DesignTokens.Space.m)
                }
            }
    }

    private var consoleDrawer: some View {
        consoleDrawerContent
            .layoutRegion("Console")
    }

    private var consoleDrawerContent: some View {
        MacConsoleDrawer(
            vmName: macConfiguration?.machineName ?? vm.selectedName,
            vmLog: vm.runtimeLog,
            errorLog: vm.errorLog,
            section: $consoleSection,
            onCopy: { lines in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            },
            onClear: { section in
                switch section {
                case .vmLog: vm.runtimeLog.removeAll()
                case .errors:
                    vm.errorLog.removeAll()
                    didAutoOpenConsole = false
                }
            }
        )
    }

    private func toggleConsole() {
        consoleExpanded.toggle()
    }

    private var blockingIssue: (title: String, message: String, setupTitle: String)? {
        guard vm.vmState == "running" else { return nil }
        switch guestCondition {
        case .ready, .stopped:
            return nil
        case .helperNotResponding:
            return nil
        case .screenRecording:
            return (
                "Screen Recording permission is needed",
                "Open the guest helper and allow Screen Recording. The agent cannot see the screen until it is granted.",
                "Open guided setup"
            )
        case .accessibility:
            return (
                "Accessibility permission is needed",
                "Open the guest helper and allow Accessibility. The agent cannot click or type until it is granted.",
                "Open guided setup"
            )
        case .error:
            return (
                "Guest error",
                vm.guestStatusError ?? vm.errorMessage ?? "The guest reported an error.",
                "View log"
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Workspace", selection: $selectedTab) {
                ForEach(MacWorkspaceTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingGuestDetails = true
            } label: {
                MacStatusPill(
                    runState: agent.runState,
                    vmState: vm.vmState,
                    condition: guestCondition,
                    guestReady: vm.guestStatus?.isReady == true
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingGuestDetails, arrowEdge: .bottom) {
                MacGuestDetailsPopover(
                    vmName: macConfiguration?.machineName ?? "Virtual Mac",
                    state: vm.vmState,
                    machine: configuredMachine,
                    guest: vm.guestStatus,
                    condition: guestCondition,
                    startedAt: vm.startedAt,
                    lastUpdated: vm.guestStatusUpdatedAt,
                    onRetry: { Task { await vm.refreshGuestStatus() } },
                    onViewLog: { showVMLog() },
                    onOpenSetup: {
                        vm.showWindow()
                        showVMLog()
                    },
                    setupButtonTitle: guestCondition == .helperNotResponding
                        ? "How to enable auto-login"
                        : "Open guided setup"
                )
            }
            .help(statusHelp)
            .accessibilityLabel("Run status")
            .accessibilityValue(statusHelp)
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Export trace") { exportMacLogs(.reasoning) }
                Button("Export outputs") { exportAllOutputs() }
                Button("Copy trace") { copyTraceToPasteboard() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export trace or outputs")
            .accessibilityLabel("Export")

            Menu {
                Button {
                    sideBySideDisplay = true
                    inspectorVisible = true
                } label: {
                    if sideBySideDisplay { Label("Side by Side", systemImage: "checkmark") } else { Text("Side by Side") }
                }
                Button {
                    sideBySideDisplay = false
                } label: {
                    if !sideBySideDisplay { Label("Stacked", systemImage: "checkmark") } else { Text("Stacked") }
                }
            } label: {
                Label("Layout", systemImage: sideBySideDisplay ? "rectangle.split.2x1" : "rectangle.split.1x2")
            }
            .help("Display layout")
            .accessibilityLabel("Display layout")

            Menu {
                Button("Restart guest", role: .destructive) { confirmingRestartGuest = true }
                Button("Open in Window") { vm.showWindow() }
                    .disabled(vm.virtualMachine == nil && vm.screenshotImage == nil)
                Button("Show VM log") { showVMLog() }
                Button("Reveal VM folder") { revealVMFolder() }
                if sideBySideDisplay {
                    Divider()
                    Button(inspectorVisible ? "Hide agent panel" : "Show agent panel") {
                        inspectorVisible.toggle()
                    }
                }
                #if DEBUG
                Divider()
                Toggle("Layout inspector", isOn: Binding(
                    get: { appState.layoutDebugEnabled },
                    set: { appState.layoutDebugEnabled = $0 }
                ))
                #endif
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
            .accessibilityLabel("More actions")
        }
    }

    private var guestCondition: MacGuestCondition {
        if vm.vmState == "error" { return .error }
        if vm.vmState == "stopped" { return .stopped }
        guard let guest = vm.guestStatus else { return .helperNotResponding }
        if !guest.screenRecording { return .screenRecording }
        if !guest.accessibility { return .accessibility }
        return .ready
    }

    private var statusHelp: String {
        switch agent.runState {
        case .running: return vm.guestStatus?.isReady == true ? "Running, guest ready" : "Running, waiting for the guest helper"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .idle: return vm.vmState == "stopped" ? "Stopped" : vm.vmState.capitalized
        }
    }

    private func startConfiguredVM() {
        guard let configuration = macConfiguration else { return }
        let options = VirtualMacOptions(
            cpus: configuration.cpus,
            memoryGiB: configuration.memoryGiB,
            diskGiB: configuration.diskGiB,
            width: configuration.width,
            height: configuration.height,
            network: configuration.network,
            scale: configuration.scale
        )
        Task {
            await vm.prepareAndStart(
                name: configuration.machineName,
                restoreImage: configuration.restoreImagePath.map { URL(fileURLWithPath: $0) },
                options: options
            )
        }
    }

    private func restartGuest() async {
        let name = macConfiguration?.machineName ?? vm.selectedName
        await vm.stop(force: false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        do {
            try await vm.start(name: name, show: false)
            await vm.refreshGuestStatus()
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }

    private func showVMLog() {
        selectedTab = .workspace
        consoleExpanded = true
        consoleSection = vm.errorLog.isEmpty ? .vmLog : .errors
    }

    private func revealVMFolder() {
        guard let path = vm.machineDirectoryPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func exportAllOutputs() {
        guard let task = appState.activeAgenticTask else { return }
        let outputs = appState.macOutputs(for: task.id)
        guard !outputs.isEmpty else {
            vm.errorMessage = "No outputs have been synced for this task yet."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for outputs"
        panel.prompt = "Export"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let sourceFolder = appState.artifactStore.outputsDirectory(for: task.id)
        do {
            for output in outputs {
                let source = sourceFolder.appendingPathComponent(output.hostFileName)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                let destination = folder.appendingPathComponent(output.hostFileName)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }

    private func copyTraceToPasteboard() {
        let task = appState.activeAgenticTask
        let sections: [(String, [String])] = [
            ("Rounds", currentMacRoundLines()),
            ("Agent loop log", agent.log),
            ("Current reasoning trace", LogExporter.reasoningTraceLines(agent.traceMessages)),
            ("Steering and task queue", LogExporter.steerLines(task?.steers ?? []) + LogExporter.queuedTaskLines(task?.queuedTasks ?? [])),
        ]
        let text = LogExporter.readableText(title: "BUU Mac Task Trace", sections: sections)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Lifecycle

    private var lifecycleSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                Text("Virtual machine")
                    .font(.title3.weight(.semibold))

                if !appState.macTaskConfigurations.isEmpty {
                    Picker("Configuration", selection: Binding(
                        get: { appState.activeMacTaskConfiguration?.id },
                        set: { if let id = $0 { appState.setMacConfigurationForCurrentTask(id) } }
                    )) {
                        ForEach(appState.macTaskConfigurations) { configuration in
                            Text(configuration.name).tag(Optional(configuration.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 190)
                    .disabled(vm.vmState != "stopped" || vm.isBusy || vm.isInstalling)
                    .help("Configuration used by this Mac task")

                    Button {
                        let id = appState.addMacTaskConfiguration()
                        appState.setMacConfigurationForCurrentTask(id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .iconHitTarget()
                    .disabled(vm.vmState != "stopped" || vm.isBusy || vm.isInstalling)
                    .help("Create and use a new virtual-Mac configuration")
                }

                Spacer()
                if vm.windowVisible {
                    Button("Close separate window") { vm.hideWindow() }
                } else {
                    Button("Open in Window") { vm.showWindow() }
                        .disabled(vm.vmState == "stopped")
                        .help("Show the live VM in a separate window instead of the Display tab")
                }
            }

            if vm.isInstalling {
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Installing macOS into “\(macConfiguration?.machineName ?? vm.selectedName)”")
                            .font(.callout.weight(.medium))
                        Text(vm.statusMessage.isEmpty ? "Start and lifecycle controls will appear when installation finishes." : vm.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(Theme.Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .fill(Theme.Colors.info.opacity(0.10))
                )
            } else if configuredMachine?.installed != true {
                newMachineControls
            } else {
                HStack(spacing: Theme.Spacing.s) {
                    Text(macConfiguration?.machineName ?? vm.selectedName)
                        .font(.callout.monospaced())

                    Button("Start") {
                        Task {
                            do {
                                if let id = macConfiguration?.id {
                                    appState.markMacConfigurationUsed(id)
                                }
                                try await vm.start(name: macConfiguration?.machineName ?? vm.selectedName, show: false)
                                await vm.refreshGuestStatus()
                            } catch {
                                vm.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.vmState != "stopped" || vm.isBusy || vm.isInstalling)

                    if vm.vmState == "running" {
                        Button("Pause") { Task { await vm.pause() } }
                    } else if vm.vmState == "paused" {
                        Button("Resume") { Task { await vm.resume() } }
                    }

                    Button("Stop", role: .destructive) {
                        Task { await vm.stop(force: false) }
                    }
                    .disabled(vm.vmState == "stopped")

                    Button("Delete VM…", role: .destructive) {
                        confirmingDeleteVM = true
                    }
                    .disabled(vm.vmState != "stopped" || vm.isBusy || vm.isInstalling)

                    Spacer()
                }

                if let machine = configuredMachine {
                    Text("\(machine.cpu) CPUs · \(machine.memoryGiB) GiB RAM · \(machine.diskGiB) GiB disk · \(machine.width)×\(machine.height) points")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            downloadProgressSection

            if let error = vm.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.Colors.danger)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = vm.guestStatusError, vm.vmState == "running" {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if vm.vmState == "running", vm.guestStatus?.isReady != true {
                setupInstructions
            }
        }
        .padding(Theme.Spacing.l)
        .background(cardBackground)
    }

    private var newMachineControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("No virtual Mac named “\(macConfiguration?.machineName ?? vm.selectedName)” yet")
                .font(.callout.weight(.medium))
            Text("BUU can download macOS from Apple (several GB) and install it locally. Complete macOS Setup Assistant in the VM window, then open the guest helper from /Volumes/My Shared Files/tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            createControls

            if configuredMachine != nil {
                Button("Discard incomplete installation…", role: .destructive) {
                    confirmingDiscard = true
                }
                .font(.caption)
                Text("The current disk size is \(macConfiguration?.diskGiB ?? 20) GiB. A failed attempt keeps its disk; discard it before retrying with a different size or image.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var createControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Button(macConfiguration?.restoreImagePath == nil ? "Choose image or folder…" : "Change image…") {
                    chooseRestoreImage()
                }
                if macConfiguration?.restoreImagePath != nil {
                    Button("Clear") {
                        updateMacConfiguration { $0.restoreImagePath = nil }
                        restoreImageError = nil
                    }
                }
                Button("Create & start") {
                    guard let configuration = macConfiguration else { return }
                    appState.markMacConfigurationUsed(configuration.id)
                    Task {
                        await vm.prepareAndStart(
                            name: configuration.machineName,
                            restoreImage: configuration.restoreImagePath.map { URL(fileURLWithPath: $0) },
                            options: VirtualMacOptions(
                                cpus: configuration.cpus,
                                memoryGiB: configuration.memoryGiB,
                                diskGiB: configuration.diskGiB,
                                width: configuration.width,
                                height: configuration.height,
                                network: configuration.network,
                                scale: configuration.scale
                            )
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(macConfiguration == nil || vm.isBusy)
                Spacer()
            }

            if let path = macConfiguration?.restoreImagePath {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("Leave the image empty to download Apple's latest compatible macOS image. You can also choose an .ipsw file or a folder containing one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let restoreImageError {
                Text(restoreImageError)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Edit these values in Settings → Mac Tasks.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func updateMacConfiguration(_ mutate: (inout MacTaskConfiguration) -> Void) {
        guard var configuration = macConfiguration else { return }
        mutate(&configuration)
        appState.updateMacTaskConfiguration(configuration)
    }

    private var downloadProgressSection: some View {
        Group {
            if vm.isDownloading || vm.downloadProgress != nil {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(vm.isDownloading
                             ? (vm.downloadResumed ? "Resuming macOS download" : "Downloading macOS")
                             : (vm.downloadProgress == nil ? "Download" : "Download paused"))
                            .font(.caption.weight(.medium))
                        Spacer()
                        if let progress = vm.downloadProgress {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let progress = vm.downloadProgress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }

                    HStack(spacing: Theme.Spacing.s) {
                        Text(downloadBytesText)
                        Spacer()
                        if let speed = vm.downloadBytesPerSecond, speed > 0 {
                            Text("\(byteCount(Int64(speed)))/s")
                        }
                        if let eta = vm.downloadETA {
                            Text(etaText(eta))
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if vm.isDownloading {
                        Button("Cancel download") { vm.cancelRestoreDownload() }
                            .font(.caption)
                    }
                }
                .padding(Theme.Spacing.s)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .fill(Theme.Colors.control)
                )
            }
        }
    }

    private var downloadBytesText: String {
        let written = byteCount(vm.downloadBytesWritten)
        guard vm.downloadTotalBytes > 0 else { return written }
        return "\(written) of \(byteCount(vm.downloadTotalBytes))"
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func etaText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s left" }
        let minutes = total / 60
        let remainder = total % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s left" }
        let hours = minutes / 60
        return "\(hours)h \(minutes % 60)m left"
    }

    @ViewBuilder
    private func artifactSection(_ task: AgenticTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Label("Artifacts", systemImage: "paperclip")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    revealArtifactWorkspace(for: task.id)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Reveal the host artifact workspace in Finder")
                Button("Add files…") { chooseArtifacts(for: task.id) }
                    .font(.caption)
            }
            Text(appState.macArtifactFolders?.artifactsRoot ?? "~/Desktop/BUU Artifacts")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)

            if !vm.canAct {
                Label("Guest not ready. Files are queued and copied as soon as the VM is running.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let artifacts = task.artifacts, !artifacts.isEmpty {
                ForEach(artifacts) { artifact in
                    artifactRow(artifact, taskID: task.id)
                }
            } else {
                Text("Attach files to this task. They are copied into the guest at ~/Desktop/BUU Artifacts so Finder, Preview and TextEdit can open them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let artifactError {
                Text(artifactError)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = appState.macArtifactMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            outputsSection(task)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleArtifactDrop(providers, taskID: task.id)
        }
    }

    private func artifactRow(_ artifact: TaskArtifact, taskID: UUID) -> some View {
        let hostURL = appState.artifactURL(for: artifact, taskID: taskID)
        let progress = appState.macArtifactProgress[artifact.id] ?? artifact.guestProgress
        return HStack(spacing: Theme.Spacing.s) {
            Image(systemName: artifactIcon(for: artifact.name))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.xs) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.byteCount), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    artifactStateChip(artifact, progress: progress)
                    if let guestName = artifact.guestName, guestName != artifact.name {
                        Text("guest: \(guestName)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                if let error = artifact.lastError, artifact.guestState == .failed {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Theme.Colors.danger)
                        .lineLimit(2)
                }
            }
            Spacer()
            if artifact.guestState == .failed {
                Button("Retry") {
                    Task { await appState.syncMacArtifact(taskID: taskID, artifactID: artifact.id, announce: false) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            Button {
                QuickLookPresenter.shared.present(hostURL)
            } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.plain)
            .help("Quick Look on host")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([hostURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Reveal on host")
            Button {
                guard let path = artifact.guestPath else { return }
                Task { try? await vm.guestRevealArtifact(path: path) }
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .disabled(artifact.guestPath == nil)
            .help("Show in the guest VM")
            Button {
                Task { await appState.removeMacArtifactEverywhere(artifact.id, for: taskID) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from host and guest")
        }
        .padding(Theme.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                .fill(Theme.Colors.control)
        )
    }

    @ViewBuilder
    private func artifactStateChip(_ artifact: TaskArtifact, progress: Double?) -> some View {
        switch artifact.guestState ?? .queued {
        case .copying:
            Text("Copying \(Int((progress ?? 0) * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.Colors.warning)
        case .inGuest:
            Text("In VM")
                .font(.caption2)
                .foregroundStyle(Theme.Colors.success)
        case .opened:
            Text("Opened by agent")
                .font(.caption2)
                .foregroundStyle(Theme.Colors.success)
        case .modified:
            Text("Modified")
                .font(.caption2)
                .foregroundStyle(Theme.Colors.warning)
        case .failed:
            Text("Failed")
                .font(.caption2)
                .foregroundStyle(Theme.Colors.danger)
        case .queued:
            Text("Queued")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func outputsSection(_ task: AgenticTaskRecord) -> some View {
        Divider().padding(.vertical, Theme.Spacing.xs)
        HStack {
            Label("Outputs", systemImage: "tray.and.arrow.down")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let root = appState.macArtifactFolders?.outputsRoot {
                Text(root)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Button("Refresh") {
                Task { await appState.refreshMacOutputs(taskID: task.id) }
            }
            .font(.caption)
        }
        if let outputs = task.outputs, !outputs.isEmpty {
            ForEach(outputs) { output in
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: artifactIcon(for: output.name))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(output.name).font(.callout).lineLimit(1)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(output.byteCount), countStyle: .file)) · \(output.guestPath)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        QuickLookPresenter.shared.present(outputHostURL(output, taskID: task.id))
                    } label: { Image(systemName: "eye") }
                        .buttonStyle(.plain)
                        .help("Quick Look")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([outputHostURL(output, taskID: task.id)])
                    } label: { Image(systemName: "folder") }
                        .buttonStyle(.plain)
                        .help("Reveal on host")
                    Button("Export") { exportOutput(output, taskID: task.id) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output.guestPath, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain)
                        .help("Copy guest path")
                }
                .padding(Theme.Spacing.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).fill(Theme.Colors.control))
            }
        } else {
            Text("Files saved in the guest's BUU Outputs folder appear here automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func outputHostURL(_ output: TaskOutput, taskID: UUID) -> URL {
        appState.artifactStore.outputsDirectory(for: taskID).appendingPathComponent(output.hostFileName)
    }

    private func exportOutput(_ output: TaskOutput, taskID: UUID) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = output.hostFileName
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: outputHostURL(output, taskID: taskID), to: destination)
        } catch {
            artifactError = "Could not export \(output.name): \(error.localizedDescription)"
        }
    }

    private nonisolated static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }

    private func handleArtifactDrop(_ providers: [NSItemProvider], taskID: UUID) -> Bool {
        guard !providers.isEmpty else { return false }
        let collector = DroppedURLCollector()
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = Self.fileURL(from: item) { collector.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = collector.snapshot()
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                do {
                    let added = try appState.addMacArtifacts(urls, for: taskID)
                    if agent.isRunning || agent.phase == .paused, agent.currentTaskID == taskID {
                        let text = steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Use the attached file(s)."
                            : steerDraft
                        if agent.enqueueSteer(text: text, attachmentIDs: added.map(\.id)) != nil {
                            steerDraft = ""
                        } else {
                            artifactError = "The steer queue is full. The files were added to the task."
                        }
                    }
                    for artifact in added {
                        await appState.syncMacArtifact(taskID: taskID, artifactID: artifact.id, announce: false)
                    }
                } catch {
                    artifactError = error.localizedDescription
                }
            }
        }
        return true
    }

    @ViewBuilder
    private var steeringPane: some View {
        if let task = appState.activeAgenticTask,
           agent.isRunning || agent.phase == .paused || agent.steerItems.contains(where: { $0.state == .failed }) {
            let capReached = SteerPlanner.pending(agent.steerItems).count >= SteerPlanner.maxPending
            let acceptsSteers = agent.isRunning || agent.phase == .paused
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SteerStripView(
                    items: agent.steerItems,
                    artifacts: appState.macArtifacts(for: task.id),
                    snapshot: agent.snapshot,
                    isRunning: agent.isRunning,
                    isPaused: agent.phase == .paused,
                    onEdit: { id, text in agent.editSteer(id: id, text: text) },
                    onDelete: { id in _ = agent.deleteSteer(id: id) },
                    onSendNow: { id in _ = agent.interruptSteer(id: id) },
                    onReorder: { ids in agent.reorderSteers(ids: ids) },
                    onRetrySteer: { item in
                        _ = agent.retrySteer(id: item.id)
                        Task {
                            for id in item.attachmentIDs {
                                await appState.syncMacArtifact(taskID: task.id, artifactID: id, announce: false)
                            }
                        }
                    },
                    onClearAll: {
                        for item in SteerPlanner.pending(agent.steerItems) where item.state == .queued || item.state == .failed {
                            _ = agent.deleteSteer(id: item.id)
                        }
                    }
                )

                SteerComposerView(
                    text: $steerDraft,
                    isEnabled: acceptsSteers && !capReached,
                    disabledReason: capReached
                        ? "Maximum 10 pending steers. Apply or delete one before adding another."
                        : (acceptsSteers ? (vm.vmState == "stopped" ? "The guest is disconnected. Text steers still queue." : nil) : "Resume a run to send this steer."),
                    isPaused: agent.phase == .paused,
                    attachmentNames: [],
                    onAttach: { attachFilesToSteer(taskID: task.id) },
                    onSteer: { sendSteer(interrupt: false, taskID: task.id) },
                    onInterrupt: { sendSteer(interrupt: true, taskID: task.id) }
                )
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    handleArtifactDrop(providers, taskID: task.id)
                }
            }
        }
    }

    @ViewBuilder
    private var queueTray: some View {
        if let task = appState.activeAgenticTask {
            QueueTrayView(
                expanded: $queueTrayExpanded,
                tasks: appState.macQueuedTasks(for: task.id),
                artifacts: appState.macArtifacts(for: task.id),
                endpoints: appState.settings.endpoints,
                defaultModel: selectedEndpoint?.defaultModel ?? agent.model,
                runningID: appState.activeQueuedTaskID,
                paused: appState.queuePaused(for: task.id),
                stopOnFailure: appState.queueStopOnFailure(for: task.id),
                transitionDeadline: appState.queueTransitionDeadline,
                transitionFrom: appState.queueTransitionFromTitle,
                transitionTo: appState.queueTransitionToTitle,
                transitionNextID: appState.queueTransitionNextTaskID,
                message: appState.workspaceQueueMessage,
                onPauseResume: { pause in
                    appState.setQueuePaused(pause, taskID: task.id)
                    if !pause { appState.resumeWorkspaceQueue(taskID: task.id) }
                },
                onStartQueue: { appState.startWorkspaceQueue(taskID: task.id) },
                onRunNextNow: { confirmingRunNextNow = true },
                onStartNow: { appState.startQueuedTaskNow(taskID: task.id) },
                onCancelTransition: { appState.cancelQueueTransition(taskID: task.id) },
                onEdit: { editingQueuedTask = $0 },
                onDuplicate: { appState.duplicateMacQueuedTask(taskID: task.id, id: $0) },
                onRemove: { appState.removeMacQueuedTask(taskID: task.id, id: $0) },
                onReorder: { appState.reorderMacQueuedTasks(taskID: task.id, ids: $0) },
                onStopOnFailure: { appState.setQueueStopOnFailure($0, taskID: task.id) },
                onQueueCurrent: { queueCurrentPrompt(taskID: task.id) }
            )
        }
    }

    private var terminalSteerLines: [String] {
        agent.steerItems
            .filter { $0.state == .applied || $0.state == .cancelled || $0.state == .failed }
            .sorted { lhs, rhs in
                (lhs.appliedAt ?? lhs.createdAt) < (rhs.appliedAt ?? rhs.createdAt)
            }
            .map { item in
                let stamp = (item.appliedAt ?? item.createdAt).formatted(date: .omitted, time: .standard)
                switch item.state {
                case .applied:
                    return "You steered (round \(item.appliedInRound ?? 0), \(stamp)): \(item.text)"
                case .cancelled:
                    return "System: Steer cancelled by user (original): \(item.text)"
                case .failed:
                    return "System: Steer failed: \(item.failure ?? "unknown") (original): \(item.text)"
                default:
                    return ""
                }
            }
            .filter { !$0.isEmpty }
    }

    private func sendSteer(interrupt: Bool, taskID: UUID) {
        let text = steerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard agent.enqueueSteer(text: text, interrupt: interrupt) != nil else { return }
        steerDraft = ""
    }

    private func attachFilesToSteer(taskID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Attach files to this steer"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let added = try appState.addMacArtifacts(panel.urls, for: taskID)
            let text = steerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Use the attached file(s)."
                : steerDraft
            guard agent.enqueueSteer(text: text, attachmentIDs: added.map(\.id)) != nil else { return }
            steerDraft = ""
            Task {
                for artifact in added {
                    await appState.syncMacArtifact(taskID: taskID, artifactID: artifact.id, announce: false)
                }
            }
        } catch {
            artifactError = error.localizedDescription
        }
    }

    private func startFollowUpWithPendingSteers() {
        guard let endpoint = selectedEndpoint else { return }
        let model = agent.model.isEmpty ? endpoint.defaultModel : agent.model
        agent.clearSteerEndPrompt()
        agent.start(
            endpoint: endpoint,
            apiKey: appState.apiKey(for: endpoint),
            model: model,
            instructions: "Continue with the pending steering instructions.",
            vm: vm
        )
    }

    private func queueCurrentPrompt(taskID: UUID) {
        guard let task = appState.activeAgenticTask else { return }
        let prompt = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            artifactError = "Add a prompt before queueing the task."
            return
        }
        appState.updateTaskPrompt(taskID: taskID, prompt: prompt)
        guard appState.enqueueMacTask(
            taskID: taskID,
            prompt: prompt,
            attachmentIDs: (task.artifacts ?? []).map(\.id),
            providerID: agent.selectedEndpointID,
            model: agent.model,
            maxRounds: appState.maxAgentRounds(for: taskID),
            vmStatePolicy: .freshState,
            continueConversation: false
        ) != nil else {
            artifactError = "Could not add the task to the queue."
            return
        }
        queueTrayExpanded = true
    }

    private func chooseArtifacts(for taskID: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Attach artifacts to this Mac Task"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        artifactError = nil
        Task {
            do {
                _ = try await appState.addMacArtifactsAndSync(panel.urls, for: taskID)
            } catch {
                artifactError = error.localizedDescription
            }
        }
    }

    private func revealArtifactWorkspace(for taskID: UUID) {
        let directory = appState.artifactDirectory(for: taskID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func artifactIcon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp":
            return "photo"
        case "pdf": return "doc.richtext"
        case "json", "yaml", "yml", "toml", "xml": return "curlybraces"
        case "swift", "py", "js", "ts", "sh", "rb", "go", "rs", "java", "c", "cpp", "h", "m", "mm":
            return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz", "tgz", "xz", "7z": return "archivebox"
        case "md", "txt", "csv", "log": return "doc.text"
        default: return "doc"
        }
    }

    private func chooseRestoreImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a macOS restore image or folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        restoreImageError = nil
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )) ?? []
            if let image = contents
                .filter({ $0.pathExtension.lowercased() == "ipsw" })
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                .first {
                updateMacConfiguration { $0.restoreImagePath = image.path }
            } else {
                restoreImageError = "No .ipsw restore image was found in \(url.lastPathComponent)."
            }
        } else {
            updateMacConfiguration { $0.restoreImagePath = url.path }
        }
    }

    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label("Finish guest setup", systemImage: "info.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Colors.warning)
            Text("In the VM window, complete macOS Setup Assistant and sign in. Then open Finder → /Volumes/My Shared Files/tools → BUUVirtualMacGuest.app. Use its buttons to allow Screen Recording and Accessibility. The model loop cannot act until both are allowed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                .fill(Theme.Colors.warning.opacity(0.10))
        )
    }

    private func tabScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                content()
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var displayWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.s) {
                Text("Workspace")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("Layout", selection: $sideBySideDisplay) {
                    Text("Stacked").tag(false)
                    Text("Side by Side").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.m)
            .background(.bar)

            Divider()

            if sideBySideDisplay {
                HSplitView {
                    splitPane { displayContent }
                    splitPane { agentSection }
                }
            } else {
                VSplitView {
                    splitPane { displayContent }
                    splitPane { agentSection }
                }
            }
        }
    }

    private func splitPane<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 280, minHeight: 220)
    }

    @ViewBuilder
    private var displayContent: some View {
        if let machine = vm.virtualMachine {
            EmbeddedVirtualMachineView(machine: machine)
                .aspectRatio(displayAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, minHeight: 360)
                .background(Theme.Colors.control)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                        .strokeBorder(Theme.Colors.separator, lineWidth: 1)
                }
        } else if vm.vmState == "running" {
            // Fallback when the VM is owned outside this process.
            VirtualMacScreenshotCard()
        } else {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "macwindow")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(vm.isInstalling ? "Installing macOS…" : "No VM is running")
                    .font(.title3)
                Text("VM setup, start, pause and stop controls are in the Workspace tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Workspace") { selectedTab = .workspace }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            lifecycleSection

            HStack {
                Text("Task Activity")
                    .font(.title3.weight(.semibold))
                Spacer()
                if vm.isInstalling {
                    Label("Installing", systemImage: "gearshape.2")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.warning)
                } else if vm.vmState != "stopped" {
                    Label(vm.vmState, systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.success)
                }
            }

            logPanel(title: "VM / installation log", lines: vm.runtimeLog)
            logPanel(title: "Error log", lines: vm.errorLog)
        }
        .padding(Theme.Spacing.l)
        .background(cardBackground)
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack {
                Text("VM Configuration")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Open VM Profiles") {
                    appState.showSettings = true
                    appState.settingsSectionRequest = .vmProfiles
                }
            }

            if let configuration = macConfiguration {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    LabeledContent("Profile", value: configuration.name)
                    if let description = configuration.profileDescription, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("VM name", value: configuration.machineName)
                    LabeledContent("macOS", value: configuration.macOSVersion ?? "Latest compatible")
                    LabeledContent("Architecture", value: configuration.architecture ?? "arm64")
                    LabeledContent("Image type", value: configuration.imageType ?? "ipsw")
                    LabeledContent("Image source", value: configuration.restoreImagePath ?? "Download from Apple")
                    LabeledContent("Storage", value: configuration.storageLocation ?? "Application Support/BUU/VirtualMacs")
                    LabeledContent("CPU", value: "\(configuration.cpus) cores")
                    LabeledContent("Memory", value: "\(configuration.memoryGiB) GB")
                    LabeledContent("Disk", value: "\(configuration.diskGiB) GB")
                    LabeledContent("Artifact transfer limit", value: "\(configuration.artifactTransferLimitGiB ?? 2) GB")
                    LabeledContent("Network", value: configuration.network ? "NAT" : "Offline")
                    LabeledContent("Shared folder", value: (configuration.sharedFolderEnabled ?? true) ? "Enabled" : "Disabled")
                    LabeledContent("Display", value: "\(configuration.width) × \(configuration.height) @ \(configuration.scale)x")
                    LabeledContent("Graphics", value: configuration.graphicsMode ?? "automatic")
                }
                .font(.callout)
            } else {
                Text("No VM configuration selected.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Theme.Spacing.s) {
                Button("Open in Window") { vm.showWindow() }
                    .disabled(vm.vmState == "stopped")
                    .help("Show the live VM in a separate window")
                Button("Refresh VM list") { vm.refreshMachines() }
            }
        }
        .padding(Theme.Spacing.l)
        .background(cardBackground)
    }

    private func logPanel(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(lines.suffix(400).joined(separator: "\n"))
                    .font(Theme.Typography.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.s)
            }
            .frame(minHeight: 80, maxHeight: 180)
            .background(Theme.Colors.codeSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        }
    }

    private func noticeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Model-driven control")
                    .font(.title3.weight(.semibold))
                Spacer()
                if agent.isRunning {
                    Button("Cancel", role: .destructive) { agent.cancel() }
                }
            }

            Text("The selected model can call only the virtual Mac tools. It cannot run shell commands or touch the host.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: Theme.Spacing.s) {
                Picker("Provider", selection: Binding(
                    get: { agent.selectedEndpointID },
                    set: { agent.selectedEndpointID = $0 }
                )) {
                    ForEach(appState.settings.endpoints) { endpoint in
                        Text(endpoint.name).tag(Optional(endpoint.id))
                    }
                }
                .frame(maxWidth: 220)
                .onChange(of: agent.selectedEndpointID) {
                    guard let endpoint = selectedEndpoint else { return }
                    if agent.model.isEmpty { agent.model = endpoint.defaultModel }
                    Task { await agent.loadModels(endpoint: endpoint, apiKey: appState.apiKey(for: endpoint)) }
                }

                TextField("Model", text: Binding(
                    get: { agent.model },
                    set: { agent.model = $0 }
                ))
                .frame(maxWidth: 260)

                if agent.isLoadingModels {
                    ProgressView().controlSize(.small)
                } else if !agent.availableModels.isEmpty {
                    Menu("Choose") {
                        ForEach(agent.availableModels) { model in
                            Button(model.displayName) { agent.model = model.id }
                        }
                    }
                    .fixedSize()
                }

                Spacer()
            }

            if let error = agent.modelError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let taskID = appState.activeAgenticTask?.id {
                HStack(spacing: Theme.Spacing.s) {
                    Text("Max rounds")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Stepper(
                        value: Binding(
                            get: { appState.maxAgentRounds(for: taskID) ?? 0 },
                            set: { appState.setMaxAgentRounds($0 == 0 ? nil : $0, for: taskID) }
                        ),
                        in: 0...500
                    ) {
                        Text(appState.maxAgentRounds(for: taskID).map { "\($0)" } ?? "Unlimited")
                            .font(.caption)
                    }
                    Text("0 = unlimited")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            TextEditor(text: Binding(
                get: { agent.instructions },
                set: { agent.instructions = String($0.prefix(8000)) }
            ))
            .font(.body)
            .frame(minHeight: 90)
            .padding(Theme.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(Theme.Colors.control)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if agent.instructions.isEmpty {
                    Text("Open Safari, search for today's weather, and report the result.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Theme.Spacing.s + 4)
                        .padding(.vertical, Theme.Spacing.s + 1)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                guard let task = appState.activeAgenticTask else { return false }
                return handleArtifactDrop(providers, taskID: task.id)
            }

            if let task = appState.activeAgenticTask {
                artifactSection(task)
            }

            HStack(spacing: Theme.Spacing.s) {
                Button(agent.isRunning ? "Running…" : (agent.hasResumableSession ? "Resume loop" : "Run loop")) {
                    guard let endpoint = selectedEndpoint else { return }
                    if let task = appState.activeAgenticTask {
                        appState.updateTaskPrompt(taskID: task.id, prompt: agent.instructions)
                        appState.updateTaskStatus(taskID: task.id, status: "running")
                    }
                    steerDraft = ""
                    agent.start(
                        endpoint: endpoint,
                        apiKey: appState.apiKey(for: endpoint),
                        model: agent.model,
                        instructions: agent.instructions,
                        vm: vm
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    agent.isRunning
                        || appState.isWorkspaceQueueRunning
                        || appState.queueTransitionDeadline != nil
                        || agent.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || selectedEndpoint == nil
                )
                .help(appState.isWorkspaceQueueRunning ? "Pause or stop the workspace queue before starting a manual run." : "")

                Button("Clear context") {
                    confirmingClearContext = true
                }
                .disabled(!agent.hasContext || agent.isRunning)
                .help("Clear the saved agent loop and reasoning for this Mac Task")

                Button("Export current trace") {
                    exportMacLogs(.reasoning)
                }
                .disabled(appState.activeAgenticTask == nil)
                .help("Export the current reasoning and tool trace to a file")

                if let task = appState.activeAgenticTask {
                    Button("Queue task") { queueCurrentPrompt(taskID: task.id) }
                        .disabled(agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Add the current prompt and files to this workspace queue")
                }

                if !vm.canAct {
                    Text("The VM is not ready. The loop will report tool errors until the guest is running and permissions are allowed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            queueTray

            if !terminalSteerLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(terminalSteerLines.enumerated()), id: \.offset) { _, line in
                        SteerTraceRow(line: line)
                    }
                }
                .padding(Theme.Spacing.s)
                .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            }

            if !agent.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(agent.log.filter { !$0.hasPrefix("You steered") }.enumerated()), id: \.offset) { index, line in
                                SteerTraceRow(line: line)
                                    .id(index)
                            }
                        }
                        .padding(Theme.Spacing.s)
                    }
                    .frame(minHeight: 140, maxHeight: 300)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                            .fill(Theme.Colors.codeSurface)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                            .strokeBorder(Theme.Colors.separator, lineWidth: 1)
                    }
                    .onChange(of: agent.log.count) {
                        if let last = agent.log.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            steeringPane

            if let error = agent.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.danger)
            }
        }
        .padding(Theme.Spacing.l)
        .background(cardBackground)
    }

    // MARK: - Helpers

    private func loadPrompt(for task: AgenticTaskRecord?) {
        guard let task else { return }
        if agent.isRunning, agent.currentTaskID != task.id { agent.cancel() }
        artifactError = nil
        steerDraft = ""
        appState.macArtifactMessage = nil
        appState.macArtifactProgress.removeAll()
        agent.instructions = task.prompt ?? ""
        agent.loadSession(for: task)
    }

    private func persistPrompt(for task: AgenticTaskRecord?) {
        guard let task else { return }
        appState.updateTaskPrompt(taskID: task.id, prompt: agent.instructions)
    }

    private enum MacLogScope {
        case vm, errors, agent, reasoning, all
    }

    private func currentMacRoundLines() -> [String] {
        guard let task = appState.activeAgenticTask else { return [] }
        let parsed = MacTraceParser.parse(
            log: agent.log,
            toolCalls: agent.traceMessages.flatMap(\.toolCalls),
            screenshots: appState.macTraceScreenshots(for: task.id),
            runState: agent.runState,
            runStartedAt: agent.runStartedAt,
            finishedAt: task.lastRunAt
        )
        return MacTraceParser.exportLines(parsed)
    }

    private func exportMacLogs(_ scope: MacLogScope) {
        let agentLog = appState.virtualMacAgent.log
        let task = appState.activeAgenticTask
        let steerLines = LogExporter.steerLines(task?.steers ?? [])
        let queueLines = LogExporter.queuedTaskLines(task?.queuedTasks ?? [])
        let outputLines = (task?.outputs ?? []).map {
            "\($0.name) | \($0.byteCount) bytes | \($0.guestPath) | host=Outputs/\($0.hostFileName)"
        }
        var sections: [(String, [String])] = []
        switch scope {
        case .vm:
            sections = [("VM and installation log", vm.runtimeLog)]
        case .errors:
            sections = [("Error log", vm.errorLog)]
        case .agent:
            sections = [("Agent loop log", agentLog)]
        case .reasoning:
            sections = [
                ("Rounds", currentMacRoundLines()),
                ("Agent loop log", agentLog),
                ("Current reasoning trace", LogExporter.reasoningTraceLines(agent.traceMessages)),
                ("Steering and task queue", steerLines + queueLines),
                ("Guest outputs", outputLines),
            ]
        case .all:
            sections = [
                ("VM and installation log", vm.runtimeLog),
                ("Error log", vm.errorLog),
                ("Rounds", currentMacRoundLines()),
                ("Agent loop log", agentLog),
                ("Current reasoning trace", LogExporter.reasoningTraceLines(agent.traceMessages)),
                ("Steering and task queue", steerLines + queueLines),
                ("Guest outputs", outputLines),
            ]
        }
        if let error = LogExporter.export(
            title: "BUU Mac Task Logs",
            suggestedName: "BUU-MacTask.log",
            sections: sections
        ) {
            vm.errorMessage = error
        }
    }

    private func exportMacTraceJSON() {
        guard let task = appState.activeAgenticTask else { return }
        let payload = MacTraceExport(
            generatedAt: Date(),
            taskID: task.id,
            title: task.title,
            steers: task.steers ?? [],
            queuedTasks: task.queuedTasks ?? [],
            log: appState.virtualMacAgent.log,
            renderedTrace: currentMacRoundLines()
        )
        if let error = LogExporter.exportJSON(
            title: "Export Mac Task trace",
            suggestedName: "BUU-MacTask.json",
            value: payload
        ) {
            vm.errorMessage = error
        }
    }

    private var selectedEndpoint: ProviderEndpoint? {
        appState.settings.endpoints.first { $0.id == agent.selectedEndpointID }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            .fill(Theme.Colors.control)
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 1)
            }
    }
}

// MARK: - Screenshot card

private struct VirtualMacScreenshotCard: View {
    @Environment(AppState.self) private var appState
    @State private var textToSend = ""
    @State private var keyChord = "return"

    private var vm: VirtualMacController { appState.virtualMac }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                Text("Guest screen")
                    .font(.headline)
                Spacer()
                if let size = vm.screenshotSize {
                    Text("\(Int(size.width))×\(Int(size.height)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let image = vm.screenshotImage, let size = vm.screenshotSize {
                if vm.canAct {
                    ScreenshotInteractionView(image: image, pixelSize: size) { x, y in
                        Task {
                            do {
                                try await vm.click(x: x, y: y)
                                await vm.refreshScreenshot()
                            } catch {
                                vm.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .accessibilityLabel("Virtual Mac screenshot. Click to act.")
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
                        }
                }
            } else {
                Text(vm.screenshotError ?? "Waiting for the guest screen…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.l)
                    .background(Theme.Colors.control)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            }

            HStack(spacing: Theme.Spacing.s) {
                TextField("Type into the focused guest field", text: $textToSend)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendText() }
                Button("Send text") { sendText() }
                    .disabled(textToSend.isEmpty || !vm.canAct)
                Button("Return") { sendKey("return") }
                    .disabled(!vm.canAct)
                Button("Tab") { sendKey("tab") }
                    .disabled(!vm.canAct)
            }

            HStack(spacing: Theme.Spacing.s) {
                TextField("Key or chord", text: $keyChord)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Button("Send key") { sendKey(keyChord) }
                    .disabled(keyChord.isEmpty || !vm.canAct)
                Spacer()
            }
        }
        .padding(Theme.Spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .fill(Theme.Colors.control)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
        }
    }

    private func sendText() {
        let text = textToSend
        guard !text.isEmpty else { return }
        textToSend = ""
        Task {
            do {
                try await vm.typeText(text)
                await vm.refreshScreenshot()
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }

    private func sendKey(_ key: String) {
        Task {
            do {
                try await vm.key(key)
                await vm.refreshScreenshot()
            } catch {
                vm.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Chips

private struct VirtualMacStateChip: View {
    let state: String

    private var signal: (String, Color) {
        switch state {
        case "running": return ("running", Theme.Colors.success)
        case "paused": return ("paused", Theme.Colors.warning)
        case "starting", "resuming", "restoring": return ("starting", Theme.Colors.info)
        case "stopping", "saving": return ("stopping", Theme.Colors.warning)
        case "error": return ("error", Theme.Colors.danger)
        default: return ("stopped", .secondary)
        }
    }

    var body: some View {
        let value = signal
        HStack(spacing: Theme.Spacing.xs) {
            Circle().fill(value.1).frame(width: 6, height: 6)
            Text(value.0).font(.caption.weight(.medium))
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .foregroundStyle(value.1)
        .background(Capsule().fill(value.1.opacity(0.14)))
    }
}

private struct VirtualMacPermissionChip: View {
    let ready: Bool

    var body: some View {
        let color = ready ? Theme.Colors.success : Theme.Colors.warning
        HStack(spacing: Theme.Spacing.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(ready ? "guest ready" : "setup needed")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

