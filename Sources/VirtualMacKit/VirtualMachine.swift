import AppKit
import Virtualization
import VirtualMacCore
import Darwin

@MainActor
enum VirtualMachines {
    static func configuration(_ machine: Machine, at directory: URL, tools: URL?) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = VZMacOSBootLoader()
        config.cpuCount = machine.cpu
        config.memorySize = UInt64(machine.memoryGiB) * 1024 * 1024 * 1024
        let platform = VZMacPlatformConfiguration()
        guard let hardware = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("hardware.bin"))), hardware.isSupported,
              let identity = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("identity.bin"))) else {
            throw Failure("This VM hardware model is not supported on this Mac")
        }
        platform.hardwareModel = hardware
        platform.machineIdentifier = identity
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: directory.appendingPathComponent("auxiliary.bin"))
        config.platform = platform
        let attachment = try VZDiskImageStorageDeviceAttachment(url: directory.appendingPathComponent("disk.img"), readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        let graphics = VZMacGraphicsDeviceConfiguration()
        // At 220 ppi macOS picks a 2x Retina mode, so the desktop keeps its point size with sharp text.
        let scale = machine.displayScale
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: machine.width * scale, heightInPixels: machine.height * scale, pixelsPerInch: scale == 2 ? 220 : 80)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        if machine.network {
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [network]
        }
        var shares: [String: VZSharedDirectory] = ["control": VZSharedDirectory(url: directory.appendingPathComponent("exchange"), readOnly: false)]
        if let tools { shares["tools"] = VZSharedDirectory(url: tools, readOnly: true) }
        let filesystem = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        filesystem.share = VZMultipleDirectoryShare(directories: shares)
        config.directorySharingDevices = [filesystem]
        try config.validate()
        return config
    }

    static func create(_ args: Arguments, store: Store, retryIncomplete: Bool = false) async throws {
        guard VZVirtualMachine.isSupported else { throw Failure("Virtualization is unavailable. Use an Apple silicon Mac and the signed build.") }
        let name = try args.machineName()
        guard let ipsw = args.options["ipsw"] else { throw Failure("Provide --ipsw /path/to/restore.ipsw. Choose a macOS restore image in BUU.") }
        let imageURL = URL(fileURLWithPath: (ipsw as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: imageURL.path) else { throw Failure("Restore image does not exist: \(imageURL.path)") }
        let directory = try store.directory(name)
        let image = try await VZMacOSRestoreImage.image(from: imageURL)
        guard let requirements = image.mostFeaturefulSupportedConfiguration else { throw Failure("This restore image is not supported by this Mac") }
        if FileManager.default.fileExists(atPath: directory.path) {
            guard retryIncomplete, let partial = try? store.load(name), !partial.installed,
                  try Data(contentsOf: directory.appendingPathComponent("hardware.bin")) == requirements.hardwareModel.dataRepresentation else {
                throw Failure("VM directory already exists and cannot be automatically retried: \(directory.path). It will not be overwritten.")
            }
            stderr("Retrying the incomplete macOS installation for '\(name)' with its existing hardware and disk.")
            try await install(partial, at: directory, imageURL: imageURL, store: store)
            return
        }
        let minMemory = Int((requirements.minimumSupportedMemorySize + 1_073_741_823) / 1_073_741_824)
        let cpu = try args.integer("cpus", default: max(requirements.minimumSupportedCPUCount, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)), range: requirements.minimumSupportedCPUCount...VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let memory = try args.integer("memory", default: max(4, minMemory), range: minMemory...Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / 1_073_741_824))
        let disk = try args.integer("disk", default: 64, range: 32...2048)
        let width = try args.integer("width", default: 1280, range: 800...3840)
        let height = try args.integer("height", default: 800, range: 600...2160)
        let machine = Machine(name: name, cpu: cpu, memoryGiB: memory, diskGiB: disk, width: width, height: height, network: !args.flags.contains("offline"),
                              scale: args.flags.contains("standard") ? 1 : 2)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try Mailbox(directory.appendingPathComponent("exchange"), create: true)
        try requirements.hardwareModel.dataRepresentation.write(to: directory.appendingPathComponent("hardware.bin"))
        try VZMacMachineIdentifier().dataRepresentation.write(to: directory.appendingPathComponent("identity.bin"))
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: directory.appendingPathComponent("auxiliary.bin"), hardwareModel: requirements.hardwareModel, options: [])
        let diskURL = directory.appendingPathComponent("disk.img")
        guard FileManager.default.createFile(atPath: diskURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure("Cannot create disk image") }
        let file = try FileHandle(forWritingTo: diskURL)
        try file.truncate(atOffset: UInt64(disk) * 1_073_741_824)
        try file.close()
        try store.save(machine)
        try await install(machine, at: directory, imageURL: imageURL, store: store)
    }
    private static func install(_ original: Machine, at directory: URL, imageURL: URL, store: Store) async throws {
        var machine = original
        let vm = VZVirtualMachine(configuration: try configuration(machine, at: directory, tools: nil))
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
        stderr("Installing macOS into '\(machine.name)' (\(machine.cpu) CPUs, \(machine.memoryGiB) GiB RAM, \(machine.diskGiB) GiB sparse disk)…")
        var lastProgress = 0.0
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            lastProgress = progress.fractionCompleted
            stderr(String(format: "Installation: %.0f%%", progress.fractionCompleted * 100))
        }
        defer { observation.invalidate() }
        do {
            try await installer.install()
        } catch {
            let percent = Int((lastProgress * 100).rounded())
            throw Failure(VirtualMacDiagnostics.describe(
                error,
                context: "Installing macOS into '\(machine.name)' failed at \(percent)%"
            ))
        }
        machine.installed = true
        try store.save(machine)
        stderr("macOS is installed in '\(machine.name)'.")
    }
}

