import AppKit
import Foundation
import Observation
import Virtualization
import VirtualMacCore

public struct VirtualMacOptions: Sendable {
    public var cpus: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var width: Int
    public var height: Int
    public var network: Bool
    public var scale: Int

    public init(
        cpus: Int = 4,
        memoryGiB: Int = 4,
        diskGiB: Int = 64,
        width: Int = 1280,
        height: Int = 800,
        network: Bool = true,
        scale: Int = 2
    ) {
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.width = width
        self.height = height
        self.network = network
        self.scale = scale
    }
}

public struct VirtualMacGuestStatus: Sendable, Equatable {
    public var screenRecording: Bool
    public var accessibility: Bool
    public var width: Int
    public var height: Int
    public var version: String
    public var build: String
    public var artifactSupport: Bool
    public var ip: String

    public init(values: [String: String]) {
        screenRecording = values["screenRecording"] == "true"
        accessibility = values["accessibility"] == "true"
        width = Int(values["width"] ?? "") ?? 0
        height = Int(values["height"] ?? "") ?? 0
        version = values["version"] ?? ""
        build = values["build"] ?? ""
        artifactSupport = values["artifactSupport"] == "true"
        ip = values["ip"] ?? ""
    }

    public var isReady: Bool { screenRecording && accessibility }
}

/// Owns the embedded Virtualization runtime and the guest mailbox for one VM.
///
/// The VM runs in-process, but all screen capture and input still happen in the
/// guest helper through the shared mailbox. BUU never calls host screen or
/// input APIs.
@MainActor
@Observable
public final class VirtualMacController {
    public var selectedName = "default"
    public var machines: [Machine] = []
    public var vmState = "stopped"
    public var guestStatus: VirtualMacGuestStatus?
    public var guestStatusError: String?
    public var guestStatusUpdatedAt: Date?
    public var startedAt: Date?
    public var errorMessage: String?
    public var statusMessage = ""
    public var isBusy = false
    public var isInstalling = false
    public var isDownloading = false
    public var downloadProgress: Double?
    public var downloadBytesWritten: Int64 = 0
    public var downloadTotalBytes: Int64 = 0
    public var downloadBytesPerSecond: Double?
    public var downloadETA: TimeInterval?
    public var downloadResumed = false
    public var runtimeLog: [String] = []
    public var errorLog: [String] = []
    public var screenshot: Data?
    public var screenshotImage: NSImage?
    public var screenshotSize: CGSize?
    public var screenshotError: String?
    public var windowVisible = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let injectedToolsURL: URL?
    @ObservationIgnored private var runtime: MachineRuntime?
    @ObservationIgnored private var restoreDownload: RestoreDownload?
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    public init(store: Store = Store(), toolsURL: URL? = nil) {
        self.store = store
        self.injectedToolsURL = toolsURL
        refreshMachines()
        VirtualMacLog.setSink { [weak self] message in
            Task { @MainActor in self?.appendRuntimeLog(message) }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restoreDownload?.cancel()
            }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        VirtualMacLog.setSink(nil)
    }

    public var selectedMachine: Machine? {
        machines.first { $0.name == selectedName }
    }

    public var canAct: Bool {
        vmState == "running" && guestStatus?.isReady == true
    }

    /// The live Virtualization VM object, for embedding `VZVirtualMachineView`
    /// directly in the Mac Task display.
    public var virtualMachine: VZVirtualMachine? { runtime?.vm }

    public var sharedFolderPath: String? {
        (try? store.directory(selectedName).appendingPathComponent("exchange").path)
    }

    public var machineDirectoryPath: String? {
        (try? store.directory(selectedName).path)
    }

    // MARK: - Machines

    public func refreshMachines() {
        let directory = store.root.appendingPathComponent("machines", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        machines = urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? store.load($0.lastPathComponent) }
        if selectedMachine == nil, let first = machines.first {
            selectedName = first.name
        }
    }