@MainActor
final class MachineRuntime: NSObject, VZVirtualMachineDelegate, NSWindowDelegate {
    let vm: VZVirtualMachine
    let machine: Machine
    let lock: Int32
    let pidURL: URL
    var window: NSWindow?
    var stopping = false
    var stopDeadline: Date?
    /// Called whenever the VM or its window changes state.
    var onStateChange: (() -> Void)?

    init(machine: Machine, directory: URL, tools: URL) throws {
        self.machine = machine
        lock = open(directory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure("Cannot open VM lock") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw Failure("This virtual Mac is already running") }
        pidURL = directory.appendingPathComponent("runtime.pid")
        vm = VZVirtualMachine(configuration: try VirtualMachines.configuration(machine, at: directory, tools: tools))
        super.init()
        vm.delegate = self
        try? Data(String(getpid()).utf8).write(to: pidURL, options: .atomic)
    }
    deinit {
        try? FileManager.default.removeItem(at: pidURL)
        close(lock)
    }

    /// Whether another process currently owns this VM's runtime lock.
    static func isRunning(directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent("runtime.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    static func ownerPID(directory: URL) -> Int32? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("runtime.pid")),
              let value = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return value
    }

    func start(show: Bool) async throws {
        try await vm.start()
        stderr("Virtual Mac '\(machine.name)' is running.")
        onStateChange?()
        if show { showWindow() }
    }

    /// Release the window and VM delegate before dropping the runtime. A window
    /// that still references VZVirtualMachineView can keep the VM object (and
    /// its auxiliary-storage lock) alive after a failed start.
    func teardown() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        vm.delegate = nil
        onStateChange = nil
    }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            onStateChange?()
            return
        }
        NSApp.setActivationPolicy(.regular)
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: machine.width, height: machine.height))
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BUU Virtual Mac · \(machine.name)"
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        onStateChange?()
    }

    func hideWindow() {
        // Only hide the VM window; NSApp.hide would also hide BUU's chat window.
        window?.orderOut(nil)
        onStateChange?()
    }

    func pause() async throws {
        try await vm.pause()
        onStateChange?()
    }

    func resume() async throws {
        try await vm.resume()
        onStateChange?()
    }

    /// `force` immediately powers off; otherwise macOS is asked to shut down.
    func requestStop(force: Bool) async throws {
        if force {
            try await vm.stop()
            onStateChange?()
            return
        }
        guard !stopping else { throw Failure("Shutdown is already in progress") }
        try vm.requestStop()
        stopping = true
        stopDeadline = Date().addingTimeInterval(60)
        onStateChange?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    var stateName: String {
        switch vm.state {
        case .stopped: return "stopped"
        case .running: return stopping ? "stopping" : "running"
        case .paused: return "paused"
        case .starting: return "starting"
        case .pausing: return "pausing"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .saving: return "saving"
        case .restoring: return "restoring"
        case .error: return "error"
        @unknown default: return "unknown"
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stderr("Virtual Mac guest shut down.")
        Task { @MainActor [weak self] in self?.onStateChange?() }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stderr("Virtual Mac stopped: \(error.localizedDescription)")
        Task { @MainActor [weak self] in self?.onStateChange?() }
    }
}

func stderr(_ message: String) {
    VirtualMacLog.record(message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