    /// Download (once), install if needed, then boot and open the guest window.
    public func prepareAndStart(
        name: String,
        restoreImage: URL?,
        options: VirtualMacOptions
    ) async {
        isBusy = true
        errorMessage = nil
        appendRuntimeLog("Preparing virtual Mac '\(name)'")
        var stage = "Preparing the virtual Mac"
        downloadProgress = nil
        downloadBytesWritten = 0
        downloadTotalBytes = 0
        downloadBytesPerSecond = nil
        downloadETA = nil
        downloadResumed = false
        defer {
            isBusy = false
            isInstalling = false
        }

        do {
            guard VZVirtualMachine.isSupported else {
                throw Failure("Virtualization is unavailable. Use an Apple silicon Mac and a signed BUU build.")
            }
            stage = "Checking the bundled guest helper"
            let tools = try toolsDirectory()
            guard FileManager.default.fileExists(atPath: tools.appendingPathComponent("BUUVirtualMacGuest.app").path) else {
                throw Failure("The guest helper is missing from this build. Rebuild BUU with Scripts/build-app.sh.")
            }

            var machine = try? store.load(name)
            if machine?.installed != true {
                isInstalling = true
                statusMessage = restoreImage == nil
                    ? "Finding a macOS restore image…"
                    : "Installing macOS…"
                stage = "Downloading the macOS restore image"
                let image = try await restoreImageURL(local: restoreImage)
                stage = "Installing macOS"
                statusMessage = "Installing macOS…"

                var input = [name, "--ipsw", image.path]
                input += ["--cpus", String(options.cpus)]
                input += ["--memory", String(options.memoryGiB)]
                input += ["--disk", String(options.diskGiB)]
                input += ["--width", String(options.width)]
                input += ["--height", String(options.height)]
                var flags: Set<String> = []
                if !options.network { flags.insert("offline") }
                if options.scale == 1 { flags.insert("standard") }
                let args = try Arguments(
                    input,
                    flags: flags,
                    options: ["ipsw", "cpus", "memory", "disk", "width", "height"]
                )
                try await VirtualMachines.create(args, store: store, retryIncomplete: true)
                machine = try store.load(name)
                statusMessage = "macOS installed. Releasing the installer…"
                refreshMachines()
                // terminal-mac starts the VM from a fresh process after install.
                // The embedded flow stays in the same process, so give the
                // installer's VZVirtualMachine time to release auxiliary.bin.
                try? await Task.sleep(for: .seconds(1))
            }

            guard let machine, machine.installed else {
                throw Failure("The virtual Mac installation did not complete.")
            }

            selectedName = name
            stage = "Starting the virtual Mac"
            try await start(name: name, show: false)
            await refreshGuestStatus()

            if guestStatus?.isReady == true {
                statusMessage = "Virtual Mac ready."
            } else {
                statusMessage = "Finish setup in the virtual Mac window: open the guest helper from /Volumes/My Shared Files/tools, then allow Screen Recording and Accessibility."
            }
            refreshMachines()
        } catch is CancellationError {
            statusMessage = "Download paused. The next attempt resumes from the saved partial download."
            downloadBytesPerSecond = nil
            downloadETA = nil
            appendRuntimeLog("Download paused")
        } catch {
            let detail = VirtualMacDiagnostics.describe(error, context: "\(stage) failed")
            errorMessage = detail
            statusMessage = ""
            appendError(detail)
        }
        isDownloading = false
        refreshMachines()
    }

    public func cancelRestoreDownload() {
        restoreDownload?.cancel()
    }

    private func runningElsewhereError(name: String, directory: URL) -> Failure? {
        guard MachineRuntime.isRunning(directory: directory) else { return nil }
        let pid = MachineRuntime.ownerPID(directory: directory).map { " (PID \($0))" } ?? ""
        return Failure(
            "Virtual Mac '\(name)' is already running in another process\(pid). "
            + "Quit the other BUU/terminal-mac instance that owns it, then try again."
        )
    }

    private func isAuxiliaryStorageLock(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.localizedDescription.localizedCaseInsensitiveContains("lock auxiliary storage") {
            return true
        }
        var current: NSError? = nsError
        var depth = 0
        while let value = current, depth < 4 {
            if value.domain == "NSPOSIXErrorDomain" && value.code == 35 { return true }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// Permanently delete a VM's disk and hardware files. The reusable Mac Task
    /// configuration is kept, so the VM can be recreated later.
    public func deleteMachine(name: String) throws {
        if runtime?.machine.name == name {
            throw Failure("Stop the virtual Mac before deleting it.")
        }
        let directory = try store.directory(name)
        if let error = runningElsewhereError(name: name, directory: directory) { throw error }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            refreshMachines()
            return
        }
        try FileManager.default.removeItem(at: directory)
        appendRuntimeLog("Deleted virtual Mac '\(name)' from disk")
        if selectedName == name {
            guestStatus = nil
            screenshot = nil
            screenshotImage = nil
            screenshotSize = nil
        }
        refreshMachines()
    }

    /// Remove a VM directory that never finished installing, so the next
    /// attempt can use the current configuration's disk size and restore image.
    public func discardIncompleteMachine(name: String) throws {
        if runtime?.machine.name == name {
            throw Failure("Stop the virtual Mac before discarding it.")
        }
        let machine = try? store.load(name)
        if machine?.installed == true {
            throw Failure("Refusing to discard an installed virtual Mac. Delete it manually if you really mean it.")
        }
        let directory = try store.directory(name)
        if let error = runningElsewhereError(name: name, directory: directory) { throw error }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        refreshMachines()
    }

    public func start(name: String, show: Bool) async throws {
        if let runtime {
            guard runtime.machine.name == name else {
                throw Failure("Stop '\(runtime.machine.name)' before starting '\(name)'.")
            }
            if show { runtime.showWindow() }
            refreshLifecycle()
            return
        }

        let machine = try store.load(name)
        guard machine.installed else {
            throw Failure("macOS is not installed in '\(name)' yet.")
        }
        let directory = try store.directory(name)
        if let error = runningElsewhereError(name: name, directory: directory) {
            throw error
        }

        selectedName = name
        for attempt in 0..<2 {
            do {
                let runtime = try MachineRuntime(
                    machine: machine,
                    directory: directory,
                    tools: try toolsDirectory()
                )
                runtime.onStateChange = { [weak self] in self?.refreshLifecycle() }
                self.runtime = runtime
                try await runtime.start(show: show)
                refreshLifecycle()
                return
            } catch {
                self.runtime?.teardown()
                self.runtime = nil
                if attempt == 0, isAuxiliaryStorageLock(error) {
                    // The installer or a just-stopped runtime can still be
                    // releasing its auxiliary-storage lock for a moment.
                    try? await Task.sleep(for: .milliseconds(750))
                    continue
                }
                let detail = VirtualMacDiagnostics.describe(error, context: "Starting the virtual Mac failed")
                appendError(detail)
                throw Failure(detail)
            }
        }
    }

    public func showWindow() {
        runtime?.showWindow()
        refreshLifecycle()
    }

    public func hideWindow() {
        runtime?.hideWindow()
        refreshLifecycle()
    }

    public func pause() async {
        do {
            try await runtime?.pause()
        } catch {
            let detail = VirtualMacDiagnostics.describe(error, context: "Pausing the virtual Mac failed")
            errorMessage = detail
            appendError(detail)
        }
        refreshLifecycle()
    }

    public func resume() async {
        do {
            try await runtime?.resume()
        } catch {
            let detail = VirtualMacDiagnostics.describe(error, context: "Resuming the virtual Mac failed")
            errorMessage = detail
            appendError(detail)
        }
        refreshLifecycle()
    }

    public func stop(force: Bool) async {
        do {
            try await runtime?.requestStop(force: force)
        } catch {
            let detail = VirtualMacDiagnostics.describe(error, context: "Stopping the virtual Mac failed")
            errorMessage = detail
            appendError(detail)
        }
        refreshLifecycle()
    }

    public func refreshLifecycle() {
        let state = runtime?.stateName ?? "stopped"
        if vmState != state {
            appendRuntimeLog("VM state: \(state)")
        }
        vmState = state
        if state == "running" {
            if startedAt == nil { startedAt = Date() }
        } else {
            startedAt = nil
        }
        windowVisible = runtime?.window?.isVisible == true
        if state == "stopped" || state == "error" {
            runtime?.teardown()
            runtime = nil
            guestStatus = nil
            guestStatusUpdatedAt = nil
            screenshot = nil
            screenshotImage = nil
            screenshotSize = nil
        }
    }

    // MARK: - Guest status and screenshots

    public func refreshGuestStatus() async {
        guard runtime?.stateName == "running" else {
            guestStatus = nil
            guestStatusUpdatedAt = nil
            return
        }
        do {
            let reply = try await call(Request(action: "status", timeout: 3))
            guestStatus = VirtualMacGuestStatus(values: reply.values)
            guestStatusError = nil
            guestStatusUpdatedAt = Date()
        } catch {
            guestStatus = nil
            guestStatusError = error.localizedDescription
            guestStatusUpdatedAt = Date()
        }
    }

    @discardableResult
    public func refreshScreenshot() async -> Data? {
        do {
            return try await captureScreenshot()
        } catch {
            screenshotError = error.localizedDescription
            return nil
        }
    }

    public func captureScreenshot() async throws -> Data {
        guard runtime?.stateName == "running" else {
            throw Failure("The virtual Mac is not running.")
        }
        let mailbox = try Mailbox(try store.directory(selectedName).appendingPathComponent("exchange"))
        let request = Request(action: "screenshot", timeout: 15)
        let imageName = "image-\(request.id.uuidString).png"
        defer { mailbox.remove(imageName) }
        let reply = try await mailbox.call(request)
        guard reply.values["image"] == imageName,
              let png = try mailbox.read(imageName, limit: 32 * 1024 * 1024) else {
            throw Failure("The guest helper returned an invalid screenshot.")
        }
        screenshot = png
        screenshotImage = NSImage(data: png)
        if let rep = NSBitmapImageRep(data: png) {
            screenshotSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else if let image = screenshotImage {
            screenshotSize = image.size
        }
        screenshotError = nil
        return png
    }

    // MARK: - Guest actions

    public func click(x: Int, y: Int, button: String? = nil, clicks: Int = 1) async throws {
        var args = ["x": String(x), "y": String(y)]
        if let button { args["button"] = button }
        if clicks > 1 { args["count"] = String(min(clicks, 3)) }
        _ = try await call(Request(action: "click", arguments: args, timeout: 10))
    }

    public func move(x: Int, y: Int) async throws {
        _ = try await call(Request(action: "move", arguments: ["x": String(x), "y": String(y)], timeout: 10))
    }

    public func drag(x: Int, y: Int, toX: Int, toY: Int) async throws {
        _ = try await call(Request(action: "drag", arguments: [
            "x": String(x), "y": String(y), "x2": String(toX), "y2": String(toY),
        ], timeout: 15))
    }

    public func scroll(x: Int, y: Int, dy: Int, dx: Int = 0) async throws {
        _ = try await call(Request(action: "scroll", arguments: [
            "x": String(x), "y": String(y), "dy": String(dy), "dx": String(dx),
        ], timeout: 10))
    }

    public func typeText(_ text: String) async throws {
        _ = try await call(Request(action: "type", arguments: ["text": text], timeout: 30))
    }

    public func key(_ chord: String) async throws {
        _ = try await call(Request(action: "key", arguments: ["key": chord], timeout: 10))
    }

    // MARK: - Guest artifacts

    public func guestArtifactFolders() async throws -> GuestArtifactFolders {
        try await artifactClient().ensureFolders()
    }

    public func guestPutArtifact(
        hostURL: URL,
        name: String,
        root: String = "artifacts",
        transferID: String,
        limit: Int64 = GuestArtifactClient.defaultTransferLimit,
        sha256: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> GuestUploadResult {
        try await artifactClient().put(
            hostURL: hostURL,
            name: name,
            root: root,
            transferID: transferID,
            limit: limit,
            sha256: sha256,
            progress: progress
        )
    }

    public func guestPutData(
        _ data: Data,
        name: String,
        root: String = "outputs",
        transferID: String,
        limit: Int64 = GuestArtifactClient.defaultTransferLimit,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> GuestUploadResult {
        try await artifactClient().put(
            data: data,
            name: name,
            root: root,
            transferID: transferID,
            limit: limit,
            progress: progress
        )
    }

    public func guestDeleteArtifact(path: String) async throws {
        try await artifactClient().delete(path: path)
    }

    public func guestListArtifacts(root: String) async throws -> [GuestFileInfo] {
        try await artifactClient().list(root: root)
    }

    public func guestOpenArtifact(path: String, app: String? = nil) async throws -> GuestOpenResult {
        try await artifactClient().open(path: path, app: app)
    }

    public func guestRevealArtifact(path: String) async throws {
        try await artifactClient().reveal(path: path)
    }

    public func guestOpenArtifactsFolder(root: String = "artifacts") async throws {
        try await artifactClient().openFolder(root: root)
    }

    public func guestReadArtifact(path: String) async throws -> GuestReadResult {
        try await artifactClient().read(path: path)
    }

    public func guestExtractArtifactText(path: String, pages: String? = nil) async throws -> GuestTextResult {
        try await artifactClient().extractText(path: path, pages: pages)
    }

    public func guestFetchOutput(
        path: String,
        to destination: URL,
        limit: Int64 = GuestArtifactClient.defaultTransferLimit,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> GuestFileInfo {
        try await artifactClient().fetch(path: path, to: destination, limit: limit, progress: progress)
    }

    public func guestFrontmostApp() async throws -> GuestFrontmostApp {
        try await artifactClient().frontmostApp()
    }

    public func guestListWindows() async throws -> [GuestWindowInfo] {
        try await artifactClient().windows()
    }

    public func consumeGuestOutputsDirty() throws -> Bool {
        try artifactClient().consumeOutputsDirty()
    }

    private func artifactClient() throws -> GuestArtifactClient {
        guard runtime?.stateName == "running" else {
            throw Failure("The virtual Mac is not running.")
        }
        let exchange = try store.directory(selectedName).appendingPathComponent("exchange")
        return GuestArtifactClient(exchange: exchange)
    }

    // MARK: - Logs

    private func appendRuntimeLog(_ message: String) {
        let entry = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
        runtimeLog.append(entry)
        if runtimeLog.count > 2_000 {
            runtimeLog.removeFirst(runtimeLog.count - 2_000)
        }
    }

    /// Record a guest/workspace diagnostic in the public error log without
    /// opening an alert. Used for transient conditions such as an unreachable
    /// guest helper.
    public func noteError(_ message: String) {
        appendError(message)
    }

    private func appendError(_ message: String) {
        let entry = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
        errorLog.append(entry)
        if errorLog.count > 1_000 {
            errorLog.removeFirst(errorLog.count - 1_000)
        }
        appendRuntimeLog("ERROR: \(message)")
    }

    // MARK: - Internals

    private func call(_ request: Request) async throws -> Reply {
        guard runtime?.stateName == "running" else {
            throw Failure("The virtual Mac is not running.")
        }
        let mailbox = try Mailbox(try store.directory(selectedName).appendingPathComponent("exchange"))
        return try await mailbox.call(request)
    }

    private func toolsDirectory() throws -> URL {
        if let injectedToolsURL { return injectedToolsURL }
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("guest-tools")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw Failure("The virtual Mac guest helper is not bundled with this build.")
    }

    private func restoreImageURL(local: URL?) async throws -> URL {
        if let local {
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw Failure("Restore image does not exist: \(local.path)")
            }
            return local
        }

        let cache = store.root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try FileLock(cache.appendingPathComponent("download.lock"))
        defer { withExtendedLifetime(lock) {} }

        statusMessage = "Checking Apple's compatible macOS restore image…"
        let image = try await VZMacOSRestoreImage.latestSupported
        guard image.buildVersion.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              image.url.scheme == "https" else {
            throw Failure("Unexpected Apple restore-image metadata.")
        }
        let destination = cache.appendingPathComponent("macOS-\(image.buildVersion).ipsw")
        if FileManager.default.fileExists(atPath: destination.path) {
            if let cached = try? await VZMacOSRestoreImage.image(from: destination),
               cached.buildVersion == image.buildVersion,
               cached.mostFeaturefulSupportedConfiguration != nil {
                statusMessage = "Using the cached macOS restore image."
                return destination
            }
            try FileManager.default.removeItem(at: destination)
        }

        let download = RestoreDownload(destination: destination)
        downloadResumed = download.hasResumeData
        isDownloading = true
        downloadProgress = downloadResumed ? 0 : 0
        downloadBytesWritten = 0
        downloadTotalBytes = 0
        downloadBytesPerSecond = nil
        downloadETA = nil
        statusMessage = downloadResumed
            ? "Resuming the macOS download…"
            : "Downloading macOS from Apple (several GB)…"
        download.onResume = { [weak self] in
            Task { @MainActor in
                self?.downloadResumed = true
                self?.statusMessage = "Resuming the macOS download…"
            }
        }
        download.onProgress = { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.downloadProgress = progress.fraction
                self.downloadBytesWritten = progress.bytesWritten
                self.downloadTotalBytes = progress.totalBytes
                self.downloadBytesPerSecond = progress.bytesPerSecond
                self.downloadETA = progress.etaSeconds
                self.isDownloading = true
            }
        }
        restoreDownload = download
        defer {
            restoreDownload = nil
            isDownloading = false
        }
        let result = try await download.run(from: image.url)
        downloadProgress = 1
        downloadBytesPerSecond = nil
        downloadETA = nil
        statusMessage = "Verifying the macOS restore image…"
        let verified = try await VZMacOSRestoreImage.image(from: result)
        guard verified.buildVersion == image.buildVersion,
              verified.mostFeaturefulSupportedConfiguration != nil else {
            throw Failure("The downloaded restore image is not compatible with this Mac.")
        }
        downloadProgress = nil
        downloadBytesWritten = 0
        downloadTotalBytes = 0
        downloadBytesPerSecond = nil
        downloadETA = nil
        downloadResumed = false
        return result
    }
}
